from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from uuid import UUID
import models, schemas
from database import get_db
from routers.auth import get_current_parent
from access import assert_parent_owns_child
from routers.auth import get_current_device

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


@router.put("/children/{child_id}", response_model=schemas.ChildResponse)
def update_child(child_id: UUID, update: schemas.ChildUpdate, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """Rename / recolor a child."""
    assert_parent_owns_child(db, current_parent, child_id)
    child = db.query(models.Child).filter(models.Child.id == child_id).first()
    if not child:
        raise HTTPException(status_code=404, detail="Child not found")
    if update.name is not None:
        if not update.name.strip():
            raise HTTPException(status_code=400, detail="name must not be blank")
        child.name = update.name.strip()[:60]
    if update.color_index is not None:
        child.color_index = update.color_index
    if update.birth_year is not None:
        child.birth_year = update.birth_year
    db.commit()
    db.refresh(child)
    child.is_paired = db.query(models.Device).filter(models.Device.child_id == child.id).count() > 0
    return child


@router.delete("/children/{child_id}")
def delete_child(child_id: UUID, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """Remove a child profile: its tasks, rules, devices etc. cascade with it."""
    assert_parent_owns_child(db, current_parent, child_id)
    db.query(models.ParentChild).filter(models.ParentChild.child_id == child_id).delete()
    db.query(models.Child).filter(models.Child.id == child_id).delete()
    db.commit()
    return {"detail": "Child removed"}


@router.get("/device/me", response_model=schemas.ChildResponse)
def get_my_child(device: models.Device = Depends(get_current_device), db: Session = Depends(get_db)):
    """The child profile a paired device belongs to (so the kid's app can show
    the name their parent sees, and learn their id)."""
    child = db.query(models.Child).filter(models.Child.id == device.child_id).first()
    if not child:
        raise HTTPException(status_code=404, detail="Child not found")
    child.is_paired = True
    return child
