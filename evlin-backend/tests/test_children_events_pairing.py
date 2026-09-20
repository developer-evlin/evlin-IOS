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


# ---- pairing ------------------------------------------------------------

def test_generate_code_default_reuses_first_child_or_creates_one(client, db_session):
    p = make_parent(db_session, "pa")
    r = client.post("/auth/generate-pairing-code", headers=auth("pa"))
    assert r.status_code == 200, r.text
    cid = r.json()["child_id"]
    assert len(r.json()["pairing_code"]) == 6
    again = client.post("/auth/generate-pairing-code", headers=auth("pa")).json()
    assert again["child_id"] == cid
    assert db_session.query(models.ParentChild).filter_by(parent_id=p.id).count() == 1


def test_generate_code_for_new_child_and_specific_child(client, db_session):
    a, b = make_parent(db_session, "pa"), make_parent(db_session, "pb")
    first = make_child(db_session, a)
    new = client.post("/auth/generate-pairing-code", headers=auth("pa"), json={"new_child": True}).json()
    assert new["child_id"] != str(first.id)
    assert db_session.query(models.ParentChild).filter_by(parent_id=a.id).count() == 2
    specific = client.post("/auth/generate-pairing-code", headers=auth("pa"), json={"child_id": str(first.id)}).json()
    assert specific["child_id"] == str(first.id)
    assert client.post("/auth/generate-pairing-code", headers=auth("pb"), json={"child_id": str(first.id)}).status_code == 404


def _pair(client, code, name):
    return client.post("/auth/pair-child", json={"pairing_code": code, "platform": "ios", "child_name": name})


def test_full_pairing_flow_updates_name_and_reports_paired(client, db_session):
    make_parent(db_session, "pa")
    g = client.post("/auth/generate-pairing-code", headers=auth("pa")).json()
    status = client.get(f"/auth/check-pairing/{g['pairing_code']}?child_id={g['child_id']}", headers=auth("pa")).json()
    assert status == {"paired": False}
    r = _pair(client, g["pairing_code"], "Esen")
    assert r.status_code == 200 and r.json()["access_token"]
    status = client.get(f"/auth/check-pairing/{g['pairing_code']}?child_id={g['child_id']}", headers=auth("pa")).json()
    assert status == {"paired": True, "kid_name": "Esen"}
    kid = client.get("/children", headers=auth("pa")).json()[0]
    assert kid["name"] == "Esen" and kid["is_paired"] is True


def test_numeric_name_is_ignored_and_code_is_single_use(client, db_session):
    make_parent(db_session, "pa")
    g = client.post("/auth/generate-pairing-code", headers=auth("pa")).json()
    assert _pair(client, g["pairing_code"], "423186").status_code == 200
    assert client.get("/children", headers=auth("pa")).json()[0]["name"] == "Your Child"
    assert _pair(client, g["pairing_code"], "Esen").status_code == 400


def test_expired_unused_code_is_not_reported_as_paired(client, db_session):
    make_parent(db_session, "pa")
    g = client.post("/auth/generate-pairing-code", headers=auth("pa")).json()
    db_session.query(models.PairingCode).delete()   # what expiry cleanup does
    db_session.commit()
    status = client.get(f"/auth/check-pairing/{g['pairing_code']}?child_id={g['child_id']}", headers=auth("pa")).json()
    assert status == {"paired": False}


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
