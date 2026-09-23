"""Milestones, and tasks completed by finishing a course.

The two share a completion check with reflections, and both hang off the
single _review path in occurrences.py.
"""
from datetime import date

import routers.milestones as milestones_router
from gemini_client import FunctionCall
from tests.conftest import auth, make_child, make_device, make_parent


def _setup(db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    make_device(db_session, c, "dev-kid")
    return p, c


def _course(client, video_id="vid1", quiz=None):
    return client.post("/courses/single-video", headers=auth("pa"), json={
        "video_id": video_id, "video_title": "Long division", "channel_title": "MathCo",
        "quiz": quiz or [],
    }).json()


def _progress_ids(client, child, token="dev-kid"):
    assignment = client.get(f"/children/{child.id}/course-assignments", headers=auth(token)).json()[0]
    order = {i["id"]: i["order_index"] for i in assignment["course"]["items"]}
    return [p["id"] for p in sorted(assignment["progress"], key=lambda p: order[p["course_item_id"]])]


def _todays_occurrence(client, child, token="pa"):
    return client.get(f"/children/{child.id}/occurrences?target_date={date.today()}",
                      headers=auth(token)).json()[0]


# ---- special tasks -------------------------------------------------------

def test_creating_a_special_task_assigns_the_course_in_one_call(client, db_session):
    p, c = _setup(db_session)
    course = _course(client)
    task = client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Watch the division lesson", "recurrence": "daily",
        "submission_kind": "course", "course_id": course["id"], "bonus_minutes": 20,
    }).json()

    assert task["submission_kind"] == "course"
    assert task["course_assignment_id"]
    # The child has a real assignment with its first item unlocked.
    assignments = client.get(f"/children/{c.id}/course-assignments", headers=auth("dev-kid")).json()
    assert len(assignments) == 1
    assert [pr["status"] for pr in assignments[0]["progress"]] == ["available"]


def test_a_drafted_course_is_published_by_creating_the_task(client, db_session, monkeypatch):
    # The parent tapping Create on the proposal card is the approval — there
    # must be no window where a task points at an unpublished course.
    import routers.courses as courses_router

    async def _search(query, max_results=10):
        return [{"video_id": "vid1", "title": "T", "channel_title": "C", "description": "",
                 "duration": "PT4M", "made_for_kids": True, "content_rating": {},
                 "embeddable": True, "thumbnail_url": "t"}]

    async def _generate(system_prompt, messages, tools=None):
        return None, FunctionCall(name="propose_course", args={
            "title": "Drafted", "items": [{"video_id": "vid1", "reason": "fine", "quiz": []}]})

    monkeypatch.setattr(courses_router, "youtube_configured", lambda: True)
    monkeypatch.setattr(courses_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(courses_router, "search_with_details", _search)
    monkeypatch.setattr(courses_router, "generate", _generate)

    p, c = _setup(db_session)
    draft = client.post("/courses/generate", headers=auth("pa"), json={"topic": "x"}).json()
    assert draft["status"] == "pending_review"

    client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Special", "submission_kind": "course", "course_id": draft["id"]})

    assert client.get(f"/courses/{draft['id']}", headers=auth("pa")).json()["status"] == "published"


def test_a_special_task_cannot_be_submitted_before_its_course_is_finished(client, db_session):
    p, c = _setup(db_session)
    course = _course(client, quiz=[{"question": "2+2?", "options": ["4", "5"], "correct_index": 0}])
    client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Watch it", "recurrence": "daily", "submission_kind": "course",
        "course_id": course["id"], "bonus_minutes": 20})
    occ = _todays_occurrence(client, c)

    # Tapping Done on the task itself must not shortcut the watching.
    early = client.post(f"/tasks/occurrences/{occ['id']}/submit", headers=auth("dev-kid"), json={})
    assert early.status_code == 400

    client.post(f"/course-item-progress/{_progress_ids(client, c)[0]}/complete",
                headers=auth("dev-kid"), json={"quiz_answers": [0]})
    ok = client.post(f"/tasks/occurrences/{occ['id']}/submit", headers=auth("dev-kid"), json={})
    assert ok.status_code == 200 and ok.json()["status"] == "submitted"


