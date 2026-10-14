"""GET /children/{id}/policy — see policy.py."""
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

import models
from access import assert_child_access
from database import get_db
from policy import compute_policy

router = APIRouter(tags=["policy"])


@router.get("/children/{child_id}/policy")
def get_policy(child_id: UUID, db: Session = Depends(get_db), _access: None = Depends(assert_child_access)):
    """Both sides: the child's device enforces it, the parent sees the same
    answer the device does."""
    child = db.query(models.Child).filter(models.Child.id == child_id).first()
    if not child:
        raise HTTPException(status_code=404, detail="Child not found")
    return compute_policy(db, child)
