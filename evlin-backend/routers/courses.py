"""Courses: shared vetted video content + per-child progress through it.

The split (see models.py's Course) is the point of this module — vetting is
expensive and happens once per course, assignment is cheap and happens per
child. Everything that needs "has this child finished this course" — a
reflection, a special task, a milestone — goes through
course_assignment_fully_completed rather than reimplementing it.

Nothing reaches a child from an unapproved course: the AI proposes, a parent
approves, and only then does an assignment exist. Same proposes-then-confirms
boundary as every other AI-initiated write in this backend.
"""
import json
from datetime import datetime, timezone
from typing import Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.security import HTTPAuthorizationCredentials
from sqlalchemy.orm import Session

import models
import schemas
from access import assert_child_access, assert_parent_owns_child, check_child_access
from database import get_db
from gemini_client import gemini_configured, generate
from routers.auth import get_current_parent, security
from youtube_client import search_with_details, youtube_configured

router = APIRouter(tags=["courses"])


# ---- shared helpers other features build on -----------------------------

def assign_course(db: Session, course_id: UUID, child_id: UUID,
                  assigned_by: str = "parent") -> models.CourseAssignment:
    """Give one child their own progress track through a course.

    Seeds one progress row per item: the first unlocked, the rest locked.
    Doesn't commit — callers fold this into their own single commit, same
    convention as award_time_grant.
    """
    course = db.query(models.Course).filter(models.Course.id == course_id).first()
    if not course:
        raise HTTPException(status_code=404, detail="Course not found")
    if course.status != "published":
        raise HTTPException(status_code=400, detail="Course hasn't been approved yet")

    assignment = models.CourseAssignment(
        course_id=course_id, child_id=child_id, assigned_by=assigned_by,
    )
    db.add(assignment)
    db.flush()  # need assignment.id for the progress rows below

    items = db.query(models.CourseItem).filter(
        models.CourseItem.course_id == course_id
    ).order_by(models.CourseItem.order_index).all()
    for position, item in enumerate(items):
        db.add(models.CourseItemProgress(
            assignment_id=assignment.id,
            course_item_id=item.id,
            status="available" if position == 0 else "locked",
        ))
    return assignment


def create_single_video_course(
    db: Session,
    video_id: str,
    video_title: Optional[str] = None,
    channel_title: Optional[str] = None,
    quiz: Optional[list] = None,
    title: Optional[str] = None,
    created_by_parent_id: Optional[UUID] = None,
) -> models.Course:
    """A parent picking one specific video: published immediately, no vetting
    pass and no approval step, because they chose it themselves. Still a real
    course, so it's reusable from the library and every consumer reads it the
    same way as a generated one. Doesn't commit."""
    course = models.Course(
        title=title or video_title or "Video",
        status="published",
        created_by="parent",
        created_by_parent_id=created_by_parent_id,
        published_at=datetime.now(timezone.utc),
    )
    db.add(course)
    db.flush()
    db.add(models.CourseItem(
        course_id=course.id, order_index=0, video_id=video_id,
        video_title=video_title, channel_title=channel_title,
        quiz=quiz or [],
    ))
    return course


def course_assignment_fully_completed(db: Session, assignment_id: UUID) -> bool:
    """Every item done. The one definition of "finished this course" —
    reflections, special tasks and milestones all ask this rather than each
    deciding for themselves."""
    rows = db.query(models.CourseItemProgress).filter(
        models.CourseItemProgress.assignment_id == assignment_id
    ).all()
    return bool(rows) and all(r.status == "completed" for r in rows)


# ---- generation + vetting ------------------------------------------------

_PROPOSE_COURSE_TOOL = {
    "name": "propose_course",
    "description": "Propose a vetted, ordered course built ONLY from the candidate videos provided.",
    "parameters": {
        "type": "OBJECT",
        "properties": {
            "title": {"type": "STRING", "description": "Short course title"},
            "items": {
                "type": "ARRAY",
                "description": "Chosen videos, in teaching order",
                "items": {
                    "type": "OBJECT",
                    "properties": {
                        "video_id": {"type": "STRING", "description": "Must be one of the candidate video ids"},
                        "reason": {"type": "STRING", "description": "Why this is safe and on-topic for this child"},
                        "quiz": {
                            "type": "ARRAY",
                            "description": "1-3 comprehension questions about this video",
                            "items": {
                                "type": "OBJECT",
                                "properties": {
                                    "question": {"type": "STRING"},
                                    "options": {"type": "ARRAY", "items": {"type": "STRING"}},
                                    "correct_index": {"type": "INTEGER"},
                                },
                                "required": ["question", "options", "correct_index"],
                            },
                        },
                    },
                    "required": ["video_id", "reason"],
                },
            },
        },
        "required": ["title", "items"],
    },
}