def test_finishing_a_special_task_earns_its_bonus_minutes(client, db_session):
    # The whole "watch this and answer the quizzes to earn screen time" flow,
    # riding the bonus path that already existed.
    p, c = _setup(db_session)
    course = _course(client)
    client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Watch it", "recurrence": "daily", "submission_kind": "course",
        "course_id": course["id"], "bonus_minutes": 25})
    occ = _todays_occurrence(client, c)

    client.post(f"/course-item-progress/{_progress_ids(client, c)[0]}/complete",
                headers=auth("dev-kid"), json={})
    client.post(f"/tasks/occurrences/{occ['id']}/submit", headers=auth("dev-kid"), json={})
    client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa"))

    grants = client.get(f"/children/{c.id}/time-grants", headers=auth("pa")).json()
    assert grants["granted_minutes"] == 25
    assert grants["available_minutes"] == 85   # 60 default + 25


def test_an_ordinary_task_is_unaffected_by_the_course_gate(client, db_session):
    p, c = _setup(db_session)
    client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Make bed", "recurrence": "daily", "submission_kind": "none"})
    occ = _todays_occurrence(client, c)
    assert client.post(f"/tasks/occurrences/{occ['id']}/submit",
                       headers=auth("dev-kid"), json={}).status_code == 200


# ---- milestones ----------------------------------------------------------

def test_count_milestone_advances_only_on_tagged_task_approvals(client, db_session):
    p, c = _setup(db_session)
    m = client.post(f"/children/{c.id}/milestones", headers=auth("pa"), json={
        "title": "Ten chores", "kind": "count", "target_count": 10, "prize_minutes": 30}).json()
    assert m["progress_count"] == 0 and m["achievable"] is False

    # An untagged task must not move it — otherwise every task in the house
    # would count toward every milestone.
    client.post(f"/children/{c.id}/tasks", headers=auth("pa"),
                json={"title": "Untagged", "recurrence": "daily"})
    untagged = _todays_occurrence(client, c)
    client.post(f"/tasks/occurrences/{untagged['id']}/approve", headers=auth("pa"))
    assert client.get(f"/children/{c.id}/milestones", headers=auth("pa")).json()[0]["progress_count"] == 0

    client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Tagged", "recurrence": "daily", "milestone_id": m["id"]})
    occs = client.get(f"/children/{c.id}/occurrences?target_date={date.today()}", headers=auth("pa")).json()
    tagged = [o for o in occs if o["status"] == "pending"][0]
    client.post(f"/tasks/occurrences/{tagged['id']}/approve", headers=auth("pa"))

    assert client.get(f"/children/{c.id}/milestones", headers=auth("pa")).json()[0]["progress_count"] == 1


def test_milestone_progress_also_ticks_through_the_put_status_route(client, db_session):
    # Both review paths run the same side effects — see the _review unification.
    p, c = _setup(db_session)
    m = client.post(f"/children/{c.id}/milestones", headers=auth("pa"), json={
        "title": "Two", "kind": "count", "target_count": 2}).json()
    client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Tagged", "recurrence": "daily", "milestone_id": m["id"]})
    occ = _todays_occurrence(client, c)
    client.put(f"/occurrences/{occ['id']}/status", headers=auth("pa"), json={"status": "approved"})
    assert client.get(f"/children/{c.id}/milestones", headers=auth("pa")).json()[0]["progress_count"] == 1


def test_claiming_pays_the_prize_into_the_ledger_once(client, db_session):
    p, c = _setup(db_session)
    m = client.post(f"/children/{c.id}/milestones", headers=auth("pa"), json={
        "title": "One chore", "kind": "count", "target_count": 1, "prize_minutes": 45}).json()
    client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Tagged", "recurrence": "daily", "milestone_id": m["id"]})
    occ = _todays_occurrence(client, c)
    client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa"))

    claimed = client.post(f"/milestones/{m['id']}/claim", headers=auth("pa")).json()
    assert claimed["status"] == "achieved" and claimed["achieved_at"]

    grants = client.get(f"/children/{c.id}/time-grants", headers=auth("pa")).json()
    assert [g["source"] for g in grants["grants"]] == ["milestone"]
    assert grants["granted_minutes"] == 45
    # source_ref_id points back at the milestone — the hook reserved for this.
    assert grants["grants"][0]["source_ref_id"] == m["id"]

    assert client.post(f"/milestones/{m['id']}/claim", headers=auth("pa")).status_code == 400


