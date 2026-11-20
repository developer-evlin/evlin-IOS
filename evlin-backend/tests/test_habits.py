"""Habits on the server (routers/habits.py): the parent sets them, the
child's device checks in, the parent approves, and the server counts."""
import uuid
from datetime import date, timedelta

import models
from blocks import local_now
from tests.conftest import auth, make_child, make_device, make_parent


def _family(db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    make_device(db_session, c, "dev-kid")
    return p, c


def _habit(client, c, **body):
    data = {"id": str(uuid.uuid4()), "title": "Read for 20 minutes", "target": 3, "unit": "days",
            "prize": "Pizza night", **body}
    r = client.post(f"/children/{c.id}/habits", headers=auth("pa"), json=data)
    assert r.status_code == 200, r.text
    return r.json()


def _check_in(client, habit, day=None, device="dev-kid"):
    body = {"id": str(uuid.uuid4())}
    if day:
        body["day"] = day.isoformat()
    return client.post(f"/habits/{habit['id']}/check-ins", headers=auth(device), json=body)


def _approve(client, check_in_id):
    return client.post(f"/habit-check-ins/{check_in_id}/approve", headers=auth("pa"))


def test_the_parent_adds_a_habit_and_the_childs_device_sees_it(client, db_session):
    _, c = _family(db_session)
    h = _habit(client, c)
    seen = client.get(f"/children/{c.id}/habits", headers=auth("dev-kid")).json()
    assert [x["id"] for x in seen] == [h["id"]]
    assert seen[0]["prize"] == "Pizza night" and seen[0]["done"] == 0


def test_a_retried_create_saves_once(client, db_session):
    _, c = _family(db_session)
    hid = str(uuid.uuid4())
    _habit(client, c, id=hid)
    _habit(client, c, id=hid)
    assert db_session.query(models.Habit).count() == 1


def test_check_in_waits_then_the_approval_counts_and_completes(client, db_session):
    _, c = _family(db_session)
    h = _habit(client, c, target=2)
    today = local_now(c).date()
    first = _check_in(client, h, today - timedelta(days=1)).json()
    assert first["status"] == "waiting"
    r = _approve(client, first["id"]).json()
    assert r["habit"]["done"] == 1 and r["habit"]["finished_at"] is None
    second = _check_in(client, h).json()
    r = _approve(client, second["id"]).json()
    assert r["habit"]["done"] == 2 and r["habit"]["finished_at"] is not None
    # Completed: no more check-ins.
    assert _check_in(client, h).status_code == 409


def test_one_check_in_a_day_and_a_retry_returns_it(client, db_session):
    _, c = _family(db_session)
    h = _habit(client, c)
    a = _check_in(client, h).json()
    b = _check_in(client, h).json()
    assert a["id"] == b["id"]
    assert db_session.query(models.HabitCheckIn).count() == 1


def test_a_second_approval_is_refused_and_counts_nothing(client, db_session):
    _, c = _family(db_session)
    h = _habit(client, c)
    ci = _check_in(client, h).json()
    _approve(client, ci["id"])
    assert _approve(client, ci["id"]).status_code == 409
    assert client.get(f"/children/{c.id}/habits", headers=auth("pa")).json()[0]["done"] == 1


def test_a_streak_starts_again_after_a_missed_day(client, db_session):
    _, c = _family(db_session)
    h = _habit(client, c, unit="streak", target=5)
    today = local_now(c).date()
    for d in (today - timedelta(days=2), today - timedelta(days=1)):
        _approve(client, _check_in(client, h, d).json()["id"])
    assert client.get(f"/children/{c.id}/habits", headers=auth("pa")).json()[0]["done"] == 2
    # Make the last counted day three days ago: today it reads 0.
    row = db_session.query(models.Habit).one()
    row.last_counted_day = today - timedelta(days=3)
    db_session.commit()
    assert client.get(f"/children/{c.id}/habits", headers=auth("pa")).json()[0]["done"] == 0
    r = _approve(client, _check_in(client, h).json()["id"]).json()
    assert r["habit"]["done"] == 1


def test_only_the_childs_own_device_checks_in_and_only_their_parent_approves(client, db_session):
    _, c = _family(db_session)
    h = _habit(client, c)
    other = make_parent(db_session, "pb")
    other_kid = make_child(db_session, other)
    make_device(db_session, other_kid, "dev-other")
    assert _check_in(client, h, device="dev-other").status_code == 404
    ci = _check_in(client, h).json()
    assert client.post(f"/habit-check-ins/{ci['id']}/approve", headers=auth("pb")).status_code == 404
    assert client.get(f"/children/{c.id}/habits", headers=auth("pb")).status_code in (403, 404)


def test_edit_is_per_field_and_delete_removes_the_check_ins(client, db_session):
    _, c = _family(db_session)
    h = _habit(client, c, target=5)
    _approve(client, _check_in(client, h).json()["id"])
    r = client.put(f"/habits/{h['id']}", headers=auth("pa"), json={"prize": "Ice cream outing"}).json()
    assert r["prize"] == "Ice cream outing" and r["title"] == "Read for 20 minutes" and r["done"] == 1
    assert client.delete(f"/habits/{h['id']}", headers=auth("pa")).status_code == 200
    assert db_session.query(models.Habit).count() == 0 and db_session.query(models.HabitCheckIn).count() == 0


def test_a_late_check_in_keeps_its_day_but_not_older_than_two_days(client, db_session):
    _, c = _family(db_session)
    h = _habit(client, c)
    today = local_now(c).date()
    assert _check_in(client, h, today - timedelta(days=2)).json()["day"] == (today - timedelta(days=2)).isoformat()
    assert _check_in(client, h, today - timedelta(days=9)).json()["day"] == today.isoformat()
