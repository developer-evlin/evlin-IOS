"""Blocking one app, either for a while or until a task is done.

The "until a task is done" case is why this is a table rather than the
free-text child_rules.custom_rules sentence the app used before: it has to
resolve itself when that task gets approved, which nothing can do with a
sentence. See models.py's AppBlock and occurrences.py's
_resolve_app_blocks.
"""
from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

import models
import schemas
from access import assert_child_access, assert_parent_owns_child, get_task_for_parent
from database import get_db
from routers.auth import get_current_parent

router = APIRouter(tags=["app_blocks"])


@router.post("/children/{child_id}/app-blocks", response_model=schemas.AppBlockResponse)
def create_app_block(child_id: UUID, body: schemas.AppBlockCreate,
                     current_parent: models.Parent = Depends(get_current_parent),
                     db: Session = Depends(get_db)):
    assert_parent_owns_child(db, current_parent, child_id)

    if body.until_task_id is not None:
        # Blocking until *someone else's* task is done would be both wrong
        # and unresolvable from this child's own approvals.
        task = get_task_for_parent(db, current_parent, body.until_task_id)
        if task.child_id != child_id:
            raise HTTPException(status_code=400, detail="That task belongs to another child")

    block = models.AppBlock(
        child_id=child_id,
        app_name=body.app_name,
        app_bundle_id=body.app_bundle_id,
        block_type=body.block_type,
        duration_minutes=body.duration_minutes,
        until_task_id=body.until_task_id,
        created_by=body.created_by,
    )
    db.add(block)
    db.commit()
    db.refresh(block)
    return block


@router.get("/children/{child_id}/app-blocks", response_model=list[schemas.AppBlockResponse])
def list_app_blocks(child_id: UUID, active: bool = Query(True), db: Session = Depends(get_db),
                    _access: None = Depends(assert_child_access)):
    """Both sides — the kid's device reads this to show an app as blocked."""
    q = db.query(models.AppBlock).filter(models.AppBlock.child_id == child_id)
    if active:
        q = q.filter(models.AppBlock.resolved == False)  # noqa: E712
    return q.order_by(models.AppBlock.created_at.desc()).all()


@router.delete("/app-blocks/{block_id}")
def delete_app_block(block_id: UUID,
                     current_parent: models.Parent = Depends(get_current_parent),
                     db: Session = Depends(get_db)):
    """A parent lifting a block early."""
    block = db.query(models.AppBlock).filter(models.AppBlock.id == block_id).first()
    if not block:
        raise HTTPException(status_code=404, detail="Block not found")
    assert_parent_owns_child(db, current_parent, block.child_id)
    db.delete(block)
    db.commit()
    return {"detail": "Block removed"}
