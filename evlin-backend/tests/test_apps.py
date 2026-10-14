"""The app catalog, each child's lockable list, and the child's timezone."""
import pytest

import app_catalog
import live_updates
import main
import models
from live_updates import child_topic
from tests.conftest import auth, make_child, make_device, make_parent


@pytest.fixture()
def catalog(db_session):
    app_catalog.seed(db_session)
    return {a.name: a for a in db_session.query(models.App).all()}


@pytest.fixture()
def family(db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    make_device(db_session, c, "kid")
    return p, c


# ---- the catalog ---------------------------------------------------------

def test_seeding_twice_changes_nothing(db_session, catalog):
    app_catalog.seed(db_session)
    assert db_session.query(models.App).count() == len(app_catalog.CATALOG)


def test_the_production_seed_covers_the_same_catalog():
    # One list feeds both; this catches a hand edit to either side.
    sql = app_catalog.seed_sql()
    for name, _aliases, _category in app_catalog.CATALOG:
        assert f"'{name}'" in sql
    assert sql in main._MIGRATIONS


def test_the_catalog_is_parent_readable(client, db_session, catalog, family):
    names = [a["name"] for a in client.get("/apps", headers=auth("pa")).json()]
    assert names == sorted(names)
    assert "YouTube" in names


# ---- a child's lockable list ---------------------------------------------

def test_a_parent_sets_the_list_and_both_sides_read_it(client, db_session, catalog, family):
    _, c = family
    ids = [str(catalog["YouTube"].id), str(catalog["Roblox"].id)]

    saved = client.put(f"/children/{c.id}/apps", headers=auth("pa"), json={"app_ids": ids}).json()
    assert [a["name"] for a in saved] == ["Roblox", "YouTube"]

    from_device = client.get(f"/children/{c.id}/apps", headers=auth("kid")).json()
    assert [a["name"] for a in from_device] == ["Roblox", "YouTube"]


def test_replacing_the_list_removes_what_was_dropped(client, db_session, catalog, family):
    _, c = family
    client.put(f"/children/{c.id}/apps", headers=auth("pa"),
               json={"app_ids": [str(catalog["YouTube"].id), str(catalog["Roblox"].id)]})
    after = client.put(f"/children/{c.id}/apps", headers=auth("pa"),
                       json={"app_ids": [str(catalog["TikTok"].id)]}).json()
    assert [a["name"] for a in after] == ["TikTok"]


def test_an_unknown_app_id_is_refused(client, db_session, catalog, family):
    _, c = family
    r = client.put(f"/children/{c.id}/apps", headers=auth("pa"),
                   json={"app_ids": ["00000000-0000-0000-0000-000000000000"]})
    assert r.status_code == 400


def test_another_family_can_neither_read_nor_set_the_list(client, db_session, catalog, family):
    _, c = family
    make_parent(db_session, "pb")
    assert client.get(f"/children/{c.id}/apps", headers=auth("pb")).status_code == 404
    assert client.put(f"/children/{c.id}/apps", headers=auth("pb"),
                      json={"app_ids": [str(catalog["YouTube"].id)]}).status_code == 404


def test_the_kid_device_cannot_change_its_own_list(client, db_session, catalog, family):
    _, c = family
    r = client.put(f"/children/{c.id}/apps", headers=auth("kid"),
                   json={"app_ids": [str(catalog["YouTube"].id)]})
    assert r.status_code == 401


# ---- timezone ------------------------------------------------------------

def test_the_device_reports_its_timezone(client, db_session, family):
    _, c = family
    r = client.put("/device/me", headers=auth("kid"), json={"timezone": "America/Los_Angeles"})
    assert r.status_code == 200
    assert r.json()["timezone"] == "America/Los_Angeles"


def test_a_made_up_timezone_is_refused(client, db_session, family):
    assert client.put("/device/me", headers=auth("kid"), json={"timezone": "Mars/Olympus"}).status_code == 422


def test_resending_the_same_timezone_announces_nothing(client, db_session, family, monkeypatch):
    # Sent on every sync. If an unchanged value still announced a change,
    # the device would sync because of its own sync, forever.
    _, c = family
    cid = c.id
    client.put("/device/me", headers=auth("kid"), json={"timezone": "Europe/London"})

    heard = []
    monkeypatch.setattr(live_updates.broker, "publish", lambda topics: heard.append(set(topics)))
    client.put("/device/me", headers=auth("kid"), json={"timezone": "Europe/London"})
    assert heard == []

    client.put("/device/me", headers=auth("kid"), json={"timezone": "Asia/Tokyo"})
    assert child_topic(cid) in set().union(*heard)


def test_an_unchanged_assignment_is_silent_even_outside_that_route(db_session, family, monkeypatch):
    # The same guarantee in the hook itself, so a route that forgets to
    # compare first still can't cause a loop.
    # Loaded fresh, as a route has it. (An attribute expired by an earlier
    # commit has no old value to compare against, so assigning it is a real
    # UPDATE either way — the route-level compare is what covers that.)
    _, c = family
    fresh = db_session.query(models.Child).filter(models.Child.id == c.id).one()
    fresh.name = fresh.name
    heard = []
    monkeypatch.setattr(live_updates.broker, "publish", lambda topics: heard.append(set(topics)))
    db_session.commit()
    assert heard == []
