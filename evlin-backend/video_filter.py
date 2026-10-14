"""What a video has to pass before a parent ever sees it on a card.

Pure functions, no I/O: the YouTube search and the model's ranking happen in
video_curation.py, and everything that can rule a video out without judgment
happens here, in code. The model only ever ranks what survives this, so a
not-made-for-kids video can't reach a child however persuasive its title is.

Filtering only narrows. Each layer (YouTube's own flags, the child's profile,
what was watched lately) can take videos away and none can add them back.
"""
import re

# The topics a parent can allow, and the words added to a search in each so
# results lean towards that kind of video. The same eight as the prototype.
CATEGORIES: dict[str, str] = {
    "science": "science experiment explained",
    "art": "drawing art craft tutorial",
    "math": "math learning",
    "nature": "animals nature documentary",
    "kitchen": "easy cooking with kids",
    "music": "music song learning",
    "reading": "phonics reading story",
    "mindful": "calm breathing mindfulness",
}

DEFAULT_DAILY_MINUTES = 30
DEFAULT_MAX_VIDEO_MINUTES = 10

# Under a minute is a Short: a feed format, not something to sit down and
# watch, and the kind of video the queue exists to replace.
MIN_SECONDS = 60

_DURATION = re.compile(r"^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$")


def parse_duration(raw: str | None) -> int | None:
    """ISO 8601 as videos.list returns it ("PT4M13S") to seconds. None for
    anything else, including a live stream's "P0D"."""
    m = _DURATION.match(raw or "")
    if not m:
        return None
    d, h, mi, s = (int(g) if g else 0 for g in m.groups())
    total = d * 86400 + h * 3600 + mi * 60 + s
    return total or None


def normalize_categories(raw) -> list[str]:
    """Known category keys, lowercased, deduplicated, in CATEGORIES order."""
    wanted = {str(c).strip().lower() for c in (raw or []) if str(c).strip()}
    return [c for c in CATEGORIES if c in wanted]


def _mentions(text: str, keyword: str) -> bool:
    # Whole words, so blocking "war" doesn't drop "Edward" or "warm".
    return re.search(rf"(?<!\w){re.escape(keyword)}(?!\w)", text, re.IGNORECASE) is not None


def filter_candidates(
    candidates: list[dict],
    *,
    max_seconds: int,
    blocked_channel_ids: set[str] = frozenset(),
    blocked_keywords: list[str] = (),
    exclude_video_ids: set[str] = frozenset(),
) -> list[dict]:
    """The candidates a child may be offered, in their original order, each
    with duration_seconds filled in. A video is dropped when it:
    - isn't flagged made for kids (unknown counts as no),
    - can't be embedded, or is age-restricted,
    - is shorter than a minute, longer than max_seconds, or has no length,
    - is from a blocked channel,
    - mentions a blocked keyword in its title or description,
    - was queued recently (exclude_video_ids), or repeats one already kept.
    """
    keywords = [k.strip() for k in blocked_keywords if k and k.strip()]
    kept, seen = [], set()
    for c in candidates:
        vid = c.get("video_id")
        if not vid or vid in seen or vid in exclude_video_ids:
            continue
        if c.get("made_for_kids") is not True:
            continue
        if c.get("embeddable") is False:
            continue
        if (c.get("content_rating") or {}).get("ytRating") == "ytAgeRestricted":
            continue
        seconds = parse_duration(c.get("duration"))
        if seconds is None or seconds < MIN_SECONDS or seconds > max_seconds:
            continue
        if c.get("channel_id") and c["channel_id"] in blocked_channel_ids:
            continue
        text = f"{c.get('title', '')}\n{c.get('description', '')}"
        if any(_mentions(text, k) for k in keywords):
            continue
        seen.add(vid)
        kept.append({**c, "duration_seconds": seconds})
    return kept
