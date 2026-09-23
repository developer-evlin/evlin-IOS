from datetime import date, datetime, timezone

import models
from routers.occurrences import task_applies_on
from tests.conftest import auth, make_child, make_device, make_parent


def T(rec, due=None, created=datetime(2026, 9, 14, tzinfo=timezone.utc)):
    return models.Task(recurrence=rec, due_date=due, created_at=created)


MON, TUE, SAT = date(2026, 9, 14), date(2026, 9, 15), date(2026, 9, 19)


# ---- recurrence rules ---------------------------------------------------

def test_none_only_on_start_day():
    assert task_applies_on(T("none"), MON)
    assert not task_applies_on(T("none"), TUE)


def test_none_uses_due_date_over_created():
    assert task_applies_on(T("none", due=SAT), SAT)
    assert not task_applies_on(T("none", due=SAT), MON)


def test_daily_from_start_onward_only():
    assert task_applies_on(T("daily"), TUE)
    # A day of slack on the created_at fallback (not a real due_date) — see
    # task_applies_on's comment: created_at is a UTC timestamp, so a device
    # west of UTC can still be on the previous local day when the task was
    # made, and this is what lets that day's occurrence still generate.
    assert task_applies_on(T("daily"), date(2026, 9, 13))
    assert not task_applies_on(T("daily"), date(2026, 9, 12))


def test_daily_with_explicit_due_date_has_no_slack():
    # Unlike the created_at fallback above, an explicit due_date is already
    # an unambiguous calendar date — a task deliberately scheduled to start
    # tomorrow must not apply today just because of the fallback's slack.
    assert task_applies_on(T("daily", due=MON), MON)
    assert not task_applies_on(T("daily", due=MON), date(2026, 9, 13))


def test_weekday_codes():
    assert task_applies_on(T("mon,wed"), MON)
    assert not task_applies_on(T("mon,wed"), TUE)
    assert task_applies_on(T("sat,sun"), SAT)


# ---- task endpoints -----------------------------------------------------

def test_create_task_returns_saved_row_with_string_due_fields(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    r = client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": " Make bed ", "instructions": "tidy", "recurrence": "none", "category": "Chore",
        "submission_kind": "none", "due_time": "09:30:00", "due_date": "2026-09-19"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["title"] == "Make bed"
    assert body["due_time"] == "09:30:00" and body["due_date"] == "2026-09-19"
    assert body["id"] and body["created_at"]


def test_create_task_minimal_payload_like_the_app_sends(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    r = client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Homework", "instructions": "", "recurrence": "none", "category": "Chore",
        "submission_kind": "none", "due_date": "2026-09-19"})
    assert r.status_code == 200, r.text


# ---- regression: category vs. the DB-constrained `bucket`, and
# submission_kind values the DB actually accepts. Caught only by running the
# real ALTER-TABLE migrations against a real Postgres with the original
# evlin-tables.sql CHECK constraints (see the manual verification in the fix
# commit) — SQLite has no CHECK enforcement, so this asserts the *values*
# the server computes/stores are the constraint-safe ones, not that a bad
# value would be rejected.

