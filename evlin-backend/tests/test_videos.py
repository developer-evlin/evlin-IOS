"""Today's videos: the filters, the chat card, and the parent-approved list."""
import json
from datetime import date

import models
import video_curation
import video_filter
import youtube_client
from gemini_client import FunctionCall
from tests.conftest import auth, fake_chat_model, make_child, make_device, make_parent


def _video(vid, **over):
    v = {"video_id": vid, "title": f"Video {vid}", "channel_id": "UCgood", "channel_title": "Good Channel",
         "description": "", "duration": "PT5M", "made_for_kids": True, "embeddable": True,
         "content_rating": {}, "thumbnail_url": "https://i.ytimg.com/x.jpg"}
    v.update(over)
    return v


# ---- filters --------------------------------------------------------------

def test_parse_duration():
    assert video_filter.parse_duration("PT4M13S") == 253
    assert video_filter.parse_duration("PT1H") == 3600
    assert video_filter.parse_duration("P0D") is None
    assert video_filter.parse_duration(None) is None


def test_filter_drops_everything_a_child_should_not_be_offered():
    candidates = [
        _video("aaaaaaaaaaa"),
        _video("notforkids1", made_for_kids=False),
        _video("unknownkids", made_for_kids=None),
        _video("noembed0001", embeddable=False),
        _video("agerestrict", content_rating={"ytRating": "ytAgeRestricted"}),
        _video("toolong0001", duration="PT25M"),
        _video("ashortvideo", duration="PT30S"),
        _video("blockedchan", channel_id="UCbad"),
        _video("keywordhit1", title="Scary monster prank"),
        _video("recentlyseen"),
        _video("aaaaaaaaaaa"),  # duplicate
    ]
    kept = video_filter.filter_candidates(
        candidates, max_seconds=600, blocked_channel_ids={"UCbad"},
        blocked_keywords=["prank"], exclude_video_ids={"recentlyseen"},
    )
    assert [c["video_id"] for c in kept] == ["aaaaaaaaaaa"]
    assert kept[0]["duration_seconds"] == 300


def test_blocked_keywords_match_whole_words_only():
    kept = video_filter.filter_candidates([_video("warmclothes", title="Warm clothes for winter")],
                                          max_seconds=600, blocked_keywords=["war"])
    assert len(kept) == 1


# ---- curation -------------------------------------------------------------

def _fake_search(results):
    async def search(query, max_results=10):
        search.queries.append(query)
        return results
    search.queries = []
    return search


def test_curate_drops_ids_the_model_invents(db_session, monkeypatch):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    monkeypatch.setattr(youtube_client, "youtube_configured", lambda: True)
    monkeypatch.setattr(youtube_client, "search_with_details",
                        _fake_search([_video("realvideo01"), _video("realvideo02")]))
    monkeypatch.setattr(video_curation, "gemini_configured", lambda: True)

    async def rank(prompt, messages, tools=None):
        return None, FunctionCall("pick_videos", {"picks": [
            {"video_id": "inventedxxx", "why": "made up"},
            {"video_id": "realvideo02", "why": "about dinosaurs"},
        ]})
    monkeypatch.setattr(video_curation, "generate", rank)

    import asyncio
    out = asyncio.run(video_curation.curate(db_session, c, "dinosaurs", ["science"], 3, date.today()))
    assert [v["video_id"] for v in out["videos"]] == ["realvideo02"]
    assert out["videos"][0]["why"] == "about dinosaurs"


def test_curate_never_widens_to_a_category_that_is_not_allowed(db_session, monkeypatch):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    db_session.add(models.ChildVideoProfile(child_id=c.id, allowed_categories=["science"], blocked_keywords=[],
                                            allowed_channels=[], blocked_channels=[],
                                            daily_minutes=30, max_video_minutes=10))
    db_session.commit()
    search = _fake_search([_video("realvideo01")])
    monkeypatch.setattr(youtube_client, "youtube_configured", lambda: True)
    monkeypatch.setattr(youtube_client, "search_with_details", search)

    import asyncio
    out = asyncio.run(video_curation.curate(db_session, c, "cookies", ["kitchen"], 3, date.today()))
    assert out["videos"] == []
    assert "Kitchen" in out["note"]
    assert search.queries == []  # nothing was searched at all


# ---- the list ---------------------------------------------------------------

def _add(client, child, token="pa", replace=False, ids=("abcdefghij1", "abcdefghij2")):
    return client.post(f"/children/{child.id}/video-queue", headers=auth(token), json={
        "replace": replace,
        "videos": [{"video_id": i, "title": f"T {i}", "duration_seconds": 300, "category": "science"} for i in ids],
    })


