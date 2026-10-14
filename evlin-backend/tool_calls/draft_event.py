"""draft_event — manage the calendar.

Pre-fills the app's Add Event card. Creates nothing: the parent's tap on
the card is what adds the event.
"""
import re
from datetime import date

TOOL = {
    "name": "draft_event",
    "description": (
        "Pre-fill the app's Add Event card for an entry on the child's calendar: somewhere the child has to "
        "be — an appointment, a lesson or class someone else runs, a match, a party, a trip. Every event is "
        "the child's; there are no parent or family-wide events. Something the child has to do and get "
        "checked off is a task (draft_task), even at a set time: a piano lesson with a teacher is an event, "
        "practising piano at home is a task. If the parent didn't say the day or the start time, call "
        "ask_follow_up instead of guessing. If the parent asks for several events, call this once per "
        "event in the same reply. Does not create the event itself."
    ),
    "parameters": {
        "type": "OBJECT",
        "properties": {
            "title": {"type": "STRING", "description": "Short event title, e.g. 'Football practice'"},
            "start_date": {"type": "STRING", "description": "Resolved calendar date as YYYY-MM-DD"},
            "start_time": {"type": "STRING", "description": "24-hour HH:MM"},
            "end_time": {"type": "STRING", "description": "24-hour HH:MM. Assume an hour if the parent didn't say."},
            "recurrence": {
                "type": "STRING",
                "description": (
                    "'none', 'daily', or comma-joined weekday codes from mon,tue,wed,thu,fri,sat,sun. "
                    "Nothing else."
                ),
            },
            "note": {"type": "STRING", "description": "Anything else worth recording, or empty."},
        },
        "required": ["title", "start_date", "start_time"],
    },
}

REPLY = "Here's the event — check the details before you add it."

_TIME = re.compile(r"^([01]?\d|2[0-3]):[0-5]\d(:[0-5]\d)?$")


def follow_up_for(args: dict, child_name: str, today: date) -> str | None:
    """The question to ask instead of showing this draft, or None if it's
    complete. The card would otherwise fill a missing day with today and a
    missing time with 9:00 — a guess the parent might not notice."""
    title = str(args.get("title") or "").strip() or "it"
    raw = str(args.get("start_date") or "").strip()
    try:
        day = date.fromisoformat(raw) if raw else None
    except ValueError:
        day = None
    if day is None:
        return f"What day is “{title}”?"
    if day < today and str(args.get("recurrence") or "none").strip().lower() in ("", "none"):
        return f"That date has already passed — what day is “{title}”?"
    if not _TIME.match(str(args.get("start_time") or "").strip()):
        return f"What time does “{title}” start?"
    return None
