from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session
from uuid import UUID
from datetime import date, datetime, timedelta, timezone
import models, schemas
from database import get_db
from routers.auth import get_current_parent, get_current_device
from access import assert_child_access, get_occurrence_for_parent
from routers.time_grants import award_time_grant

router = APIRouter(tags=["occurrences"])

_WEEKDAY_CODES = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]


def task_applies_on(task: models.Task, day: date) -> bool:
    """Whether `task` should have an occurrence on `day`.

    recurrence is "none" (only on its start day), "daily", or a comma-joined
    list of weekday codes ("mon,wed,fri") — the same codes the app stores.
    """
    start = task.due_date or (task.created_at.date() if task.created_at else day)
    rec = (task.recurrence or "none").strip().lower()
    if rec in ("", "none"):
        return day == start
    # created_at is a UTC server timestamp, so a device west of UTC can
    # still be on the previous local calendar day when it's already
    # "tomorrow" in UTC (e.g. 6pm Pacific = 1am UTC the next day). Without
    # slack here, a recurring task created that evening never gets an
    # occurrence on the day it was actually created — the kid's device asks
    # for "today" (its own local date), this says that's still before
    # `start`, no occurrence is generated, and every photo they take fails
    # immediately (no occurrenceId to attach it to). Only the created_at
    # fallback needs this: due_date is already an unambiguous calendar
    # date with no UTC conversion involved, so a task explicitly scheduled
    # to start tomorrow must still not apply today.
    slack = timedelta(days=1) if task.due_date is None else timedelta(0)
    if day < start - slack:
        return False
    if rec == "daily":
        return True
    if rec == "weekly":
        return day.weekday() == start.weekday()
    codes = {c.strip() for c in rec.split(",") if c.strip()}
    return _WEEKDAY_CODES[day.weekday()] in codes


def _generate_occurrences_for_date(child_id: UUID, target_date: date, db: Session):
    """On-demand materializer: ensure an occurrence exists for every active
    task of the child that applies on `target_date`."""
    tasks = db.query(models.Task).filter(
        models.Task.child_id == child_id,
        models.Task.active == True
    ).all()

    for task in tasks:
        if not task_applies_on(task, target_date):
            continue
        existing = db.query(models.Occurrence).filter(
            models.Occurrence.task_id == task.id,
            models.Occurrence.due_date == target_date
        ).first()
        if not existing:
            db.add(models.Occurrence(
                task_id=task.id,
                child_id=child_id,
                due_date=target_date,
                due_time=task.due_time,
                status="pending",
                gates_apps=task.gates_apps,
            ))
    db.commit()

@router.get("/children/{child_id}/occurrences", response_model=list[schemas.OccurrenceResponse])
def get_occurrences(child_id: UUID, target_date: date = Query(...), db: Session = Depends(get_db),
                    _access: None = Depends(assert_child_access)):
    """Fetch all occurrences for a child on a specific date (that child's device or their parent)"""
    
    # Materialize if missing
    _generate_occurrences_for_date(child_id, target_date, db)
    
    occurrences = db.query(models.Occurrence).filter(
        models.Occurrence.child_id == child_id,
        models.Occurrence.due_date == target_date
    ).all()
    
    return occurrences

@router.put("/occurrences/{occurrence_id}/status", response_model=schemas.OccurrenceResponse)
def update_occurrence_status(occurrence_id: UUID, status_update: schemas.OccurrenceStatusUpdate,
                             current_parent: models.Parent = Depends(get_current_parent),
                             db: Session = Depends(get_db)):
    """Parent approves or rejects an occurrence.

    Delegates to _review like the /approve and /reject routes do: approving
    has side effects (bonus minutes, and more as they land) and which of the
    two review endpoints a client happens to call must not decide whether
    those fire. The app uses this route for redo-with-a-note and the POST
    routes for plain approve/reject, so both are live.
    """
    if status_update.status not in ("approved", "rejected"):
        raise HTTPException(status_code=400, detail="status must be 'approved' or 'rejected'")

    return _review(occurrence_id, status_update.status == "approved", current_parent, db,
                   rejection_note=status_update.rejection_note)

@router.post("/occurrences/{occurrence_id}/bypass", response_model=schemas.OccurrenceResponse)
def request_bypass(occurrence_id: UUID, bypass_req: schemas.OccurrenceBypassRequest, 
                   current_device: models.Device = Depends(get_current_device), 
                   db: Session = Depends(get_db)):
    """Child requests a bypass (to skip the task)"""
    occurrence = db.query(models.Occurrence).filter(models.Occurrence.id == occurrence_id).first()
    if not occurrence:
        raise HTTPException(status_code=404, detail="Occurrence not found")
        
    # Enforce device owns this occurrence
    if occurrence.child_id != current_device.child_id:
        raise HTTPException(status_code=403, detail="Not your occurrence")
        
    occurrence.bypass_requested = True
    occurrence.bypass_note = bypass_req.bypass_note
    db.commit()
    db.refresh(occurrence)
    return occurrence


