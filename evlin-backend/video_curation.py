"""Turning a parent's request into a short list of videos to approve.

Three layers, each only able to narrow (see video_filter.py):
1. YouTube's search with strict SafeSearch, embeddable only.
2. The hard filters: made for kids, length, the child's blocked channels and
   keywords, nothing queued in the last two weeks.
3. The model ranks the survivors against what the parent asked. Any id it
   returns that wasn't a survivor is dropped, so it can't invent a video.

Nothing here writes. The result goes onto a chat card, and only the parent's
tap puts videos on a child's list.
"""
import json
from datetime import date, timedelta

from sqlalchemy.orm import Session

import models
import video_filter
import youtube_client
from gemini_client import FunctionCall, gemini_configured, generate

_RECENT_DAYS = 14
_PER_CATEGORY = 12


def profile_for(db: Session, child_id) -> dict:
    """The child's video settings, with defaults for a child who has none
    saved. A plain dict, so callers never write a row by reading one."""
    row = db.query(models.ChildVideoProfile).filter(models.ChildVideoProfile.child_id == child_id).first()
    if row is None:
        return {
            "child_id": child_id,
            "allowed_categories": list(video_filter.CATEGORIES),
            "blocked_keywords": [],
            "allowed_channels": [],
            "blocked_channels": [],
            "daily_minutes": video_filter.DEFAULT_DAILY_MINUTES,
            "max_video_minutes": video_filter.DEFAULT_MAX_VIDEO_MINUTES,
        }
    return {
        "child_id": child_id,
        "allowed_categories": video_filter.normalize_categories(row.allowed_categories),
        "blocked_keywords": list(row.blocked_keywords or []),
        "allowed_channels": list(row.allowed_channels or []),
        "blocked_channels": list(row.blocked_channels or []),
        "daily_minutes": row.daily_minutes,
        "max_video_minutes": row.max_video_minutes,
    }


def recent_video_ids(db: Session, child_id, today: date) -> set[str]:
    since = today - timedelta(days=_RECENT_DAYS)
    rows = db.query(models.VideoQueueItem.video_id).filter(
        models.VideoQueueItem.child_id == child_id,
        models.VideoQueueItem.local_date >= since,
    ).all()
    return {r[0] for r in rows}


def _age(child: models.Child, today: date) -> int | None:
    return today.year - child.birth_year if child.birth_year else None


def _search_query(query: str, category: str, age: int | None) -> str:
    who = f"for kids age {age}" if age else "for kids"
    return f"{query} {video_filter.CATEGORIES[category]} {who}".strip()


_RANK_TOOL = {
    "name": "pick_videos",
    "description": "Choose the best videos for this child from the candidates given, best first.",
    "parameters": {
        "type": "OBJECT",
        "properties": {
            "picks": {
                "type": "ARRAY",
                "items": {
                    "type": "OBJECT",
                    "properties": {
                        "video_id": {"type": "STRING", "description": "Exactly as given in the candidates"},
                        "why": {"type": "STRING", "description": "One short sentence a parent reads: why this fits"},
                    },
                    "required": ["video_id", "why"],
                },
            },
        },
        "required": ["picks"],
    },
}


