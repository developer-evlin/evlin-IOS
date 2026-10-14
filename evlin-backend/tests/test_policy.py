"""The policy: one answer to what a child's device should be doing now."""
from datetime import date, datetime, time, timedelta, timezone

import pytest

import app_catalog
import blocks
import models
from policy import compute_policy
from tests.conftest import auth, make_child, make_device, make_parent


def _app(db, name):
    return db.query(models.App).filter(models.App.name == name).one()


@pytest.fixture()
def fam(db_session):
    app_catalog.seed(db_session)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p, name="Wse")
    make_device(db_session, c, "kid")
    for n in ("YouTube", "Roblox"):
        db_session.add(models.ChildApp(child_id=c.id, app_id=_app(db_session, n).id))
    db_session.commit()
    return p, c


def _policy(client, c, who="pa"):
    r = client.get(f"/children/{c.id}/policy", headers=auth(who))
    assert r.status_code == 200, r.text
    return r.json()


def _task(client, c, title="Homework", **kw):
    return client.post(f"/children/{c.id}/tasks", headers=auth("pa"),
                       json={"title": title, "recurrence": "daily", **kw}).json()


def _occ(client, c, task_id):
    today = blocks.local_now(None).date()
    occs = client.get(f"/children/{c.id}/occurrences?target_date={today}", headers=auth("pa")).json()
    return [o for o in occs if o["task_id"] == task_id][0]


# ---- the lock ------------------------------------------------------------

def test_a_child_with_nothing_outstanding_is_unlocked(client, db_session, fam):
    _, c = fam
    p = _policy(client, c, "kid")
    assert (p["locked"], p["lock_reasons"]) == (False, [])
    assert [a["name"] for a in p["lock_apps"]] == ["Roblox", "YouTube"]
    assert p["allowance_minutes"] == 60


def test_each_reason_locks_on_its_own(client, db_session, fam):
    _, c = fam
    task = _task(client, c)
    assert _policy(client, c)["lock_reasons"] == ["unfinished_tasks"]

    client.post(f"/tasks/occurrences/{_occ(client, c, task['id'])['id']}/approve", headers=auth("pa"))
    assert _policy(client, c)["locked"] is False

    client.put(f"/children/{c.id}/state", headers=auth("pa"), json={"manual_lock": True, "task_gate_override": False})
    assert _policy(client, c)["lock_reasons"] == ["manual_lock"]


def test_the_task_gate_override_lifts_only_the_task_gate(client, db_session, fam):
    _, c = fam
    _task(client, c)
    client.put(f"/children/{c.id}/state", headers=auth("pa"), json={"manual_lock": True, "task_gate_override": True})
    assert _policy(client, c)["lock_reasons"] == ["manual_lock"]


def test_todays_requirement_is_the_occurrence_snapshot_not_the_tasks_current_flag(client, db_session, fam):
    # Editing a task to stop gating shouldn't rewrite what today already asked.
    _, c = fam
    task = _task(client, c)
    _occ(client, c, task["id"])  # today's occurrence exists, gating
    client.put(f"/tasks/{task['id']}", headers=auth("pa"),
               json={"title": "Homework", "recurrence": "daily", "gates_apps": False})
    assert "unfinished_tasks" in _policy(client, c)["lock_reasons"]


def test_a_non_gating_task_never_locks(client, db_session, fam):
    _, c = fam
    _task(client, c, gates_apps=False)
    assert _policy(client, c)["locked"] is False


# ---- blocks at a moment --------------------------------------------------

def _block(db, c, name, **kw):
    app = _app(db, name)
    b = models.AppBlock(child_id=c.id, app_id=app.id, app_name=app.name, **kw)
    db.add(b)
    db.commit()
    return b


