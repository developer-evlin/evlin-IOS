"""Two parents (or a phone back online after a force-quit) can change the
same task or the same child's lock (2026-11-19). The rule:

- Per field: a phone sends only the fields it changed, so a title edit on
  one phone never overwrites a repeat edit made on the other.
- Last write wins, by when the edit was made, not when it arrived: each
  write carries `X-Edited-At` (the moment it was queued on the phone), and
  a field takes a value only if that's at least as new as the field's last
  change (`field_edits`, a field -> ISO time map on the row). So an old edit
  replayed late can't undo a newer one. A time in the future counts as now.
- A write with no `X-Edited-At` (an older build) counts as made when it
  arrives, as before.
"""
from datetime import datetime, timezone

from fastapi import Request


def edited_at(request: Request) -> datetime:
    now = datetime.now(timezone.utc)
    raw = request.headers.get("x-edited-at")
    if not raw:
        return now
    try:
        at = datetime.fromisoformat(raw.strip().replace("Z", "+00:00"))
    except ValueError:
        return now
    if at.tzinfo is None:
        at = at.replace(tzinfo=timezone.utc)
    return min(at, now)


def apply(row, values: dict, at: datetime) -> list[str]:
    """Sets each field newer than its last change; returns the ones set."""
    stamps = dict(row.field_edits or {})
    applied = []
    for field, value in values.items():
        last = stamps.get(field)
        if last:
            try:
                last_at = datetime.fromisoformat(last)
            except ValueError:
                last_at = None
            if last_at is not None and last_at > at:
                continue
        setattr(row, field, value)
        stamps[field] = at.isoformat()
        applied.append(field)
    row.field_edits = stamps
    return applied
