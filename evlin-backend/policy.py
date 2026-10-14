"""The one answer to "what should this child's device be doing right now".

Before this, the iOS client pieced it together from four endpoints (state,
occurrences, time grants, app blocks) with its own copy of
the rules. This computes it once, from the same tables and the same
helpers every route already uses:

  locked        manual lock, or a gating task not yet approved today
                (unless the parent overrode the task gate)
  lock_apps     the child's lockable list — what a lock covers
  blocked_now   individual apps blocked at this moment (blocks.py)
  allowance     today's screen time: base limit (or weekly override) plus
                today's grants; no limit when the parent switched it off

All "today" and "now" are the child's own (children.timezone).
"""
import hashlib
import json
from datetime import datetime

from sqlalchemy.orm import Session

import blocks
import models
from routers.apps import child_apps
from routers.app_blocks import blocks_in_force
from routers.occurrences import _generate_occurrences_for_date
from routers.time_grants import _base_limit_for


def compute_policy(db: Session, child: models.Child, now: datetime | None = None) -> dict:
    now_local = blocks.local_now(child, now)
    today = now_local.date()

    state = db.query(models.ChildState).filter(models.ChildState.child_id == child.id).first()
    rule = db.query(models.ChildRule).filter(models.ChildRule.child_id == child.id).first()

    # Idempotent: creates today's occurrences only if they don't exist yet,
    # exactly as GET /occurrences does. Without it a gating task nobody has
    # opened today wouldn't count.
    _generate_occurrences_for_date(child.id, today, db)
    occurrences = db.query(models.Occurrence).filter(
        models.Occurrence.child_id == child.id, models.Occurrence.due_date == today
    ).all()
    # The occurrence's own gates_apps snapshot, not the task's current flag:
    # editing a task later doesn't rewrite what today already required.
    outstanding = [o for o in occurrences if o.gates_apps and o.status != "approved"]

    reasons = []
    if outstanding and not (state and state.task_gate_override):
        reasons.append("unfinished_tasks")
    if state and state.manual_lock:
        reasons.append("manual_lock")

    limit_enabled = rule.daily_limit_enabled if rule is not None and rule.daily_limit_enabled is not None else True
    granted = sum(g.minutes for g in db.query(models.TimeGrant).filter(
        models.TimeGrant.child_id == child.id, models.TimeGrant.credited_date == today
    ).all())
    allowance = max(0, _base_limit_for(rule, today) + granted) if limit_enabled else None

    blocked_now, scheduled = [], []
    for b in blocks_in_force(db, child, now):
        title = None
        if b.until_task_id:
            task = db.query(models.Task).filter(models.Task.id == b.until_task_id).first()
            title = task.title if task else None
        if blocks.is_active(b, now_local):
            ends = blocks._aware(b.ends_at)
            window = blocks.current_window(b, now_local) if b.block_type == "scheduled" else None
            until = ends or (window[1] if window else None)
            blocked_now.append({
                "block_id": str(b.id), "app_id": str(b.app_id) if b.app_id else None, "app_name": b.app_name,
                "kind": b.block_type, "description": blocks.describe(b, now_local, title),
                "until": until.isoformat() if until else None,
            })
        if b.block_type == "scheduled":
            # The definitions, so a device can keep enforcing the window with
            # no connection. Times are the child's local clock.
            scheduled.append({
                "block_id": str(b.id), "app_id": str(b.app_id) if b.app_id else None, "app_name": b.app_name,
                "days": b.schedule_days, "start": b.schedule_start.strftime("%H:%M"),
                "end": b.schedule_end.strftime("%H:%M"),
            })

    doc = {
        "child_id": str(child.id),
        "timezone": now_local.tzinfo.key,
        "local_date": today.isoformat(),
        "locked": bool(reasons),
        "lock_reasons": reasons,
        "lock_apps": [{"app_id": str(a.id), "name": a.name} for a in child_apps(db, child.id)],
        "blocked_now": blocked_now,
        "scheduled_blocks": scheduled,
        "daily_limit_enabled": limit_enabled,
        "allowance_minutes": allowance,
    }
    # Same inputs, same etag: a device can tell "nothing changed" without
    # comparing field by field.
    doc["etag"] = hashlib.sha256(json.dumps(doc, sort_keys=True).encode()).hexdigest()[:16]
    return doc
