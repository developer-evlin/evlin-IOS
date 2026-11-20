"""draft_app_block — block one app for a length of time.

Pre-fills the chat's Block card, which offers exactly what blocking by hand
from the child's screen time page does (Parent/AddBlockedAppsSheet.swift):
one app, and 30 minutes, an hour, a custom length, the rest of today, or no
end time. Creates nothing: the parent's tap on Block does, and the parent can
change the app or the length first.

Blocks are by time, never tied to a task or a weekly schedule (README).
"""
import re

import models

LENGTHS = ("30_minutes", "1_hour", "custom", "rest_of_today", "no_end_time")

TOOL = {
    "name": "draft_app_block",
    "description": (
        "Pre-fill the Block card for ONE app on the child's phone, for a length of time; call once per app. Use it "
        "when the parent wants an app blocked, paused or taken away. Blocks are by time only, never 'until a task "
        "is done' or on a weekly schedule: if asked for that, offer a length instead. If the parent didn't name the "
        "app, call ask_follow_up and ask which one. If they didn't say how long, choose the length that fits what "
        "they said and the time where the child is (the rest of today late in the evening, an hour for a short "
        "break, no end time only when they clearly mean until they say so) and give the reason. Don't block an app "
        "that's already blocked. Does not block anything itself."
    ),
    "parameters": {
        "type": "OBJECT",
        "properties": {
            "app": {"type": "STRING", "description": "The app as the parent named it, e.g. 'YouTube', 'yt', 'Roblox'."},
            "length": {
                "type": "STRING",
                "enum": list(LENGTHS),
                "description": "How long: 30_minutes, 1_hour, custom (set minutes), rest_of_today, or no_end_time.",
            },
            "minutes": {"type": "INTEGER", "description": "Only for custom: the length in minutes, 5 to 1440."},
            "reason": {
                "type": "STRING",
                "description": (
                    "One short sentence to the parent: what you're blocking, for how long, and why that length. "
                    "E.g. 'Blocking YouTube for the rest of today, since it's nearly bedtime.'"
                ),
            },
        },
        "required": ["app", "length"],
    },
}

# Said above the card when the model gave no reason of its own.
REPLY = "Here's the block. Change the app or the length before you tap Block."
# The model's own sentence for this card, when it wrote one.
REPLY_ARG = "reason"


def follow_up_for(args: dict, child_name: str, today) -> str | None:
    if not str(args.get("app") or "").strip():
        return f"Which app should I block for {child_name}?"
    return None


def _norm(s: str) -> str:
    return re.sub(r"[^a-z0-9+]", "", (s or "").lower())


def match_app(db, said: str) -> models.App | None:
    """Evlin's catalog row for what the parent typed: the name or one of its
    aliases ("yt", "insta"), ignoring case, spaces and punctuation; failing
    that, the one app whose name contains it. Never a guess between two."""
    want = _norm(said)
    if not want:
        return None
    apps = db.query(models.App).all()
    for app in apps:
        if want == _norm(app.name) or want in {_norm(a) for a in (app.aliases or [])}:
            return app
    partial = [a for a in apps if want in _norm(a.name)]
    return partial[0] if len(partial) == 1 else None


def resolve(db, child, args: dict) -> str | None:
    """Turns the model's draft into what the card needs, or the question to
    ask instead. Adds app_id, app_name and on_list (whether it's on the
    child's lockable list yet; Block adds it if not), and settles the length.
    """
    from routers.app_blocks import blocks_in_force

    said = str(args.get("app") or "").strip()
    app = match_app(db, said)
    if app is None:
        return f"I couldn't find “{said}” in Evlin's app list. Which app did you mean?"
    in_force = [b for b in blocks_in_force(db, child) if b.app_id == app.id]
    if in_force:
        return f"{app.name} is already blocked for {child.name}. Want me to block a different app?"

    on_list = db.query(models.ChildApp).filter(
        models.ChildApp.child_id == child.id, models.ChildApp.app_id == app.id).first() is not None
    length = str(args.get("length") or "")
    if length not in LENGTHS:
        length = "1_hour"
    args.update(app_id=str(app.id), app_name=app.name, on_list=on_list, length=length)
    if length == "custom":
        try:
            minutes = int(args.get("minutes") or 0)
        except (TypeError, ValueError):
            minutes = 0
        args["minutes"] = min(1440, max(5, minutes or 60))
    else:
        args.pop("minutes", None)
    return None