def _vetting_prompt(topic: str, video_count: int, child: Optional[models.Child]) -> str:
    who = "a child"
    if child is not None:
        who = child.name
        if child.birth_year:
            age = datetime.now(timezone.utc).year - child.birth_year
            who = f"{child.name} (about {age} years old)"
    return (
        f"You are vetting YouTube videos to build a short course on \"{topic}\" for {who}.\n"
        f"Pick at most {video_count} videos from the candidate list and put them in a sensible teaching order.\n"
        "Rules you must follow:\n"
        "- Only ever use video ids from the candidate list. Never invent an id or suggest a video that isn't listed.\n"
        "- Reject anything not clearly age-appropriate, not clearly educational, or off-topic — it is correct to "
        "return fewer videos than asked for, or none at all, rather than pad the course with something unsuitable.\n"
        "- Prefer videos flagged made_for_kids, from recognisable educational channels, and of a sane length.\n"
        "- For each pick, give a short concrete reason a parent can check (age-appropriateness, channel, topic match).\n"
        "- Write 1-3 simple comprehension questions per video, answerable from watching it, with the correct option "
        "marked by its zero-based index.\n"
        "Call propose_course with your choice. Do not reply with prose."
    )


def _candidates_message(candidates: list[dict]) -> str:
    trimmed = [
        {
            "video_id": c["video_id"],
            "title": c.get("title"),
            "channel_title": c.get("channel_title"),
            "description": (c.get("description") or "")[:300],
            "duration": c.get("duration"),
            "made_for_kids": c.get("made_for_kids"),
            "content_rating": c.get("content_rating"),
        }
        for c in candidates
    ]
    return "Candidate videos:\n" + json.dumps(trimmed, indent=2)


async def generate_and_vet_course(
    db: Session,
    topic: str,
    video_count: int = 4,
    child: Optional[models.Child] = None,
    created_by_parent_id: Optional[UUID] = None,
) -> models.Course:
    """Real YouTube search -> real metadata -> an LLM safety/ordering pass ->
    a draft course awaiting parent approval. Doesn't commit.

    The model only ever picks from candidates we actually found: anything it
    returns that isn't a real candidate id is dropped rather than trusted,
    so a hallucinated video can't reach the approval card, let alone a child.
    """
    if not youtube_configured():
        raise HTTPException(status_code=503, detail="Course search isn't configured yet (no YOUTUBE_API_KEY)")
    if not gemini_configured():
        raise HTTPException(status_code=503, detail="Course vetting isn't configured yet (no GEMINI_API_KEY)")

    try:
        candidates = await search_with_details(topic, max_results=max(8, video_count * 3))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"YouTube search failed: {e}")
    if not candidates:
        raise HTTPException(status_code=404, detail=f"No usable videos found for \"{topic}\"")

    try:
        _text, call = await generate(
            _vetting_prompt(topic, video_count, child),
            [{"role": "user", "text": _candidates_message(candidates)}],
            tools=[_PROPOSE_COURSE_TOOL],
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Course vetting failed: {e}")

    if call is None or call.name != "propose_course":
        raise HTTPException(status_code=502, detail="Vetting didn't return a course proposal")

    by_id = {c["video_id"]: c for c in candidates}
    chosen = []
    for raw in (call.args.get("items") or []):
        candidate = by_id.get(raw.get("video_id"))
        if candidate is None:
            continue  # not a real search result — never trust an invented id
        chosen.append((candidate, raw))
        if len(chosen) >= video_count:
            break
    if not chosen:
        raise HTTPException(status_code=502, detail="Vetting rejected every candidate video")

    course = models.Course(
        title=(call.args.get("title") or topic).strip()[:200],
        topic=topic,
        status="pending_review",
        created_by="ai_agent",
        created_by_parent_id=created_by_parent_id,
    )
    db.add(course)
    db.flush()
    for order_index, (candidate, raw) in enumerate(chosen):
        db.add(models.CourseItem(
            course_id=course.id,
            order_index=order_index,
            video_id=candidate["video_id"],
            video_title=candidate.get("title"),
            channel_title=candidate.get("channel_title"),
            vetting_notes=raw.get("reason"),
            quiz=raw.get("quiz") or [],
        ))
    return course


# ---- serialization -------------------------------------------------------

def _course_response(db: Session, course: models.Course) -> schemas.CourseResponse:
    items = db.query(models.CourseItem).filter(
        models.CourseItem.course_id == course.id
    ).order_by(models.CourseItem.order_index).all()
    body = schemas.CourseResponse.model_validate(course)
    body.items = [schemas.CourseItemResponse.model_validate(i) for i in items]
    return body


def _assignment_response(db: Session, assignment: models.CourseAssignment) -> schemas.CourseAssignmentResponse:
    course = db.query(models.Course).filter(models.Course.id == assignment.course_id).first()
    progress = db.query(models.CourseItemProgress).filter(
        models.CourseItemProgress.assignment_id == assignment.id
    ).all()
    body = schemas.CourseAssignmentResponse.model_validate(assignment)
    body.course = _course_response(db, course) if course else None
    body.progress = [schemas.CourseItemProgressResponse.model_validate(p) for p in progress]
    return body


# ---- routes --------------------------------------------------------------

@router.get("/youtube/search")
async def youtube_search(q: str = Query(..., min_length=1),
                         current_parent: models.Parent = Depends(get_current_parent)):
    """Parent-side authoring tool: pick one specific video without the full
    vetting pipeline. Parent-only — a kid's device never calls this."""
    if not youtube_configured():
        raise HTTPException(status_code=503, detail="Video search isn't configured yet (no YOUTUBE_API_KEY)")
    try:
        return await search_with_details(q, max_results=10)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"YouTube search failed: {e}")


