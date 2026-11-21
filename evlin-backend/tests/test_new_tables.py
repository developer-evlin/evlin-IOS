"""The tables added 2026-11-20: the child's profile and per-field edits,
notifications to parents, and payments (entitlements). Most aren't read by
any route yet; these check the rules the tables themselves keep."""
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy.exc import IntegrityError

import main
import models
from live_updates import broker
from tests.conftest import auth, make_child, make_device, make_parent


def _family(db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    return p, c


# ---- the child's profile --------------------------------------------------

def test_a_child_made_on_the_phone_is_made_once(client, db_session):
    make_parent(db_session, "pa")
    cid = str(uuid.uuid4())
    body = {"id": cid, "name": "Mia", "age_range": "7-9", "gender": "female"}
    first = client.post("/children", headers=auth("pa"), json=body)
    again = client.post("/children", headers=auth("pa"), json=body)
    assert first.status_code == again.status_code == 200
    assert first.json()["id"] == again.json()["id"] == cid
    assert first.json()["age_range"] == "7-9" and first.json()["gender"] == "female"
    assert db_session.query(models.Child).count() == 1
    assert db_session.query(models.ChildRule).count() == 1


def test_another_familys_child_id_is_refused(client, db_session):
    _, c = _family(db_session)
    make_parent(db_session, "pb")
    r = client.post("/children", headers=auth("pb"), json={"id": str(c.id), "name": "Not mine"})
    assert r.status_code == 409


def test_age_range_and_gender_are_checked(client, db_session):
    _, c = _family(db_session)
    assert client.put(f"/children/{c.id}", headers=auth("pa"), json={"age_range": "21-30"}).status_code == 422
    assert client.put(f"/children/{c.id}", headers=auth("pa"), json={"gender": "robot"}).status_code == 422


def test_the_childs_device_sends_the_profile_picked_in_setup(client, db_session):
    _, c = _family(db_session)
    make_device(db_session, c, "dev-kid")
    r = client.put("/device/me", headers=auth("dev-kid"), json={"name": "Mia", "age_range": "10-12", "gender": "female"})
    assert r.status_code == 200
    assert r.json()["age_range"] == "10-12" and r.json()["gender"] == "female" and r.json()["name"] == "Mia"
    seen = client.get("/children", headers=auth("pa")).json()[0]
    assert seen["age_range"] == "10-12" and seen["gender"] == "female"


def test_two_parents_editing_a_child_keep_both_changes(client, db_session):
    p, c = _family(db_session)
    other = make_parent(db_session, "pb")
    db_session.add(models.ParentChild(parent_id=other.id, child_id=c.id, role="secondary"))
    db_session.commit()
    now = datetime.now(timezone.utc)
    client.put(f"/children/{c.id}", headers={**auth("pa"), "X-Edited-At": now.isoformat()}, json={"name": "Mia"})
    # Made earlier, arriving later: only its own field applies.
    r = client.put(f"/children/{c.id}", headers={**auth("pb"), "X-Edited-At": (now - timedelta(minutes=5)).isoformat()},
                   json={"name": "Old name", "age_range": "7-9"}).json()
    assert r["name"] == "Mia" and r["age_range"] == "7-9"


def test_a_child_has_when_it_was_added(db_session):
    _, c = _family(db_session)
    db_session.refresh(c)
    assert c.added_at is not None


def test_a_split_task_names_the_task_it_came_from(client, db_session):
    _, c = _family(db_session)
    t = client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Water the plants", "recurrence": "daily", "due_date": "2026-11-16"}).json()
    new_id = str(uuid.uuid4())
    r = client.post(f"/tasks/{t['id']}/split", headers=auth("pa"), json={
        "from": "2026-11-18", "through": "2026-11-18",
        "task": {"id": new_id, "title": "Water the garden", "recurrence": "none", "due_date": "2026-11-18"}})
    assert r.status_code == 200, r.text
    made = db_session.query(models.Task).filter(models.Task.id == uuid.UUID(new_id)).one()
    assert made.split_from == uuid.UUID(t["id"])


# ---- notifications --------------------------------------------------------

def test_a_push_token_belongs_to_a_parents_phone_or_a_childs_device_not_both(db_session):
    p, c = _family(db_session)
    d = make_device(db_session, c, "dev-kid")
    session = models.ParentSession(parent_id=p.id, token_hash="h")
    db_session.add(session)
    db_session.commit()
    db_session.add(models.PushToken(token="a", parent_session_id=session.id, device_id=d.id))
    with pytest.raises(IntegrityError):
        db_session.commit()
    db_session.rollback()
    db_session.add(models.PushToken(token="b"))
    with pytest.raises(IntegrityError):
        db_session.commit()
    db_session.rollback()
    db_session.add(models.PushToken(token="c", device_id=d.id))
    db_session.commit()


def test_a_notification_is_written_once_by_its_key(db_session):
    p, c = _family(db_session)
    key = f"all_sent_in:{c.id}:2026-11-20:0:{p.id}"
    db_session.add(models.Notification(kind="all_sent_in", parent_id=p.id, child_id=c.id, dedupe_key=key,
                                       title="Mia finished today's chores"))
    db_session.commit()
    db_session.add(models.Notification(kind="all_sent_in", parent_id=p.id, child_id=c.id, dedupe_key=key,
                                       title="Mia finished today's chores"))
    with pytest.raises(IntegrityError):
        db_session.commit()


def test_notifications_and_push_tokens_wake_no_device(db_session, monkeypatch):
    p, c = _family(db_session)
    calls = []
    monkeypatch.setattr(broker, "publish", lambda topics: calls.append(set(topics)))
    db_session.add(models.Notification(kind="habit_checked_in", parent_id=p.id, child_id=c.id,
                                       dedupe_key="k", title="Mia did Read for 20 minutes"))
    db_session.add(models.NotificationPref(parent_id=p.id, kind="habits", enabled=False))
    db_session.commit()
    assert calls == []


# ---- payments -------------------------------------------------------------

def _account(db_session, parent):
    acct = models.BillingAccount()
    db_session.add(acct)
    db_session.flush()
    db_session.add(models.BillingAccountMember(parent_id=parent.id, billing_account_id=acct.id, role="owner"))
    if db_session.get(models.Plan, ("pro", 1)) is None:
        db_session.add(models.Plan(code="pro", version=1, name="Pro"))
    db_session.commit()
    return acct


def test_the_free_trial_is_once_per_account_ever(db_session):
    p, _ = _family(db_session)
    acct = _account(db_session, p)
    db_session.add(models.EntitlementGrant(billing_account_id=acct.id, source="trial", plan_code="pro", plan_version=1))
    db_session.commit()
    # A promo or a support extension is fine; a second trial isn't.
    db_session.add(models.EntitlementGrant(billing_account_id=acct.id, source="support", plan_code="pro", plan_version=1))
    db_session.commit()
    db_session.add(models.EntitlementGrant(billing_account_id=acct.id, source="trial", plan_code="pro", plan_version=1))
    with pytest.raises(IntegrityError):
        db_session.commit()


def test_a_grant_gives_a_plan_or_a_limit(db_session):
    p, _ = _family(db_session)
    acct = _account(db_session, p)
    db_session.add(models.EntitlementGrant(billing_account_id=acct.id, source="promo"))
    with pytest.raises(IntegrityError):
        db_session.commit()
    db_session.rollback()
    db_session.add(models.EntitlementGrant(billing_account_id=acct.id, source="referral",
                                           limit_key="ai_tokens", limit_value=50_000))
    db_session.commit()


def test_a_purchase_covers_one_account_but_a_family_shared_copy_another(db_session):
    p, _ = _family(db_session)
    acct = _account(db_session, p)
    other = _account(db_session, make_parent(db_session, "pb"))
    common = dict(store="app_store", original_transaction_id="2000000123", product_id="evlin.pro.yearly",
                  plan_code="pro", plan_version=1, status="active")
    db_session.add(models.Subscription(billing_account_id=acct.id, **common))
    db_session.commit()
    db_session.add(models.Subscription(billing_account_id=other.id, ownership="family_shared", **common))
    db_session.commit()
    db_session.add(models.Subscription(billing_account_id=other.id, **common))
    with pytest.raises(IntegrityError):
        db_session.commit()


def test_apples_notification_is_stored_once(db_session):
    db_session.add(models.SubscriptionEvent(source="notification", notification_uuid="n-1", type="DID_RENEW"))
    db_session.commit()
    db_session.add(models.SubscriptionEvent(source="notification", notification_uuid="n-1", type="DID_RENEW"))
    with pytest.raises(IntegrityError):
        db_session.commit()


def test_every_new_table_has_its_migration():
    sql = "\n".join(main._MIGRATIONS)
    for model in (models.PushToken, models.Notification, models.NotificationPref, models.Plan, models.PlanLimit,
                  models.StoreProduct, models.BillingAccount, models.BillingAccountMember, models.Subscription,
                  models.SubscriptionEvent, models.EntitlementGrant, models.UsageEvent, models.UsageCounter):
        table = model.__tablename__
        assert f"CREATE TABLE IF NOT EXISTS app.{table} (" in sql, f"{table} has a model but no migration"
        create = sql.split(f"CREATE TABLE IF NOT EXISTS app.{table} (", 1)[1].split(")\"", 1)[0]
        for column in model.__table__.columns:
            assert column.name in create, f"app.{table}.{column.name} is missing from its CREATE TABLE"
    for column in ("age_range", "gender", "added_at", "updated_at", "field_edits"):
        assert f"app.children ADD COLUMN IF NOT EXISTS {column}" in sql
    for column in ("screen_time_access", "signed_out_by", "last_synced_at"):
        assert f"app.devices ADD COLUMN IF NOT EXISTS {column}" in sql
    assert "app.tasks ADD COLUMN IF NOT EXISTS split_from" in sql


def test_the_unused_push_tables_are_dropped_and_never_made_again():
    sql = "\n".join(main._MIGRATIONS)
    for table in ("push_outbox", "parent_devices"):
        assert f"DROP TABLE IF EXISTS app.{table}" in sql
        assert f"CREATE TABLE IF NOT EXISTS app.{table} " not in sql and f"CREATE TABLE app.{table}" not in sql
    assert "ALTER TABLE app.devices DROP COLUMN IF EXISTS push_token" in sql
    assert "push_token " not in sql.replace("DROP COLUMN IF EXISTS push_token", "")
