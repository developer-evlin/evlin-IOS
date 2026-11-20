"""The screen time access code (2026-11-19, the user's call): six random
digits a parent types on their child's device to get into its settings.

Made and checked only here, kept in app.access_codes (models.AccessCode),
never on a device. One parent's code opens any of their children's devices.
A code is good for a minute (`LIFETIME`) and once: typed right, it's used
up, and asking again makes a new one. The child's device asks again every
time its settings are opened.
"""
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.orm import Session

import models
import schemas
from database import get_db
from routers.auth import get_current_device, get_current_parent, limiter

router = APIRouter(tags=["access code"])

LIFETIME = timedelta(minutes=1)
# Time to type it on the child's device after the phone's countdown ends,
# and the two clocks a little apart.
GRACE = timedelta(seconds=5)
# Codes long gone are cleared as new ones are made.
KEEP = timedelta(days=1)


def _aware(t: datetime) -> datetime:
    """SQLite (the tests) hands back naive datetimes; Postgres aware ones."""
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


@router.post("/access-code", response_model=schemas.AccessCodeResponse)
def current_code(current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """The parent's code right now: the one still good, or a new one. The
    phone shows it with how long it has left and asks again when it runs
    out. A POST: it can make a row."""
    now = datetime.now(timezone.utc)
    db.query(models.AccessCode).filter(models.AccessCode.parent_id == current_parent.id,
                                       models.AccessCode.expires_at < now - KEEP).delete(synchronize_session=False)
    live = (db.query(models.AccessCode)
            .filter(models.AccessCode.parent_id == current_parent.id,
                    models.AccessCode.used_at.is_(None),
                    models.AccessCode.expires_at > now)
            .order_by(models.AccessCode.expires_at.desc()).first())
    if live is None:
        live = models.AccessCode(parent_id=current_parent.id, code=f"{secrets.randbelow(1_000_000):06d}",
                                 expires_at=now + LIFETIME)
        db.add(live)
    db.commit()
    db.refresh(live)
    left = max(0.0, (_aware(live.expires_at) - now).total_seconds())
    return {"code": live.code, "expires_at": _aware(live.expires_at), "seconds_left": left,
            "lifetime": LIFETIME.total_seconds()}


@router.post("/device/access-code", response_model=schemas.AccessCodeCheckResponse)
@limiter.limit("10/minute")
def check_code(request: Request, body: schemas.AccessCodeCheck,
               current_device: models.Device = Depends(get_current_device), db: Session = Depends(get_db)):
    """The child's device: whether a typed code is one of this child's
    parents' codes, still good and not used. Right, it's used up."""
    typed = (body.code or "").strip()
    if len(typed) != 6 or not typed.isdigit() or current_device.child_id is None:
        return {"ok": False}
    now = datetime.now(timezone.utc)
    parents = db.query(models.ParentChild.parent_id).filter(models.ParentChild.child_id == current_device.child_id)
    match = (db.query(models.AccessCode)
             .filter(models.AccessCode.parent_id.in_(parents),
                     models.AccessCode.code == typed,
                     models.AccessCode.used_at.is_(None),
                     models.AccessCode.expires_at > now - GRACE)
             .first())
    if match is None:
        return {"ok": False}
    match.used_at = now
    db.commit()
    return {"ok": True}
