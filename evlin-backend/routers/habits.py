"""Habits ("goals" in the app's code), 2026-11-19: on the server, so the
parent's phone and the child's device share them.

- The parent adds, edits (per field, newest edit wins: edits.py) and deletes
  a habit. Its id is made on the phone, so a retried create saves once.
- The child checks in from their device ("Hold to send"), once a day per
  habit; it waits for the parent.
- The parent approves a check-in. The server counts it (`done`), by the
  child's own days: "days" and "times" add one; "streak" adds one when the
  last counted day was the day before, and starts again at 1 otherwise. The
  approval that reaches the target sets `finished_at`: a completed
  milestone. A second approval is refused (409).
- Every change is announced to both phones by the live-updates hook
  (both tables carry child_id).
"""
from datetime import datetime, timedelta, timezone
from typing import Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

import edits
import models
import schemas
from access import assert_child_access, assert_parent_owns_child, parent_owns_child
from blocks import local_now
from database import get_db
from routers.auth import get_current_device, get_current_parent

router = APIRouter(tags=["habits"])

# Check-ins kept in a habit's answer: the last week, today's included.
_RECENT = timedelta(days=7)
# How far back a check-in sent late (offline) may name its day.
_LATE = timedelta(days=2)


def _child(db: Session, child_id) -> models.Child:
    child = db.query(models.Child).filter(models.Child.id == child_id).first()
    if child is None:
        raise HTTPException(status_code=404, detail="Child not found")
    return child


def _habit_for_parent(db: Session, parent: models.Parent, habit_id: UUID) -> models.Habit:
    habit = db.query(models.Habit).filter(models.Habit.id == habit_id).first()
    if habit is None or not parent_owns_child(db, parent, habit.child_id):
        raise HTTPException(status_code=404, detail="Habit not found")
    return habit


def _as_shown(db: Session, habit: models.Habit, today) -> schemas.HabitResponse:
    out = schemas.HabitResponse.model_validate(habit)
    # A streak with a day missed since its last count reads 0 until the next
    # approval starts it again.
    if (habit.unit == "streak" and habit.finished_at is None and habit.last_counted_day is not None
            and habit.last_counted_day < today - timedelta(days=1)):
        out.done = 0
    rows = (db.query(models.HabitCheckIn)
            .filter(models.HabitCheckIn.habit_id == habit.id, models.HabitCheckIn.day >= today - _RECENT)
            .order_by(models.HabitCheckIn.day.desc()).all())
    out.check_ins = [schemas.HabitCheckInResponse.model_validate(r) for r in rows]
    return out


@router.get("/children/{child_id}/habits", response_model=list[schemas.HabitResponse])
def list_habits(child_id: UUID, db: Session = Depends(get_db), _access: None = Depends(assert_child_access)):
    """Every habit of the child, running and completed (that child's device,
    or their parent)."""
    today = local_now(_child(db, child_id)).date()
    habits = (db.query(models.Habit).filter(models.Habit.child_id == child_id)
              .order_by(models.Habit.created_at, models.Habit.id).all())
    return [_as_shown(db, h, today) for h in habits]


