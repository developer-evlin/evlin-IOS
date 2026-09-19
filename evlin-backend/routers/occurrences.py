from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session
from uuid import UUID
from datetime import date, datetime, timezone
import models, schemas
from database import get_db
from routers.auth import get_current_parent, get_current_device

router = APIRouter(tags=["occurrences"])

def _generate_occurrences_for_date(child_id: UUID, target_date: date, db: Session):
    """
    On-demand materializer. 
    Finds active tasks for the child and ensures an occurrence exists for the target date.
    (Simplified recurrence logic for MVP: 'daily' and 'none' create occurrences)
    """
    tasks = db.query(models.Task).filter(
        models.Task.child_id == child_id,
        models.Task.active == True
    ).all()
    
    for task in tasks:
        # Check if occurrence already exists
        existing = db.query(models.Occurrence).filter(
            models.Occurrence.task_id == task.id,
            models.Occurrence.due_date == target_date
        ).first()
        
        if not existing:
            # For 'daily' or 'weekly' we can add logic. For now let's just make it daily for everything
            # MVP: just generate it.
            new_occurrence = models.Occurrence(
                task_id=task.id,
                child_id=child_id,
                due_date=target_date,
                due_time=task.due_time,
                status="pending",
                gates_apps=task.gates_apps,
                points=task.points
            )
            db.add(new_occurrence)
    db.commit()

@router.get("/children/{child_id}/occurrences", response_model=list[schemas.OccurrenceResponse])
def get_occurrences(child_id: UUID, target_date: date = Query(...), db: Session = Depends(get_db)):
    """Fetch all occurrences for a child on a specific date (Can be called by parent or child)"""
    
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
    """Parent approves or rejects an occurrence"""
    occurrence = db.query(models.Occurrence).filter(models.Occurrence.id == occurrence_id).first()
    if not occurrence:
        raise HTTPException(status_code=404, detail="Occurrence not found")
        
    occurrence.status = status_update.status
    if status_update.status == "approved":
        occurrence.approved_at = datetime.now(timezone.utc)
        occurrence.approved_by = current_parent.id
    elif status_update.status == "rejected":
        occurrence.rejection_note = status_update.rejection_note
        # If rejecting a bypass request, clear the bypass flag so it stays pending
        if occurrence.bypass_requested:
            occurrence.bypass_requested = False
            occurrence.status = "pending"
            
    db.commit()
    db.refresh(occurrence)
    return occurrence

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
