from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy.orm import Session
from uuid import UUID
from datetime import timedelta, time, date
from sqlalchemy.exc import IntegrityError
from typing import Optional
import models, schemas
import edits
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


# Must match the DB's CHECK constraint on this column — see the
# submission_kind migration in main.py.
_VALID_SUBMISSION_KINDS = {"none", "photo"}


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
    existing = _existing_create(db, child_id, task)
    if existing is not None:
        return existing
    new_task = _new_task(db, child_id, task)
    db.add(new_task)
    _lock_again_for_new_task(db, child_id, new_task)
    _commit_or_400(db)
    db.refresh(new_task)
    return new_task


def _existing_create(db: Session, child_id: UUID, task: schemas.TaskCreate) -> Optional[models.Task]:
    """A retry of a create that already went through: the row it made."""
    if task.id is None:
        return None
    existing = db.query(models.Task).filter(models.Task.id == task.id).first()
    if existing is not None and existing.child_id != child_id:
        raise HTTPException(status_code=409, detail="That id is already in use")
    return existing


def _new_task(db: Session, child_id: UUID, task: schemas.TaskCreate) -> models.Task:
    parsed_time, parsed_date = _parse_due(task)
    if parsed_date is None and (task.recurrence or "none").strip().lower() in ("", "none"):
        # A one-off with no day is for today — the child's today. Left
        # empty, it fell back to created_at's UTC date, which is already
        # tomorrow for a Pacific family every evening after 5pm.
        from blocks import local_now
        child = db.query(models.Child).filter(models.Child.id == child_id).first()
        parsed_date = local_now(child).date()

    return models.Task(
        **({"id": task.id} if task.id is not None else {}),
        child_id=child_id,
        title=task.title,
        instructions=task.instructions,
        category=task.category,
        icon=task.icon,
        bucket=_derive_bucket(parsed_time),
        due_time=parsed_time,
        due_date=parsed_date,
        recurrence=task.recurrence,
        gates_apps=task.gates_apps,
        submission_kind=_safe_submission_kind(task.submission_kind),
        active=task.active,
        bonus_minutes=task.bonus_minutes,
        created_by=task.created_by,
    )


def _lock_again_for_new_task(db: Session, child_id: UUID, task: models.Task):
    """A new task that gates apps today closes the phone again, even if the
    parent had opened it: the task-gate override is cleared. (The app clears
    it too, so the screen changes at once; this keeps every client, the AI
    drafts' included, to the same rule.)"""
    from blocks import local_now
    from routers.occurrences import task_applies_on
    if not task.gates_apps:
        return
    child = db.query(models.Child).filter(models.Child.id == child_id).first()
    if child is None or not task_applies_on(task, local_now(child).date()):
        return
    state = db.query(models.ChildState).filter(models.ChildState.child_id == child_id).first()
    if state is not None and state.task_gate_override:
        state.task_gate_override = False

