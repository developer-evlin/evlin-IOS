"""Reflections: the priority-0 gate.

The key property under test is independence — a reflection locks the device
regardless of task status, and clearing it doesn't satisfy tasks either.
"""
from tests.conftest import auth, make_child, make_device, make_parent


def _reflection(client, child, prompt="What did you learn?", quiz=None):
    return client.post(f"/children/{child.id}/reflections", headers=auth("pa"), json={
        "video_id": "vid1", "video_title": "Being kind", "channel_title": "SciKids",
        "quiz": quiz if quiz is not None else [
            {"question": "Was it kind?", "options": ["Yes", "No"], "correct_index": 0}
        ],
        "written_prompt": prompt,
    })


def _progress_ids(client, child, token="dev-kid"):
    assignment = client.get(f"/children/{child.id}/course-assignments", headers=auth(token)).json()[0]
    order = {i["id"]: i["order_index"] for i in assignment["course"]["items"]}
    return [p["id"] for p in sorted(assignment["progress"], key=lambda p: order[p["course_item_id"]])]


def _setup(db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    make_device(db_session, c, "dev-kid")
    return p, c


# ---- the gate ------------------------------------------------------------

def test_an_open_reflection_shows_in_child_state(client, db_session):
    p, c = _setup(db_session)
    before = client.get(f"/children/{c.id}/state", headers=auth("dev-kid")).json()
    assert before["has_open_reflection"] is False

    _reflection(client, c)
    after = client.get(f"/children/{c.id}/state", headers=auth("dev-kid")).json()
    assert after["has_open_reflection"] is True


def test_the_gate_stays_closed_while_awaiting_review(client, db_session):
    # 'submitted' still counts as open: the child shouldn't get the device
    # back just by handing something in.
    p, c = _setup(db_session)
    r = _reflection(client, c).json()
    first = _progress_ids(client, c)[0]
    client.post(f"/course-item-progress/{first}/complete", headers=auth("dev-kid"), json={"quiz_answers": [0]})
    client.post(f"/reflections/{r['id']}/submit", headers=auth("dev-kid"), json={"written_response": "I learned a lot"})

    state = client.get(f"/children/{c.id}/state", headers=auth("dev-kid")).json()
    assert state["has_open_reflection"] is True


def test_approval_closes_the_gate(client, db_session):
    p, c = _setup(db_session)
    r = _reflection(client, c).json()
    first = _progress_ids(client, c)[0]
    client.post(f"/course-item-progress/{first}/complete", headers=auth("dev-kid"), json={"quiz_answers": [0]})
    client.post(f"/reflections/{r['id']}/submit", headers=auth("dev-kid"), json={"written_response": "done"})

    client.put(f"/reflections/{r['id']}/review", headers=auth("pa"), json={"status": "approved"})
    state = client.get(f"/children/{c.id}/state", headers=auth("dev-kid")).json()
    assert state["has_open_reflection"] is False


def test_needs_redo_reopens_the_gate_without_losing_watched_videos(client, db_session):
    p, c = _setup(db_session)
    r = _reflection(client, c).json()
    first = _progress_ids(client, c)[0]
    client.post(f"/course-item-progress/{first}/complete", headers=auth("dev-kid"), json={"quiz_answers": [0]})
    client.post(f"/reflections/{r['id']}/submit", headers=auth("dev-kid"), json={"written_response": "meh"})

    back = client.put(f"/reflections/{r['id']}/review", headers=auth("pa"),
                      json={"status": "needs_redo", "review_note": "say more"}).json()
    assert back["status"] == "pending" and back["review_note"] == "say more"
    assert client.get(f"/children/{c.id}/state", headers=auth("dev-kid")).json()["has_open_reflection"] is True

    # A redo means writing more, not watching everything again.
    assert [p["status"] for p in back["assignment"]["progress"]] == ["completed"]
    again = client.post(f"/reflections/{r['id']}/submit", headers=auth("dev-kid"),
                        json={"written_response": "a proper answer"})
    assert again.status_code == 200 and again.json()["status"] == "submitted"


# ---- submission rules ----------------------------------------------------

def test_cannot_submit_before_finishing_the_videos(client, db_session):
    p, c = _setup(db_session)
    r = _reflection(client, c).json()
    # "Watch this to get your phone back" must not be satisfiable by typing
    # a sentence and skipping the video.
    bad = client.post(f"/reflections/{r['id']}/submit", headers=auth("dev-kid"),
                      json={"written_response": "I totally watched it"})
    assert bad.status_code == 400


def test_a_written_prompt_requires_a_written_answer(client, db_session):
    p, c = _setup(db_session)
    r = _reflection(client, c).json()
    first = _progress_ids(client, c)[0]
    client.post(f"/course-item-progress/{first}/complete", headers=auth("dev-kid"), json={"quiz_answers": [0]})
    assert client.post(f"/reflections/{r['id']}/submit", headers=auth("dev-kid"),
                       json={"written_response": "   "}).status_code == 400


def test_no_prompt_means_no_writing_required(client, db_session):
    p, c = _setup(db_session)
    r = _reflection(client, c, prompt=None).json()
    first = _progress_ids(client, c)[0]
    client.post(f"/course-item-progress/{first}/complete", headers=auth("dev-kid"), json={"quiz_answers": [0]})
    assert client.post(f"/reflections/{r['id']}/submit", headers=auth("dev-kid"), json={}).status_code == 200


def test_review_before_submission_is_rejected(client, db_session):
    p, c = _setup(db_session)
    r = _reflection(client, c).json()
    assert client.put(f"/reflections/{r['id']}/review", headers=auth("pa"),
                      json={"status": "approved"}).status_code == 400


# ---- content sources -----------------------------------------------------

def test_creating_a_reflection_builds_its_course_and_assignment(client, db_session):
    p, c = _setup(db_session)
    r = _reflection(client, c).json()
    assert r["status"] == "pending"
    assert r["assignment"]["course"]["items"][0]["video_id"] == "vid1"
    assert [pr["status"] for pr in r["assignment"]["progress"]] == ["available"]


def test_exactly_one_content_source_is_required(client, db_session):
    p, c = _setup(db_session)
    assert client.post(f"/children/{c.id}/reflections", headers=auth("pa"), json={}).status_code == 422
    assert client.post(f"/children/{c.id}/reflections", headers=auth("pa"), json={
        "video_id": "v", "course_id": "00000000-0000-0000-0000-000000000000",
    }).status_code == 422


def test_a_reflection_can_use_an_existing_library_course(client, db_session):
    p, c = _setup(db_session)
    course = client.post("/courses/single-video", headers=auth("pa"),
                         json={"video_id": "libvid", "video_title": "From the library"}).json()
    r = client.post(f"/children/{c.id}/reflections", headers=auth("pa"),
                    json={"course_id": course["id"], "written_prompt": "thoughts?"})
    assert r.status_code == 200
    assert r.json()["assignment"]["course"]["items"][0]["video_id"] == "libvid"


# ---- access control ------------------------------------------------------

def test_another_family_cannot_see_or_review_a_reflection(client, db_session):
    p, c = _setup(db_session)
    make_parent(db_session, "pb")
    r = _reflection(client, c).json()
    assert client.get(f"/children/{c.id}/reflections", headers=auth("pb")).status_code == 404
    assert client.put(f"/reflections/{r['id']}/review", headers=auth("pb"),
                      json={"status": "approved"}).status_code == 404


def test_a_child_cannot_approve_their_own_reflection(client, db_session):
    p, c = _setup(db_session)
    r = _reflection(client, c).json()
    first = _progress_ids(client, c)[0]
    client.post(f"/course-item-progress/{first}/complete", headers=auth("dev-kid"), json={"quiz_answers": [0]})
    client.post(f"/reflections/{r['id']}/submit", headers=auth("dev-kid"), json={"written_response": "x"})
    assert client.put(f"/reflections/{r['id']}/review", headers=auth("dev-kid"),
                      json={"status": "approved"}).status_code == 401
