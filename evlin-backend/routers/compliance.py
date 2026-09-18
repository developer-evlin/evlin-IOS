from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from uuid import UUID
import models, schemas
from database import get_db
from routers.auth import get_current_parent, get_current_device

router = APIRouter(tags=["compliance"])

@router.post("/consent")
def record_consent(consent: schemas.ConsentCreate, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """Record parent consent (Terms of Service, Privacy Policy, etc)"""
    new_consent = models.Consent(
        parent_id=current_parent.id,
        toggle_key=consent.toggle_key,
        granted=consent.granted,
        version=consent.version
    )
    db.add(new_consent)
    db.commit()
    return {"status": "recorded"}

@router.post("/audit")
def record_audit(audit: schemas.AuditLogCreate, current_device: models.Device = Depends(get_current_device), db: Session = Depends(get_db)):
    """Record a child audit event (e.g. app blocked, lock screen bypassed)"""
    new_audit = models.AuditLog(
        child_id=current_device.child_id,
        kind=audit.kind,
        metadata_json=audit.metadata
    )
    db.add(new_audit)
    db.commit()
    return {"status": "recorded"}
