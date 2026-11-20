"""A kid's photos and Send arrive together (2026-11-19).

The phone names each photo (an id) and asks for an upload link signed for
the photo's exact size; Send names the photos, and the server counts each
only once R2 really has it, in the same commit that sends the task in."""
import uuid
from datetime import date
from urllib.parse import parse_qs, urlparse

import models
from tests.conftest import auth, make_child, make_device, make_parent

TODAY = str(date.today())


def _occurrence(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    make_device(db_session, kid, "dev-kid")
    client.post(f"/children/{kid.id}/tasks", headers=auth("pa"), json={"title": "Tidy the desk", "recurrence": "daily"})
    occ = client.get(f"/children/{kid.id}/occurrences?target_date={TODAY}", headers=auth("dev-kid")).json()[0]
    return kid, occ


def _photo(client, occ, photo_id=None, size=200_000, content_type="image/heic"):
    body = {"kind": "photo", "content_type": content_type, "bytes_size": size}
    if photo_id:
        body["id"] = photo_id
    return client.post(f"/occurrences/{occ['id']}/submissions", headers=auth("dev-kid"), json=body)


def _send(client, occ, photo_ids=None):
    body = {} if photo_ids is None else {"photo_ids": photo_ids}
    return client.post(f"/tasks/occurrences/{occ['id']}/submit", headers=auth("dev-kid"), json=body)


def test_the_phone_names_the_photo_and_a_retry_gets_the_same_one(client, db_session):
    _, occ = _occurrence(client, db_session)
    photo_id = str(uuid.uuid4())
    first = _photo(client, occ, photo_id)
    again = _photo(client, occ, photo_id)
    assert first.status_code == 200 and again.status_code == 200, again.text
    assert first.json()["submission"]["id"] == again.json()["submission"]["id"] == photo_id
    assert first.json()["submission"]["r2_key"].endswith(f"/{photo_id}.heic")
    assert db_session.query(models.Submission).count() == 1


def test_the_upload_link_is_signed_for_the_photos_size(client, db_session):
    _, occ = _occurrence(client, db_session)
    url = _photo(client, occ, str(uuid.uuid4()), size=123_456).json()["upload_url"]
    signed = parse_qs(urlparse(url).query)["X-Amz-SignedHeaders"][0].split(";")
    assert "content-length" in signed and "content-type" in signed


def test_too_big_or_not_an_image_is_refused(client, db_session):
    _, occ = _occurrence(client, db_session)
    assert _photo(client, occ, size=6 * 1024 * 1024).status_code == 422
    assert _photo(client, occ, content_type="application/zip").status_code == 422


def test_a_photo_id_from_another_task_is_refused(client, db_session):
    kid, occ = _occurrence(client, db_session)
    other = client.post(f"/children/{kid.id}/tasks", headers=auth("pa"), json={"title": "Feed the cat", "recurrence": "daily"}).json()
    occs = client.get(f"/children/{kid.id}/occurrences?target_date={TODAY}", headers=auth("dev-kid")).json()
    other_occ = next(o for o in occs if o["task_id"] == other["id"])
    photo_id = str(uuid.uuid4())
    assert _photo(client, occ, photo_id).status_code == 200
    assert _photo(client, other_occ, photo_id).status_code == 409


def test_send_counts_a_photo_r2_has_and_sends_the_task_in(client, db_session, r2_files):
    kid, occ = _occurrence(client, db_session)
    photo_id = str(uuid.uuid4())
    sub = _photo(client, occ, photo_id).json()["submission"]
    r2_files[sub["r2_key"]] = 200_000

    r = _send(client, occ, [photo_id])
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "submitted" and r.json()["missing_photo_ids"] == []

    photos = client.get(f"/occurrences/{occ['id']}/submissions", headers=auth("pa")).json()
    assert photos[0]["status"] == "uploaded" and photos[0]["download_url"].startswith("https://")
    assert photos[0]["bytes_size"] == 200_000


def test_a_photo_that_never_arrived_is_named_and_the_task_still_goes_in(client, db_session, r2_files):
    _, occ = _occurrence(client, db_session)
    arrived, lost, stranger = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
    r2_files[_photo(client, occ, arrived).json()["submission"]["r2_key"]] = 1000
    _photo(client, occ, lost)

    r = _send(client, occ, [arrived, lost, stranger])
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "submitted"
    assert set(r.json()["missing_photo_ids"]) == {lost, stranger}
    # The parent sees only what's really there.
    photos = client.get(f"/occurrences/{occ['id']}/submissions", headers=auth("pa")).json()
    assert {p["id"]: p["status"] for p in photos} == {arrived: "uploaded", lost: "pending"}

    # Uploaded again and sent again: now it counts.
    r2_files[f"submissions/{occ['child_id']}/{occ['id']}/{lost}.heic"] = 1000
    assert _send(client, occ, [arrived, lost]).json()["missing_photo_ids"] == []


def test_send_with_no_photos_is_as_before(client, db_session):
    _, occ = _occurrence(client, db_session)
    assert _send(client, occ).json()["status"] == "submitted"
    assert _send(client, occ, []).json()["missing_photo_ids"] == []


def test_a_late_send_keeps_the_parents_approval(client, db_session, r2_files):
    _, occ = _occurrence(client, db_session)
    assert _send(client, occ).status_code == 200
    assert client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa")).status_code == 200
    photo_id = str(uuid.uuid4())
    r2_files[_photo(client, occ, photo_id).json()["submission"]["r2_key"]] = 1000
    r = _send(client, occ, [photo_id])
    assert r.json()["status"] == "approved" and r.json()["missing_photo_ids"] == []


def test_r2_out_of_reach_is_a_retry_not_a_missing_photo(client, db_session, monkeypatch):
    import storage
    _, occ = _occurrence(client, db_session)
    photo_id = str(uuid.uuid4())
    _photo(client, occ, photo_id)

    def unreachable(key):
        raise storage.StorageUnavailable("down")
    monkeypatch.setattr(storage, "object_size", unreachable)
    assert _send(client, occ, [photo_id]).status_code == 503
    occ_row = db_session.query(models.Occurrence).filter(models.Occurrence.id == uuid.UUID(occ["id"])).one()
    db_session.refresh(occ_row)
    assert occ_row.status == "pending"
