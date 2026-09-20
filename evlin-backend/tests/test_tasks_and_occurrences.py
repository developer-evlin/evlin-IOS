from datetime import date, datetime, timezone

import models
from routers.occurrences import task_applies_on
from tests.conftest import auth, make_child, make_device, make_parent


def T(rec, due=None, created=datetime(2026, 9, 14, tzinfo=timezone.utc)):
    return models.Task(recurrence=rec, due_date=due, created_at=created)


MON, TUE, SAT = date(2026, 9, 14), date(2026, 9, 15), date(2026, 9, 19)


# ---- recurrence rules ---------------------------------------------------

def test_none_only_on_start_day():
    assert task_applies_on(T("none"), MON)
    assert not task_applies_on(T("none"), TUE)


def test_none_uses_due_date_over_created():
    assert task_applies_on(T("none", due=SAT), SAT)
    assert not task_applies_on(T("none", due=SAT), MON)


def test_daily_from_start_onward_only():
    assert task_applies_on(T("daily"), TUE)
    assert not task_applies_on(T("daily"), date(2026, 9, 13))


def test_weekday_codes():
    assert task_applies_on(T("mon,wed"), MON)
    assert not task_applies_on(T("mon,wed"), TUE)
    assert task_applies_on(T("sat,sun"), SAT)


# ---- task endpoints -----------------------------------------------------

def test_create_task_returns_saved_row_with_string_due_fields(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    r = client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": " Make bed ", "instructions": "tidy", "recurrence": "none", "bucket": "anytime",
        "submission_kind": "button", "due_time": "09:30:00", "due_date": "2026-09-19"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["title"] == "Make bed"
    assert body["due_time"] == "09:30:00" and body["due_date"] == "2026-09-19"
    assert body["id"] and body["created_at"]


def test_create_task_minimal_payload_like_the_app_sends(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    r = client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Homework", "instructions": "", "recurrence": "none", "bucket": "Chore",
        "submission_kind": "button", "due_date": "2026-09-19"})
    assert r.status_code == 200, r.text


def test_create_task_rejects_blank_title_and_bad_dates(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    assert client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={"title": "  "}).status_code == 422
    assert client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={"title": "x", "due_date": "nope"}).status_code == 400
    assert client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={"title": "x", "due_time": "9am"}).status_code == 400


def test_other_familys_child_is_404_for_every_task_route(client, db_session):
    a, b = make_parent(db_session, "pa"), make_parent(db_session, "pb")
    kid_a = make_child(db_session, a)
    task = client.post(f"/children/{kid_a.id}/tasks", headers=auth("pa"), json={"title": "x"}).json()
    hb = auth("pb")
    assert client.get(f"/children/{kid_a.id}/tasks", headers=hb).status_code == 404
    assert client.post(f"/children/{kid_a.id}/tasks", headers=hb, json={"title": "y"}).status_code == 404
    assert client.put(f"/tasks/{task['id']}", headers=hb, json={"title": "hack"}).status_code == 404
    assert client.delete(f"/tasks/{task['id']}", headers=hb).status_code == 404
    assert client.delete(f"/tasks/{task['id']}", headers=auth("pa")).status_code == 200


def test_missing_or_bad_token_is_rejected(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    assert client.get(f"/children/{c.id}/tasks").status_code in (401, 403)
    assert client.get(f"/children/{c.id}/tasks", headers=auth("nope")).status_code == 401


def test_update_keeps_schedule_when_not_sent(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    t = client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "x", "due_time": "08:00:00", "due_date": "2026-09-19"}).json()
    r = client.put(f"/tasks/{t['id']}", headers=auth("pa"), json={"title": "renamed"})
    assert r.status_code == 200
    assert r.json()["due_time"] == "08:00:00" and r.json()["due_date"] == "2026-09-19"


# ---- occurrences --------------------------------------------------------

def _tasks(client, child, *specs):
    for s in specs:
        assert client.post(f"/children/{child.id}/tasks", headers=auth("pa"), json=s).status_code == 200


def test_occurrences_follow_recurrence(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    _tasks(client, c,
           {"title": "once", "recurrence": "none", "due_date": "2026-09-19"},
           {"title": "daily", "recurrence": "daily", "due_date": "2026-09-14"},
           {"title": "mondays", "recurrence": "mon", "due_date": "2026-09-14"})
    def titles(day):
        occ = client.get(f"/children/{c.id}/occurrences?target_date={day}", headers=auth("pa")).json()
        ids = {o["task_id"] for o in occ}
        return sorted(t.title for t in db_session.query(models.Task).all() if str(t.id) in ids)
    assert titles("2026-09-19") == ["daily", "once"]
    assert titles("2026-09-21") == ["daily", "mondays"]
    assert titles("2026-09-13") == []


def test_occurrence_lookup_is_idempotent(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    _tasks(client, c, {"title": "d", "recurrence": "daily", "due_date": "2026-09-14"})
    for _ in range(3):
        client.get(f"/children/{c.id}/occurrences?target_date=2026-09-20", headers=auth("pa"))
    assert db_session.query(models.Occurrence).count() == 1


def test_occurrence_read_access(client, db_session):
    a, b = make_parent(db_session, "pa"), make_parent(db_session, "pb")
    kid, other = make_child(db_session, a), make_child(db_session, b)
    make_device(db_session, kid, "dev-kid")
    url = f"/children/{kid.id}/occurrences?target_date=2026-09-20"
    assert client.get(url).status_code in (401, 403)                      # anonymous
    assert client.get(url, headers=auth("dev-kid")).status_code == 200    # the child's own device
    assert client.get(url, headers=auth("pa")).status_code == 200         # their parent
    assert client.get(url, headers=auth("pb")).status_code == 404         # someone else's parent
    other_url = f"/children/{other.id}/occurrences?target_date=2026-09-20"
    assert client.get(other_url, headers=auth("dev-kid")).status_code == 404  # another child's device


def _occurrence(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    make_device(db_session, c, "dev-kid")
    _tasks(client, c, {"title": "d", "recurrence": "daily", "due_date": "2026-09-14"})
    occ = client.get(f"/children/{c.id}/occurrences?target_date=2026-09-20", headers=auth("pa")).json()[0]
    return c, occ


def test_submit_then_approve_and_reject_flow(client, db_session):
    c, occ = _occurrence(client, db_session)
    r = client.post(f"/tasks/occurrences/{occ['id']}/submit", headers=auth("dev-kid"), json={"bypass_note": "done!"})
    assert r.status_code == 200 and r.json()["status"] == "submitted"
    assert client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa")).json()["status"] == "approved"
    assert client.post(f"/tasks/occurrences/{occ['id']}/reject", headers=auth("pa")).json()["status"] == "rejected"


def test_only_the_owning_device_can_submit_and_only_the_parent_can_review(client, db_session):
    c, occ = _occurrence(client, db_session)
    b = make_parent(db_session, "pb")
    other = make_child(db_session, b)
    make_device(db_session, other, "dev-other")
    assert client.post(f"/tasks/occurrences/{occ['id']}/submit", headers=auth("dev-other"), json={}).status_code == 404
    assert client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pb")).status_code == 404
    assert client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("dev-kid")).status_code == 401
