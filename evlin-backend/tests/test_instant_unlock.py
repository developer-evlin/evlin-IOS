"""Instant unlock (instant_unlock.py): earned by 3 approved days, any 3; the
server refuses "on" before that; off starts the count again."""
from datetime import timedelta

import models
from blocks import local_now
from tests.conftest import auth, make_child, make_device, make_parent


def _family(db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    make_device(db_session, c, "dev-kid")
    return p, c


def _day(client, db_session, c, day, sent_in=True, approve=True, tasks=1):
    """Makes `tasks` occurrences on `day`; the kid sends them in and the
    parent approves them, as asked."""
    for i in range(tasks):
        t = client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
            "title": f"Task {day} {i}", "recurrence": "none", "due_date": day.isoformat()}).json()
        occ = client.get(f"/children/{c.id}/occurrences", headers=auth("pa"),
                         params={"target_date": day.isoformat()}).json()
        mine = [o for o in occ if o["task_id"] == t["id"]][0]
        if sent_in:
            client.post(f"/tasks/occurrences/{mine['id']}/submit", headers=auth("dev-kid"), json={})
        if approve:
            client.post(f"/tasks/occurrences/{mine['id']}/approve", headers=auth("pa"))


def _state(client, c):
    return client.get(f"/children/{c.id}/state", headers=auth("pa")).json()


def test_three_approved_days_earn_it(client, db_session):
    _, c = _family(db_session)
    today = local_now(c).date()
    for n in (6, 4, 1):          # any 3, not in a row
        _day(client, db_session, c, today - timedelta(days=n))
    s = _state(client, c)
    assert s["instant_unlock_earned"] is True and s["instant_unlock_days"] == 3


def test_progress_counts_up_on_every_phone(client, db_session):
    _, c = _family(db_session)
    today = local_now(c).date()
    _day(client, db_session, c, today - timedelta(days=2))
    s = _state(client, c)
    assert s["instant_unlock_earned"] is False and s["instant_unlock_days"] == 1 and s["instant_unlock_needed"] == 3


def test_a_day_with_a_task_not_approved_doesnt_count(client, db_session):
    _, c = _family(db_session)
    today = local_now(c).date()
    _day(client, db_session, c, today - timedelta(days=3), tasks=2)
    _day(client, db_session, c, today - timedelta(days=2), approve=False)     # sent in, not approved
    assert _state(client, c)["instant_unlock_days"] == 1


def test_a_task_the_parent_ticked_without_the_child_doesnt_count(client, db_session):
    _, c = _family(db_session)
    today = local_now(c).date()
    for n in (3, 2, 1):
        _day(client, db_session, c, today - timedelta(days=n), sent_in=False)
    s = _state(client, c)
    assert s["instant_unlock_earned"] is False and s["instant_unlock_days"] == 0


def test_on_is_refused_until_its_earned(client, db_session):
    _, c = _family(db_session)
    r = client.put(f"/children/{c.id}/state", headers=auth("pa"), json={"instant_unlock": True})
    assert r.status_code == 409
    today = local_now(c).date()
    for n in (3, 2, 1):
        _day(client, db_session, c, today - timedelta(days=n))
    r = client.put(f"/children/{c.id}/state", headers=auth("pa"), json={"instant_unlock": True})
    assert r.status_code == 200 and r.json()["instant_unlock"] is True


def test_off_starts_the_count_again(client, db_session):
    p, c = _family(db_session)
    today = local_now(c).date()
    for n in (3, 2, 1):
        _day(client, db_session, c, today - timedelta(days=n))
    client.put(f"/children/{c.id}/state", headers=auth("pa"), json={"instant_unlock": True})
    s = client.put(f"/children/{c.id}/state", headers=auth("pa"), json={"instant_unlock": False}).json()
    assert s["instant_unlock"] is False and s["instant_unlock_earned"] is False and s["instant_unlock_days"] == 0
    row = db_session.query(models.ChildState).filter_by(child_id=c.id).one()
    db_session.refresh(row)
    assert row.instant_unlock_changed_by == p.id and row.instant_unlock_reset_on == today
    assert client.put(f"/children/{c.id}/state", headers=auth("pa"), json={"instant_unlock": True}).status_code == 409


def test_sent_in_unlocks_only_when_on_and_earned(client, db_session):
    _, c = _family(db_session)
    today = local_now(c).date()
    for n in (3, 2, 1):
        _day(client, db_session, c, today - timedelta(days=n))
    _day(client, db_session, c, today, approve=False)          # today's task sent in, not approved
    assert client.get(f"/children/{c.id}/policy", headers=auth("pa")).json()["locked"] is True
    client.put(f"/children/{c.id}/state", headers=auth("pa"), json={"instant_unlock": True})
    assert client.get(f"/children/{c.id}/policy", headers=auth("pa")).json()["locked"] is False
