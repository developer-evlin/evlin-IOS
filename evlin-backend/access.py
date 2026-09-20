"""Ownership checks shared by the routers.

Every endpoint that takes a child/task/occurrence id used to trust that the id
belonged to the caller ("simplified for MVP"), so any signed-in parent could
read or change any other family's data. These helpers close that.
"""
from uuid import UUID
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials
from sqlalchemy.orm import Session
import models
from database import get_db
from routers.auth import get_current_parent, get_current_device, hash_token, security


def parent_owns_child(db: Session, parent: models.Parent, child_id: UUID) -> bool:
    return db.query(models.ParentChild).filter(
        models.ParentChild.parent_id == parent.id,
        models.ParentChild.child_id == child_id,
    ).first() is not None


def assert_parent_owns_child(db: Session, parent: models.Parent, child_id: UUID) -> None:
    # 404 rather than 403 so ids of other families can't be probed.
    if not parent_owns_child(db, parent, child_id):
        raise HTTPException(status_code=404, detail="Child not found")


def get_task_for_parent(db: Session, parent: models.Parent, task_id: UUID) -> models.Task:
    task = db.query(models.Task).filter(models.Task.id == task_id).first()
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    assert_parent_owns_child(db, parent, task.child_id)
    return task


def get_occurrence_for_parent(db: Session, parent: models.Parent, occurrence_id: UUID) -> models.Occurrence:
    occ = db.query(models.Occurrence).filter(models.Occurrence.id == occurrence_id).first()
    if not occ:
        raise HTTPException(status_code=404, detail="Occurrence not found")
    assert_parent_owns_child(db, parent, occ.child_id)
    return occ


def assert_child_access(
    child_id: UUID,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
) -> None:
    """Allow either the child's own paired device or a parent of that child."""
    device = db.query(models.Device).filter(
        models.Device.token_hash == hash_token(credentials.credentials),
        models.Device.revoked_at == None,  # noqa: E711
    ).first()
    if device:
        if device.child_id != child_id:
            raise HTTPException(status_code=404, detail="Child not found")
        return
    parent = get_current_parent(credentials, db)
    assert_parent_owns_child(db, parent, child_id)


def get_occurrence_for_device_or_parent(
    occurrence_id: UUID,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
) -> models.Occurrence:
    """Same either/or rule as assert_child_access, resolved from an
    occurrence id instead of a child id — used by routes that only take the
    occurrence (submissions)."""
    occ = db.query(models.Occurrence).filter(models.Occurrence.id == occurrence_id).first()
    if not occ:
        raise HTTPException(status_code=404, detail="Occurrence not found")
    device = db.query(models.Device).filter(
        models.Device.token_hash == hash_token(credentials.credentials),
        models.Device.revoked_at == None,  # noqa: E711
    ).first()
    if device:
        if device.child_id != occ.child_id:
            raise HTTPException(status_code=404, detail="Occurrence not found")
        return occ
    parent = get_current_parent(credentials, db)
    assert_parent_owns_child(db, parent, occ.child_id)
    return occ