@router.get("/courses", response_model=list[schemas.CourseResponse])
def list_courses(status: str = Query("published"),
                 current_parent: models.Parent = Depends(get_current_parent),
                 db: Session = Depends(get_db)):
    """The shared library. Not child-scoped — that's the whole point."""
    courses = db.query(models.Course).filter(
        models.Course.status == status
    ).order_by(models.Course.created_at.desc()).all()
    return [_course_response(db, c) for c in courses]


@router.get("/courses/{course_id}", response_model=schemas.CourseResponse)
def get_course(course_id: UUID,
               current_parent: models.Parent = Depends(get_current_parent),
               db: Session = Depends(get_db)):
    course = db.query(models.Course).filter(models.Course.id == course_id).first()
    if not course:
        raise HTTPException(status_code=404, detail="Course not found")
    return _course_response(db, course)


@router.post("/courses/generate", response_model=schemas.CourseResponse)
async def generate_course(body: schemas.CourseGenerateRequest,
                          current_parent: models.Parent = Depends(get_current_parent),
                          db: Session = Depends(get_db)):
    """Search, vet, and save a draft course. Returns it pending_review —
    nothing is assigned to any child until a parent approves it."""
    child = None
    if body.child_id is not None:
        assert_parent_owns_child(db, current_parent, body.child_id)
        child = db.query(models.Child).filter(models.Child.id == body.child_id).first()

    course = await generate_and_vet_course(
        db, body.topic, video_count=body.video_count, child=child,
        created_by_parent_id=current_parent.id,
    )
    db.commit()
    db.refresh(course)
    return _course_response(db, course)


@router.post("/courses/single-video", response_model=schemas.CourseResponse)
def create_course_from_one_video(body: schemas.SingleVideoCourseRequest,
                                 current_parent: models.Parent = Depends(get_current_parent),
                                 db: Session = Depends(get_db)):
    course = create_single_video_course(
        db, body.video_id, video_title=body.video_title, channel_title=body.channel_title,
        quiz=body.quiz, title=body.title, created_by_parent_id=current_parent.id,
    )
    db.commit()
    db.refresh(course)
    return _course_response(db, course)


