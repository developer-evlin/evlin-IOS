"""What an app block means at a given moment — pure functions, no writes.

Four kinds:
- duration    blocked until ends_at (created_at + duration, fixed at creation)
- until_task  blocked until that task is approved (_resolve_app_blocks)
- indefinite  blocked until a parent lifts it
- scheduled   blocked inside a weekly window, local to the child
              ("mon,tue,wed,thu,sun" 19:00–07:00; a window that crosses
              midnight belongs to the day it starts on)

Expiry is computed here, never written. There's no background job to write
it, and a read that wrote would announce a live update, which makes the
device sync, which reads again. `resolved` is reserved for decisions:
'task_approved' and 'parent_lifted'.
"""
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import models
from routers.occurrences import _WEEKDAY_CODES

KINDS = ("duration", "until_task", "indefinite", "scheduled")

_DAY_NAMES = {"mon": "Mon", "tue": "Tue", "wed": "Wed", "thu": "Thu", "fri": "Fri", "sat": "Sat", "sun": "Sun"}


def child_zone(child: models.Child | None) -> ZoneInfo:
    """The child's own zone. UTC until their device has reported one."""
    try:
        return ZoneInfo(child.timezone) if child and child.timezone else ZoneInfo("UTC")
    except ZoneInfoNotFoundError:
        return ZoneInfo("UTC")


def local_now(child: models.Child | None, now: datetime | None = None) -> datetime:
    return (now or datetime.now(timezone.utc)).astimezone(child_zone(child))


def _aware(dt: datetime | None) -> datetime | None:
    # SQLite (the test harness) hands back naive datetimes; Postgres
    # timestamptz is always aware. Naive here means UTC.
    if dt is not None and dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt


def parse_days(raw: str | None) -> list[str]:
    """Weekday codes in week order, deduplicated. Raises on anything else —
    the same vocabulary tasks use, so "school nights" means one thing."""
    codes = [c.strip().lower() for c in (raw or "").split(",") if c.strip()]
    if not codes or any(c not in _WEEKDAY_CODES for c in codes):
        raise ValueError("days must be weekday codes: mon,tue,wed,thu,fri,sat,sun")
    return [c for c in _WEEKDAY_CODES if c in codes]


def parse_clock(raw: str | None) -> time:
    """HH:MM (seconds tolerated). Raises on anything else."""
    try:
        return time.fromisoformat((raw or "").strip())
    except ValueError:
        raise ValueError(f"not a time of day: {raw!r}")


def _window_on(block: models.AppBlock, start_day: date, zone) -> tuple[datetime, datetime]:
    """The scheduled window that starts on start_day, as aware datetimes."""
    start = datetime.combine(start_day, block.schedule_start, tzinfo=zone)
    end_day = start_day if block.schedule_end > block.schedule_start else start_day + timedelta(days=1)
    return start, datetime.combine(end_day, block.schedule_end, tzinfo=zone)


def _days_of(block: models.AppBlock) -> set[str]:
    return {c.strip() for c in (block.schedule_days or "").split(",") if c.strip()}


def current_window(block: models.AppBlock, now_local: datetime) -> tuple[datetime, datetime] | None:
    """The scheduled window `now_local` is inside, if any. Checks the window
    that started today and the one that started yesterday, since an
    overnight window is still running after midnight."""
    days = _days_of(block)
    for back in (0, 1):
        day = now_local.date() - timedelta(days=back)
        if _WEEKDAY_CODES[day.weekday()] in days:
            start, end = _window_on(block, day, now_local.tzinfo)
            if start <= now_local < end:
                return start, end
    return None


def state(block: models.AppBlock, now_local: datetime) -> str:
    """'active' | 'off_window' | 'expired' | 'lifted' | 'done'.

    off_window is a scheduled block that's in force but outside its hours;
    done is an until_task block whose task was approved.
    """
    if block.resolved:
        return "done" if block.resolved_reason == "task_approved" else "lifted"
    if block.block_type == "duration":
        ends = _aware(block.ends_at)
        return "active" if ends is None or now_local < ends else "expired"
    if block.block_type == "scheduled":
        return "active" if current_window(block, now_local) else "off_window"
    return "active"  # until_task, indefinite


def is_active(block: models.AppBlock, now_local: datetime) -> bool:
    return state(block, now_local) == "active"


def is_in_force(block: models.AppBlock, now_local: datetime) -> bool:
    """Still part of the rules — active now, or a scheduled block waiting
    for its next window. What "active blocks" means in a list."""
    return state(block, now_local) in ("active", "off_window")


def _clock(t: time) -> str:
    return t.strftime("%H:%M")


def _day_span(days: set[str]) -> str:
    ordered = [c for c in _WEEKDAY_CODES if c in days]
    if len(ordered) == 7:
        return "every day"
    if ordered == ["mon", "tue", "wed", "thu", "fri"]:
        return "weekdays"
    if ordered == ["sat", "sun"]:
        return "weekends"
    if ordered == ["mon", "tue", "wed", "thu", "sun"]:
        return "school nights"
    return ", ".join(_DAY_NAMES[c] for c in ordered)


def describe(block: models.AppBlock, now_local: datetime, task_title: str | None = None) -> str:
    """How a parent (and the AI) would say what this block is doing. One
    wording for the app and the prompt, so they never disagree."""
    kind = block.block_type
    if kind == "duration":
        ends = _aware(block.ends_at)
        return f"until {ends.astimezone(now_local.tzinfo):%H:%M}" if ends else "for a while"
    if kind == "until_task":
        return f"until '{task_title}' is approved" if task_title else "until a task is approved"
    if kind == "scheduled":
        return f"{_day_span(_days_of(block))} {_clock(block.schedule_start)}–{_clock(block.schedule_end)}"
    return "until you lift it"
