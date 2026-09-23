"""Courses: shared vetted content, per-child progress.

The vetting pipeline is mocked at the gemini_client / youtube_client
boundary, the same way test_chat.py mocks generate — no test makes a real
external call.
"""
import pytest

import routers.courses as courses_router
from gemini_client import FunctionCall
from tests.conftest import auth, make_child, make_device, make_parent


CANDIDATES = [
    {"video_id": "vid1", "title": "Water Cycle 101", "channel_title": "SciKids",
     "description": "how rain works", "duration": "PT5M", "made_for_kids": True,
     "content_rating": {}, "embeddable": True, "thumbnail_url": "t1"},
    {"video_id": "vid2", "title": "Clouds Explained", "channel_title": "SciKids",
     "description": "cloud types", "duration": "PT6M", "made_for_kids": True,
     "content_rating": {}, "embeddable": True, "thumbnail_url": "t2"},
    {"video_id": "vid3", "title": "Unrelated prank video", "channel_title": "Randoms",
     "description": "not educational", "duration": "PT12M", "made_for_kids": False,
     "content_rating": {}, "embeddable": True, "thumbnail_url": "t3"},
]


def _mock_pipeline(monkeypatch, items=None, candidates=None):
    async def _search(query, max_results=10):
        return candidates if candidates is not None else CANDIDATES

    async def _generate(system_prompt, messages, tools=None):
        return None, FunctionCall(name="propose_course", args={
            "title": "The Water Cycle",
            "items": items if items is not None else [
                {"video_id": "vid1", "reason": "Age-appropriate, educational channel",
                 "quiz": [{"question": "What falls from clouds?",
                           "options": ["Rain", "Rocks"], "correct_index": 0}]},
                {"video_id": "vid2", "reason": "Follows on from the first", "quiz": []},
            ],
        })

    monkeypatch.setattr(courses_router, "youtube_configured", lambda: True)
    monkeypatch.setattr(courses_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(courses_router, "search_with_details", _search)
    monkeypatch.setattr(courses_router, "generate", _generate)


def _generated_course(client, monkeypatch, **kw):
    _mock_pipeline(monkeypatch, **kw)
    r = client.post("/courses/generate", headers=auth("pa"), json={"topic": "water cycle", "video_count": 4})
    assert r.status_code == 200, r.text
    return r.json()


# ---- generation and vetting ---------------------------------------------

def test_generated_course_starts_unapproved_and_invisible_to_children(client, db_session, monkeypatch):
    p = make_parent(db_session, "pa")
    course = _generated_course(client, monkeypatch)

    assert course["status"] == "pending_review"
    assert [i["video_id"] for i in course["items"]] == ["vid1", "vid2"]
    assert course["items"][0]["vetting_notes"]
    # The shared library only lists published courses, so a draft can't be
    # browsed or assigned by anyone yet.
    assert client.get("/courses", headers=auth("pa")).json() == []


def test_videos_the_model_invents_are_dropped_not_trusted(client, db_session, monkeypatch):
    p = make_parent(db_session, "pa")
    course = _generated_course(client, monkeypatch, items=[
        {"video_id": "vid1", "reason": "real one"},
        {"video_id": "hallucinated", "reason": "not in the candidate list"},
    ])
    assert [i["video_id"] for i in course["items"]] == ["vid1"]


def test_vetting_rejecting_everything_is_an_error_not_an_empty_course(client, db_session, monkeypatch):
    p = make_parent(db_session, "pa")
    _mock_pipeline(monkeypatch, items=[])
    r = client.post("/courses/generate", headers=auth("pa"), json={"topic": "x"})
    assert r.status_code == 502


def test_generation_is_capped_at_the_requested_video_count(client, db_session, monkeypatch):
    p = make_parent(db_session, "pa")
    _mock_pipeline(monkeypatch)
    r = client.post("/courses/generate", headers=auth("pa"), json={"topic": "water", "video_count": 1}).json()
    assert len(r["items"]) == 1


def test_generate_requires_both_services_configured(client, db_session, monkeypatch):
    p = make_parent(db_session, "pa")
    _mock_pipeline(monkeypatch)
    monkeypatch.setattr(courses_router, "youtube_configured", lambda: False)
    assert client.post("/courses/generate", headers=auth("pa"), json={"topic": "x"}).status_code == 503

    monkeypatch.setattr(courses_router, "youtube_configured", lambda: True)
    monkeypatch.setattr(courses_router, "gemini_configured", lambda: False)
    assert client.post("/courses/generate", headers=auth("pa"), json={"topic": "x"}).status_code == 503


# ---- approval and assignment --------------------------------------------

def test_approve_publishes_and_assigns_in_one_call(client, db_session, monkeypatch):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    course = _generated_course(client, monkeypatch)

    r = client.put(f"/courses/{course['id']}/approve", headers=auth("pa"),
                   json={"assign_to_child_id": str(c.id)})
    assert r.status_code == 200 and r.json()["status"] == "published"

    assignments = client.get(f"/children/{c.id}/course-assignments", headers=auth("pa")).json()
    assert len(assignments) == 1
    assert [pr["status"] for pr in _ordered(assignments[0])] == ["available", "locked"]


def test_unapproved_course_cannot_be_assigned(client, db_session, monkeypatch):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    course = _generated_course(client, monkeypatch)
    r = client.post(f"/children/{c.id}/course-assignments", headers=auth("pa"),
                    json={"course_id": course["id"]})
    assert r.status_code == 400


def test_same_course_assigned_to_two_children_tracks_progress_independently(client, db_session, monkeypatch):
    p = make_parent(db_session, "pa")
    a = make_child(db_session, p, name="A")
    b = make_child(db_session, p, name="B")
    course = _generated_course(client, monkeypatch)
    client.put(f"/courses/{course['id']}/approve", headers=auth("pa"), json={"assign_to_child_id": str(a.id)})
    # The sibling gets the already-vetted course with no repeat search.
    client.post(f"/children/{b.id}/course-assignments", headers=auth("pa"), json={"course_id": course["id"]})

    a_assign = client.get(f"/children/{a.id}/course-assignments", headers=auth("pa")).json()[0]
    first = _ordered(a_assign)[0]
    client.post(f"/course-item-progress/{first['id']}/complete", headers=auth("pa"),
                json={"quiz_answers": [0]})

    a_after = _ordered(client.get(f"/children/{a.id}/course-assignments", headers=auth("pa")).json()[0])
    b_after = _ordered(client.get(f"/children/{b.id}/course-assignments", headers=auth("pa")).json()[0])
    assert [x["status"] for x in a_after] == ["completed", "available"]
    assert [x["status"] for x in b_after] == ["available", "locked"]   # untouched


# ---- sequential unlock ---------------------------------------------------

def _ordered(assignment: dict) -> list[dict]:
    """Progress rows in the course's own item order."""
    order = {i["id"]: i["order_index"] for i in assignment["course"]["items"]}
    return sorted(assignment["progress"], key=lambda p: order[p["course_item_id"]])


def _assigned(client, db_session, monkeypatch):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    make_device(db_session, c, "dev-kid")
    course = _generated_course(client, monkeypatch)
    client.put(f"/courses/{course['id']}/approve", headers=auth("pa"), json={"assign_to_child_id": str(c.id)})
    assignment = client.get(f"/children/{c.id}/course-assignments", headers=auth("pa")).json()[0]
    return c, assignment


def test_completing_one_item_unlocks_exactly_the_next(client, db_session, monkeypatch):
    c, assignment = _assigned(client, db_session, monkeypatch)
    rows = _ordered(assignment)

    r = client.post(f"/course-item-progress/{rows[0]['id']}/complete", headers=auth("dev-kid"),
                    json={"quiz_answers": [0]})
    assert r.status_code == 200, r.text
    after = _ordered(client.get(f"/children/{c.id}/course-assignments", headers=auth("dev-kid")).json()[0])
    assert [x["status"] for x in after] == ["completed", "available"]


def test_a_locked_item_cannot_be_completed_out_of_order(client, db_session, monkeypatch):
    c, assignment = _assigned(client, db_session, monkeypatch)
    second = _ordered(assignment)[1]
    r = client.post(f"/course-item-progress/{second['id']}/complete", headers=auth("dev-kid"), json={})
    assert r.status_code == 400


def test_finishing_every_item_completes_the_assignment(client, db_session, monkeypatch):
    c, assignment = _assigned(client, db_session, monkeypatch)
    rows = _ordered(assignment)
    client.post(f"/course-item-progress/{rows[0]['id']}/complete", headers=auth("dev-kid"), json={"quiz_answers": [0]})
    client.post(f"/course-item-progress/{rows[1]['id']}/complete", headers=auth("dev-kid"), json={})

    after = client.get(f"/children/{c.id}/course-assignments", headers=auth("dev-kid")).json()[0]
    assert after["status"] == "completed" and after["completed_at"]


# ---- quizzes -------------------------------------------------------------

def test_quiz_is_scored_server_side(client, db_session, monkeypatch):
    c, assignment = _assigned(client, db_session, monkeypatch)
    first = _ordered(assignment)[0]
    r = client.post(f"/course-item-progress/{first['id']}/complete", headers=auth("dev-kid"),
                    json={"quiz_answers": [1]}).json()   # wrong answer
    assert r["quiz_score"] == 0 and r["status"] == "completed"


def test_an_item_with_a_quiz_needs_every_answer(client, db_session, monkeypatch):
    c, assignment = _assigned(client, db_session, monkeypatch)
    first = _ordered(assignment)[0]
    assert client.post(f"/course-item-progress/{first['id']}/complete",
                       headers=auth("dev-kid"), json={}).status_code == 400


# ---- the simple single-video path ---------------------------------------

def test_single_video_course_is_published_without_a_vetting_pass(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    course = client.post("/courses/single-video", headers=auth("pa"), json={
        "video_id": "abc123", "video_title": "Long division", "channel_title": "MathCo",
    }).json()
    # The parent picked this one themselves, so there's nothing to approve.
    assert course["status"] == "published" and course["created_by"] == "parent"
    assert [i["video_id"] for i in course["items"]] == ["abc123"]

    r = client.post(f"/children/{c.id}/course-assignments", headers=auth("pa"),
                    json={"course_id": course["id"]})
    assert r.status_code == 200


# ---- access control ------------------------------------------------------

def test_another_familys_parent_cannot_assign_or_read(client, db_session, monkeypatch):
    p = make_parent(db_session, "pa")
    other = make_parent(db_session, "pb")
    c = make_child(db_session, p)
    course = _generated_course(client, monkeypatch)
    client.put(f"/courses/{course['id']}/approve", headers=auth("pa"), json={"assign_to_child_id": str(c.id)})

    assert client.get(f"/children/{c.id}/course-assignments", headers=auth("pb")).status_code == 404
    assert client.post(f"/children/{c.id}/course-assignments", headers=auth("pb"),
                       json={"course_id": course["id"]}).status_code == 404


def test_another_childs_device_cannot_complete_an_item(client, db_session, monkeypatch):
    c, assignment = _assigned(client, db_session, monkeypatch)
    intruder_parent = make_parent(db_session, "pb")
    intruder = make_child(db_session, intruder_parent, name="Other")
    make_device(db_session, intruder, "dev-other")

    first = _ordered(assignment)[0]
    r = client.post(f"/course-item-progress/{first['id']}/complete", headers=auth("dev-other"),
                    json={"quiz_answers": [0]})
    assert r.status_code == 404


def test_youtube_search_is_parent_only_and_reports_missing_config(client, db_session, monkeypatch):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    make_device(db_session, c, "dev-kid")
    monkeypatch.setattr(courses_router, "youtube_configured", lambda: False)
    assert client.get("/youtube/search?q=x", headers=auth("pa")).status_code == 503
    # A kid's device has no business searching YouTube at all.
    assert client.get("/youtube/search?q=x", headers=auth("dev-kid")).status_code == 401
