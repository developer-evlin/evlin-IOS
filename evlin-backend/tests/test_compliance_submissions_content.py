"""Coverage for the three routers nothing exercised before: compliance.py
(consent/audit), submissions.py (photo/voice evidence), and content.py
(generic uploads). The manual real-Postgres sweep that led to this file
caught a live bug here — models.AuditLog mapped a Python attribute to a
"metadata" column that doesn't exist (the real column is `payload`, per
evlin-tables.sql); every /audit call crashed with a 500. That's what
test_audit_persists_the_real_payload guards against.
"""
import models
from tests.conftest import auth, make_child, make_device, make_parent


# ---- consent --------------------------------------------------------------

def test_consent_is_recorded_per_parent(client, db_session):
    p = make_parent(db_session, "pa")
    r = client.post("/consent", headers=auth("pa"), json={"toggle_key": "tos", "granted": True, "version": 2})
    assert r.status_code == 200, r.text
    row = db_session.query(models.Consent).filter(models.Consent.parent_id == p.id).first()
    assert row.toggle_key == "tos" and row.granted is True and row.version == 2


def test_consent_requires_a_parent_login(client, db_session):
    assert client.post("/consent", json={"toggle_key": "tos", "granted": True}).status_code in (401, 403)


# ---- audit ------------------------------------------------------------

def test_audit_persists_the_real_payload(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    make_device(db_session, kid, "dev-kid")
    r = client.post("/audit", headers=auth("dev-kid"), json={"kind": "app_blocked", "metadata": {"app": "TikTok"}})
    assert r.status_code == 200, r.text
    row = db_session.query(models.AuditLog).filter(models.AuditLog.child_id == kid.id).first()
    assert row.kind == "app_blocked" and row.payload == {"app": "TikTok"}


def test_audit_without_metadata_defaults_to_empty_dict_not_null(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    make_device(db_session, kid, "dev-kid")
    r = client.post("/audit", headers=auth("dev-kid"), json={"kind": "lock_bypass_attempt"})
    assert r.status_code == 200, r.text
    row = db_session.query(models.AuditLog).filter(models.AuditLog.child_id == kid.id).first()
    assert row.payload == {}


def test_audit_requires_a_device_token_not_a_parent_login(client, db_session):
    p = make_parent(db_session, "pa")
    r = client.post("/audit", headers=auth("pa"), json={"kind": "x"})
    assert r.status_code == 401


# ---- submissions ------------------------------------------------------

def _occurrence(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    make_device(db_session, kid, "dev-kid")
    client.post(f"/children/{kid.id}/tasks", headers=auth("pa"), json={
        "title": "Take a photo", "recurrence": "daily", "submission_kind": "photo"})
    occ = client.get(f"/children/{kid.id}/occurrences?target_date=2026-09-20", headers=auth("dev-kid")).json()[0]
    return kid, occ


def test_submission_upload_flow_generates_a_url_and_marks_uploaded(client, db_session):
    kid, occ = _occurrence(client, db_session)
    r = client.post(f"/occurrences/{occ['id']}/submissions", headers=auth("dev-kid"),
                     json={"kind": "photo", "content_type": "image/jpeg"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["upload_url"].startswith("https://") and body["submission"]["status"] == "pending"
    sub_id = body["submission"]["id"]

    done = client.post(f"/submissions/{sub_id}/complete", headers=auth("dev-kid"))
    assert done.status_code == 200 and done.json()["status"] == "uploaded" and done.json()["uploaded_at"]

    occ_after = client.get(f"/children/{kid.id}/occurrences?target_date=2026-09-20", headers=auth("dev-kid")).json()[0]
    assert occ_after["status"] == "submitted"  # completing a submission moves the occurrence forward


def test_submission_requires_owning_the_occurrence(client, db_session):
    kid, occ = _occurrence(client, db_session)
    other_parent = make_parent(db_session, "pb")
    other_kid = make_child(db_session, other_parent)
    make_device(db_session, other_kid, "dev-other")
    r = client.post(f"/occurrences/{occ['id']}/submissions", headers=auth("dev-other"),
                     json={"kind": "photo", "content_type": "image/jpeg"})
    assert r.status_code == 403


def test_complete_requires_owning_the_submission(client, db_session):
    kid, occ = _occurrence(client, db_session)
    sub = client.post(f"/occurrences/{occ['id']}/submissions", headers=auth("dev-kid"),
                       json={"kind": "photo", "content_type": "image/jpeg"}).json()["submission"]
    other_parent = make_parent(db_session, "pb")
    other_kid = make_child(db_session, other_parent)
    make_device(db_session, other_kid, "dev-other")
    r = client.post(f"/submissions/{sub['id']}/complete", headers=auth("dev-other"))
    assert r.status_code == 403


def test_unknown_occurrence_and_submission_404(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    make_device(db_session, kid, "dev-kid")
    assert client.post("/occurrences/00000000-0000-0000-0000-000000000000/submissions",
                        headers=auth("dev-kid"), json={"kind": "photo", "content_type": "image/jpeg"}).status_code == 404
    assert client.post("/submissions/00000000-0000-0000-0000-000000000000/complete",
                        headers=auth("dev-kid")).status_code == 404


# ---- content ------------------------------------------------------------

def test_content_upload_and_download_urls(client, db_session):
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    make_device(db_session, kid, "dev-kid")
    up = client.post("/content/upload-url", headers=auth("dev-kid"), json={"content_type": "image/png"})
    assert up.status_code == 200, up.text
    assert up.json()["upload_url"].startswith("https://") and up.json()["object_key"]

    down = client.get(f"/content/{up.json()['object_key']}/url", headers=auth("dev-kid"))
    assert down.status_code == 200 and down.json()["download_url"].startswith("https://")


def test_content_requires_a_device_token(client, db_session):
    p = make_parent(db_session, "pa")
    r = client.post("/content/upload-url", headers=auth("pa"), json={"content_type": "image/png"})
    assert r.status_code == 401
