"""Milestones: longer-arc goals with a prize.

Two shapes of progress, deliberately not merged into one counter:
count/streak tick up as tagged tasks get approved (see
occurrences.py's _bump_milestone_progress), while a course milestone is
achieved by finishing its assigned course — the same completion check
reflections and special tasks use.

The prize pays out through the existing append-only time-grant ledger, via
the source='milestone' / source_ref_id hook that's been reserved for this
since before milestones existed.
"""
import json
from datetime import datetime, timezone
from typing import Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

import models
import schemas
from access import assert_child_access, assert_parent_owns_child
from database import get_db
from gemini_client import gemini_configured, generate
from routers.auth import get_current_parent
from routers.courses import _assignment_response, assign_course, course_assignment_fully_completed
from routers.time_grants import award_time_grant

router = APIRouter(tags=["milestones"])


def _is_achievable(db: Session, milestone: models.Milestone) -> bool:
    """Whether what this milestone asks for is actually done — two different
    questions depending on kind, one answer the client can just read."""
    if milestone.kind == "course":
        return bool(milestone.course_assignment_id) and course_assignment_fully_completed(
            db, milestone.course_assignment_id
        )
    if milestone.kind in ("count", "streak"):
        return bool(milestone.target_count) and milestone.progress_count >= milestone.target_count
    return True  # 'custom' — the parent is the judge


def _response(db: Session, milestone: models.Milestone) -> schemas.MilestoneResponse:
    body = schemas.MilestoneResponse.model_validate(milestone)
    body.achievable = _is_achievable(db, milestone)
    if milestone.course_assignment_id:
        assignment = db.query(models.CourseAssignment).filter(
            models.CourseAssignment.id == milestone.course_assignment_id
        ).first()
        body.assignment = _assignment_response(db, assignment) if assignment else None
    return body


def _get_for_parent(db: Session, parent: models.Parent, milestone_id: UUID) -> models.Milestone:
    milestone = db.query(models.Milestone).filter(models.Milestone.id == milestone_id).first()
    if not milestone:
        raise HTTPException(status_code=404, detail="Milestone not found")
    assert_parent_owns_child(db, parent, milestone.child_id)
    return milestone


@router.post("/children/{child_id}/milestones", response_model=schemas.MilestoneResponse)
def create_milestone(child_id: UUID, body: schemas.MilestoneCreate,
                     current_parent: models.Parent = Depends(get_current_parent),
                     db: Session = Depends(get_db)):
    """Create a milestone. An AI-proposed one is saved through this same
    route once the parent confirms it — there's no separate AI-writes path."""
    assert_parent_owns_child(db, current_parent, child_id)

    assignment_id = None
    if body.kind == "course":
        course = db.query(models.Course).filter(models.Course.id == body.course_id).first()
        if not course:
            raise HTTPException(status_code=404, detail="Course not found")
        if course.status == "pending_review":
            # Same reasoning as creating a special task from a drafted
            # course: the parent confirming the milestone is the approval.
            course.status = "published"
            course.published_at = datetime.now(timezone.utc)
            db.flush()
        assignment = assign_course(db, course.id, child_id, assigned_by="parent")
        db.flush()
        assignment_id = assignment.id

    milestone = models.Milestone(
        child_id=child_id,
        title=body.title,
        description=body.description,
        kind=body.kind,
        target_count=body.target_count,
        course_assignment_id=assignment_id,
        prize_text=body.prize_text,
        prize_minutes=body.prize_minutes,
        created_by=body.created_by,
    )
    db.add(milestone)
    db.commit()
    db.refresh(milestone)
    return _response(db, milestone)


@router.get("/children/{child_id}/milestones", response_model=list[schemas.MilestoneResponse])
def list_milestones(child_id: UUID, db: Session = Depends(get_db),
                    _access: None = Depends(assert_child_access)):
    """Both sides — the kid sees what they're working toward."""
    rows = db.query(models.Milestone).filter(
        models.Milestone.child_id == child_id
    ).order_by(models.Milestone.created_at.desc()).all()
    return [_response(db, m) for m in rows]


