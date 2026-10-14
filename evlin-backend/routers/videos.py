"""Today's videos: each child's video settings and their parent-approved list.

The list is the only thing the child's player will play. Videos reach it one
way, a parent's approval (POST /children/{id}/video-queue). Nothing in the
app writes to it yet: the Library runs on sample data until the Library
Agent exists, and this is kept for it.

"Today" is the child's day (blocks.local_now). Time left is computed from
what was watched, on every read, never stored.
"""
from datetime import date, datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials
from sqlalchemy.orm import Session

import models
import schemas
import video_filter
from access import assert_child_access, assert_parent_owns_child, check_child_access
from blocks import local_now
from database import get_db
from routers.auth import get_current_parent, security
from video_curation import profile_for

router = APIRouter(tags=["videos"])


def _child(db: Session, child_id: UUID) -> models.Child:
    child = db.query(models.Child).filter(models.Child.id == child_id).first()
    if not child:
        raise HTTPException(status_code=404, detail="Child not found")
    return child


def _profile_response(profile: dict) -> schemas.VideoProfileResponse:
    return schemas.VideoProfileResponse(**profile, all_categories=list(video_filter.CATEGORIES))


def _today_items(db: Session, child_id: UUID, day: date) -> list[models.VideoQueueItem]:
    return db.query(models.VideoQueueItem).filter(
        models.VideoQueueItem.child_id == child_id,
        models.VideoQueueItem.local_date == day,
    ).order_by(models.VideoQueueItem.position, models.VideoQueueItem.created_at).all()


def queue_for(db: Session, child: models.Child, day: date | None = None) -> schemas.VideoQueueResponse:
    day = day or local_now(child).date()
    items = _today_items(db, child.id, day)
    daily = profile_for(db, child.id)["daily_minutes"]
    watched = sum(i.watched_seconds for i in items)
    return schemas.VideoQueueResponse(
        child_id=child.id, local_date=day, daily_minutes=daily, watched_seconds=watched,
        remaining_seconds=max(0, daily * 60 - watched),
        items=[schemas.VideoQueueItemResponse.model_validate(i) for i in items],
    )


