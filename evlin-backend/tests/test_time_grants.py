from datetime import date

import models
from tests.conftest import auth, make_child, make_device, make_parent


def test_manual_grant_adds_to_available_minutes(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)  # daily_limit_minutes=60

    r = client.post(f"/children/{c.id}/time-grants", headers=auth("pa"), json={"minutes": 15, "reason": "Extra reading"})
    assert r.status_code == 200
    body = r.json()
    assert body["source"] == "manual" and body["minutes"] == 15 and body["reason"] == "Extra reading"

    summary = client.get(f"/children/{c.id}/time-grants", headers=auth("pa")).json()
    assert summary["daily_limit_minutes"] == 60
    assert summary["granted_minutes"] == 15
    assert summary["available_minutes"] == 75
    assert len(summary["grants"]) == 1


def test_grants_are_additive_not_overwritten(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    client.post(f"/children/{c.id}/time-grants", headers=auth("pa"), json={"minutes": 10})
    client.post(f"/children/{c.id}/time-grants", headers=auth("pa"), json={"minutes": 20})
    summary = client.get(f"/children/{c.id}/time-grants", headers=auth("pa")).json()
    assert summary["granted_minutes"] == 30
    assert len(summary["grants"]) == 2


def test_nonpositive_minutes_rejected(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    assert client.post(f"/children/{c.id}/time-grants", headers=auth("pa"), json={"minutes": 0}).status_code == 422
    assert client.post(f"/children/{c.id}/time-grants", headers=auth("pa"), json={"minutes": -5}).status_code == 422


def test_grant_access_control(client, db_session):
    a, b = make_parent(db_session, "pa"), make_parent(db_session, "pb")
    kid = make_child(db_session, a)
    make_device(db_session, kid, "dev-kid")

    # Another parent can't grant or read this child's pool.
    assert client.post(f"/children/{kid.id}/time-grants", headers=auth("pb"), json={"minutes": 5}).status_code == 404
    assert client.get(f"/children/{kid.id}/time-grants", headers=auth("pb")).status_code == 404
    # The kid's own device can read (not grant — no route lets a device post).
    assert client.get(f"/children/{kid.id}/time-grants", headers=auth("dev-kid")).status_code == 200


def test_task_bonus_awarded_on_approve(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    r = client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Extra chores", "recurrence": "none", "due_date": str(date.today()), "bonus_minutes": 20,
    })
    assert r.status_code == 200
    occ = client.get(f"/children/{c.id}/occurrences?target_date={date.today()}", headers=auth("pa")).json()[0]

    client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa"))

    summary = client.get(f"/children/{c.id}/time-grants", headers=auth("pa")).json()
    assert summary["granted_minutes"] == 20
    grant = summary["grants"][0]
    assert grant["source"] == "task_bonus"
    assert grant["source_ref_id"] == occ["id"]
    assert grant["reason"] == "Task: Extra chores"


def test_no_bonus_task_awards_nothing(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Plain task", "recurrence": "none", "due_date": str(date.today()),
    })
    occ = client.get(f"/children/{c.id}/occurrences?target_date={date.today()}", headers=auth("pa")).json()[0]
    client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa"))

    summary = client.get(f"/children/{c.id}/time-grants", headers=auth("pa")).json()
    assert summary["granted_minutes"] == 0
    assert summary["grants"] == []


def test_rejecting_a_bonus_task_awards_nothing(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Bonus task", "recurrence": "none", "due_date": str(date.today()), "bonus_minutes": 10,
    })
    occ = client.get(f"/children/{c.id}/occurrences?target_date={date.today()}", headers=auth("pa")).json()[0]
    client.post(f"/tasks/occurrences/{occ['id']}/reject", headers=auth("pa"))

    summary = client.get(f"/children/{c.id}/time-grants", headers=auth("pa")).json()
    assert summary["granted_minutes"] == 0
