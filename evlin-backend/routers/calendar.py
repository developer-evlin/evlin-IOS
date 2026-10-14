from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session
from uuid import UUID
from datetime import datetime
from typing import List, Optional
import models, schemas
from database import get_db
from routers.auth import get_current_parent, get_current_device
from access import assert_child_access, assert_parent_owns_child, parent_owns_child
from sqlalchemy.exc import IntegrityError

router = APIRouter(tags=["calendar"])


def _commit_or_400(db: Session):
    try:
        db.commit()
    except IntegrityError as e:
        db.rollback()
        raise HTTPException(status_code=400, detail=f"That couldn't be saved: {e.orig}")


def _event_for_parent(db: Session, parent: models.Parent, event_id: UUID) -> models.Event:
    event = db.query(models.Event).filter(models.Event.id == event_id).first()
    if not event:
        raise HTTPException(status_code=404, detail="Event not found")
    assert_parent_owns_child(db, parent, event.child_id)
    return event


def _existing_event(db: Session, event_id: Optional[UUID], child_id: UUID) -> Optional[models.Event]:
    """The event a retried create already made, if any. The id comes from
    the phone, so one belonging to another child is refused."""
    if event_id is None:
        return None
    existing = db.query(models.Event).filter(models.Event.id == event_id).first()
    if existing is not None and existing.child_id != child_id:
        raise HTTPException(status_code=409, detail="That id is already in use")
    return existing


@router.get("/children/{child_id}/events", response_model=List[schemas.EventResponse])
def get_child_events(
    child_id: UUID,
    start_date: datetime = Query(...),
    end_date: datetime = Query(...),
    db: Session = Depends(get_db),
    _access: None = Depends(assert_child_access),
):
    """This child's events, for a parent of the child or the child's own
    device (the kid's calendar). Writing stays parent-only."""
    # This child's events. A recurring event that started before the window
    # still has to come back, so filter on "starts before the window ends"
    # and let the client expand repeats.
    events = db.query(models.Event).filter(
        models.Event.child_id == child_id,
        models.Event.start_at <= end_date,
        (models.Event.start_at >= start_date) | (models.Event.recurrence != "none")
    ).all()
    return events


