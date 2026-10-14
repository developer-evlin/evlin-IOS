"""Blocking apps: for a while, until a task is done, until lifted, or on a
weekly schedule."""
import uuid
from datetime import date, datetime, time, timedelta, timezone

import pytest

import app_catalog
import blocks
import live_updates
import models
from tests.conftest import auth, make_child, make_device, make_parent


@pytest.fixture()
def fam(db_session):
    app_catalog.seed(db_session)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    make_device(db_session, c, "dev-kid")
    apps = {a.name: str(a.id) for a in db_session.query(models.App).all()}
    db_session.add_all([models.ChildApp(child_id=c.id, app_id=a.id) for a in db_session.query(models.App).filter(
        models.App.name.in_(["YouTube", "Roblox", "TikTok"])).all()])
    db_session.commit()
    return p, c, apps


def _task(client, child, title="Homework"):
    return client.post(f"/children/{child.id}/tasks", headers=auth("pa"),
                       json={"title": title, "recurrence": "daily"}).json()


def _todays_occurrence(client, child, task_id):
    occs = client.get(f"/children/{child.id}/occurrences?target_date={date.today()}",
                      headers=auth("pa")).json()
    return [o for o in occs if o["task_id"] == task_id][0]


def _block(client, child, apps, *names, **body):
    return client.post(f"/children/{child.id}/app-blocks", headers=auth("pa"),
                       json={"app_ids": [apps[n] for n in names], **body})


def _in_force(client, child, who="pa"):
    return client.get(f"/children/{child.id}/app-blocks", headers=auth(who)).json()


# ---- the four kinds ------------------------------------------------------

def test_one_row_per_app_in_a_single_request(client, db_session, fam):
    _, c, apps = fam
    task = _task(client, c)
    made = _block(client, c, apps, "YouTube", "Roblox", block_type="until_task", until_task_id=task["id"]).json()
    assert [b["app_name"] for b in made] == ["YouTube", "Roblox"]
    assert all(b["state"] == "active" for b in made)
    assert made[0]["description"] == "until 'Homework' is approved"


def test_a_duration_block_gets_a_fixed_end(client, db_session, fam):
    _, c, apps = fam
    before = datetime.now(timezone.utc)
    [b] = _block(client, c, apps, "TikTok", block_type="duration", duration_minutes=60).json()
    ends = datetime.fromisoformat(b["ends_at"].replace("Z", "+00:00"))
    if ends.tzinfo is None:
        ends = ends.replace(tzinfo=timezone.utc)
    assert timedelta(minutes=59) < ends - before < timedelta(minutes=61)


def test_an_indefinite_block_lasts_until_lifted(client, db_session, fam):
    _, c, apps = fam
    [b] = _block(client, c, apps, "TikTok", block_type="indefinite").json()
    assert b["description"] == "until you lift it"
    lifted = client.post(f"/app-blocks/{b['id']}/lift", headers=auth("pa")).json()
    assert (lifted["state"], lifted["resolved_reason"]) == ("lifted", "parent_lifted")
    assert _in_force(client, c) == []


def test_a_scheduled_block_is_stored_in_the_tasks_weekday_vocabulary(client, db_session, fam):
    _, c, apps = fam
    [b] = _block(client, c, apps, "Roblox", block_type="scheduled",
                 schedule_days="sun,MON,tue,wed,thu", schedule_start="19:00", schedule_end="07:00").json()
    assert b["schedule_days"] == "mon,tue,wed,thu,sun"
    assert (b["schedule_start"], b["schedule_end"]) == ("19:00", "07:00")
    assert b["description"] == "school nights 19:00–07:00"
    assert b["state"] in ("active", "off_window")


@pytest.mark.parametrize("body", [
    {"block_type": "duration"},
    {"block_type": "duration", "duration_minutes": 0},
    {"block_type": "until_task"},
    {"block_type": "scheduled", "schedule_days": "mon", "schedule_start": "19:00"},
    {"block_type": "scheduled", "schedule_days": "someday", "schedule_start": "19:00", "schedule_end": "20:00"},
    {"block_type": "scheduled", "schedule_days": "mon", "schedule_start": "19:00", "schedule_end": "19:00"},
    {"block_type": "forever"},
])
def test_each_kind_needs_what_it_needs(client, db_session, fam, body):
    _, c, apps = fam
    assert _block(client, c, apps, "TikTok", **body).status_code == 422


