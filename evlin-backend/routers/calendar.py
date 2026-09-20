from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session
from uuid import UUID
from datetime import datetime
from typing import List
import models, schemas
from database import get_db
from routers.auth import get_current_parent
from access import assert_parent_owns_child, parent_owns_child
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
    # Family-wide events (child_id NULL) have no owner column, so they are
    # editable by any parent that has at least one child. Child events need
    # ownership of that child.
    if event.child_id is not None:
        assert_parent_owns_child(db, parent, event.child_id)
    return event


@router.get("/children/{child_id}/events", response_model=List[schemas.EventResponse])
def get_child_events(
    child_id: UUID,
    start_date: datetime = Query(...),
    end_date: datetime = Query(...),
    current_parent: models.Parent = Depends(get_current_parent),
    db: Session = Depends(get_db)
):
    assert_parent_owns_child(db, current_parent, child_id)
    # Family-wide events (child_id is NULL) plus this child's own. A recurring
    # event that started before the window still has to come back, so filter
    # on "starts before the window ends" and let the client expand repeats.
    events = db.query(models.Event).filter(
        (models.Event.child_id == child_id) | (models.Event.child_id == None),
        models.Event.start_at <= end_date,
        (models.Event.start_at >= start_date) | (models.Event.recurrence != "none")
    ).all()
    return events


@router.post("/events", response_model=schemas.EventResponse)
def create_event(event: schemas.EventCreate, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    if event.child_id is not None:
        assert_parent_owns_child(db, current_parent, event.child_id)
    if event.end_at < event.start_at:
        raise HTTPException(status_code=400, detail="end_at must not be before start_at")
    new_event = models.Event(
        child_id=event.child_id,
        title=event.title,
        start_at=event.start_at,
        end_at=event.end_at,
        gates_apps=event.gates_apps,
        location_or_link=event.location_or_link,
        # The DB only allows ('manual','ics_import') here — it describes how
        # the row was created, not whose calendar lane it's in (that's
        # child_id / is_parent_only). There's no ICS import feature yet, so
        # this is always "manual" regardless of what a client sends.
        source="manual",
        is_parent_only=event.is_parent_only,
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
    if update.child_id is not None:
        assert_parent_owns_child(db, current_parent, update.child_id)
    event.child_id = update.child_id
    event.title = update.title
    event.start_at = update.start_at
    event.end_at = update.end_at
    event.gates_apps = update.gates_apps
    event.location_or_link = update.location_or_link
    event.source = "manual"
    event.is_parent_only = update.is_parent_only
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
