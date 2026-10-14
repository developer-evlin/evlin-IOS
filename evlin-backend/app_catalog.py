"""Evlin's own catalog of apps a parent can put on a child's lockable list.

An app is identified by Evlin's own row, never by a platform identifier.
How a device turns "YouTube" into something it can actually enforce is the
device's business; everything here — the lockable list and blocks —
speaks in catalog rows.

CATALOG is the one source for both the production seed (a migration in
main.py) and the test seed. Aliases are what parents type: the app's
search matches them, and so does the backfill of blocks written before
the catalog existed.
"""
import json

from sqlalchemy.orm import Session

import models

# (name, aliases, category). Aliases are what parents actually type or say:
# nicknames, abbreviations and common misspellings. Categories are coarse on
# purpose — they label, they don't enforce.
CATALOG: list[tuple[str, list[str], str]] = [
    ("YouTube", ["yt", "you tube"], "video"),
    ("YouTube Kids", ["yt kids", "youtube for kids"], "video"),
    ("Netflix", [], "video"),
    ("Disney+", ["disney plus", "disney"], "video"),
    ("TikTok", ["tik tok"], "social"),
    ("Instagram", ["insta", "ig"], "social"),
    ("Snapchat", ["snap"], "social"),
    ("WhatsApp", ["whats app"], "messaging"),
    ("Messages", ["imessage", "texts", "texting"], "messaging"),
    ("Discord", [], "messaging"),
    ("Roblox", [], "games"),
    ("Minecraft", [], "games"),
    ("Fortnite", [], "games"),
    ("Brawl Stars", [], "games"),
    ("Clash Royale", [], "games"),
    ("Among Us", [], "games"),
    ("Pokemon GO", ["pokemon go", "pokémon go", "pokemon"], "games"),
    ("Subway Surfers", [], "games"),
    ("Safari", ["browser", "internet"], "browser"),
    ("Google Chrome", ["chrome"], "browser"),
    ("Spotify", [], "music"),
]


def seed_sql() -> str:
    """The idempotent INSERT that seeds CATALOG in production.

    ON CONFLICT DO NOTHING rides on the unique index on lower(name), so
    rerunning on every boot adds new entries and never duplicates or
    overwrites existing ones.
    """
    def lit(s: str) -> str:
        return "'" + s.replace("'", "''") + "'"

    rows = ",\n        ".join(
        f"(gen_random_uuid(), {lit(name)}, {lit(json.dumps(aliases))}::jsonb, {lit(category)})"
        for name, aliases, category in CATALOG
    )
    return f"""INSERT INTO app.apps (id, name, aliases, category) VALUES
        {rows}
    ON CONFLICT DO NOTHING"""


def seed(db: Session) -> None:
    """The same catalog for databases the migrations never run on (tests)."""
    existing = {name.lower() for (name,) in db.query(models.App.name).all()}
    for name, aliases, category in CATALOG:
        if name.lower() not in existing:
            db.add(models.App(name=name, aliases=aliases, category=category))
    db.commit()