def _item_for_parent(db: Session, parent: models.Parent, item_id: UUID) -> models.VideoQueueItem:
    item = db.query(models.VideoQueueItem).filter(models.VideoQueueItem.id == item_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Video not found")
    assert_parent_owns_child(db, parent, item.child_id)
    return item


# ---- settings -----------------------------------------------------------

@router.get("/children/{child_id}/video-profile", response_model=schemas.VideoProfileResponse)
def get_video_profile(child_id: UUID, db: Session = Depends(get_db),
                      _access: None = Depends(assert_child_access)):
    return _profile_response(profile_for(db, child_id))


@router.put("/children/{child_id}/video-profile", response_model=schemas.VideoProfileResponse)
def update_video_profile(child_id: UUID, body: schemas.VideoProfileUpdate,
                         current_parent: models.Parent = Depends(get_current_parent),
                         db: Session = Depends(get_db)):
    """Partial: only the fields sent change."""
    assert_parent_owns_child(db, current_parent, child_id)
    _child(db, child_id)
    if body.allowed_categories is not None:
        unknown = {c.strip().lower() for c in body.allowed_categories} - set(video_filter.CATEGORIES)
        if unknown:
            raise HTTPException(status_code=400, detail=f"Unknown categories: {sorted(unknown)}")

    current = profile_for(db, child_id)
    row = db.query(models.ChildVideoProfile).filter(models.ChildVideoProfile.child_id == child_id).first()
    if row is None:
        row = models.ChildVideoProfile(
            child_id=child_id,
            allowed_categories=current["allowed_categories"],
            blocked_keywords=[], allowed_channels=[], blocked_channels=[],
            daily_minutes=current["daily_minutes"], max_video_minutes=current["max_video_minutes"],
        )
        db.add(row)

    if body.allowed_categories is not None:
        row.allowed_categories = video_filter.normalize_categories(body.allowed_categories)
    if body.blocked_keywords is not None:
        row.blocked_keywords = body.blocked_keywords
    if body.allowed_channels is not None or body.blocked_channels is not None:
        allowed = [c.model_dump() for c in body.allowed_channels] if body.allowed_channels is not None \
            else list(row.allowed_channels or [])
        blocked = [c.model_dump() for c in body.blocked_channels] if body.blocked_channels is not None \
            else list(row.blocked_channels or [])
        # A channel is one or the other. Blocking wins.
        blocked_ids = {c["id"] for c in blocked}
        row.allowed_channels = [c for c in allowed if c["id"] not in blocked_ids]
        row.blocked_channels = blocked
    if body.daily_minutes is not None:
        row.daily_minutes = body.daily_minutes
    if body.max_video_minutes is not None:
        row.max_video_minutes = body.max_video_minutes
    row.updated_at = datetime.now(timezone.utc)
    db.commit()
    return _profile_response(profile_for(db, child_id))


# ---- the list -----------------------------------------------------------

@router.get("/children/{child_id}/video-queue", response_model=schemas.VideoQueueResponse)
def get_video_queue(child_id: UUID, day: date | None = None, db: Session = Depends(get_db),
                    _access: None = Depends(assert_child_access)):
    """Both sides. Without ?day= it's the child's today."""
    return queue_for(db, _child(db, child_id), day)


@router.post("/children/{child_id}/video-queue", response_model=schemas.VideoQueueResponse)
def add_to_video_queue(child_id: UUID, body: schemas.VideoQueueCreate,
                       current_parent: models.Parent = Depends(get_current_parent),
                       db: Session = Depends(get_db)):
    """The parent's approval — the one way a video reaches a child.

    replace drops what's still unwatched today and keeps anything started,
    so the minutes already used still count. A video already on today's list
    isn't added twice."""
    assert_parent_owns_child(db, current_parent, child_id)
    child = _child(db, child_id)
    day = local_now(child).date()
    items = _today_items(db, child_id, day)
    if body.replace:
        for i in items:
            if i.watched_seconds == 0 and i.completed_at is None:
                db.delete(i)
        items = [i for i in items if i.watched_seconds > 0 or i.completed_at is not None]

    have = {i.video_id for i in items}
    position = max((i.position for i in items), default=-1) + 1
    for v in body.videos:
        if v.video_id in have:
            continue
        have.add(v.video_id)
        db.add(models.VideoQueueItem(
            child_id=child_id, local_date=day, position=position,
            video_id=v.video_id, title=v.title[:200], channel_id=v.channel_id,
            channel_title=v.channel_title, thumbnail_url=v.thumbnail_url,
            duration_seconds=v.duration_seconds, category=v.category,
            added_by_parent_id=current_parent.id,
        ))
        position += 1
    db.commit()
    return queue_for(db, child, day)


@router.put("/children/{child_id}/video-queue/order", response_model=schemas.VideoQueueResponse)
def reorder_video_queue(child_id: UUID, body: schemas.VideoQueueOrder,
                        current_parent: models.Parent = Depends(get_current_parent),
                        db: Session = Depends(get_db)):
    assert_parent_owns_child(db, current_parent, child_id)
    child = _child(db, child_id)
    day = local_now(child).date()
    items = {i.id: i for i in _today_items(db, child_id, day)}
    if set(body.item_ids) != set(items):
        raise HTTPException(status_code=400, detail="item_ids must be exactly today's list")
    for pos, item_id in enumerate(body.item_ids):
        if items[item_id].position != pos:
            items[item_id].position = pos
    db.commit()
    return queue_for(db, child, day)


@router.delete("/video-queue/{item_id}")
def remove_from_video_queue(item_id: UUID, current_parent: models.Parent = Depends(get_current_parent),
                            db: Session = Depends(get_db)):
    item = _item_for_parent(db, current_parent, item_id)
    db.delete(item)
    db.commit()
    return {"detail": "Video removed"}


@router.post("/video-queue/{item_id}/progress", response_model=schemas.VideoQueueItemResponse)
def report_progress(item_id: UUID, body: schemas.VideoProgress,
                    credentials: HTTPAuthorizationCredentials = Depends(security),
                    db: Session = Depends(get_db)):
    """The child's player saying how long this video has been played, in
    total (a rewatch keeps counting, so it spends the allowance too). Only
    ever moves forward, so a repeated report changes nothing, and never by
    more than what's left of today's allowance."""
    item = db.query(models.VideoQueueItem).filter(models.VideoQueueItem.id == item_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Video not found")
    check_child_access(db, credentials, item.child_id)
    child = _child(db, item.child_id)
    remaining = queue_for(db, child, item.local_date).remaining_seconds
    watched = min(body.watched_seconds, item.watched_seconds + remaining)
    if watched > item.watched_seconds:
        item.watched_seconds = watched
    if body.completed and item.completed_at is None:
        item.completed_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(item)
    return item