def test_no_apps_is_refused(client, db_session, fam):
    _, c, _ = fam
    r = client.post(f"/children/{c.id}/app-blocks", headers=auth("pa"),
                    json={"app_ids": [], "block_type": "indefinite"})
    assert r.status_code == 422


# ---- the lockable list ---------------------------------------------------

def test_an_app_off_the_childs_list_is_refused_by_name(client, db_session, fam):
    _, c, apps = fam
    r = _block(client, c, apps, "Minecraft", block_type="indefinite")
    assert r.status_code == 400
    assert "Minecraft" in r.json()["detail"]


def test_add_to_list_puts_it_on_the_list_and_blocks_it(client, db_session, fam):
    _, c, apps = fam
    assert _block(client, c, apps, "Minecraft", block_type="indefinite", add_to_list=True).status_code == 200
    on_list = [a["name"] for a in client.get(f"/children/{c.id}/apps", headers=auth("pa")).json()]
    assert "Minecraft" in on_list


# ---- until a task is done ------------------------------------------------

def test_until_task_block_resolves_itself_when_that_task_is_approved(client, db_session, fam):
    _, c, apps = fam
    task = _task(client, c)
    _block(client, c, apps, "YouTube", block_type="until_task", until_task_id=task["id"])
    assert len(_in_force(client, c, "dev-kid")) == 1

    occ = _todays_occurrence(client, c, task["id"])
    client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa"))

    assert _in_force(client, c, "dev-kid") == []
    [done] = client.get(f"/children/{c.id}/app-blocks?active=false", headers=auth("pa")).json()
    assert (done["state"], done["resolved_reason"]) == ("done", "task_approved")
    assert done["resolved_at"]


def test_a_different_tasks_approval_leaves_the_block_alone(client, db_session, fam):
    _, c, apps = fam
    gate = _task(client, c, title="Homework")
    other = _task(client, c, title="Dishes")
    _block(client, c, apps, "YouTube", block_type="until_task", until_task_id=gate["id"])
    occ = _todays_occurrence(client, c, other["id"])
    client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa"))
    assert len(_in_force(client, c)) == 1


def test_rejecting_the_task_does_not_lift_the_block(client, db_session, fam):
    _, c, apps = fam
    task = _task(client, c)
    _block(client, c, apps, "YouTube", block_type="until_task", until_task_id=task["id"])
    occ = _todays_occurrence(client, c, task["id"])
    client.post(f"/tasks/occurrences/{occ['id']}/submit", headers=auth("dev-kid"), json={})
    client.post(f"/tasks/occurrences/{occ['id']}/reject", headers=auth("pa"))
    assert len(_in_force(client, c)) == 1


def test_block_resolution_works_through_the_put_status_route_too(client, db_session, fam):
    _, c, apps = fam
    task = _task(client, c)
    _block(client, c, apps, "YouTube", block_type="until_task", until_task_id=task["id"])
    occ = _todays_occurrence(client, c, task["id"])
    client.put(f"/occurrences/{occ['id']}/status", headers=auth("pa"), json={"status": "approved"})
    assert _in_force(client, c) == []


def test_cannot_gate_a_block_on_another_childs_task(client, db_session, fam):
    p, c, apps = fam
    sibling = make_child(db_session, p, name="Sib")
    their_task = _task(client, sibling, title="Not yours")
    r = _block(client, c, apps, "YouTube", block_type="until_task", until_task_id=their_task["id"])
    assert r.status_code == 400


# ---- lifting, history, access --------------------------------------------

def test_lifting_keeps_the_block_as_history(client, db_session, fam):
    _, c, apps = fam
    [b] = _block(client, c, apps, "TikTok", block_type="duration", duration_minutes=120).json()
    assert client.post(f"/app-blocks/{b['id']}/lift", headers=auth("pa")).status_code == 200
    assert _in_force(client, c) == []
    assert len(client.get(f"/children/{c.id}/app-blocks?active=false", headers=auth("pa")).json()) == 1
    assert client.post(f"/app-blocks/{b['id']}/lift", headers=auth("pa")).status_code == 409