@router.post("/milestones/{milestone_id}/claim", response_model=schemas.MilestoneResponse)
def claim_milestone(milestone_id: UUID,
                    current_parent: models.Parent = Depends(get_current_parent),
                    db: Session = Depends(get_db)):
    """Parent confirms the prize once it's actually been earned."""
    milestone = _get_for_parent(db, current_parent, milestone_id)
    if milestone.status == "achieved":
        raise HTTPException(status_code=400, detail="Already claimed")
    if not _is_achievable(db, milestone):
        raise HTTPException(status_code=400, detail="Not finished yet")

    if milestone.prize_minutes > 0:
        award_time_grant(
            db, milestone.child_id, milestone.prize_minutes, source="milestone",
            reason=f"Milestone: {milestone.title}", granted_by_parent_id=current_parent.id,
            source_ref_id=milestone.id,
        )

    milestone.status = "achieved"
    milestone.achieved_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(milestone)
    return _response(db, milestone)


@router.delete("/milestones/{milestone_id}")
def delete_milestone(milestone_id: UUID,
                     current_parent: models.Parent = Depends(get_current_parent),
                     db: Session = Depends(get_db)):
    milestone = _get_for_parent(db, current_parent, milestone_id)
    # Tasks tagged toward it keep existing; their milestone_id goes null
    # (ON DELETE SET NULL) rather than the delete failing.
    db.delete(milestone)
    db.commit()
    return {"detail": "Milestone deleted"}


# ---- AI generation -------------------------------------------------------

_PROPOSE_MILESTONE_TOOL = {
    "name": "propose_milestone",
    "description": "Propose one milestone for the parent to review, edit and confirm. Does not create anything.",
    "parameters": {
        "type": "OBJECT",
        "properties": {
            "title": {"type": "STRING"},
            "description": {"type": "STRING"},
            "kind": {"type": "STRING", "description": "count or streak"},
            "target_count": {"type": "INTEGER"},
            "prize_text": {"type": "STRING", "description": "A non-screen-time reward, if one fits"},
            "prize_minutes": {"type": "INTEGER", "description": "Bonus screen-time minutes, 0 if none"},
        },
        "required": ["title", "kind", "target_count"],
    },
}


@router.post("/children/{child_id}/milestones/generate")
async def generate_milestone(child_id: UUID, body: schemas.MilestoneGenerateRequest,
                             current_parent: models.Parent = Depends(get_current_parent),
                             db: Session = Depends(get_db)):
    """Returns a draft for the parent to edit and save through the normal
    create route — never creates a milestone itself."""
    assert_parent_owns_child(db, current_parent, child_id)
    if not gemini_configured():
        raise HTTPException(status_code=503, detail="Milestone suggestions aren't configured yet (no GEMINI_API_KEY)")

    child = db.query(models.Child).filter(models.Child.id == child_id).first()
    tasks = db.query(models.Task).filter(
        models.Task.child_id == child_id, models.Task.active == True  # noqa: E712
    ).all()

    who = child.name if child else "this child"
    if child and child.birth_year:
        who += f" (about {datetime.now(timezone.utc).year - child.birth_year} years old)"
    prompt = (
        f"You are helping a parent set a motivating milestone for {who}.\n"
        "A milestone is a longer-arc goal made of repeated task completions — "
        "'count' means N completions total, 'streak' means N days in a row.\n"
        "Keep the target realistic for the child's age, and make the prize modest.\n"
        "Call propose_milestone. Do not reply with prose."
    )
    context = "Their current tasks:\n" + ("\n".join(f"- {t.title}" for t in tasks) or "- (none yet)")
    if body.hint:
        context += f"\n\nWhat the parent asked for: {body.hint}"

    try:
        _text, call = await generate(prompt, [{"role": "user", "text": context}],
                                     tools=[_PROPOSE_MILESTONE_TOOL])
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Milestone suggestion failed: {e}")
    if call is None or call.name != "propose_milestone":
        raise HTTPException(status_code=502, detail="No milestone was proposed")

    draft = dict(call.args)
    draft["created_by"] = "ai_agent"
    return draft