def test_cannot_claim_before_the_target_is_reached(client, db_session):
    p, c = _setup(db_session)
    m = client.post(f"/children/{c.id}/milestones", headers=auth("pa"), json={
        "title": "Five", "kind": "count", "target_count": 5, "prize_minutes": 10}).json()
    assert client.post(f"/milestones/{m['id']}/claim", headers=auth("pa")).status_code == 400


def test_course_milestone_is_achieved_by_finishing_the_course(client, db_session):
    p, c = _setup(db_session)
    course = _course(client)
    m = client.post(f"/children/{c.id}/milestones", headers=auth("pa"), json={
        "title": "Finish the lesson", "kind": "course", "course_id": course["id"],
        "prize_minutes": 15}).json()
    assert m["achievable"] is False
    assert client.post(f"/milestones/{m['id']}/claim", headers=auth("pa")).status_code == 400

    client.post(f"/course-item-progress/{_progress_ids(client, c)[0]}/complete",
                headers=auth("dev-kid"), json={})
    after = client.get(f"/children/{c.id}/milestones", headers=auth("pa")).json()[0]
    assert after["achievable"] is True
    assert client.post(f"/milestones/{m['id']}/claim", headers=auth("pa")).status_code == 200


def test_a_course_milestone_does_not_advance_on_task_approvals(client, db_session):
    p, c = _setup(db_session)
    course = _course(client)
    m = client.post(f"/children/{c.id}/milestones", headers=auth("pa"), json={
        "title": "Finish it", "kind": "course", "course_id": course["id"]}).json()
    client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Tagged", "recurrence": "daily", "milestone_id": m["id"]})
    occ = _todays_occurrence(client, c)
    client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa"))

    after = client.get(f"/children/{c.id}/milestones", headers=auth("pa")).json()[0]
    assert after["progress_count"] == 0 and after["achievable"] is False


def test_milestone_validation_requires_what_its_kind_needs(client, db_session):
    p, c = _setup(db_session)
    assert client.post(f"/children/{c.id}/milestones", headers=auth("pa"),
                       json={"title": "x", "kind": "count"}).status_code == 422
    assert client.post(f"/children/{c.id}/milestones", headers=auth("pa"),
                       json={"title": "x", "kind": "course"}).status_code == 422


def test_deleting_a_milestone_keeps_the_tasks_tagged_to_it(client, db_session):
    p, c = _setup(db_session)
    m = client.post(f"/children/{c.id}/milestones", headers=auth("pa"), json={
        "title": "Gone soon", "kind": "count", "target_count": 3}).json()
    task = client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Tagged", "recurrence": "daily", "milestone_id": m["id"]}).json()

    assert client.delete(f"/milestones/{m['id']}", headers=auth("pa")).status_code == 200
    still_there = [t for t in client.get(f"/children/{c.id}/tasks", headers=auth("pa")).json()
                   if t["id"] == task["id"]]
    assert len(still_there) == 1


def test_milestone_access_control(client, db_session):
    p, c = _setup(db_session)
    make_parent(db_session, "pb")
    m = client.post(f"/children/{c.id}/milestones", headers=auth("pa"), json={
        "title": "Mine", "kind": "count", "target_count": 2}).json()
    assert client.get(f"/children/{c.id}/milestones", headers=auth("pb")).status_code == 404
    assert client.post(f"/milestones/{m['id']}/claim", headers=auth("pb")).status_code == 404
    # The kid can see what they're working toward, but not award themselves.
    assert client.get(f"/children/{c.id}/milestones", headers=auth("dev-kid")).status_code == 200
    assert client.post(f"/milestones/{m['id']}/claim", headers=auth("dev-kid")).status_code == 401


# ---- AI suggestion -------------------------------------------------------

