"""Retried writes count once (idempotency.py), and two phones editing the
same task or lock never undo each other (edits.py): per field, last write
wins by when the edit was made."""
from datetime import datetime, timedelta, timezone

import app_catalog
import models
from tests.conftest import auth, make_child, make_parent


def _family(db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    return p, c


def _h(token="pa", key=None, at=None):
    headers = auth(token)
    if key:
        headers["Idempotency-Key"] = key
    if at:
        headers["X-Edited-At"] = at.isoformat()
    return headers


# ---- retries ------------------------------------------------------------

def test_extra_time_retried_with_the_same_key_counts_once(client, db_session):
    _, c = _family(db_session)
    first = client.post(f"/children/{c.id}/time-grants", headers=_h(key="w-1"), json={"minutes": 15})
    again = client.post(f"/children/{c.id}/time-grants", headers=_h(key="w-1"), json={"minutes": 15})
    assert first.status_code == again.status_code == 200
    assert again.headers.get("idempotent-replay") == "true"
    assert again.json()["id"] == first.json()["id"]
    summary = client.get(f"/children/{c.id}/time-grants", headers=auth("pa")).json()
    assert summary["granted_minutes"] == 15 and len(summary["grants"]) == 1


def test_a_new_key_is_a_new_write(client, db_session):
    _, c = _family(db_session)
    client.post(f"/children/{c.id}/time-grants", headers=_h(key="w-1"), json={"minutes": 15})
    client.post(f"/children/{c.id}/time-grants", headers=_h(key="w-2"), json={"minutes": 15})
    assert client.get(f"/children/{c.id}/time-grants", headers=auth("pa")).json()["granted_minutes"] == 30


def test_a_key_is_only_ever_the_callers_own(client, db_session):
    _, c = _family(db_session)
    other = make_parent(db_session, "pb")
    db_session.add(models.ParentChild(parent_id=other.id, child_id=c.id, role="secondary"))
    db_session.commit()
    client.post(f"/children/{c.id}/time-grants", headers=_h("pa", key="same"), json={"minutes": 10})
    r = client.post(f"/children/{c.id}/time-grants", headers=_h("pb", key="same"), json={"minutes": 10})
    assert r.headers.get("idempotent-replay") is None
    assert client.get(f"/children/{c.id}/time-grants", headers=auth("pa")).json()["granted_minutes"] == 20


def test_a_block_retried_with_the_same_key_is_made_once(client, db_session):
    _, c = _family(db_session)
    app_catalog.seed(db_session)
    youtube = db_session.query(models.App).filter_by(name="YouTube").one()
    body = {"app_ids": [str(youtube.id)], "block_type": "indefinite", "add_to_list": True}
    client.post(f"/children/{c.id}/app-blocks", headers=_h(key="b-1"), json=body)
    client.post(f"/children/{c.id}/app-blocks", headers=_h(key="b-1"), json=body)
    assert len(client.get(f"/children/{c.id}/app-blocks", headers=auth("pa")).json()) == 1


def test_a_refused_write_is_answered_the_same_on_retry(client, db_session):
    _, c = _family(db_session)
    first = client.post(f"/children/{c.id}/time-grants", headers=_h(key="w-0"), json={"minutes": 0})
    again = client.post(f"/children/{c.id}/time-grants", headers=_h(key="w-0"), json={"minutes": 0})
    assert first.status_code == again.status_code == 422


def test_without_a_key_nothing_changes(client, db_session):
    _, c = _family(db_session)
    client.post(f"/children/{c.id}/time-grants", headers=auth("pa"), json={"minutes": 5})
    client.post(f"/children/{c.id}/time-grants", headers=auth("pa"), json={"minutes": 5})
    assert client.get(f"/children/{c.id}/time-grants", headers=auth("pa")).json()["granted_minutes"] == 10
    assert db_session.query(models.IdempotencyKey).count() == 0


# ---- per field, last write wins by edit time ----------------------------

def _task(client, c):
    return client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Water the plants", "recurrence": "daily", "due_date": "2026-11-17"}).json()


def test_two_phones_editing_different_fields_both_keep_their_change(client, db_session):
    _, c = _family(db_session)
    t = _task(client, c)
    now = datetime.now(timezone.utc)
    client.put(f"/tasks/{t['id']}", headers=_h(at=now - timedelta(seconds=5)), json={"title": "Water the garden"})
    client.put(f"/tasks/{t['id']}", headers=_h(at=now - timedelta(seconds=10)), json={"recurrence": "sat"})
    saved = client.get(f"/children/{c.id}/tasks", headers=auth("pa")).json()[0]
    assert saved["title"] == "Water the garden" and saved["recurrence"] == "sat"


def test_an_old_edit_replayed_late_never_undoes_a_newer_one(client, db_session):
    _, c = _family(db_session)
    t = _task(client, c)
    now = datetime.now(timezone.utc)
    # The newer edit arrives first; the phone that was offline replays an
    # older one afterwards.
    client.put(f"/tasks/{t['id']}", headers=_h(at=now), json={"title": "Newer"})
    r = client.put(f"/tasks/{t['id']}", headers=_h(at=now - timedelta(hours=2)),
                   json={"title": "Older", "instructions": "With the blue can"})
    assert r.status_code == 200
    saved = r.json()
    assert saved["title"] == "Newer"                         # the newer title stands
    assert saved["instructions"] == "With the blue can"      # a field nobody else changed applies


def test_an_edit_time_in_the_future_counts_as_now(client, db_session):
    _, c = _family(db_session)
    t = _task(client, c)
    client.put(f"/tasks/{t['id']}", headers=_h(at=datetime.now(timezone.utc) + timedelta(days=1)), json={"title": "Ahead"})
    later = client.put(f"/tasks/{t['id']}", headers=auth("pa"), json={"title": "Later"}).json()
    assert later["title"] == "Later"


def test_an_older_build_sending_every_field_still_saves(client, db_session):
    _, c = _family(db_session)
    t = _task(client, c)
    r = client.put(f"/tasks/{t['id']}", headers=auth("pa"), json={
        "title": "Read", "instructions": "", "recurrence": "mon,wed", "category": "Chore", "submission_kind": "none"})
    assert r.status_code == 200 and r.json()["recurrence"] == "mon,wed" and r.json()["updated_at"]


def test_the_lock_and_unlock_are_per_flag(client, db_session):
    _, c = _family(db_session)
    now = datetime.now(timezone.utc)
    client.put(f"/children/{c.id}/state", headers=_h(at=now - timedelta(seconds=1)), json={"manual_lock": True})
    # The other parent's unlock, made earlier, arrives later: only its own flag changes.
    r = client.put(f"/children/{c.id}/state", headers=_h(at=now - timedelta(seconds=30)),
                   json={"task_gate_override": True, "manual_lock": False}).json()
    assert r["manual_lock"] is True and r["task_gate_override"] is True


def test_a_newer_lock_wins_over_an_older_unlock(client, db_session):
    _, c = _family(db_session)
    now = datetime.now(timezone.utc)
    client.put(f"/children/{c.id}/state", headers=_h(at=now), json={"manual_lock": True})
    r = client.put(f"/children/{c.id}/state", headers=_h(at=now - timedelta(minutes=5)), json={"manual_lock": False}).json()
    assert r["manual_lock"] is True
