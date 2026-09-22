from fastapi import APIRouter, Depends, Query
from sqlalchemy import func
from sqlalchemy.orm import Session
from uuid import UUID
from datetime import date
from typing import Optional
import models, schemas
from database import get_db
from routers.auth import get_current_parent
from access import assert_parent_owns_child, assert_child_access

router = APIRouter(tags=["time_grants"])


def award_time_grant(
    db: Session,
    child_id: UUID,
    minutes: int,
    source: str,
    reason: Optional[str] = None,
    granted_by_parent_id: Optional[UUID] = None,
    source_ref_id: Optional[UUID] = None,
) -> models.TimeGrant:
    """Inserts one ledger row. Doesn't commit — callers fold this into
    whatever single commit they already have (see occurrences.py's
    _review, which calls this before its own db.commit())."""
    grant = models.TimeGrant(
        child_id=child_id,
        minutes=minutes,
        source=source,
        reason=reason,
        granted_by_parent_id=granted_by_parent_id,
        source_ref_id=source_ref_id,
        credited_date=date.today(),
    )
    db.add(grant)
    return grant


@router.post("/children/{child_id}/time-grants", response_model=schemas.TimeGrantResponse)
def create_time_grant(
    child_id: UUID,
    body: schemas.TimeGrantCreate,
    current_parent: models.Parent = Depends(get_current_parent),
    db: Session = Depends(get_db),
):
    """Parent grants bonus minutes for today — what GrantExtraTimeSheet
    calls now instead of just mutating local state."""
    assert_parent_owns_child(db, current_parent, child_id)
    grant = award_time_grant(
        db, child_id, body.minutes, source="manual",
        reason=body.reason, granted_by_parent_id=current_parent.id,
    )
    db.commit()
    db.refresh(grant)
    return grant


@router.get("/children/{child_id}/time-grants", response_model=schemas.TimeGrantsSummary)
def get_time_grants(
    child_id: UUID,
    target_date: date = Query(default_factory=date.today, alias="date"),
    db: Session = Depends(get_db),
    _access: None = Depends(assert_child_access),
):
    """Today's pool (or a given day's) — the child's own device or their
    parent. available_minutes = daily_limit_minutes + sum of today's
    grants; there's no usage/consumption subtracted here, since no real
    usage tracking exists yet (see the plan doc) — this is minutes
    *available*, not minutes *remaining*."""
    rule = db.query(models.ChildRule).filter(models.ChildRule.child_id == child_id).first()
    daily_limit = rule.daily_limit_minutes if rule else 60

    grants = db.query(models.TimeGrant).filter(
        models.TimeGrant.child_id == child_id,
        models.TimeGrant.credited_date == target_date,
    ).order_by(models.TimeGrant.created_at).all()
    granted_total = sum(g.minutes for g in grants)

    return schemas.TimeGrantsSummary(
        date=target_date,
        daily_limit_minutes=daily_limit,
        granted_minutes=granted_total,
        available_minutes=daily_limit + granted_total,
        grants=grants,
    )
