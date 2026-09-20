from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session
from uuid import UUID
from datetime import datetime, timezone, time
import models, schemas
from database import get_db
from routers.auth import get_current_parent
from access import assert_parent_owns_child

router = APIRouter(tags=["rules", "state"])

@router.get("/children/{child_id}/rules", response_model=schemas.ChildRuleResponse)
def get_child_rules(child_id: UUID, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    assert_parent_owns_child(db, current_parent, child_id)
    rules = db.query(models.ChildRule).filter(models.ChildRule.child_id == child_id).first()
    if not rules:
        # Default fallback if missing
        rules = models.ChildRule(child_id=child_id)
        db.add(rules)
        db.commit()
        db.refresh(rules)
    return rules

@router.put("/children/{child_id}/rules", response_model=schemas.ChildRuleResponse)
def update_child_rules(child_id: UUID, rules_update: schemas.ChildRuleUpdate, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    assert_parent_owns_child(db, current_parent, child_id)
    rules = db.query(models.ChildRule).filter(models.ChildRule.child_id == child_id).first()
    if not rules:
        rules = models.ChildRule(child_id=child_id)
        db.add(rules)

    rules.daily_limit_minutes = rules_update.daily_limit_minutes
    rules.downtime_enabled = rules_update.downtime_enabled
    if rules_update.downtime_start:
        rules.downtime_start = time.fromisoformat(rules_update.downtime_start)
    if rules_update.downtime_end:
        rules.downtime_end = time.fromisoformat(rules_update.downtime_end)
        
    rules.bedtime_enabled = rules_update.bedtime_enabled
    if rules_update.bedtime_start:
        rules.bedtime_start = time.fromisoformat(rules_update.bedtime_start)
    if rules_update.bedtime_end:
        rules.bedtime_end = time.fromisoformat(rules_update.bedtime_end)

    rules.blocked_categories = rules_update.blocked_categories
    rules.updated_at = datetime.now(timezone.utc)
    
    db.commit()
    db.refresh(rules)
    return rules

@router.get("/children/{child_id}/state", response_model=schemas.ChildStateResponse)
def get_child_state(child_id: UUID, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    assert_parent_owns_child(db, current_parent, child_id)
    state = db.query(models.ChildState).filter(models.ChildState.child_id == child_id).first()
    if not state:
        state = models.ChildState(child_id=child_id)
        db.add(state)
        db.commit()
        db.refresh(state)
    return state

@router.put("/children/{child_id}/state", response_model=schemas.ChildStateResponse)
def update_child_state(child_id: UUID, state_update: schemas.ChildStateUpdate, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    assert_parent_owns_child(db, current_parent, child_id)
    state = db.query(models.ChildState).filter(models.ChildState.child_id == child_id).first()
    if not state:
        state = models.ChildState(child_id=child_id)
        db.add(state)
        
    state.manual_lock = state_update.manual_lock
    state.task_gate_override = state_update.task_gate_override
    state.last_tripwire_minutes = state_update.last_tripwire_minutes
    state.updated_at = datetime.now(timezone.utc)
    
    db.commit()
    db.refresh(state)
    return state
