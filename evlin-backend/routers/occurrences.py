from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
from uuid import UUID
from datetime import date, datetime, timedelta, timezone
import models, schemas
from database import get_db
from routers.auth import get_current_parent, get_current_device
from access import assert_child_access, get_occurrence_for_parent
from routers.time_grants import award_time_grant
import storage

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
        if existing:
            continue
        # Another request (the same sync's policy fetch, the other phone)
        # can make the same one between the check and the insert: the
        # unique index refuses the second, and this one is simply skipped.
        try:
            with db.begin_nested():
                db.add(models.Occurrence(
                    task_id=task.id,
                    child_id=child_id,
                    due_date=target_date,
                    due_time=task.due_time,
                    status="pending",
                    gates_apps=task.gates_apps,
                ))
        except IntegrityError:
            pass
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
    """A task's screen-time bonus. Doesn't commit — _review owns that."""
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
        block.resolved_reason = "task_approved"
        block.resolved_at = datetime.now(timezone.utc)


def _sent_in(occurrence: models.Occurrence, db: Session) -> bool:
    """Whether the kid sent this in (as opposed to a parent ticking it done
    with nothing from the kid)."""
    return occurrence.completed_at is not None or db.query(models.Submission).filter(
        models.Submission.occurrence_id == occurrence.id).first() is not None


def _undo_approval(occurrence: models.Occurrence, task: models.Task | None,
                   parent: models.Parent, db: Session) -> None:
    """Takes an approval back, leaving the task as it was before it: waiting
    for review if the kid had sent it in (what they sent is kept), plain
    "to do" if they hadn't. What approving did is undone too: the bonus
    minutes come back off (a balancing ledger row, not a deletion), and an
    app block the approval lifted is in force again. Doesn't commit —
    _review owns that."""
    was_approved = occurrence.status == "approved"
    approved_at = occurrence.approved_at
    occurrence.status = "submitted" if _sent_in(occurrence, db) else "pending"
    occurrence.rejection_note = None
    occurrence.approved_at = None
    occurrence.approved_by = None
    if not was_approved:
        return
    paid = sum(g.minutes for g in db.query(models.TimeGrant).filter(
        models.TimeGrant.source_ref_id == occurrence.id,
        models.TimeGrant.source.in_(("task_bonus", "task_bonus_undone")),
    ).all())
    if paid:
        award_time_grant(
            db, occurrence.child_id, -paid, source="task_bonus_undone",
            reason=f"Task: {task.title if task else ''} (approval undone)",
            granted_by_parent_id=parent.id, source_ref_id=occurrence.id,
        )
    if task and approved_at:
        for block in db.query(models.AppBlock).filter(
            models.AppBlock.until_task_id == task.id,
            models.AppBlock.resolved == True,  # noqa: E712
            models.AppBlock.resolved_reason == "task_approved",
            models.AppBlock.resolved_at >= approved_at,
        ).all():
            block.resolved = False
            block.resolved_reason = None
            block.resolved_at = None


def _review(occurrence_id: UUID, approved: bool, parent: models.Parent, db: Session,
            rejection_note: str | None = None, undo: bool = False):
    """The one place a parent's review of an occurrence is applied.

    Every approval side effect hangs off here rather than off a route, so
    they can't silently not fire depending on which endpoint was called.
    Each is an independent step over the same occurrence/task rows, folded
    into the single commit at the end.
    """
    occurrence = get_occurrence_for_parent(db, parent, occurrence_id)
    task = db.query(models.Task).filter(models.Task.id == occurrence.task_id).first()
    discarded_keys: list[str] = []

    if undo:
        # Taking an approval back (the parent unticked it): the task returns
        # to how it was, with nothing for the kid to read as sent back.
        if occurrence.status == "approved":
            _undo_approval(occurrence, task, parent, db)
    elif approved:
        # Every side effect below is a one-time payout: a second approval
        # used to award the bonus again.
        if occurrence.status == "approved":
            raise HTTPException(status_code=409, detail="Already approved")
        occurrence.status = "approved"
        occurrence.approved_at = datetime.now(timezone.utc)
        occurrence.approved_by = parent.id
        _award_task_bonus(occurrence, task, parent, db)
        _resolve_app_blocks(task, db)
    elif not occurrence.bypass_requested and not _sent_in(occurrence, db):
        # Nothing was ever sent in: the parent ticked it done themselves and
        # is taking that back. That's an undo, not a redo: the task goes
        # back to plain "to do", with no note and nothing for the kid to read
        # as "sent back", and what the approval did is reversed.
        _undo_approval(occurrence, task, parent, db)
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
        else:
            # A redo starts the task over: what was sent in is discarded, so
            # neither phone keeps showing the old photos next to the new.
            subs = db.query(models.Submission).filter(models.Submission.occurrence_id == occurrence.id).all()
            discarded_keys = [s.r2_key for s in subs]
            for s in subs:
                db.delete(s)

    db.commit()
    db.refresh(occurrence)
    # The files go after the commit, so a failed delete never undoes the redo.
    storage.delete_objects(discarded_keys)
    return occurrence


@router.post("/tasks/occurrences/{occurrence_id}/approve", response_model=schemas.OccurrenceResponse)
def approve_occurrence(occurrence_id: UUID, current_parent: models.Parent = Depends(get_current_parent),
                       db: Session = Depends(get_db)):
    return _review(occurrence_id, True, current_parent, db)


@router.post("/tasks/occurrences/{occurrence_id}/unapprove", response_model=schemas.OccurrenceResponse)
def unapprove_occurrence(occurrence_id: UUID, current_parent: models.Parent = Depends(get_current_parent),
                         db: Session = Depends(get_db)):
    """Takes an approval back: the task is as it was before it (see
    _undo_approval). Not approved: nothing changes."""
    return _review(occurrence_id, False, current_parent, db, undo=True)


@router.post("/tasks/occurrences/{occurrence_id}/reject", response_model=schemas.OccurrenceResponse)
def reject_occurrence(occurrence_id: UUID, current_parent: models.Parent = Depends(get_current_parent),
                      db: Session = Depends(get_db)):
    return _review(occurrence_id, False, current_parent, db)
