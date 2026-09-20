from datetime import datetime, timezone

import models
from tests.conftest import auth, make_child, make_device, make_parent


# ---- children -----------------------------------------------------------

def test_list_only_own_children_with_is_paired(client, db_session):
    a, b = make_parent(db_session, "pa"), make_parent(db_session, "pb")
    mine, _theirs = make_child(db_session, a, "Mine"), make_child(db_session, b, "Theirs")
    make_device(db_session, mine, "d")
    kids = client.get("/children", headers=auth("pa")).json()
    assert [k["name"] for k in kids] == ["Mine"] and kids[0]["is_paired"] is True


def test_rename_and_delete_child_with_ownership(client, db_session):
    a, b = make_parent(db_session, "pa"), make_parent(db_session, "pb")
    kid = make_child(db_session, a, "Old")
    assert client.put(f"/children/{kid.id}", headers=auth("pb"), json={"name": "x"}).status_code == 404
    assert client.put(f"/children/{kid.id}", headers=auth("pa"), json={"name": "  "}).status_code == 400
    r = client.put(f"/children/{kid.id}", headers=auth("pa"), json={"name": " Esen ", "color_index": 3})
    assert r.status_code == 200 and r.json()["name"] == "Esen" and r.json()["color_index"] == 3
    assert client.delete(f"/children/{kid.id}", headers=auth("pb")).status_code == 404
    assert client.delete(f"/children/{kid.id}", headers=auth("pa")).status_code == 200
    assert client.get("/children", headers=auth("pa")).json() == []


# ---- events -------------------------------------------------------------

EV = {"title": "Dentist", "start_at": "2026-09-19T15:00:00Z", "end_at": "2026-09-19T16:00:00Z",
      "category": "Activity", "note": "bring card", "recurrence": "none", "source": "manual"}
WINDOW = "start_date=2026-09-01T00:00:00Z&end_date=2026-09-30T23:59:59Z"