def test_parent_approves_and_kid_sees_the_list_with_time_left(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    make_device(db_session, c, "kid")

    r = _add(client, c)
    assert r.status_code == 200, r.text
    q = client.get(f"/children/{c.id}/video-queue", headers=auth("kid")).json()
    assert [i["video_id"] for i in q["items"]] == ["abcdefghij1", "abcdefghij2"]
    assert q["remaining_seconds"] == 30 * 60

    item = q["items"][0]["id"]
    assert client.post(f"/video-queue/{item}/progress", headers=auth("kid"),
                       json={"watched_seconds": 120}).status_code == 200
    # Never backwards.
    client.post(f"/video-queue/{item}/progress", headers=auth("kid"), json={"watched_seconds": 60})
    client.post(f"/video-queue/{item}/progress", headers=auth("kid"), json={"watched_seconds": 300, "completed": True})
    q = client.get(f"/children/{c.id}/video-queue", headers=auth("pa")).json()
    assert q["watched_seconds"] == 300
    assert q["remaining_seconds"] == 30 * 60 - 300
    assert q["items"][0]["completed_at"] is not None

    # A rewatch spends the allowance too, but never more than is left.
    client.post(f"/video-queue/{item}/progress", headers=auth("kid"), json={"watched_seconds": 99999})
    q = client.get(f"/children/{c.id}/video-queue", headers=auth("pa")).json()
    assert q["watched_seconds"] == 30 * 60
    assert q["remaining_seconds"] == 0


def test_replace_keeps_started_videos_and_skips_duplicates(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    make_device(db_session, c, "kid")
    q = _add(client, c).json()
    client.post(f"/video-queue/{q['items'][0]['id']}/progress", headers=auth("kid"), json={"watched_seconds": 30})

    q = _add(client, c, replace=True, ids=("abcdefghij1", "newvideo003")).json()
    assert [i["video_id"] for i in q["items"]] == ["abcdefghij1", "newvideo003"]


def test_kid_cannot_add_videos_and_other_families_cannot_see(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    make_device(db_session, c, "kid")
    make_parent(db_session, "other")

    assert _add(client, c, token="kid").status_code == 401
    assert _add(client, c, token="other").status_code == 404
    assert client.get(f"/children/{c.id}/video-queue", headers=auth("other")).status_code == 404
    q = _add(client, c).json()
    item = q["items"][0]["id"]
    assert client.post(f"/video-queue/{item}/progress", headers=auth("other"),
                       json={"watched_seconds": 1}).status_code == 404
    assert client.delete(f"/video-queue/{item}", headers=auth("other")).status_code == 404


def test_bad_video_ids_are_refused(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    assert _add(client, c, ids=("javascript:alert(1)",)).status_code == 422


def test_reorder_and_remove(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    q = _add(client, c).json()
    ids = [i["id"] for i in q["items"]]
    q = client.put(f"/children/{c.id}/video-queue/order", headers=auth("pa"),
                   json={"item_ids": list(reversed(ids))}).json()
    assert [i["video_id"] for i in q["items"]] == ["abcdefghij2", "abcdefghij1"]
    assert client.delete(f"/video-queue/{ids[0]}", headers=auth("pa")).status_code == 200
    q = client.get(f"/children/{c.id}/video-queue", headers=auth("pa")).json()
    assert [i["video_id"] for i in q["items"]] == ["abcdefghij2"]


# ---- settings ---------------------------------------------------------------

def test_profile_defaults_then_partial_update(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    make_device(db_session, c, "kid")

    prof = client.get(f"/children/{c.id}/video-profile", headers=auth("kid")).json()
    assert prof["allowed_categories"] == list(video_filter.CATEGORIES)
    assert prof["all_categories"] == list(video_filter.CATEGORIES)
    # Reading defaults writes nothing.
    assert db_session.query(models.ChildVideoProfile).count() == 0

    r = client.put(f"/children/{c.id}/video-profile", headers=auth("pa"), json={
        "allowed_categories": ["Science", "art"], "daily_minutes": 45,
        "allowed_channels": [{"id": "UCx", "title": "X"}], "blocked_channels": [{"id": "UCx", "title": "X"}],
    })
    assert r.status_code == 200, r.text
    prof = r.json()
    assert prof["allowed_categories"] == ["science", "art"]
    assert prof["daily_minutes"] == 45
    assert prof["max_video_minutes"] == video_filter.DEFAULT_MAX_VIDEO_MINUTES
    assert prof["allowed_channels"] == [] and prof["blocked_channels"] == [{"id": "UCx", "title": "X"}]

    assert client.put(f"/children/{c.id}/video-profile", headers=auth("pa"),
                      json={"allowed_categories": ["gaming"]}).status_code == 400
    assert client.put(f"/children/{c.id}/video-profile", headers=auth("kid"),
                      json={"daily_minutes": 200}).status_code == 401
