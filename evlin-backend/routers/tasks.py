from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session
from uuid import UUID
from datetime import datetime, timezone, timedelta, time, date
from sqlalchemy.exc import IntegrityError
from typing import Optional
import models, schemas
from database import get_db
from routers.auth import get_current_parent
from access import assert_parent_owns_child, assert_child_access, get_task_for_parent

router = APIRouter(tags=["tasks"])


# bucket is a DB-enforced time-of-day grouping (morning/after_school/
# evening/anytime) — nothing in the UI lets a parent pick it directly (it
# used to carry the free-form category label instead — "category" is where
# that actually lives now), so it's derived from due_time rather than
# trusted from the client.
def _derive_bucket(due_time: Optional[time]) -> str:
    if due_time is None:
        return "anytime"
    if due_time.hour < 12:
        return "morning"
    if due_time.hour < 17:
        return "after_school"
    return "evening"


_VALID_SUBMISSION_KINDS = {"none", "photo", "voice", "either"}


def _safe_submission_kind(value: str) -> str:
    # Coerced rather than 400'd: an older/cached client build sending
    # something outside this vocabulary (e.g. "button", meaning "no
    # evidence needed" — the same thing "none" already means here) shouldn't
    # hard-fail every task save until every device updates.
    return value if value in _VALID_SUBMISSION_KINDS else "none"


def _commit_or_400(db: Session):
    try:
        db.commit()
    except IntegrityError as e:
        db.rollback()
        raise HTTPException(status_code=400, detail=f"That couldn't be saved: {e.orig}")


def _parse_due(task: schemas.TaskCreate):
    """Validate the optional HH:MM[:SS] / YYYY-MM-DD strings from the client."""
    parsed_time = None
    parsed_date = None
    if task.due_time:
        try:
            parsed_time = time.fromisoformat(task.due_time)
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid time format. Use HH:MM:SS")
    if task.due_date:
        try:
            parsed_date = date.fromisoformat(task.due_date)
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid date format. Use YYYY-MM-DD")
    return parsed_time, parsed_date


@router.get("/children/{child_id}/tasks", response_model=list[schemas.TaskResponse])
def get_child_tasks(child_id: UUID, db: Session = Depends(get_db), _access: None = Depends(assert_child_access)):
    """Fetch all tasks for a child (that child's device, or their parent)"""
    tasks = db.query(models.Task).filter(models.Task.child_id == child_id).all()
    return tasks

@router.post("/children/{child_id}/tasks", response_model=schemas.TaskResponse)
def create_task(child_id: UUID, task: schemas.TaskCreate, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """Create a new task for a child"""
    assert_parent_owns_child(db, current_parent, child_id)
    parsed_time, parsed_date = _parse_due(task)

    new_task = models.Task(
        child_id=child_id,
        title=task.title,
        instructions=task.instructions,
        category=task.category,
        bucket=_derive_bucket(parsed_time),
        due_time=parsed_time,
        due_date=parsed_date,
        recurrence=task.recurrence,
        gates_apps=task.gates_apps,
        points=task.points,
        submission_kind=_safe_submission_kind(task.submission_kind),
        active=task.active
    )
    db.add(new_task)
    _commit_or_400(db)
    db.refresh(new_task)
    return new_task

@router.put("/tasks/{task_id}", response_model=schemas.TaskResponse)
def update_task(task_id: UUID, task_update: schemas.TaskCreate, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """Update an existing task"""
    db_task = get_task_for_parent(db, current_parent, task_id)
    parsed_time, parsed_date = _parse_due(task_update)

    db_task.title = task_update.title
    db_task.instructions = task_update.instructions
    if "category" in task_update.model_fields_set:
        db_task.category = task_update.category
    # Only touch the schedule when the client actually sent it, so a partial
    # edit (e.g. a title change from the review screen) doesn't wipe it.
    if "due_time" in task_update.model_fields_set:
        db_task.due_time = parsed_time
    if "due_date" in task_update.model_fields_set:
        db_task.due_date = parsed_date
    db_task.bucket = _derive_bucket(db_task.due_time)  # keep in sync either way
    db_task.recurrence = task_update.recurrence
    db_task.gates_apps = task_update.gates_apps
    db_task.points = task_update.points
    db_task.submission_kind = _safe_submission_kind(task_update.submission_kind)
    db_task.active = task_update.active

    _commit_or_400(db)
    db.refresh(db_task)
    return db_task

@router.delete("/tasks/{task_id}")
def delete_task(task_id: UUID, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """Delete a task"""
    db_task = get_task_for_parent(db, current_parent, task_id)
    db.delete(db_task)
    db.commit()
    return {"detail": "Task deleted"}