def test_event_crud_keeps_child_category_note(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    r = client.post("/events", headers=auth("pa"), json={**EV, "child_id": str(kid.id)})
    assert r.status_code == 200, r.text
    ev = r.json()
    assert ev["child_id"] == str(kid.id) and ev["category"] == "Activity" and ev["note"] == "bring card"
    up = client.put(f"/events/{ev['id']}", headers=auth("pa"), json={**EV, "child_id": str(kid.id), "title": "Dentist 2"})
    assert up.json()["title"] == "Dentist 2"
    listed = client.get(f"/children/{kid.id}/events?{WINDOW}", headers=auth("pa")).json()
    assert [e["title"] for e in listed] == ["Dentist 2"]
    assert client.delete(f"/events/{ev['id']}", headers=auth("pa")).status_code == 200


def test_family_wide_event_shows_for_every_child_and_events_are_ownership_checked(client, db_session):
    a, b = make_parent(db_session, "pa"), make_parent(db_session, "pb")
    k1, k2 = make_child(db_session, a, "K1"), make_child(db_session, a, "K2")
    other = make_child(db_session, b)
    client.post("/events", headers=auth("pa"), json={**EV, "title": "Family lunch", "source": "everyone"})
    for k in (k1, k2):
        assert [e["title"] for e in client.get(f"/children/{k.id}/events?{WINDOW}", headers=auth("pa")).json()] == ["Family lunch"]
    assert client.post("/events", headers=auth("pb"), json={**EV, "child_id": str(k1.id)}).status_code == 404
    assert client.get(f"/children/{k1.id}/events?{WINDOW}", headers=auth("pb")).status_code == 404
    priv = client.post("/events", headers=auth("pa"), json={**EV, "child_id": str(k1.id)}).json()
    assert client.delete(f"/events/{priv['id']}", headers=auth("pb")).status_code == 404
    assert other  # silence unused


def test_recurring_event_from_before_the_window_is_still_returned(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    client.post("/events", headers=auth("pa"), json={**EV, "child_id": str(kid.id), "title": "Swim",
                "start_at": "2026-08-03T15:00:00Z", "end_at": "2026-08-03T16:00:00Z", "recurrence": "mon"})
    titles = [e["title"] for e in client.get(f"/children/{kid.id}/events?{WINDOW}", headers=auth("pa")).json()]
    assert titles == ["Swim"]


def test_event_end_before_start_rejected(client, db_session):
    p = make_parent(db_session, "pa")
    r = client.post("/events", headers=auth("pa"), json={**EV, "end_at": "2026-09-19T14:00:00Z"})
    assert r.status_code == 400


# ---- pairing (kid shows the code, parent claims it) ---------------------

def _request(client, name="Esen"):
    r = client.post("/auth/pairing/request", json={"child_name": name, "platform": "ios"})
    assert r.status_code == 200, r.text
    return r.json()


def _status(client, req):
    return client.post("/auth/pairing/status", json={"code": req["code"], "secret": req["secret"]})


def test_kid_requests_code_parent_claims_kid_collects_token(client, db_session):
    p = make_parent(db_session, "pa")
    req = _request(client)
    assert len(req["code"]) == 6 and req["secret"]
    assert _status(client, req).json() == {"status": "pending", "access_token": None, "child": None}

    claimed = client.post("/auth/pairing/claim", headers=auth("pa"), json={"code": req["code"]})
    assert claimed.status_code == 200, claimed.text
    assert claimed.json()["name"] == "Esen"          # the name typed on the kid's device

    done = _status(client, req).json()
    assert done["status"] == "paired" and done["access_token"] and done["child"]["name"] == "Esen"
    # the token really is a device token for that child, and it is single-use
    assert client.get("/device/me", headers=auth(done["access_token"])).json()["id"] == done["child"]["id"]
    assert _status(client, req).status_code == 404
    kid = client.get("/children", headers=auth("pa")).json()[0]
    assert kid["is_paired"] is True
    assert db_session.query(models.ParentChild).filter_by(parent_id=p.id).count() == 1


def test_only_the_requesting_device_can_collect_the_token(client, db_session):
    make_parent(db_session, "pa")
    req = _request(client)
    client.post("/auth/pairing/claim", headers=auth("pa"), json={"code": req["code"]})
    stolen = client.post("/auth/pairing/status", json={"code": req["code"], "secret": "guess"})
    assert stolen.status_code == 404
    assert _status(client, req).json()["status"] == "paired"   # the real device still can


def test_claim_rejects_bad_expired_and_reused_codes(client, db_session):
    make_parent(db_session, "pa"), make_parent(db_session, "pb")
    assert client.post("/auth/pairing/claim", headers=auth("pa"), json={"code": "000000"}).status_code == 400
    req = _request(client)
    assert client.post("/auth/pairing/claim", headers=auth("pa"), json={"code": req["code"]}).status_code == 200
    assert client.post("/auth/pairing/claim", headers=auth("pb"), json={"code": req["code"]}).status_code == 409
    req2 = _request(client)
    db_session.query(models.DevicePairing).filter_by(code=req2["code"]).update({"expires_at": datetime(2020, 1, 1, tzinfo=timezone.utc)})
    db_session.commit()
    assert client.post("/auth/pairing/claim", headers=auth("pa"), json={"code": req2["code"]}).status_code == 400
    assert _status(client, req2).status_code == 404


def test_claim_requires_a_parent_login(client, db_session):
    req = _request(client)
    assert client.post("/auth/pairing/claim", json={"code": req["code"]}).status_code in (401, 403)
    assert client.post("/auth/pairing/claim", headers=auth("nope"), json={"code": req["code"]}).status_code == 401


def test_claim_targets_new_specific_or_unpaired_child(client, db_session):
    a, b = make_parent(db_session, "pa"), make_parent(db_session, "pb")
    existing = make_child(db_session, a, "Your Child")
    # default: reuse the unpaired profile that already exists
    r1 = client.post("/auth/pairing/claim", headers=auth("pa"), json={"code": _request(client, "Ada")["code"]}).json()
    assert r1["id"] == str(existing.id) and r1["name"] == "Ada"
    # new_child: always another profile
    r2 = client.post("/auth/pairing/claim", headers=auth("pa"), json={"code": _request(client, "Bo")["code"], "new_child": True}).json()
    assert r2["id"] != str(existing.id) and r2["name"] == "Bo"
    assert db_session.query(models.ParentChild).filter_by(parent_id=a.id).count() == 2
    # specific child, but only your own
    code = _request(client, "Cy")["code"]
    assert client.post("/auth/pairing/claim", headers=auth("pb"), json={"code": code, "child_id": str(existing.id)}).status_code == 404
    r3 = client.post("/auth/pairing/claim", headers=auth("pa"), json={"code": code, "child_id": str(existing.id)}).json()
    assert r3["id"] == str(existing.id) and r3["name"] == "Ada"   # an already-named profile keeps its name


def test_numeric_kid_name_is_ignored(client, db_session):
    make_parent(db_session, "pa")
    req = _request(client, "423186")
    c = client.post("/auth/pairing/claim", headers=auth("pa"), json={"code": req["code"]}).json()
    assert c["name"] == "Your Child"


def test_repairing_replaces_the_old_device(client, db_session):
    a = make_parent(db_session, "pa")
    kid = make_child(db_session, a, "Esen")
    make_device(db_session, kid, "old-dev")
    req = _request(client, "Esen")
    client.post("/auth/pairing/claim", headers=auth("pa"), json={"code": req["code"], "child_id": str(kid.id)})
    token = _status(client, req).json()["access_token"]
    assert client.get("/device/me", headers=auth(token)).status_code == 200
    assert client.get("/device/me", headers=auth("old-dev")).status_code == 401
    assert db_session.query(models.Device).filter_by(child_id=kid.id).count() == 1


def test_delete_account_removes_children_and_devices(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    make_device(db_session, kid, "d")
    assert client.delete("/auth/account", headers=auth("pa")).status_code == 200
    assert db_session.query(models.Child).count() == 0


# ---- kid-device access --------------------------------------------------

def test_device_me_returns_own_child_and_needs_a_device_token(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p, "Esen")
    make_device(db_session, kid, "dev-kid")
    r = client.get("/device/me", headers=auth("dev-kid"))
    assert r.status_code == 200 and r.json()["name"] == "Esen" and r.json()["id"] == str(kid.id)
    assert client.get("/device/me", headers=auth("pa")).status_code == 401
    assert client.get("/device/me").status_code in (401, 403)


def test_kid_device_can_read_its_own_tasks_rules_state_but_not_write_or_read_others(client, db_session):
    a, b = make_parent(db_session, "pa"), make_parent(db_session, "pb")
    kid, other = make_child(db_session, a), make_child(db_session, b)
    make_device(db_session, kid, "dev-kid")
    client.post(f"/children/{kid.id}/tasks", headers=auth("pa"), json={"title": "x"})
    h = auth("dev-kid")
    assert [t["title"] for t in client.get(f"/children/{kid.id}/tasks", headers=h).json()] == ["x"]
    assert client.get(f"/children/{kid.id}/rules", headers=h).status_code == 200
    assert client.get(f"/children/{kid.id}/state", headers=h).status_code == 200
    assert client.post(f"/children/{kid.id}/tasks", headers=h, json={"title": "cheat"}).status_code == 401
    assert client.put(f"/children/{kid.id}/state", headers=h, json={"manual_lock": False, "task_gate_override": True}).status_code == 401
    assert client.get(f"/children/{other.id}/tasks", headers=h).status_code == 404
    assert client.get(f"/children/{other.id}/rules", headers=h).status_code == 404


# ---- token refresh ------------------------------------------------------

class _FakeSupabaseAuth:
    def refresh_session(self, token):
        from types import SimpleNamespace as NS
        if token != "good-refresh":
            raise Exception("Invalid Refresh Token")
        return NS(session=NS(access_token="new-access", refresh_token="new-refresh"))


def test_refresh_exchanges_token_and_rejects_bad_one(client, monkeypatch):
    from types import SimpleNamespace as NS
    from routers import auth as auth_router
    monkeypatch.setattr(auth_router, "supabase", NS(auth=_FakeSupabaseAuth()))
    ok = client.post("/auth/refresh", json={"refresh_token": "good-refresh"})
    assert ok.status_code == 200 and ok.json() == {"access_token": "new-access", "refresh_token": "new-refresh"}
    assert client.post("/auth/refresh", json={"refresh_token": "bad"}).status_code == 401


# ---- rules / state ------------------------------------------------------

def test_rules_update_with_only_the_fields_the_app_sends(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    r = client.put(f"/children/{kid.id}/rules", headers=auth("pa"),
                   json={"daily_limit_minutes": 90, "downtime_enabled": True})
    assert r.status_code == 200, r.text
    assert r.json()["daily_limit_minutes"] == 90 and r.json()["downtime_enabled"] is True
    assert r.json()["blocked_categories"] == []   # untouched


def test_state_update_and_ownership(client, db_session):
    a, b = make_parent(db_session, "pa"), make_parent(db_session, "pb")
    kid = make_child(db_session, a)
    body = {"manual_lock": True, "task_gate_override": False}
    assert client.put(f"/children/{kid.id}/state", headers=auth("pa"), json=body).json()["manual_lock"] is True
    assert client.put(f"/children/{kid.id}/state", headers=auth("pb"), json=body).status_code == 404


def test_rules_persist_toggle_and_custom_rules(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    custom = [{"id": "r1", "title": "No TikTok", "detail": "Blocked", "icon": "block", "on": True}]
    r = client.put(f"/children/{kid.id}/rules", headers=auth("pa"), json={
        "daily_limit_minutes": 45, "downtime_enabled": True, "downtime_start": "20:00:00", "downtime_end": "07:00:00",
        "daily_limit_enabled": False, "custom_rules": custom})
    assert r.status_code == 200, r.text
    got = client.get(f"/children/{kid.id}/rules", headers=auth("pa")).json()
    assert got["daily_limit_enabled"] is False and got["custom_rules"] == custom
    assert got["downtime_start"] == "20:00:00" and got["downtime_end"] == "07:00:00"
    # an update that omits them leaves them alone
    client.put(f"/children/{kid.id}/rules", headers=auth("pa"), json={"daily_limit_minutes": 30, "downtime_enabled": True})
    again = client.get(f"/children/{kid.id}/rules", headers=auth("pa")).json()
    assert again["custom_rules"] == custom and again["daily_limit_minutes"] == 30


def test_deleting_the_downtime_rule_clears_its_times(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    put = lambda body: client.put(f"/children/{kid.id}/rules", headers=auth("pa"), json=body)
    put({"daily_limit_minutes": 60, "downtime_enabled": True, "downtime_start": "20:00:00", "downtime_end": "07:00:00"})
    put({"daily_limit_minutes": 60, "downtime_enabled": False, "downtime_clear": True})
    got = client.get(f"/children/{kid.id}/rules", headers=auth("pa")).json()
    assert got["downtime_enabled"] is False and got["downtime_start"] is None and got["downtime_end"] is None


# ---- parent profile -----------------------------------------------------

def test_parent_name_saved_trimmed_and_private_to_that_parent(client, db_session):
    make_parent(db_session, "pa", "ada@example.com"), make_parent(db_session, "pb", "bo@example.com")
    assert client.get("/auth/me", headers=auth("pa")).json()["name"] is None
    r = client.put("/auth/me", headers=auth("pa"), json={"name": "  Ada Lovelace "})
    assert r.status_code == 200 and r.json()["name"] == "Ada Lovelace"
    assert client.get("/auth/me", headers=auth("pa")).json()["name"] == "Ada Lovelace"
    assert client.get("/auth/me", headers=auth("pb")).json()["name"] is None


def test_parent_name_validation_and_auth(client, db_session):
    make_parent(db_session, "pa")
    assert client.put("/auth/me", headers=auth("pa"), json={"name": "   "}).status_code == 422
    assert client.put("/auth/me", headers=auth("pa"), json={}).status_code == 422
    assert client.put("/auth/me", json={"name": "x"}).status_code in (401, 403)
    long = client.put("/auth/me", headers=auth("pa"), json={"name": "x" * 200}).json()["name"]
    assert len(long) == 60
