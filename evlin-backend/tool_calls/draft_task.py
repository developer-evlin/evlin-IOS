"""draft_task — assign a task.

Pre-fills the app's Add Task card. Creates nothing: the parent's tap on the
card is what creates the task (see tool_calls/__init__.py).
"""
from datetime import date

TOOL = {
    "name": "draft_task",
    "description": (
        "Pre-fill the app's Add Task card for the parent to review and confirm — does not create the task "
        "itself. A task is something the child has to do and the parent checks off: chores, homework, "
        "reading, practising an instrument at home. It's still a task when it happens at a set time or "
        "repeats: 'piano practice every weekday at 5pm' is a task, not a calendar event. "
        "Work out the concrete date, time and recurrence from what the parent said; the card is meant to "
        "arrive correct, not to be filled in by hand afterwards. If the parent didn't say which day (or "
        "that it repeats), don't pick one — call ask_follow_up to ask when. If the parent asks for several "
        "tasks, call this once per task in the same reply."
    ),
    "parameters": {
        "type": "OBJECT",
        "properties": {
            "title": {"type": "STRING", "description": "Short task title, e.g. 'Tidy his room'"},
            "instructions": {"type": "STRING", "description": "What to actually do, if the parent said. Empty otherwise."},
            "due_date": {
                "type": "STRING",
                "description": (
                    "Resolved calendar date as YYYY-MM-DD: the day it's due, or the first day for a repeating "
                    "task. Only a day the parent actually said; empty for a repeating task with no start day."
                ),
            },
            "due_time": {"type": "STRING", "description": "24-hour HH:MM. Empty if no specific time."},
            "recurrence": {
                "type": "STRING",
                "description": (
                    "'none' for a one-off, 'daily', or comma-joined weekday codes from "
                    "mon,tue,wed,thu,fri,sat,sun — e.g. 'mon,wed,fri' or 'sat,sun'. Nothing else."
                ),
            },
            "gates_apps": {"type": "BOOLEAN", "description": "Whether not doing it should keep apps locked. Default true."},
            "bonus_minutes": {"type": "INTEGER", "description": "Extra screen-time minutes for finishing it, 0 if the parent didn't say."},
            "emoji": {
                "type": "STRING",
                "description": (
                    "The single emoji shown beside this task on the child's phone. Pick the one a 6-12 year old "
                    "would instantly read as this task: the object or the action itself, not a mood or a face. "
                    "Any emoji in Unicode, as specific as possible: 🦷 brushing teeth, 🧦 sorting socks, 🐠 feeding "
                    "the fish, 🎻 violin practice, 🧩 a puzzle, 🌱 watering the seedlings. Use ⭐ only when nothing "
                    "fits. Exactly one emoji, no words."
                ),
            },
        },
        "required": ["title"],
    },
}

# What the assistant says while the card does the rest.
REPLY = "Sure — let's set that up."


def follow_up_for(args: dict, child_name: str, today: date) -> str | None:
    """The question to ask instead of showing this draft, or None if it's
    complete. A one-off needs a day: the model is told to ask rather than
    pick one, and this holds it to that — without a day the task used to
    land on whatever date the server's UTC clock said."""
    title = str(args.get("title") or "").strip() or "this task"
    recurrence = str(args.get("recurrence") or "none").strip().lower()
    raw = str(args.get("due_date") or "").strip()
    if raw:
        try:
            day = date.fromisoformat(raw)
        except ValueError:
            return f"Which day should {child_name} do “{title}”?"
        if day < today:
            return f"That date has already passed — which day should {child_name} do “{title}”?"
        return None
    if recurrence in ("", "none"):
        return f"When should {child_name} do “{title}”?"
    return None
