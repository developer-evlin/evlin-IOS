from datetime import datetime, timezone
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from uuid import UUID
import models, schemas
from database import get_db
from routers.auth import get_current_parent
from access import assert_parent_owns_child
from routers.auth import get_current_device

router = APIRouter(tags=["children"])


def device_kind(platform):
    """"ipad" or "iphone" from the platform a device paired with, so the
    parent's phone can name it; None for older builds' plain "ios"."""
    return platform if platform in ("ipad", "iphone") else None

@router.get("/children", response_model=list[schemas.ChildResponse])
def get_children(current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """Get all children belonging to the current parent"""
    parent_children = db.query(models.ParentChild).filter(models.ParentChild.parent_id == current_parent.id).all()
    child_ids = [pc.child_id for pc in parent_children]
    
    children = db.query(models.Child).filter(models.Child.id.in_(child_ids)).all()
    
    # Paired, and whether that device has finished its setup.
    for child in children:
        devices = db.query(models.Device).filter(models.Device.child_id == child.id).all()
        child.is_paired = len(devices) > 0
        child.setup_complete = any(d.setup_completed_at is not None for d in devices)
        child.setup_stage = next((d.setup_stage for d in devices if d.setup_stage), None)
        child.device_kind = next((device_kind(d.platform) for d in devices if device_kind(d.platform)), None)
        
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
    # Only fills an empty one: until the kid's device has reported its zone,
    # the parent's phone stands in for it (a family nearly always shares
    # one), so "today" on the server isn't UTC's.
    if update.timezone is not None and child.timezone is None:
        child.timezone = update.timezone
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


@router.delete("/children/{child_id}/device")
def unpair_device(child_id: UUID, current_parent: models.Parent = Depends(get_current_parent),
                  db: Session = Depends(get_db)):
    """The parent unpairs the child's device. Its token stops working, so its
    next request is a 401 and the kid's app goes back to the start. Until
    then the token is the only thing that keeps a kid's phone signed in:
    updates and reinstalls keep it, and it doesn't expire."""
    assert_parent_owns_child(db, current_parent, child_id)
    db.query(models.Device).filter(models.Device.child_id == child_id).delete()
    db.commit()
    return {"detail": "Device unpaired"}


@router.put("/children/{child_id}/setup-stage")
def set_setup_stage(child_id: UUID, body: schemas.ParentSetupStage,
                    current_parent: models.Parent = Depends(get_current_parent),
                    db: Session = Depends(get_db)):
    """"I've created the account" from the parent's phone: the kid's device
    showing how to make the child's Apple Account moves on to signing in,
    as if it had been tapped there. Only a device on that step moves, so a
    late or repeated tap changes nothing."""
    assert_parent_owns_child(db, current_parent, child_id)
    devices = db.query(models.Device).filter(models.Device.child_id == child_id).all()
    changed = False
    for device in devices:
        if device.setup_stage == "creating_account":
            device.setup_stage = body.setup_stage
            changed = True
    if changed:
        db.commit()
    return {"setup_stage": next((d.setup_stage for d in devices if d.setup_stage), None)}


@router.get("/device/me", response_model=schemas.ChildResponse)
def get_my_child(device: models.Device = Depends(get_current_device), db: Session = Depends(get_db)):
    """The child profile a paired device belongs to (so the kid's app can show
    the name their parent sees, and learn their id)."""
    child = db.query(models.Child).filter(models.Child.id == device.child_id).first()
    if not child:
        raise HTTPException(status_code=404, detail="Child not found")
    child.is_paired = True
    child.setup_stage = device.setup_stage
    return child


@router.put("/device/me", response_model=schemas.ChildResponse)
def update_my_device(body: schemas.DeviceUpdate, device: models.Device = Depends(get_current_device),
                     db: Session = Depends(get_db)):
    """What the child's own device knows about the child that the server
    can't: which timezone "today" is in.

    Sent on every sync, so it only writes on a real change. An unchanged
    value written anyway would announce a live update, which makes the
    device sync, which sends this again.
    """
    child = db.query(models.Child).filter(models.Child.id == device.child_id).first()
    if not child:
        raise HTTPException(status_code=404, detail="Child not found")
    changed = False
    if body.timezone is not None and body.timezone != child.timezone:
        child.timezone = body.timezone
        changed = True
    # The name typed on the kid's device after pairing.
    from routers.auth import _usable_name
    name = _usable_name(body.name)
    if name and name != child.name:
        child.name = name
        changed = True
    # Once only: later syncs send it again, and an unchanged write would
    # announce a live update for nothing.
    if body.setup_complete and device.setup_completed_at is None:
        device.setup_completed_at = datetime.now(timezone.utc)
        changed = True
    # Family Sharing's hand-off; "" clears it (the kid's device left the step).
    if body.setup_stage is not None:
        stage = body.setup_stage or None
        if stage != device.setup_stage:
            device.setup_stage = stage
            changed = True
    if changed:
        db.commit()
        db.refresh(child)
    child.is_paired = True
    # Echoed, so the device knows the server has it (and keeps telling an
    # older server that doesn't).
    child.setup_complete = device.setup_completed_at is not None
    child.setup_stage = device.setup_stage
    return child