def test_bucket_is_derived_from_due_time_not_trusted_from_the_client(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    # A client that still sends a free-form "bucket" (the old, wrong usage —
    # e.g. a category label like "Chore") must not have it stored verbatim;
    # the DB only accepts morning/after_school/evening/anytime here.
    no_time = client.post(f"/children/{c.id}/tasks", headers=auth("pa"),
                           json={"title": "x", "bucket": "Chore"}).json()
    assert no_time["bucket"] == "anytime"
    morning = client.post(f"/children/{c.id}/tasks", headers=auth("pa"),
                           json={"title": "x", "due_time": "08:00:00"}).json()
    assert morning["bucket"] == "morning"
    after_school = client.post(f"/children/{c.id}/tasks", headers=auth("pa"),
                                json={"title": "x", "due_time": "15:00:00"}).json()
    assert after_school["bucket"] == "after_school"
    evening = client.post(f"/children/{c.id}/tasks", headers=auth("pa"),
                           json={"title": "x", "due_time": "20:00:00"}).json()
    assert evening["bucket"] == "evening"


def test_category_label_is_kept_separate_from_bucket(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    r = client.post(f"/children/{c.id}/tasks", headers=auth("pa"),
                     json={"title": "x", "category": "Study", "due_time": "16:00:00"}).json()
    assert r["category"] == "Study" and r["bucket"] == "after_school"
    up = client.put(f"/tasks/{r['id']}", headers=auth("pa"), json={"title": "x"}).json()
    assert up["category"] == "Study"  # untouched when the update omits it


def test_unrecognized_submission_kind_is_coerced_to_none(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    # "button" was the app's old (invalid) value, meaning "no evidence
    # required" — exactly what "none" already means in the DB's vocabulary.
    r = client.post(f"/children/{c.id}/tasks", headers=auth("pa"),
                     json={"title": "x", "submission_kind": "button"}).json()
    assert r["submission_kind"] == "none"
    photo = client.post(f"/children/{c.id}/tasks", headers=auth("pa"),
                         json={"title": "x", "submission_kind": "photo"}).json()
    assert photo["submission_kind"] == "photo"


def test_create_task_rejects_blank_title_and_bad_dates(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    assert client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={"title": "  "}).status_code == 422
    assert client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={"title": "x", "due_date": "nope"}).status_code == 400
    assert client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={"title": "x", "due_time": "9am"}).status_code == 400


def test_other_familys_child_is_404_for_every_task_route(client, db_session):
    a, b = make_parent(db_session, "pa"), make_parent(db_session, "pb")
    kid_a = make_child(db_session, a)
    task = client.post(f"/children/{kid_a.id}/tasks", headers=auth("pa"), json={"title": "x"}).json()
    hb = auth("pb")
    assert client.get(f"/children/{kid_a.id}/tasks", headers=hb).status_code == 404
    assert client.post(f"/children/{kid_a.id}/tasks", headers=hb, json={"title": "y"}).status_code == 404
    assert client.put(f"/tasks/{task['id']}", headers=hb, json={"title": "hack"}).status_code == 404
    assert client.delete(f"/tasks/{task['id']}", headers=hb).status_code == 404
    assert client.delete(f"/tasks/{task['id']}", headers=auth("pa")).status_code == 200


def test_missing_or_bad_token_is_rejected(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    assert client.get(f"/children/{c.id}/tasks").status_code in (401, 403)
    assert client.get(f"/children/{c.id}/tasks", headers=auth("nope")).status_code == 401


def test_update_keeps_schedule_when_not_sent(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    t = client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "x", "due_time": "08:00:00", "due_date": "2026-09-19"}).json()
    r = client.put(f"/tasks/{t['id']}", headers=auth("pa"), json={"title": "renamed"})
    assert r.status_code == 200
    assert r.json()["due_time"] == "08:00:00" and r.json()["due_date"] == "2026-09-19"


# ---- occurrences --------------------------------------------------------

def _tasks(client, child, *specs):
    for s in specs:
        assert client.post(f"/children/{child.id}/tasks", headers=auth("pa"), json=s).status_code == 200


def test_occurrences_follow_recurrence(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    _tasks(client, c,
           {"title": "once", "recurrence": "none", "due_date": "2026-09-19"},
           {"title": "daily", "recurrence": "daily", "due_date": "2026-09-14"},
           {"title": "mondays", "recurrence": "mon", "due_date": "2026-09-14"})
    def titles(day):
        occ = client.get(f"/children/{c.id}/occurrences?target_date={day}", headers=auth("pa")).json()
        ids = {o["task_id"] for o in occ}
        return sorted(t.title for t in db_session.query(models.Task).all() if str(t.id) in ids)
    assert titles("2026-09-19") == ["daily", "once"]
    assert titles("2026-09-21") == ["daily", "mondays"]
    assert titles("2026-09-13") == []


def test_occurrence_lookup_is_idempotent(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    _tasks(client, c, {"title": "d", "recurrence": "daily", "due_date": "2026-09-14"})
    for _ in range(3):
        client.get(f"/children/{c.id}/occurrences?target_date=2026-09-20", headers=auth("pa"))
    assert db_session.query(models.Occurrence).count() == 1


def test_occurrence_read_access(client, db_session):
    a, b = make_parent(db_session, "pa"), make_parent(db_session, "pb")
    kid, other = make_child(db_session, a), make_child(db_session, b)
    make_device(db_session, kid, "dev-kid")
    url = f"/children/{kid.id}/occurrences?target_date=2026-09-20"
    assert client.get(url).status_code in (401, 403)                      # anonymous
    assert client.get(url, headers=auth("dev-kid")).status_code == 200    # the child's own device
    assert client.get(url, headers=auth("pa")).status_code == 200         # their parent
    assert client.get(url, headers=auth("pb")).status_code == 404         # someone else's parent
    other_url = f"/children/{other.id}/occurrences?target_date=2026-09-20"
    assert client.get(other_url, headers=auth("dev-kid")).status_code == 404  # another child's device


def test_occurrence_with_due_time_serializes(client, db_session):
    # Regression: OccurrenceResponse.due_time was a bare Optional[str] with
    # no from-ORM conversion (unlike TaskResponse's own due_time/due_date,
    # which already had one) — any occurrence for a task with a real
    # due_time crashed FastAPI's response serialization into a 500. Dormant
    # until a task actually carried one, which is exactly what this covers.
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    _tasks(client, c, {"title": "timed", "recurrence": "none", "due_date": "2026-09-21", "due_time": "11:11:00"})
    r = client.get(f"/children/{c.id}/occurrences?target_date=2026-09-21", headers=auth("pa"))
    assert r.status_code == 200
    assert r.json()[0]["due_time"] == "11:11:00"


def _occurrence(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    make_device(db_session, c, "dev-kid")
    _tasks(client, c, {"title": "d", "recurrence": "daily", "due_date": "2026-09-14"})
    occ = client.get(f"/children/{c.id}/occurrences?target_date=2026-09-20", headers=auth("pa")).json()[0]
    return c, occ


def test_submit_then_approve_and_reject_flow(client, db_session):
    c, occ = _occurrence(client, db_session)
    r = client.post(f"/tasks/occurrences/{occ['id']}/submit", headers=auth("dev-kid"), json={"bypass_note": "done!"})
    assert r.status_code == 200 and r.json()["status"] == "submitted"
    assert client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa")).json()["status"] == "approved"
    assert client.post(f"/tasks/occurrences/{occ['id']}/reject", headers=auth("pa")).json()["status"] == "rejected"


def test_only_the_owning_device_can_submit_and_only_the_parent_can_review(client, db_session):
    c, occ = _occurrence(client, db_session)
    b = make_parent(db_session, "pb")
    other = make_child(db_session, b)
    make_device(db_session, other, "dev-other")
    assert client.post(f"/tasks/occurrences/{occ['id']}/submit", headers=auth("dev-other"), json={}).status_code == 404
    assert client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pb")).status_code == 404
    assert client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("dev-kid")).status_code == 401


def test_redo_note_reaches_the_kid_and_resubmitting_clears_it(client, db_session):
    c, occ = _occurrence(client, db_session)
    client.post(f"/tasks/occurrences/{occ['id']}/submit", headers=auth("dev-kid"), json={})
    r = client.put(f"/occurrences/{occ['id']}/status", headers=auth("pa"),
                   json={"status": "rejected", "rejection_note": "photo is blurry"})
    assert r.status_code == 200 and r.json()["status"] == "rejected"
    kid_view = client.get(f"/children/{c.id}/occurrences?target_date=2026-09-20", headers=auth("dev-kid")).json()[0]
    assert kid_view["rejection_note"] == "photo is blurry"
    again = client.post(f"/tasks/occurrences/{occ['id']}/submit", headers=auth("dev-kid"), json={}).json()
    assert again["status"] == "submitted" and again["rejection_note"] is None


def test_course_is_an_accepted_submission_kind(client, db_session):
    # A "special task" is completed by finishing an assigned course rather
    # than by photo/voice evidence. Both the server's own vocabulary and the
    # DB CHECK constraint (see the migration) have to accept it — without
    # the former it was silently coerced to "none", losing the course with
    # no error anywhere.
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    r = client.post(f"/children/{c.id}/tasks", headers=auth("pa"),
                     json={"title": "Watch the water cycle course", "submission_kind": "course"}).json()
    assert r["submission_kind"] == "course"


def test_both_review_routes_award_the_task_bonus(client, db_session):
    # Approving through PUT /status used to skip _review entirely, so the
    # bonus (and every later approval side effect) fired or didn't purely
    # based on which endpoint the client happened to call.
    c, occ = _occurrence(client, db_session)
    task_id = client.get(f"/children/{c.id}/tasks", headers=auth("pa")).json()[0]["id"]
    client.put(f"/tasks/{task_id}", headers=auth("pa"),
               json={"title": "d", "recurrence": "daily", "bonus_minutes": 15})

    r = client.put(f"/occurrences/{occ['id']}/status", headers=auth("pa"), json={"status": "approved"})
    assert r.status_code == 200 and r.json()["status"] == "approved"

    grants = client.get(f"/children/{c.id}/time-grants", headers=auth("pa")).json()
    assert grants["granted_minutes"] == 15
    assert [g["source"] for g in grants["grants"]] == ["task_bonus"]


def test_rejecting_a_bypass_returns_the_task_to_pending_on_both_routes(client, db_session):
    # evlin-tables.sql documents this as the intended resolution ("the child
    # still owes the original task"), but only the PUT route implemented it
    # before the two review paths were unified.
    c, occ = _occurrence(client, db_session)
    client.post(f"/occurrences/{occ['id']}/bypass", headers=auth("dev-kid"), json={"bypass_note": "sick"})
    r = client.post(f"/tasks/occurrences/{occ['id']}/reject", headers=auth("pa")).json()
    assert r["status"] == "pending" and r["bypass_requested"] is False


def test_kid_bypass_request_is_visible_and_approval_keeps_the_flag(client, db_session):
    c, occ = _occurrence(client, db_session)
    r = client.post(f"/occurrences/{occ['id']}/bypass", headers=auth("dev-kid"), json={"bypass_note": "sick today"})
    assert r.status_code == 200 and r.json()["bypass_requested"] is True
    seen = client.get(f"/children/{c.id}/occurrences?target_date=2026-09-20", headers=auth("pa")).json()[0]
    assert seen["bypass_requested"] and seen["bypass_note"] == "sick today"
    ok = client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa")).json()
    assert ok["status"] == "approved" and ok["bypass_requested"] is True   # app shows it as "bypassed"


# ---- icon: reserved for a future kid-side per-task icon picker ----------

def test_icon_is_stored_and_returned_but_optional(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    without = client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={"title": "x"}).json()
    assert without["icon"] is None
    with_icon = client.post(f"/children/{c.id}/tasks", headers=auth("pa"),
                             json={"title": "y", "icon": "pawprint.fill"}).json()
    assert with_icon["icon"] == "pawprint.fill"


def test_icon_update_is_partial_like_category(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    t = client.post(f"/children/{c.id}/tasks", headers=auth("pa"),
                     json={"title": "x", "icon": "star.fill"}).json()
    renamed = client.put(f"/tasks/{t['id']}", headers=auth("pa"), json={"title": "renamed"}).json()
    assert renamed["icon"] == "star.fill"  # untouched when the update omits it
    changed = client.put(f"/tasks/{t['id']}", headers=auth("pa"),
                          json={"title": "renamed", "icon": "moon.fill"}).json()
    assert changed["icon"] == "moon.fill"
