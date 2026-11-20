"""A kid's device stays paired until the parent says otherwise."""
from datetime import datetime, timedelta, timezone

from tests.conftest import auth, make_child, make_device, make_parent


def test_device_token_does_not_expire(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    d = make_device(db_session, kid, "dev")
    d.paired_at = datetime.now(timezone.utc) - timedelta(days=400)
    db_session.commit()
    assert client.get("/device/me", headers=auth("dev")).status_code == 200


def test_parent_unpair_ends_the_device_token(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    make_device(db_session, kid, "dev")
    assert client.delete(f"/children/{kid.id}/device", headers=auth("pa")).status_code == 200
    assert client.get("/device/me", headers=auth("dev")).status_code == 401
    listed = client.get("/children", headers=auth("pa")).json()
    assert listed[0]["is_paired"] is False


def test_only_the_childs_parent_can_unpair(client, db_session):
    a, b = make_parent(db_session, "pa"), make_parent(db_session, "pb")
    kid = make_child(db_session, a)
    make_device(db_session, kid, "dev")
    assert client.delete(f"/children/{kid.id}/device", headers=auth("pb")).status_code == 404
    assert client.get("/device/me", headers=auth("dev")).status_code == 200


def test_parent_sees_when_the_kid_has_finished_setting_up(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    make_device(db_session, kid, "dev")
    assert client.get("/children", headers=auth("pa")).json()[0]["setup_complete"] is False

    assert client.put("/device/me", headers=auth("dev"), json={"setup_complete": True}).status_code == 200
    assert client.get("/children", headers=auth("pa")).json()[0]["setup_complete"] is True


def test_setup_complete_is_written_once(client, db_session):
    import models
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    d = make_device(db_session, kid, "dev")
    client.put("/device/me", headers=auth("dev"), json={"setup_complete": True})
    first = db_session.query(models.Device).get(d.id).setup_completed_at
    client.put("/device/me", headers=auth("dev"), json={"setup_complete": True})
    assert db_session.query(models.Device).get(d.id).setup_completed_at == first


def test_a_new_pairing_waits_for_setup_again(client, db_session):
    import models
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    make_device(db_session, kid, "old")
    client.put("/device/me", headers=auth("old"), json={"setup_complete": True})
    db_session.query(models.Device).filter_by(child_id=kid.id).delete()
    db_session.commit()
    make_device(db_session, kid, "new")
    assert client.get("/children", headers=auth("pa")).json()[0]["setup_complete"] is False


def test_device_update_echoes_setup_complete(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    make_device(db_session, kid, "dev")
    assert client.put("/device/me", headers=auth("dev"), json={"timezone": "UTC"}).json()["setup_complete"] is False
    assert client.put("/device/me", headers=auth("dev"), json={"setup_complete": True}).json()["setup_complete"] is True


def test_kid_device_names_its_child_after_pairing(client, db_session):
    """The kid's setup pairs first, then asks the name: the device sends it."""
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    make_device(db_session, kid, "dev")
    r = client.put("/device/me", headers=auth("dev"), json={"name": "  Mia  "})
    assert r.status_code == 200 and r.json()["name"] == "Mia"
    assert client.get("/children", headers=auth("pa")).json()[0]["name"] == "Mia"
    # A mistyped code is not a name: the name stays.
    client.put("/device/me", headers=auth("dev"), json={"name": "482913"})
    assert client.get("/children", headers=auth("pa")).json()[0]["name"] == "Mia"



def test_family_sharing_hand_off_between_the_devices(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    make_device(db_session, kid, "dev")
    assert client.get("/children", headers=auth("pa")).json()[0]["setup_stage"] is None

    # The kid's device: the account is made; the parent's phone shows how
    # to sign the device in.
    r = client.put("/device/me", headers=auth("dev"), json={"setup_stage": "account_created"})
    assert r.status_code == 200 and r.json()["setup_stage"] == "account_created"
    assert client.get("/children", headers=auth("pa")).json()[0]["setup_stage"] == "account_created"

    # Signed in: the parent's phone hears it and says so.
    client.put("/device/me", headers=auth("dev"), json={"setup_stage": "signed_in"})
    assert client.get("/children", headers=auth("pa")).json()[0]["setup_stage"] == "signed_in"

    # Left the step: cleared.
    client.put("/device/me", headers=auth("dev"), json={"setup_stage": ""})
    assert client.get("/children", headers=auth("pa")).json()[0]["setup_stage"] is None


def test_setup_stage_is_checked(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    make_device(db_session, kid, "dev")
    assert client.put("/device/me", headers=auth("dev"), json={"setup_stage": "nonsense"}).status_code == 422


def test_parent_says_the_account_is_created(client, db_session):
    """The kid's device shows how to make the account; "I've created the
    account" tapped on the parent's phone moves it on."""
    p = make_parent(db_session, "pa")
    child = make_child(db_session, p)
    make_device(db_session, child, "dev")
    client.put("/device/me", headers=auth("dev"), json={"setup_stage": "creating_account"})
    assert client.get("/children", headers=auth("pa")).json()[0]["setup_stage"] == "creating_account"

    r = client.put(f"/children/{child.id}/setup-stage", headers=auth("pa"), json={"setup_stage": "account_created"})
    assert r.status_code == 200 and r.json()["setup_stage"] == "account_created"
    assert client.get("/device/me", headers=auth("dev")).json()["setup_stage"] == "account_created"

    # Only a device on that step moves: once it has left, a late tap does nothing.
    client.put("/device/me", headers=auth("dev"), json={"setup_stage": ""})
    client.put(f"/children/{child.id}/setup-stage", headers=auth("pa"), json={"setup_stage": "account_created"})
    assert client.get("/device/me", headers=auth("dev")).json()["setup_stage"] is None


def test_only_the_childs_parent_moves_the_setup(client, db_session):
    p = make_parent(db_session, "pa")
    child = make_child(db_session, p)
    make_device(db_session, child, "dev")
    make_parent(db_session, "other")
    client.put("/device/me", headers=auth("dev"), json={"setup_stage": "creating_account"})
    r = client.put(f"/children/{child.id}/setup-stage", headers=auth("other"), json={"setup_stage": "account_created"})
    assert r.status_code in (403, 404)
    assert client.get("/device/me", headers=auth("dev")).json()["setup_stage"] == "creating_account"
    assert client.put(f"/children/{child.id}/setup-stage", headers=auth("pa"), json={"setup_stage": "nonsense"}).status_code == 422
