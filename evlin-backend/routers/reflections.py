"""Reflections: the priority-0 gate.

While a reflection is open the device is locked regardless of task status,
and clearing it doesn't satisfy outstanding tasks either — the two gates are
independent, which is the whole point of it being its own thing rather than
another task.

The watch-and-answer half is a course assignment (see routers/courses.py),
so there's one implementation of that shared with special tasks and
milestones rather than three.
"""
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
from routers.auth import get_current_parent, security
from routers.courses import (
    _assignment_response,
    assign_course,
    course_assignment_fully_completed,
    create_single_video_course,
)

router = APIRouter(tags=["reflections"])

# The statuses that hold the gate closed. 'submitted' still counts: the child
# is waiting on a parent's review and shouldn't get the device back by
# submitting anything at all.
OPEN_STATUSES = ("pending", "submitted")


def child_has_open_reflection(db: Session, child_id: UUID) -> bool:
    """The gate flag the lock logic reads. One query, indexed on
    (child_id, status)."""
    return db.query(models.Reflection).filter(
        models.Reflection.child_id == child_id,
        models.Reflection.status.in_(OPEN_STATUSES),
    ).first() is not None


def _response(db: Session, reflection: models.Reflection) -> schemas.ReflectionResponse:
    assignment = db.query(models.CourseAssignment).filter(
        models.CourseAssignment.id == reflection.course_assignment_id
    ).first()
    body = schemas.ReflectionResponse.model_validate(reflection)
    body.assignment = _assignment_response(db, assignment) if assignment else None
    return body


def _get_for_parent(db: Session, parent: models.Parent, reflection_id: UUID) -> models.Reflection:
    reflection = db.query(models.Reflection).filter(models.Reflection.id == reflection_id).first()
    if not reflection:
        raise HTTPException(status_code=404, detail="Reflection not found")
    assert_parent_owns_child(db, parent, reflection.child_id)
    return reflection


@router.post("/children/{child_id}/reflections", response_model=schemas.ReflectionResponse)
def create_reflection(child_id: UUID, body: schemas.ReflectionCreate,
                      current_parent: models.Parent = Depends(get_current_parent),
                      db: Session = Depends(get_db)):
    """Assign a reflection. Its content is either one picked video (a
    one-video course is created for it) or an existing published course."""
    assert_parent_owns_child(db, current_parent, child_id)

    if body.video_id:
        course = create_single_video_course(
            db, body.video_id, video_title=body.video_title,
            channel_title=body.channel_title, quiz=body.quiz,
            created_by_parent_id=current_parent.id,
        )
        db.flush()
        course_id = course.id
    else:
        course_id = body.course_id

    assignment = assign_course(db, course_id, child_id, assigned_by="parent")
    db.flush()

    reflection = models.Reflection(
        child_id=child_id,
        course_assignment_id=assignment.id,
        written_prompt=body.written_prompt,
    )
    db.add(reflection)
    db.commit()
    db.refresh(reflection)
    return _response(db, reflection)


@router.get("/children/{child_id}/reflections", response_model=list[schemas.ReflectionResponse])
def list_reflections(child_id: UUID, status: Optional[str] = Query(None),
                     db: Session = Depends(get_db),
                     _access: None = Depends(assert_child_access)):
    """Both sides — the kid's device polls this for "is one open" the same
    way it already polls tasks."""
    q = db.query(models.Reflection).filter(models.Reflection.child_id == child_id)
    if status == "open":
        q = q.filter(models.Reflection.status.in_(OPEN_STATUSES))
    elif status:
        q = q.filter(models.Reflection.status == status)
    rows = q.order_by(models.Reflection.created_at.desc()).all()
    return [_response(db, r) for r in rows]


@router.post("/reflections/{reflection_id}/submit", response_model=schemas.ReflectionResponse)
def submit_reflection(reflection_id: UUID, body: schemas.ReflectionSubmit,
                      db: Session = Depends(get_db),
                      credentials: HTTPAuthorizationCredentials = Depends(security)):
    """The child hands it in. Can't be submitted until every video in the
    assigned course is actually finished — otherwise "watch this to get your
    phone back" would be satisfied by typing a sentence."""
    reflection = db.query(models.Reflection).filter(models.Reflection.id == reflection_id).first()
    if not reflection:
        raise HTTPException(status_code=404, detail="Reflection not found")
    check_child_access(db, credentials, reflection.child_id)

    if not course_assignment_fully_completed(db, reflection.course_assignment_id):
        raise HTTPException(status_code=400, detail="Finish the videos and quizzes first")
    if reflection.written_prompt and not (body.written_response or "").strip():
        raise HTTPException(status_code=400, detail="Write your reflection first")

    reflection.written_response = body.written_response
    reflection.status = "submitted"
    reflection.submitted_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(reflection)
    return _response(db, reflection)


@router.put("/reflections/{reflection_id}/review", response_model=schemas.ReflectionResponse)
def review_reflection(reflection_id: UUID, body: schemas.ReflectionReview,
                      current_parent: models.Parent = Depends(get_current_parent),
                      db: Session = Depends(get_db)):
    """Approve (closes the gate) or send back for another go."""
    reflection = _get_for_parent(db, current_parent, reflection_id)
    if reflection.status not in ("submitted", "approved", "needs_redo"):
        raise HTTPException(status_code=400, detail="Nothing submitted to review yet")

    reflection.status = body.status
    reflection.review_note = body.review_note
    reflection.reviewed_at = datetime.now(timezone.utc)
    if body.status == "needs_redo":
        # Back to the child. Their completed course items stay completed —
        # only the written response needs doing again, so a redo doesn't mean
        # re-watching everything.
        reflection.status = "pending"
        reflection.submitted_at = None

    db.commit()
    db.refresh(reflection)
    return _response(db, reflection)