async def _rank(candidates: list[dict], query: str, child: models.Child, age: int | None,
                count: int) -> list[dict]:
    """The model's order over candidates, each with a "why". Falls back to
    the filtered order when the model isn't available or answers badly:
    a worse ranking is fine, a failed card isn't."""
    fallback = [{**c, "why": ""} for c in candidates[:count]]
    if not gemini_configured() or not candidates:
        return fallback
    who = f"{child.name}, age {age}" if age else child.name
    prompt = (
        f"You pick YouTube videos for {who}. The parent asked: \"{query}\".\n"
        f"Choose up to {count} videos from the candidates, best first. Prefer ones that are educational or "
        "creative, clearly suit the child's age, match what the parent asked, and come from channels marked "
        "preferred. Skip anything sensational, clickbait, toy-unboxing or ad-like, even if it's on topic. "
        "Use only video_id values from the candidates. Call pick_videos."
    )
    listing = [{
        "video_id": c["video_id"], "title": c.get("title", ""), "channel": c.get("channel_title", ""),
        "preferred_channel": bool(c.get("preferred")), "minutes": round(c["duration_seconds"] / 60, 1),
        "category": c.get("category"), "description": (c.get("description") or "")[:200],
    } for c in candidates]
    try:
        _text, call = await generate(prompt, [{"role": "user", "text": json.dumps(listing)}], tools=[_RANK_TOOL])
    except Exception:
        return fallback
    if not isinstance(call, FunctionCall):
        return fallback
    by_id = {c["video_id"]: c for c in candidates}
    out, used = [], set()
    for pick in call.args.get("picks") or []:
        vid = (pick or {}).get("video_id")
        if vid in by_id and vid not in used:
            used.add(vid)
            out.append({**by_id[vid], "why": str(pick.get("why") or "")[:160]})
        if len(out) == count:
            break
    return out or fallback


def _card_video(c: dict) -> dict:
    return {
        "video_id": c["video_id"],
        "title": c.get("title", ""),
        "channel_id": c.get("channel_id") or "",
        "channel_title": c.get("channel_title") or "",
        "thumbnail_url": c.get("thumbnail_url") or "",
        "duration_seconds": c["duration_seconds"],
        "category": c.get("category") or "",
        "why": c.get("why") or "",
    }


async def curate(db: Session, child: models.Child, query: str, categories, count: int,
                 today: date) -> dict:
    """{"videos": [...], "note": str}. The note says what the parent should
    know (a category that isn't allowed, nothing suitable found); empty when
    there's nothing to say. Never raises for a search or model failure."""
    profile = profile_for(db, child.id)
    allowed = profile["allowed_categories"]
    asked = video_filter.normalize_categories(categories)
    notes = []

    refused = [c for c in asked if c not in allowed]
    if refused:
        names = ", ".join(c.capitalize() for c in refused)
        notes.append(f"{names} isn't in {child.name}'s video categories, so I left it out. "
                      "You can allow it in their video settings.")
    # Asked for nothing in particular: search every allowed category. Asked
    # only for refused ones: search nothing, rather than quietly widening.
    use = [c for c in asked if c in allowed] if asked else allowed
    if not use:
        if not allowed:
            notes.append(f"{child.name} has no video categories allowed yet.")
        return {"videos": [], "note": " ".join(notes)}

    if not youtube_client.youtube_configured():
        return {"videos": [], "note": "Video search isn't set up yet."}

    age = _age(child, today)
    raw = []
    try:
        for cat in use[:3]:
            for c in await youtube_client.search_with_details(_search_query(query, cat, age), _PER_CATEGORY):
                raw.append({**c, "category": cat})
    except Exception:
        if not raw:
            return {"videos": [], "note": "I couldn't reach YouTube just now. Try again in a moment."}

    blocked_ids = {ch.get("id") for ch in profile["blocked_channels"] if ch.get("id")}
    preferred_ids = {ch.get("id") for ch in profile["allowed_channels"] if ch.get("id")}
    survivors = video_filter.filter_candidates(
        raw,
        max_seconds=profile["max_video_minutes"] * 60,
        blocked_channel_ids=blocked_ids,
        blocked_keywords=profile["blocked_keywords"],
        exclude_video_ids=recent_video_ids(db, child.id, today),
    )
    for c in survivors:
        c["preferred"] = c.get("channel_id") in preferred_ids
    # Preferred channels first, so the fallback order favours them too.
    survivors.sort(key=lambda c: not c["preferred"])

    if not survivors:
        notes.append("I couldn't find videos that pass the filters for that. "
                     "Try asking a bit differently, or allow longer videos.")
        return {"videos": [], "note": " ".join(notes)}

    picks = await _rank(survivors, query, child, age, count)
    return {"videos": [_card_video(c) for c in picks], "note": " ".join(notes)}