# --- Endpoints the iOS client calls under /tasks/occurrences/... ---------

@router.post("/tasks/occurrences/{occurrence_id}/submit", response_model=schemas.OccurrenceResponse)
def submit_occurrence(occurrence_id: UUID, body: schemas.OccurrenceBypassRequest,
                      current_device: models.Device = Depends(get_current_device),
                      db: Session = Depends(get_db)):
    """Child marks a task done; it then waits for the parent's review."""
    occurrence = db.query(models.Occurrence).filter(models.Occurrence.id == occurrence_id).first()
    if not occurrence or occurrence.child_id != current_device.child_id:
        raise HTTPException(status_code=404, detail="Occurrence not found")

    # A special task is done when its course is done — "watch this and answer
    # the quizzes" can't be satisfied by tapping Done on the task itself.
    task = db.query(models.Task).filter(models.Task.id == occurrence.task_id).first()
    if task and task.submission_kind == "course" and task.course_assignment_id:
        from routers.courses import course_assignment_fully_completed
        if not course_assignment_fully_completed(db, task.course_assignment_id):
            raise HTTPException(status_code=400, detail="Finish the videos and quizzes first")

    occurrence.status = "submitted"
    occurrence.rejection_note = None   # a resubmission answers the earlier redo request
    occurrence.completed_at = datetime.now(timezone.utc)
    if body.bypass_note:
        occurrence.bypass_note = body.bypass_note
    db.commit()
    db.refresh(occurrence)
    return occurrence


def _award_task_bonus(occurrence: models.Occurrence, task: models.Task | None,
                      parent: models.Parent, db: Session) -> None:
    """A special task's screen-time reward. Doesn't commit — _review owns that."""
    if task and task.bonus_minutes > 0:
        award_time_grant(
            db, occurrence.child_id, task.bonus_minutes, source="task_bonus",
            reason=f"Task: {task.title}", granted_by_parent_id=parent.id,
            source_ref_id=occurrence.id,
        )


def _resolve_app_blocks(task: models.Task | None, db: Session) -> None:
    """"No YouTube until homework is done" lifts itself when the homework is
    approved. Doesn't commit — _review owns that."""
    if not task:
        return
    blocks = db.query(models.AppBlock).filter(
        models.AppBlock.until_task_id == task.id,
        models.AppBlock.resolved == False,  # noqa: E712
    ).all()
    for block in blocks:
        block.resolved = True
        block.resolved_at = datetime.now(timezone.utc)


def _bump_milestone_progress(task: models.Task | None, db: Session) -> None:
    """A task tagged toward a milestone ticks it on approval.

    Only count/streak milestones track progress this way — a course
    milestone is achieved by finishing its course, not by task approvals.
    Doesn't commit — _review owns that.
    """
    if not task or not task.milestone_id:
        return
    milestone = db.query(models.Milestone).filter(models.Milestone.id == task.milestone_id).first()
    if milestone and milestone.status == "active" and milestone.kind in ("count", "streak"):
        milestone.progress_count = (milestone.progress_count or 0) + 1


def _review(occurrence_id: UUID, approved: bool, parent: models.Parent, db: Session,
            rejection_note: str | None = None):
    """The one place a parent's review of an occurrence is applied.

    Every approval side effect hangs off here rather than off a route, so
    they can't silently not fire depending on which endpoint was called.
    Each is an independent step over the same occurrence/task rows, folded
    into the single commit at the end.
    """
    occurrence = get_occurrence_for_parent(db, parent, occurrence_id)
    task = db.query(models.Task).filter(models.Task.id == occurrence.task_id).first()

    if approved:
        occurrence.status = "approved"
        occurrence.approved_at = datetime.now(timezone.utc)
        occurrence.approved_by = parent.id
        _award_task_bonus(occurrence, task, parent, db)
        _resolve_app_blocks(task, db)
        _bump_milestone_progress(task, db)
    else:
        occurrence.status = "rejected"
        occurrence.rejection_note = rejection_note
        # Rejecting a bypass means "no, you still owe me this one" — the
        # request is withdrawn and the occurrence goes back to pending,
        # rather than sitting in a rejected-but-still-requested state.
        # (evlin-tables.sql documents this as the intended resolution; only
        # the PUT route implemented it before these paths were unified.)
        if occurrence.bypass_requested:
            occurrence.bypass_requested = False
            occurrence.status = "pending"

    db.commit()
    db.refresh(occurrence)
    return occurrence


@router.post("/tasks/occurrences/{occurrence_id}/approve", response_model=schemas.OccurrenceResponse)
def approve_occurrence(occurrence_id: UUID, current_parent: models.Parent = Depends(get_current_parent),
                       db: Session = Depends(get_db)):
    return _review(occurrence_id, True, current_parent, db)


@router.post("/tasks/occurrences/{occurrence_id}/reject", response_model=schemas.OccurrenceResponse)
def reject_occurrence(occurrence_id: UUID, current_parent: models.Parent = Depends(get_current_parent),
                      db: Session = Depends(get_db)):
    return _review(occurrence_id, False, current_parent, db)
