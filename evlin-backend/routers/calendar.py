from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session
from uuid import UUID
from datetime import datetime, timezone
from typing import List, Optional
import models, schemas
from database import get_db
from routers.auth import get_current_parent

router = APIRouter(tags=["calendar"])

@router.get("/children/{child_id}/events", response_model=List[schemas.EventResponse])
def get_child_events(
    child_id: UUID, 
    start_date: datetime = Query(...), 
    end_date: datetime = Query(...), 
    current_parent: models.Parent = Depends(get_current_parent), 
    db: Session = Depends(get_db)
):
    # Events can be family-wide (child_id is None) or specific to the child
    events = db.query(models.Event).filter(
        (models.Event.child_id == child_id) | (models.Event.child_id == None),
        models.Event.start_at >= start_date,
        models.Event.start_at <= end_date
    ).all()
    return events

@router.post("/events", response_model=schemas.EventResponse)
def create_event(event: schemas.EventCreate, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    new_event = models.Event(
        title=event.title,
        start_at=event.start_at,
        end_at=event.end_at,
        gates_apps=event.gates_apps,
        location_or_link=event.location_or_link,
        source=event.source
    )
    db.add(new_event)
    db.commit()
    db.refresh(new_event)
    return new_event

@router.delete("/events/{event_id}")
def delete_event(event_id: UUID, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    db_event = db.query(models.Event).filter(models.Event.id == event_id).first()
    if not db_event:
        raise HTTPException(status_code=404, detail="Event not found")
        
    db.delete(db_event)
    db.commit()
    return {"detail": "Event deleted"}
