"""The screen time access code (routers/access_codes.py): made and checked
only on the server, one parent's code for all their children's devices,
good for a minute and once."""
from datetime import datetime, timedelta, timezone

import models
from tests.conftest import auth, make_child, make_device, make_parent


def _family(db_session):
    p = make_parent(db_session, "pa")
    mia, leo = make_child(db_session, p, "Mia"), make_child(db_session, p, "Leo")
    make_device(db_session, mia, "dev-mia")
    make_device(db_session, leo, "dev-leo")
    return p, mia, leo


def _code(client, who="pa"):
    r = client.post("/access-code", headers=auth(who))
    assert r.status_code == 200, r.text
    return r.json()


def _check(client, code, device="dev-mia"):
    r = client.post("/device/access-code", headers=auth(device), json={"code": code})
    assert r.status_code == 200, r.text
    return r.json()["ok"]


def test_the_parent_gets_six_random_digits_good_for_a_minute(client, db_session):
    _family(db_session)
    first = _code(client)
    assert len(first["code"]) == 6 and first["code"].isdigit()
    assert 55 <= first["seconds_left"] <= 60 and first["lifetime"] == 60
    # Asked again while it's good: the same code, so the screen doesn't jump.
    assert _code(client)["code"] == first["code"]


def test_one_code_opens_any_of_the_parents_childrens_devices_once(client, db_session):
    _family(db_session)
    code = _code(client)["code"]
    assert _check(client, code, "dev-leo")
    # Used up: it opens nothing again, and the phone is given a new one.
    assert not _check(client, code, "dev-mia")
    fresh = _code(client)["code"]
    assert _check(client, fresh, "dev-mia")


def test_a_wrong_or_malformed_code_opens_nothing(client, db_session):
    _family(db_session)
    code = _code(client)["code"]
    wrong = f"{(int(code) + 1) % 1_000_000:06d}"
    assert not _check(client, wrong)
    assert not _check(client, "12345")
    assert not _check(client, "abcdef")
    assert _check(client, code)  # a wrong try doesn't use the right one up


def test_a_code_past_its_minute_opens_nothing(client, db_session):
    _family(db_session)
    code = _code(client)["code"]
    row = db_session.query(models.AccessCode).one()
    row.expires_at = datetime.now(timezone.utc) - timedelta(seconds=10)
    db_session.commit()
    assert not _check(client, code)
    # And the phone is given a new one.
    assert db_session.query(models.AccessCode).count() == 1
    _code(client)
    assert db_session.query(models.AccessCode).count() == 2


def test_another_familys_code_never_opens_this_device(client, db_session):
    _family(db_session)
    other = make_parent(db_session, "pb")
    make_child(db_session, other)
    theirs = _code(client, "pb")["code"]
    assert not _check(client, theirs)


def test_a_second_parent_of_the_child_has_a_code_that_works_too(client, db_session):
    p, mia, _ = _family(db_session)
    dad = make_parent(db_session, "pdad")
    db_session.add(models.ParentChild(parent_id=dad.id, child_id=mia.id, role="secondary"))
    db_session.commit()
    assert _check(client, _code(client, "pdad")["code"])


def test_only_a_parent_gets_a_code_and_only_a_device_checks_one(client, db_session):
    _family(db_session)
    assert client.post("/access-code", headers=auth("dev-mia")).status_code == 401
    assert client.post("/device/access-code", headers=auth("pa"), json={"code": "123456"}).status_code == 401


def test_the_children_no_longer_carry_a_secret(client, db_session):
    _family(db_session)
    me = client.get("/device/me", headers=auth("dev-mia")).json()
    assert "access_secret" not in me