def test_generate_returns_a_draft_and_creates_nothing(client, db_session, monkeypatch):
    async def _propose(system_prompt, messages, tools=None):
        return None, FunctionCall(name="propose_milestone", args={
            "title": "Read 5 books", "kind": "count", "target_count": 5, "prize_minutes": 20})

    monkeypatch.setattr(milestones_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(milestones_router, "generate", _propose)
    p, c = _setup(db_session)

    draft = client.post(f"/children/{c.id}/milestones/generate", headers=auth("pa"), json={}).json()
    assert draft["title"] == "Read 5 books" and draft["created_by"] == "ai_agent"
    # A proposal is not a write.
    assert client.get(f"/children/{c.id}/milestones", headers=auth("pa")).json() == []


def test_generate_reports_missing_config(client, db_session, monkeypatch):
    monkeypatch.setattr(milestones_router, "gemini_configured", lambda: False)
    p, c = _setup(db_session)
    assert client.post(f"/children/{c.id}/milestones/generate",
                       headers=auth("pa"), json={}).status_code == 503


# ---- a child proposing their own ----------------------------------------

def test_child_can_propose_and_it_carries_no_prize(client, db_session):
    p, c = _setup(db_session)
    proposed = client.post(f"/children/{c.id}/milestones/propose", headers=auth("dev-kid"),
                           json={"title": "Save up for a skateboard"}).json()
    assert proposed["status"] == "proposed"
    assert proposed["created_by"] == "child"
    assert proposed["prize_minutes"] == 0


def test_a_child_cannot_write_themselves_a_screen_time_prize(client, db_session):
    # The whole point of the app is that a child can't grant themselves
    # time. The proposal schema has no prize field, so sending one is simply
    # not honoured.
    p, c = _setup(db_session)
    proposed = client.post(f"/children/{c.id}/milestones/propose", headers=auth("dev-kid"),
                           json={"title": "Free time", "prize_minutes": 999,
                                 "status": "active", "kind": "custom"}).json()
    assert proposed["prize_minutes"] == 0
    assert proposed["status"] == "proposed"
    # And it can't be cashed in before a parent has looked at it.
    assert client.post(f"/milestones/{proposed['id']}/claim", headers=auth("pa")).status_code == 400


def test_parent_approval_is_what_sets_the_terms(client, db_session):
    p, c = _setup(db_session)
    proposed = client.post(f"/children/{c.id}/milestones/propose", headers=auth("dev-kid"),
                           json={"title": "Skateboard"}).json()

    approved = client.put(f"/milestones/{proposed['id']}/approve", headers=auth("pa"), json={
        "kind": "count", "target_count": 20, "prize_minutes": 30,
        "prize_text": "Trip to the skate park"}).json()
    assert approved["status"] == "active" and approved["target_count"] == 20
    assert approved["prize_minutes"] == 30
    assert approved["created_by"] == "child"   # still their idea


def test_approving_something_already_active_is_rejected(client, db_session):
    p, c = _setup(db_session)
    m = client.post(f"/children/{c.id}/milestones", headers=auth("pa"), json={
        "title": "Parent's own", "kind": "count", "target_count": 3}).json()
    assert client.put(f"/milestones/{m['id']}/approve", headers=auth("pa"),
                      json={"prize_minutes": 10}).status_code == 400


def test_a_child_cannot_approve_their_own_proposal(client, db_session):
    p, c = _setup(db_session)
    proposed = client.post(f"/children/{c.id}/milestones/propose", headers=auth("dev-kid"),
                           json={"title": "Skateboard"}).json()
    assert client.put(f"/milestones/{proposed['id']}/approve", headers=auth("dev-kid"),
                      json={"prize_minutes": 500}).status_code == 401


def test_another_childs_device_cannot_propose(client, db_session):
    p, c = _setup(db_session)
    other_parent = make_parent(db_session, "pb")
    other = make_child(db_session, other_parent, name="Other")
    make_device(db_session, other, "dev-other")
    assert client.post(f"/children/{c.id}/milestones/propose", headers=auth("dev-other"),
                       json={"title": "Nope"}).status_code == 404