@router.post("/children/{child_id}/habits", response_model=schemas.HabitResponse)
def create_habit(child_id: UUID, body: schemas.HabitCreate,
                 current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    assert_parent_owns_child(db, current_parent, child_id)
    child = _child(db, child_id)
    if body.id is not None:
        existing = db.query(models.Habit).filter(models.Habit.id == body.id).first()
        if existing is not None:
            # A retry of a create that already went through.
            if existing.child_id != child_id:
                raise HTTPException(status_code=409, detail="That id is already in use")
            return _as_shown(db, existing, local_now(child).date())
    habit = models.Habit(**({"id": body.id} if body.id is not None else {}), child_id=child_id, title=body.title,
                         picture=body.picture, target=body.target, unit=body.unit, prize=body.prize or "",
                         color_index=body.color_index, created_by=body.created_by or "parent")
    db.add(habit)
    db.commit()
    db.refresh(habit)
    return _as_shown(db, habit, local_now(child).date())


@router.put("/habits/{habit_id}", response_model=schemas.HabitResponse)
def update_habit(habit_id: UUID, body: schemas.HabitUpdate, request: Request,
                 current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """An edit: only the fields sent change, each only if this edit is at
    least as new as its last change. What's been counted stays (capped at a
    lower target)."""
    habit = _habit_for_parent(db, current_parent, habit_id)
    values = {f: getattr(body, f) for f in ("title", "picture", "target", "prize", "color_index")
              if f in body.model_fields_set and (getattr(body, f) is not None or f == "picture")}
    if "prize" in values and values["prize"] is None:
        values["prize"] = ""
    edits.apply(habit, values, edits.edited_at(request))
    habit.done = min(habit.done, habit.target)
    db.commit()
    db.refresh(habit)
    return _as_shown(db, habit, local_now(_child(db, habit.child_id)).date())


@router.delete("/habits/{habit_id}")
def delete_habit(habit_id: UUID, current_parent: models.Parent = Depends(get_current_parent),
                 db: Session = Depends(get_db)):
    habit = _habit_for_parent(db, current_parent, habit_id)
    for row in db.query(models.HabitCheckIn).filter(models.HabitCheckIn.habit_id == habit.id).all():
        db.delete(row)
    db.delete(habit)
    db.commit()
    return {"detail": "Habit deleted"}


@router.post("/habits/{habit_id}/check-ins", response_model=schemas.HabitCheckInResponse)
def check_in(habit_id: UUID, body: schemas.HabitCheckInCreate,
             current_device: models.Device = Depends(get_current_device), db: Session = Depends(get_db)):
    """The child's "I did it", from their device: one a day per habit. Sent
    twice (a retry, or a second hold the same day), the day's one comes back."""
    habit = db.query(models.Habit).filter(models.Habit.id == habit_id).first()
    if habit is None or habit.child_id != current_device.child_id:
        raise HTTPException(status_code=404, detail="Habit not found")
    if habit.finished_at is not None:
        raise HTTPException(status_code=409, detail="This habit is already completed")
    today = local_now(_child(db, habit.child_id)).date()
    day = body.day if body.day is not None and today - _LATE <= body.day <= today else today

    existing = None
    if body.id is not None:
        existing = db.query(models.HabitCheckIn).filter(models.HabitCheckIn.id == body.id).first()
    if existing is None:
        existing = db.query(models.HabitCheckIn).filter(models.HabitCheckIn.habit_id == habit.id,
                                                        models.HabitCheckIn.day == day).first()
    if existing is not None:
        if existing.habit_id != habit.id:
            raise HTTPException(status_code=409, detail="That id is already in use")
        return existing
    row = models.HabitCheckIn(**({"id": body.id} if body.id is not None else {}), habit_id=habit.id,
                              child_id=habit.child_id, day=day, status="waiting")
    db.add(row)
    try:
        db.commit()
    except IntegrityError:
        # The same day's check-in, made by a request a moment before.
        db.rollback()
        row = db.query(models.HabitCheckIn).filter(models.HabitCheckIn.habit_id == habit.id,
                                                   models.HabitCheckIn.day == day).one()
    db.refresh(row)
    return row


@router.post("/habit-check-ins/{check_in_id}/approve", response_model=schemas.HabitApproveResponse)
def approve_check_in(check_in_id: UUID, current_parent: models.Parent = Depends(get_current_parent),
                     db: Session = Depends(get_db)):
    """The parent's approval: counted once, by the child's days."""
    row = db.query(models.HabitCheckIn).filter(models.HabitCheckIn.id == check_in_id).first()
    if row is None or not parent_owns_child(db, current_parent, row.child_id):
        raise HTTPException(status_code=404, detail="Check-in not found")
    if row.status == "approved":
        raise HTTPException(status_code=409, detail="Already approved")
    habit = db.query(models.Habit).filter(models.Habit.id == row.habit_id).one()
    now = datetime.now(timezone.utc)
    row.status = "approved"
    row.reviewed_at = now
    row.reviewed_by = current_parent.id

    if habit.finished_at is None:
        last = habit.last_counted_day
        if habit.unit == "streak":
            if last == row.day:
                pass                                   # that day already counted
            elif last is not None and last == row.day - timedelta(days=1):
                habit.done = min(habit.target, habit.done + 1)
            else:
                habit.done = 1                         # a missed day: the run starts again
        else:
            habit.done = min(habit.target, habit.done + 1)
        if last is None or row.day > last:
            habit.last_counted_day = row.day
        if habit.done >= habit.target:
            habit.finished_at = now
    db.commit()
    db.refresh(row)
    db.refresh(habit)
    today = local_now(_child(db, habit.child_id)).date()
    return {"check_in": row, "habit": _as_shown(db, habit, today)}