def test_blocked_now_across_kinds(db_session, fam):
    _, c = fam
    c.timezone = "Europe/London"
    db_session.commit()
    now = datetime(2026, 9, 21, 20, 0, tzinfo=timezone.utc)  # Monday 21:00 in London
    _block(db_session, c, "YouTube", block_type="indefinite")
    _block(db_session, c, "Roblox", block_type="duration", duration_minutes=30,
           ends_at=now - timedelta(minutes=1))                                   # ended
    _block(db_session, c, "Roblox", block_type="scheduled", schedule_days="mon",
           schedule_start=time(19, 0), schedule_end=time(22, 0))                  # in window
    _block(db_session, c, "YouTube", block_type="scheduled", schedule_days="sat",
           schedule_start=time(10, 0), schedule_end=time(12, 0))                  # not today

    p = compute_policy(db_session, c, now)
    active = sorted((b["app_name"], b["kind"]) for b in p["blocked_now"])
    assert active == [("Roblox", "scheduled"), ("YouTube", "indefinite")]
    roblox = next(b for b in p["blocked_now"] if b["kind"] == "scheduled")
    assert roblox["until"].startswith("2026-09-21T22:00")
    assert sorted(s["days"] for s in p["scheduled_blocks"]) == ["mon", "sat"]


# ---- allowance -----------------------------------------------------------

def test_allowance_is_base_plus_todays_grants(client, db_session, fam):
    _, c = fam
    client.post(f"/children/{c.id}/time-grants", headers=auth("pa"), json={"minutes": 15})
    client.post(f"/children/{c.id}/time-grants", headers=auth("pa"), json={"minutes": -5})
    assert _policy(client, c)["allowance_minutes"] == 70


def test_a_limit_switched_off_means_no_allowance_at_all(client, db_session, fam):
    # daily_limit_enabled used to be ignored: the limit applied anyway.
    _, c = fam
    rule = db_session.query(models.ChildRule).filter_by(child_id=c.id).one()
    rule.daily_limit_enabled = False
    db_session.commit()
    p = _policy(client, c)
    assert (p["daily_limit_enabled"], p["allowance_minutes"]) == (False, None)


def test_a_pacific_evening_grant_lands_on_that_evening(client, db_session, fam, monkeypatch):
    # 03:00 UTC Tuesday is still Monday evening in Los Angeles. The server's
    # UTC date would have put this grant on Tuesday — invisible all Monday.
    _, c = fam
    c.timezone = "America/Los_Angeles"
    db_session.commit()
    instant = datetime(2026, 9, 22, 3, 0, tzinfo=timezone.utc)
    real = blocks.local_now
    monkeypatch.setattr(blocks, "local_now", lambda child, now=None: real(child, now or instant))

    client.post(f"/children/{c.id}/time-grants", headers=auth("pa"), json={"minutes": 20})
    grant = db_session.query(models.TimeGrant).filter_by(child_id=c.id).one()
    assert grant.credited_date == date(2026, 9, 21)
    assert compute_policy(db_session, c, instant)["allowance_minutes"] == 80


# ---- approval is a one-time payout ---------------------------------------

def test_approving_twice_pays_once(client, db_session, fam):
    _, c = fam
    task = _task(client, c, bonus_minutes=10)
    occ = _occ(client, c, task["id"])
    assert client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa")).status_code == 200
    assert client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa")).status_code == 409
    assert db_session.query(models.TimeGrant).filter_by(child_id=c.id).count() == 1


# ---- etag and access -----------------------------------------------------

def test_the_etag_moves_only_when_the_answer_does(client, db_session, fam):
    _, c = fam
    first = _policy(client, c)["etag"]
    assert _policy(client, c)["etag"] == first
    client.put(f"/children/{c.id}/state", headers=auth("pa"), json={"manual_lock": True, "task_gate_override": False})
    assert _policy(client, c)["etag"] != first


def test_only_this_family_and_this_childs_device_can_read_it(client, db_session, fam):
    p, c = fam
    make_parent(db_session, "pb")
    sibling = make_child(db_session, p, name="Sib")
    make_device(db_session, sibling, "sib-device")
    assert client.get(f"/children/{c.id}/policy", headers=auth("pb")).status_code == 404
    assert client.get(f"/children/{c.id}/policy", headers=auth("sib-device")).status_code == 404