@router.put("/courses/{course_id}/approve", response_model=schemas.CourseResponse)
def approve_course(course_id: UUID, body: schemas.CourseApproveRequest,
                   current_parent: models.Parent = Depends(get_current_parent),
                   db: Session = Depends(get_db)):
    """Publish a drafted course to the library, and (when asked) assign it to
    the child it was generated for — one tap, one transaction, rather than
    leaving a published-but-unassigned course behind on a failed second call."""
    course = db.query(models.Course).filter(models.Course.id == course_id).first()
    if not course:
        raise HTTPException(status_code=404, detail="Course not found")

    if course.status != "published":
        course.status = "published"
        course.published_at = datetime.now(timezone.utc)

    if body.assign_to_child_id is not None:
        assert_parent_owns_child(db, current_parent, body.assign_to_child_id)
        db.flush()  # the assign below re-reads status from this same session
        assign_course(db, course.id, body.assign_to_child_id, assigned_by="parent")

    db.commit()
    db.refresh(course)
    return _course_response(db, course)


@router.get("/children/{child_id}/course-assignments", response_model=list[schemas.CourseAssignmentResponse])
def list_course_assignments(child_id: UUID, db: Session = Depends(get_db),
                            _access: None = Depends(assert_child_access)):
    """Both sides: the parent reviewing progress and the kid's own device."""
    assignments = db.query(models.CourseAssignment).filter(
        models.CourseAssignment.child_id == child_id
    ).order_by(models.CourseAssignment.created_at.desc()).all()
    return [_assignment_response(db, a) for a in assignments]


@router.post("/children/{child_id}/course-assignments", response_model=schemas.CourseAssignmentResponse)
def create_course_assignment(child_id: UUID, body: schemas.CourseAssignRequest,
                             current_parent: models.Parent = Depends(get_current_parent),
                             db: Session = Depends(get_db)):
    """Assign an already-published course — how a sibling gets the same
    vetted course with no repeat search or vetting."""
    assert_parent_owns_child(db, current_parent, child_id)
    assignment = assign_course(db, body.course_id, child_id, assigned_by="parent")
    db.commit()
    db.refresh(assignment)
    return _assignment_response(db, assignment)


@router.post("/course-item-progress/{progress_id}/complete",
             response_model=schemas.CourseItemProgressResponse)
def complete_course_item(progress_id: UUID, body: schemas.CourseItemCompleteRequest,
                         db: Session = Depends(get_db),
                         credentials: HTTPAuthorizationCredentials = Depends(security)):
    """The kid finishing one video (and its quiz, if it has one). Unlocks
    exactly the next item — not all remaining ones."""
    progress = db.query(models.CourseItemProgress).filter(
        models.CourseItemProgress.id == progress_id
    ).first()
    if not progress:
        raise HTTPException(status_code=404, detail="Not found")

    assignment = db.query(models.CourseAssignment).filter(
        models.CourseAssignment.id == progress.assignment_id
    ).first()
    if not assignment:
        raise HTTPException(status_code=404, detail="Not found")
    # The kid's own device makes this write themselves; a parent can too.
    check_child_access(db, credentials, assignment.child_id)

    if progress.status == "locked":
        raise HTTPException(status_code=400, detail="Finish the previous video first")

    item = db.query(models.CourseItem).filter(
        models.CourseItem.id == progress.course_item_id
    ).first()
    quiz = (item.quiz if item else None) or []
    if quiz:
        answers = body.quiz_answers or []
        if len(answers) != len(quiz):
            raise HTTPException(status_code=400, detail="Answer every question first")
        progress.quiz_answers = answers
        progress.quiz_score = sum(
            1 for q, a in zip(quiz, answers) if a == q.get("correct_index")
        )

    progress.status = "completed"
    progress.completed_at = datetime.now(timezone.utc)

    _unlock_next_item(db, assignment, progress)

    if course_assignment_fully_completed(db, assignment.id):
        assignment.status = "completed"
        assignment.completed_at = datetime.now(timezone.utc)

    db.commit()
    db.refresh(progress)
    return progress


def _unlock_next_item(db: Session, assignment: models.CourseAssignment,
                      just_completed: models.CourseItemProgress) -> None:
    """Unlock only the item immediately after this one, by the course's own
    ordering — never "everything still locked"."""
    ordered = db.query(models.CourseItemProgress, models.CourseItem).join(
        models.CourseItem, models.CourseItem.id == models.CourseItemProgress.course_item_id
    ).filter(
        models.CourseItemProgress.assignment_id == assignment.id
    ).order_by(models.CourseItem.order_index).all()

    for position, (progress, _item) in enumerate(ordered):
        if progress.id == just_completed.id:
            if position + 1 < len(ordered):
                nxt = ordered[position + 1][0]
                if nxt.status == "locked":
                    nxt.status = "available"
            return
