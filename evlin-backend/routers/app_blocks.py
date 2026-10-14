"""Blocking apps: for a while, until a task is done, until lifted, or on a
weekly schedule.

A block is a row per catalog app (see app_catalog.py), not the free-text
child_rules.custom_rules sentence the app used before — a sentence can't
lift itself when the homework is approved, and nothing can enforce it. What
each kind means at a given moment lives in blocks.py.
"""
from datetime import datetime, timedelta, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

import blocks
import models
import schemas
from access import assert_child_access, assert_parent_owns_child, get_task_for_parent
from database import get_db
from routers.auth import get_current_parent

router = APIRouter(tags=["app_blocks"])


def block_response(db: Session, block: models.AppBlock, child: models.Child | None = None,
                   now: datetime | None = None) -> schemas.AppBlockResponse:
    """A row plus what it means right now, in the child's own timezone."""
    child = child or db.query(models.Child).filter(models.Child.id == block.child_id).first()
    now_local = blocks.local_now(child, now)
    title = None
    if block.until_task_id:
        task = db.query(models.Task).filter(models.Task.id == block.until_task_id).first()
        title = task.title if task else None
    body = schemas.AppBlockResponse.model_validate(block)
    body.state = blocks.state(block, now_local)
    body.description = blocks.describe(block, now_local, title)
    return body


def blocks_in_force(db: Session, child: models.Child, now: datetime | None = None) -> list[models.AppBlock]:
    """Blocks still part of the rules: active now, or scheduled and waiting
    for their next window. Newest first."""
    now_local = blocks.local_now(child, now)
    rows = db.query(models.AppBlock).filter(
        models.AppBlock.child_id == child.id,
        models.AppBlock.resolved == False,  # noqa: E712
    ).order_by(models.AppBlock.created_at.desc()).all()
    return [b for b in rows if blocks.is_in_force(b, now_local)]


@router.post("/children/{child_id}/app-blocks", response_model=list[schemas.AppBlockResponse])
def create_app_blocks(child_id: UUID, body: schemas.AppBlockCreate,
                      current_parent: models.Parent = Depends(get_current_parent),
                      db: Session = Depends(get_db)):
    """One row per app, all in one commit — "YouTube and Roblox until
    homework" is two blocks that can each be lifted on their own."""
    assert_parent_owns_child(db, current_parent, child_id)
    child = db.query(models.Child).filter(models.Child.id == child_id).first()

    wanted = list(dict.fromkeys(body.app_ids))  # keep order, drop repeats
    apps = {a.id: a for a in db.query(models.App).filter(models.App.id.in_(wanted)).all()}
    if unknown := [str(a) for a in wanted if a not in apps]:
        raise HTTPException(status_code=400, detail=f"Unknown app ids: {unknown}")

    on_list = {a for (a,) in db.query(models.ChildApp.app_id).filter(models.ChildApp.child_id == child_id).all()}
    missing = [apps[a] for a in wanted if a not in on_list]
    if missing and not body.add_to_list:
        names = ", ".join(a.name for a in missing)
        raise HTTPException(status_code=400, detail=f"Not on {child.name}'s app list yet: {names}")
    for app in missing:
        db.add(models.ChildApp(child_id=child_id, app_id=app.id, added_by=body.created_by))

    if body.until_task_id is not None:
        # Blocking until *someone else's* task is done would be both wrong
        # and unresolvable from this child's own approvals.
        task = get_task_for_parent(db, current_parent, body.until_task_id)
        if task.child_id != child_id:
            raise HTTPException(status_code=400, detail="That task belongs to another child")

    now = datetime.now(timezone.utc)
    created = []
    for app_id in wanted:
        block = models.AppBlock(
            child_id=child_id,
            app_id=app_id,
            app_name=apps[app_id].name,
            block_type=body.block_type,
            duration_minutes=body.duration_minutes if body.block_type == "duration" else None,
            ends_at=now + timedelta(minutes=body.duration_minutes) if body.block_type == "duration" else None,
            until_task_id=body.until_task_id if body.block_type == "until_task" else None,
            schedule_days=body.schedule_days if body.block_type == "scheduled" else None,
            schedule_start=blocks.parse_clock(body.schedule_start) if body.block_type == "scheduled" else None,
            schedule_end=blocks.parse_clock(body.schedule_end) if body.block_type == "scheduled" else None,
            created_by=body.created_by,
        )
        db.add(block)
        created.append(block)
    db.commit()
    return [block_response(db, b, child) for b in created]


@router.get("/children/{child_id}/app-blocks", response_model=list[schemas.AppBlockResponse])
def list_app_blocks(child_id: UUID, active: bool = Query(True), db: Session = Depends(get_db),
                    _access: None = Depends(assert_child_access)):
    """Both sides. active=true is what's still in force (including a
    scheduled block outside its hours — its `state` says which); false is
    the whole history, lifted and expired included."""
    child = db.query(models.Child).filter(models.Child.id == child_id).first()
    if active:
        rows = blocks_in_force(db, child)
    else:
        rows = db.query(models.AppBlock).filter(
            models.AppBlock.child_id == child_id
        ).order_by(models.AppBlock.created_at.desc()).all()
    return [block_response(db, b, child) for b in rows]


@router.post("/app-blocks/{block_id}/lift", response_model=schemas.AppBlockResponse)
def lift_app_block(block_id: UUID,
                   current_parent: models.Parent = Depends(get_current_parent),
                   db: Session = Depends(get_db)):
    """A parent lifting a block early. Kept as history rather than deleted,
    so "what was blocked" still has an answer afterwards."""
    block = db.query(models.AppBlock).filter(models.AppBlock.id == block_id).first()
    if not block:
        raise HTTPException(status_code=404, detail="Block not found")
    assert_parent_owns_child(db, current_parent, block.child_id)
    if block.resolved:
        raise HTTPException(status_code=409, detail="That block has already ended")
    block.resolved = True
    block.resolved_reason = "parent_lifted"
    block.resolved_at = datetime.now(timezone.utc)
    db.commit()
    return block_response(db, block)
