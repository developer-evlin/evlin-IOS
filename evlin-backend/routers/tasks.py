from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session
from uuid import UUID
from datetime import datetime, timezone, timedelta, time
import models, schemas
from database import get_db
from routers.auth import get_current_parent

router = APIRouter(tags=["tasks"])

@router.get("/children/{child_id}/tasks", response_model=list[schemas.TaskResponse])
def get_child_tasks(child_id: UUID, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """Fetch all tasks for a specific child (Parent only)"""
    # Enforce parent access (simplified for MVP)
    tasks = db.query(models.Task).filter(models.Task.child_id == child_id).all()
    return tasks

@router.post("/children/{child_id}/tasks", response_model=schemas.TaskResponse)
def create_task(child_id: UUID, task: schemas.TaskCreate, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """Create a new task for a child"""
    
    # Optional string time parsing (HH:MM:SS)
    parsed_time = None
    if task.due_time:
        try:
            parsed_time = time.fromisoformat(task.due_time)
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid time format. Use HH:MM:SS")

    new_task = models.Task(
        child_id=child_id,
        title=task.title,
        instructions=task.instructions,
        bucket=task.bucket,
        due_time=parsed_time,
        recurrence=task.recurrence,
        gates_apps=task.gates_apps,
        points=task.points,
        submission_kind=task.submission_kind,
        active=task.active
    )
    db.add(new_task)
    db.commit()
    db.refresh(new_task)
    return new_task

@router.put("/tasks/{task_id}", response_model=schemas.TaskResponse)
def update_task(task_id: UUID, task_update: schemas.TaskCreate, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """Update an existing task"""
    db_task = db.query(models.Task).filter(models.Task.id == task_id).first()
    if not db_task:
        raise HTTPException(status_code=404, detail="Task not found")

    parsed_time = None
    if task_update.due_time:
        try:
            parsed_time = time.fromisoformat(task_update.due_time)
        except ValueError:
            pass

    db_task.title = task_update.title
    db_task.instructions = task_update.instructions
    db_task.bucket = task_update.bucket
    db_task.due_time = parsed_time
    db_task.recurrence = task_update.recurrence
    db_task.gates_apps = task_update.gates_apps
    db_task.points = task_update.points
    db_task.submission_kind = task_update.submission_kind
    db_task.active = task_update.active

    db.commit()
    db.refresh(db_task)
    return db_task

@router.delete("/tasks/{task_id}")
def delete_task(task_id: UUID, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """Delete a task"""
    db_task = db.query(models.Task).filter(models.Task.id == task_id).first()
    if not db_task:
        raise HTTPException(status_code=404, detail="Task not found")
        
    db.delete(db_task)
    db.commit()
    return {"detail": "Task deleted"}
