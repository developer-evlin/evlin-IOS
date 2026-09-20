from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from uuid import UUID
import models, schemas
from database import get_db
from routers.auth import get_current_parent

router = APIRouter(tags=["children"])

@router.get("/children", response_model=list[schemas.ChildResponse])
def get_children(current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """Get all children belonging to the current parent"""
    parent_children = db.query(models.ParentChild).filter(models.ParentChild.parent_id == current_parent.id).all()
    child_ids = [pc.child_id for pc in parent_children]
    
    children = db.query(models.Child).filter(models.Child.id.in_(child_ids)).all()
    
    # Calculate is_paired
    for child in children:
        devices = db.query(models.Device).filter(models.Device.child_id == child.id).count()
        child.is_paired = devices > 0
        
    return children

@router.post("/children", response_model=schemas.ChildResponse)
def create_child(child: schemas.ChildCreate, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """Create a new child and link them to the current parent"""
    
    # 1. Create Child
    new_child = models.Child(
        name=child.name,
        birth_year=child.birth_year,
        color_index=child.color_index,
        avatar_url=child.avatar_url
    )
    db.add(new_child)
    db.commit()
    db.refresh(new_child)
    
    # 2. Link Parent and Child
    parent_link = models.ParentChild(
        parent_id=current_parent.id,
        child_id=new_child.id,
        role="primary"
    )
    db.add(parent_link)
    
    # 3. Create Default Rules (Screen Time limit, etc.)
    default_rules = models.ChildRule(
        child_id=new_child.id,
        daily_limit_minutes=60, # Matches frontend default
        downtime_enabled=False,
        bedtime_enabled=False,
        blocked_categories=[]
    )
    db.add(default_rules)
    
    # 4. Create Default State (Unlocked)
    default_state = models.ChildState(
        child_id=new_child.id,
        manual_lock=False,
        task_gate_override=False
    )
    db.add(default_state)
    
    db.commit()
    return new_child
