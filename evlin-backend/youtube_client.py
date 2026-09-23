"""The one place that knows the YouTube Data API's wire format.

Same shape and reasoning as gemini_client.py: plain httpx against the REST
API rather than a Google SDK, and no knowledge of what the caller wants the
results for. The key never leaves the server — the client asks this backend,
not Google.

Two calls, because search.list alone doesn't return the fields a safety pass
needs: search.list finds candidates, videos.list fills in madeForKids, the
content rating, the description and the real channel title for each one.
"""
import os
from typing import Optional

import httpx

YOUTUBE_API_KEY = os.getenv("YOUTUBE_API_KEY")
_SEARCH_URL = "https://www.googleapis.com/youtube/v3/search"
_VIDEOS_URL = "https://www.googleapis.com/youtube/v3/videos"


def youtube_configured() -> bool:
    return bool(YOUTUBE_API_KEY)


def _thumb(snippet: dict) -> Optional[str]:
    thumbs = snippet.get("thumbnails") or {}
    for size in ("medium", "high", "default"):
        if size in thumbs:
            return thumbs[size].get("url")
    return None


async def search_videos(query: str, max_results: int = 10) -> list[dict]:
    """Candidate videos for a topic: [{video_id, title, channel_title,
    thumbnail_url, description}]. Raises on a real API failure — callers
    decide how to surface it."""
    if not YOUTUBE_API_KEY:
        raise RuntimeError("YOUTUBE_API_KEY is not configured")

    params = {
        "key": YOUTUBE_API_KEY,
        "q": query,
        "part": "snippet",
        "type": "video",
        "maxResults": max(1, min(max_results, 25)),
        # embeddable only: a video that can't be embedded would pass vetting
        # and then fail to play inside the app, which reads to a kid as the
        # app being broken.
        "videoEmbeddable": "true",
        "safeSearch": "strict",
    }
    async with httpx.AsyncClient(timeout=20.0) as client:
        resp = await client.get(_SEARCH_URL, params=params)
        resp.raise_for_status()
        data = resp.json()

    out = []
    for item in data.get("items", []):
        video_id = (item.get("id") or {}).get("videoId")
        if not video_id:
            continue
        snippet = item.get("snippet") or {}
        out.append({
            "video_id": video_id,
            "title": snippet.get("title", ""),
            "channel_title": snippet.get("channelTitle", ""),
            "thumbnail_url": _thumb(snippet),
            "description": (snippet.get("description") or "")[:500],
        })
    return out


async def video_details(video_ids: list[str]) -> dict[str, dict]:
    """The metadata a safety pass actually needs, keyed by video id:
    made_for_kids, content_rating, duration, plus title/channel/description.
    One batched call — videos.list takes a comma-joined id list."""
    if not YOUTUBE_API_KEY:
        raise RuntimeError("YOUTUBE_API_KEY is not configured")
    if not video_ids:
        return {}

    params = {
        "key": YOUTUBE_API_KEY,
        "id": ",".join(video_ids[:50]),
        "part": "snippet,contentDetails,status",
    }
    async with httpx.AsyncClient(timeout=20.0) as client:
        resp = await client.get(_VIDEOS_URL, params=params)
        resp.raise_for_status()
        data = resp.json()

    details = {}
    for item in data.get("items", []):
        snippet = item.get("snippet") or {}
        content = item.get("contentDetails") or {}
        status = item.get("status") or {}
        details[item["id"]] = {
            "video_id": item["id"],
            "title": snippet.get("title", ""),
            "channel_title": snippet.get("channelTitle", ""),
            "description": (snippet.get("description") or "")[:500],
            "thumbnail_url": _thumb(snippet),
            "duration": content.get("duration"),
            "content_rating": content.get("contentRating") or {},
            "made_for_kids": status.get("madeForKids"),
            "embeddable": status.get("embeddable", True),
        }
    return details


async def search_with_details(query: str, max_results: int = 10) -> list[dict]:
    """search_videos + video_details merged — the candidate list a vetting
    pass sees. Candidates the details call drops (deleted/private between the
    two calls) are dropped here too rather than passed on half-populated."""
    candidates = await search_videos(query, max_results=max_results)
    details = await video_details([c["video_id"] for c in candidates])
    merged = []
    for c in candidates:
        d = details.get(c["video_id"])
        if d is None:
            continue
        if d.get("embeddable") is False:
            continue
        merged.append({**c, **d})
    return merged
