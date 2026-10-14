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