@router.post("/events", response_model=schemas.EventResponse)
def create_event(event: schemas.EventCreate, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    assert_parent_owns_child(db, current_parent, event.child_id)
    existing = _existing_event(db, event.id, event.child_id)
    if existing is not None:
        return existing
    if event.end_at < event.start_at:
        raise HTTPException(status_code=400, detail="end_at must not be before start_at")
    new_event = models.Event(
        **({"id": event.id} if event.id is not None else {}),
        child_id=event.child_id,
        title=event.title,
        start_at=event.start_at,
        end_at=event.end_at,
        gates_apps=event.gates_apps,
        location_or_link=event.location_or_link,
        # The DB only allows ('manual','ics_import') here — it describes how
        # the row was created. There's no ICS import feature yet, so this is
        # always "manual" regardless of what a client sends.
        source="manual",
        category=event.category,
        note=event.note,
        recurrence=event.recurrence,
    )
    db.add(new_event)
    _commit_or_400(db)
    db.refresh(new_event)
    return new_event


@router.put("/events/{event_id}", response_model=schemas.EventResponse)
def update_event(event_id: UUID, update: schemas.EventCreate, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    event = _event_for_parent(db, current_parent, event_id)
    assert_parent_owns_child(db, current_parent, update.child_id)
    event.child_id = update.child_id
    event.title = update.title
    event.start_at = update.start_at
    event.end_at = update.end_at
    event.gates_apps = update.gates_apps
    event.location_or_link = update.location_or_link
    event.source = "manual"
    event.category = update.category
    event.note = update.note
    event.recurrence = update.recurrence
    _commit_or_400(db)
    db.refresh(event)
    return event


@router.delete("/events/{event_id}")
def delete_event(event_id: UUID, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    db_event = _event_for_parent(db, current_parent, event_id)
    db.delete(db_event)
    db.commit()
    return {"detail": "Event deleted"}


# ---- kids' plans ----------------------------------------------------------
#
# A child plans something on their own calendar: an event with
# created_by='child' and status='proposed'. The parent approves it (it's then
# an ordinary event) or declines it with an optional note; a declined plan
# stays on the child's calendar until they dismiss it. Plans are one day
# only, and a child can only change or remove their own plans while they're
# still waiting (or, once declined, dismiss them).

def _plan_for_device(db: Session, device: models.Device, event_id: UUID) -> models.Event:
    event = db.query(models.Event).filter(models.Event.id == event_id).first()
    if not event or event.child_id != device.child_id or event.created_by != "child":
        raise HTTPException(status_code=404, detail="Plan not found")
    return event


def _check_times(start_at: datetime, end_at: datetime):
    if end_at < start_at:
        raise HTTPException(status_code=400, detail="end_at must not be before start_at")


@router.post("/device/plans", response_model=schemas.EventResponse)
def create_plan(plan: schemas.PlanCreate, device: models.Device = Depends(get_current_device), db: Session = Depends(get_db)):
    existing = _existing_event(db, plan.id, device.child_id)
    if existing is not None:
        return existing
    _check_times(plan.start_at, plan.end_at)
    event = models.Event(
        **({"id": plan.id} if plan.id is not None else {}),
        child_id=device.child_id,
        title=plan.title,
        start_at=plan.start_at,
        end_at=plan.end_at,
        location_or_link=plan.location_or_link,
        category=plan.category,
        note=plan.note,
        recurrence="none",
        source="manual",
        created_by="child",
        status="proposed",
    )
    db.add(event)
    _commit_or_400(db)
    db.refresh(event)
    return event


@router.put("/device/plans/{event_id}", response_model=schemas.EventResponse)
def update_plan(event_id: UUID, plan: schemas.PlanCreate, device: models.Device = Depends(get_current_device), db: Session = Depends(get_db)):
    event = _plan_for_device(db, device, event_id)
    if event.status != "proposed":
        raise HTTPException(status_code=409, detail="Only a plan that's still waiting can be changed")
    _check_times(plan.start_at, plan.end_at)
    event.title = plan.title
    event.start_at = plan.start_at
    event.end_at = plan.end_at
    event.location_or_link = plan.location_or_link
    event.category = plan.category
    event.note = plan.note
    _commit_or_400(db)
    db.refresh(event)
    return event


@router.delete("/device/plans/{event_id}")
def delete_plan(event_id: UUID, device: models.Device = Depends(get_current_device), db: Session = Depends(get_db)):
    """Withdraw a waiting plan, or dismiss a declined one ("Okay, got it")."""
    event = _plan_for_device(db, device, event_id)
    if event.status not in ("proposed", "declined"):
        raise HTTPException(status_code=409, detail="An approved plan is on the calendar now")
    db.delete(event)
    db.commit()
    return {"detail": "Plan removed"}


def _review_plan(event: models.Event, approved: bool, note: Optional[str], db: Session) -> models.Event:
    """The one place a parent's answer to a plan is applied."""
    if event.created_by != "child" or event.status != "proposed":
        raise HTTPException(status_code=409, detail="This isn't a plan waiting for an answer")
    event.status = "approved" if approved else "declined"
    event.review_note = None if approved else ((note or "").strip() or None)
    _commit_or_400(db)
    db.refresh(event)
    return event


@router.post("/events/{event_id}/approve", response_model=schemas.EventResponse)
def approve_plan(event_id: UUID, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    return _review_plan(_event_for_parent(db, current_parent, event_id), True, None, db)


@router.post("/events/{event_id}/decline", response_model=schemas.EventResponse)
def decline_plan(event_id: UUID, body: schemas.PlanDecline, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    return _review_plan(_event_for_parent(db, current_parent, event_id), False, body.note, db)