@router.put("/tasks/{task_id}", response_model=schemas.TaskResponse)
def update_task(task_id: UUID, task_update: schemas.TaskUpdate, request: Request,
                current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """An edit to a task. Only the fields sent change, and each only if this
    edit is at least as new as that field's last change (edits.py): a title
    edit on one phone never overwrites a repeat edit made on the other, and
    an old edit replayed late never undoes a newer one."""
    db_task = get_task_for_parent(db, current_parent, task_id)
    sent = task_update.model_fields_set
    values = {}
    for field in ("title", "instructions", "category", "icon", "recurrence", "gates_apps", "active", "bonus_minutes"):
        if field in sent:
            value = getattr(task_update, field)
            # A required column sent empty keeps what it had.
            if value is None and field in ("title", "recurrence", "gates_apps", "active", "bonus_minutes"):
                continue
            values[field] = value
    if "submission_kind" in sent and task_update.submission_kind is not None:
        values["submission_kind"] = _safe_submission_kind(task_update.submission_kind)
    if "due_time" in sent:
        values["due_time"] = _parse_time(task_update.due_time)
    if "due_date" in sent:
        values["due_date"] = _parse_date(task_update.due_date)

    schedule_before = (db_task.recurrence, db_task.due_date, db_task.active, db_task.due_time)
    edits.apply(db_task, values, edits.edited_at(request))
    db_task.bucket = _derive_bucket(db_task.due_time)  # keep in sync either way

    if (db_task.recurrence, db_task.due_date, db_task.active) != schedule_before[:3]:
        _drop_days_it_no_longer_falls_on(db, db_task)
    _commit_or_400(db)
    db.refresh(db_task)
    return db_task


def _parse_time(raw: Optional[str]) -> Optional[time]:
    if not raw:
        return None
    try:
        return time.fromisoformat(raw)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid time format. Use HH:MM:SS")


def _parse_date(raw: Optional[str]) -> Optional[date]:
    if not raw:
        return None
    try:
        return date.fromisoformat(raw)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid date format. Use YYYY-MM-DD")


def _drop_days_it_no_longer_falls_on(db: Session, task: models.Task):
    """An edit that moves a task off a day (its repeat days changed, or it
    was switched off) takes it off that day from today on: today's and any
    later occurrence already made for a day it no longer falls on is
    deleted, so it leaves today's list and stops locking the kid's phone.
    Only ones the kid hasn't sent in (pending, or a redo): work waiting for
    review or approved stays, as do earlier days."""
    from blocks import local_now
    from routers.occurrences import task_applies_on
    child = db.query(models.Child).filter(models.Child.id == task.child_id).first()
    if child is None:
        return
    db.flush()
    today = local_now(child).date()
    rows = db.query(models.Occurrence).filter(
        models.Occurrence.task_id == task.id,
        models.Occurrence.due_date >= today,
        models.Occurrence.status.in_(("pending", "rejected")),
    ).all()
    for row in rows:
        if not task.active or not task_applies_on(task, row.due_date):
            db.delete(row)

@router.delete("/tasks/{task_id}")
def delete_task(task_id: UUID, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """Delete a task"""
    db_task = get_task_for_parent(db, current_parent, task_id)
    db.delete(db_task)
    db.commit()
    return {"detail": "Task deleted"}


# --- One day of a repeating task, or the rest of it ------------------------
#
# As calendars do it: "This task" takes the day out of the series
# (skipped_dates), "This and following tasks" ends the series the day before
# (repeat_until). An edit puts those days on a new task of their own (split),
# carrying whatever was sent in or approved on them; a delete takes them off
# (cut), whatever was done on them. Both are safe to send twice: the phone's
# outbox retries.


def _check_cut(task: models.Task, cut: schemas.TaskCut):
    if cut.through is not None and cut.through != cut.from_:
        raise HTTPException(status_code=400, detail="through must be the same day as from, or left out")


def _cut_series(task: models.Task, cut: schemas.TaskCut):
    """Writes the exception on the task: the day skipped, or the series'
    last day set to the day before `from` (skips after it go with it)."""
    if cut.through is not None:
        days = set(task.skipped_dates or [])
        days.add(cut.from_.isoformat())
        task.skipped_dates = sorted(days)
        return
    last = cut.from_ - timedelta(days=1)
    if task.repeat_until is None or task.repeat_until > last:
        task.repeat_until = last
    kept = [d for d in (task.skipped_dates or []) if d <= last.isoformat()]
    task.skipped_dates = kept or None


def _days(db: Session, task_id: UUID, cut: schemas.TaskCut):
    q = db.query(models.Occurrence).filter(models.Occurrence.task_id == task_id,
                                           models.Occurrence.due_date >= cut.from_)
    if cut.through is not None:
        q = q.filter(models.Occurrence.due_date <= cut.through)
    return q


@router.post("/tasks/{task_id}/cut", response_model=schemas.TaskResponse)
def cut_task(task_id: UUID, cut: schemas.TaskCut, current_parent: models.Parent = Depends(get_current_parent),
             db: Session = Depends(get_db)):
    """A repeating task deleted for one day, or from a day on: those days
    leave every list, whatever was done on them."""
    task = get_task_for_parent(db, current_parent, task_id)
    _check_cut(task, cut)
    _cut_series(task, cut)
    _days(db, task.id, cut).delete(synchronize_session=False)
    _commit_or_400(db)
    db.refresh(task)
    return task


@router.post("/tasks/{task_id}/split", response_model=schemas.TaskResponse)
def split_task(task_id: UUID, split: schemas.TaskSplit, current_parent: models.Parent = Depends(get_current_parent),
               db: Session = Depends(get_db)):
    """A repeating task edited for one day, or from a day on: `split.task`
    (made on the phone, with the edits) takes those days, with whatever was
    sent in or approved on them, and the series keeps the rest. Answers
    the new task. A day it doesn't take stays only where it was done: the
    new task's own row for a day already made is dropped for the old one's."""
    task = get_task_for_parent(db, current_parent, task_id)
    _check_cut(task, split)
    new_task = _existing_create(db, task.child_id, split.task)
    if new_task is None:
        new_task = _new_task(db, task.child_id, split.task)
        # Named, so a send-in for those days under the old id can be
        # followed here (models.Task.split_from).
        new_task.split_from = task.id
        db.add(new_task)
        db.flush()
    _cut_series(task, split)
    for row in _days(db, task.id, split).all():
        made = db.query(models.Occurrence).filter(models.Occurrence.task_id == new_task.id,
                                                  models.Occurrence.due_date == row.due_date).first()
        if made is not None:
            db.delete(made)
            db.flush()
        row.task_id = new_task.id
    _commit_or_400(db)
    db.refresh(new_task)
    return new_task