def test_app_block_access_control(client, db_session, fam):
    _, c, apps = fam
    make_parent(db_session, "pb")
    [b] = _block(client, c, apps, "TikTok", block_type="duration", duration_minutes=60).json()
    assert client.get(f"/children/{c.id}/app-blocks", headers=auth("pb")).status_code == 404
    assert client.post(f"/app-blocks/{b['id']}/lift", headers=auth("pb")).status_code == 404
    # The kid can see they're blocked; they can't unblock themselves.
    assert client.get(f"/children/{c.id}/app-blocks", headers=auth("dev-kid")).status_code == 200
    assert client.post(f"/app-blocks/{b['id']}/lift", headers=auth("dev-kid")).status_code == 401
    # Nor create one for another family's child.
    assert client.post(f"/children/{c.id}/app-blocks", headers=auth("pb"),
                       json={"app_ids": [apps["TikTok"]], "block_type": "indefinite"}).status_code == 404


def test_expiry_is_read_not_written(client, db_session, fam, monkeypatch):
    # A read that wrote "expired" would announce a live update, which makes
    # the device sync, which reads again.
    _, c, apps = fam
    [b] = _block(client, c, apps, "TikTok", block_type="duration", duration_minutes=30).json()
    row = db_session.query(models.AppBlock).filter(models.AppBlock.id == uuid.UUID(b["id"])).one()
    row.ends_at = datetime.now(timezone.utc) - timedelta(minutes=1)
    db_session.commit()

    heard = []
    monkeypatch.setattr(live_updates.broker, "publish", lambda topics: heard.append(topics))
    assert _in_force(client, c) == []
    [past] = client.get(f"/children/{c.id}/app-blocks?active=false", headers=auth("pa")).json()
    assert past["state"] == "expired" and past["resolved"] is False
    assert heard == []


# ---- what "now" means (blocks.py) ----------------------------------------

def _sched(days, start, end):
    return models.AppBlock(block_type="scheduled", schedule_days=days,
                           schedule_start=time.fromisoformat(start), schedule_end=time.fromisoformat(end),
                           resolved=False)


def _at(iso, zone="Europe/London"):
    from zoneinfo import ZoneInfo
    return datetime.fromisoformat(iso).replace(tzinfo=ZoneInfo(zone))


# 2026-09-21 is a Monday.
@pytest.mark.parametrize("when,expected", [
    ("2026-09-21T18:59", "off_window"),   # Monday, before
    ("2026-09-21T19:00", "active"),       # Monday, starts
    ("2026-09-21T23:30", "active"),
    ("2026-09-22T06:59", "active"),       # Tuesday morning, Monday's window still running
    ("2026-09-22T07:00", "off_window"),   # ends
    ("2026-09-25T20:00", "off_window"),   # Friday isn't a school night
    ("2026-09-26T06:00", "off_window"),   # so Saturday morning isn't covered either
    ("2026-09-28T06:00", "active"),       # Monday morning: Sunday's window
])
def test_an_overnight_window_belongs_to_the_day_it_starts(when, expected):
    block = _sched("mon,tue,wed,thu,sun", "19:00", "07:00")
    assert blocks.state(block, _at(when)) == expected


def test_a_same_day_window():
    block = _sched("sat,sun", "10:00", "12:00")
    assert blocks.state(block, _at("2026-09-26T11:00")) == "active"
    assert blocks.state(block, _at("2026-09-26T12:00")) == "off_window"
    assert blocks.state(block, _at("2026-09-21T11:00")) == "off_window"


def test_now_is_the_childs_now_not_the_servers():
    # 03:00 UTC Tuesday is still 20:00 Monday in Los Angeles — inside a
    # Monday-evening window there, outside it in London.
    block = _sched("mon", "19:00", "22:00")
    utc = datetime(2026, 9, 22, 3, 0, tzinfo=timezone.utc)
    la = models.Child(name="A", timezone="America/Los_Angeles")
    london = models.Child(name="B", timezone="Europe/London")
    assert blocks.state(block, blocks.local_now(la, utc)) == "active"
    assert blocks.state(block, blocks.local_now(london, utc)) == "off_window"


def test_a_child_without_a_zone_yet_is_treated_as_utc():
    assert blocks.child_zone(models.Child(name="A")).key == "UTC"
    assert blocks.child_zone(models.Child(name="A", timezone="Nowhere/Real")).key == "UTC"


@pytest.mark.parametrize("days,said", [
    ("mon,tue,wed,thu,fri", "weekdays"),
    ("sat,sun", "weekends"),
    ("mon,tue,wed,thu,fri,sat,sun", "every day"),
    ("mon,wed", "Mon, Wed"),
])
def test_day_spans_read_the_way_a_parent_says_them(days, said):
    assert blocks.describe(_sched(days, "19:00", "20:00"), _at("2026-09-21T12:00")).startswith(said)
