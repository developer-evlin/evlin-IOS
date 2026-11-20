"""Instant unlock (2026-11-19, the user's rules).

On, work the child sends in counts as finished at once: the child's device
unlocks without waiting for the parent to check (policy.py). The parent can
still ask for a redo, which locks it again.

It's earned first: 3 approved days, any 3, not in a row. A day counts when
the child sent in that day's tasks on their device and the parent approved
them all; a task the parent ticked done without the child sending it in
doesn't count (no `completed_at`), and a day with no tasks doesn't count.
Counted from `child_state.instant_unlock_reset_on` (turning it off starts
the count again). Worked out from the occurrences the server already keeps,
by the child's own days. The approval that makes the third day writes
`instant_unlock_earned_at`; the server refuses "on" until it's set.
"""
from datetime import date, datetime, timezone

from sqlalchemy.orm import Session

import models

NEEDED = 3


def approved_days(db: Session, child_id, since: date | None) -> int:
    q = db.query(models.Occurrence.due_date, models.Occurrence.status, models.Occurrence.completed_at
                 ).filter(models.Occurrence.child_id == child_id)
    if since is not None:
        q = q.filter(models.Occurrence.due_date >= since)
    days: dict = {}
    for day, status, completed_at in q.all():
        days.setdefault(day, []).append(status == "approved" and completed_at is not None)
    return sum(1 for done in days.values() if done and all(done))


def earned(state: models.ChildState | None) -> bool:
    return state is not None and state.instant_unlock_earned_at is not None


def is_on(state: models.ChildState | None) -> bool:
    """On and earned: what decides whether sent-in work counts as finished."""
    return state is not None and bool(state.instant_unlock) and earned(state)


def progress(db: Session, state: models.ChildState | None, child_id) -> dict:
    if earned(state):
        return {"instant_unlock_earned": True, "instant_unlock_days": NEEDED, "instant_unlock_needed": NEEDED}
    count = approved_days(db, child_id, state.instant_unlock_reset_on if state else None)
    return {"instant_unlock_earned": False, "instant_unlock_days": min(count, NEEDED),
            "instant_unlock_needed": NEEDED}


def note_approval(db: Session, child_id) -> None:
    """After an approval (routers/occurrences.py _review, before its commit):
    the third approved day earns it."""
    state = db.query(models.ChildState).filter(models.ChildState.child_id == child_id).first()
    if state is None or earned(state):
        return
    db.flush()
    if approved_days(db, child_id, state.instant_unlock_reset_on) >= NEEDED:
        state.instant_unlock_earned_at = datetime.now(timezone.utc)
