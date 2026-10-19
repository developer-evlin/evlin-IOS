import uuid
import pytest
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


def test_course_is_no_longer_a_submission_kind(client, db_session):
    # Courses were removed, and the DB constraint no longer allows 'course'.
    # An older app build that still sends it gets an ordinary task instead
    # of a 400 on the constraint.
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    r = client.post(f"/children/{c.id}/tasks", headers=auth("pa"),
                     json={"title": "Watch the water cycle course", "submission_kind": "course"}).json()
    assert r["submission_kind"] == "none"


@pytest.mark.parametrize("sent,stored", [("either", "none"), ("voice", "none"), ("photo", "photo"), ("none", "none")])
def test_only_photo_or_no_proof_is_stored(client, db_session, sent, stored):
    # Voice notes were removed: anything but "photo" is a task with no
    # evidence, coerced rather than refused like any unknown value.
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    r = client.post(f"/children/{c.id}/tasks", headers=auth("pa"),
                    json={"title": "Tidy room", "submission_kind": sent}).json()
    assert r["submission_kind"] == stored


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
                             json={"title": "y", "icon": "🐾"}).json()
    assert with_icon["icon"] == "🐾"


def test_icon_update_is_partial_like_category(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    t = client.post(f"/children/{c.id}/tasks", headers=auth("pa"),
                     json={"title": "x", "icon": "⭐"}).json()
    renamed = client.put(f"/tasks/{t['id']}", headers=auth("pa"), json={"title": "renamed"}).json()
    assert renamed["icon"] == "⭐"  # untouched when the update omits it
    changed = client.put(f"/tasks/{t['id']}", headers=auth("pa"),
                          json={"title": "renamed", "icon": "🌙"}).json()
    assert changed["icon"] == "🌙"


def test_update_clears_due_time_only_when_sent_as_null(client, db_session):
    # The app's edit form removes a deadline by sending due_time: null;
    # leaving the field out keeps the time as it was.
    p = make_parent(db_session, "pa")
    kid = make_child(db_session, p)
    t = client.post(f"/children/{kid.id}/tasks", headers=auth("pa"), json={"title": "x", "due_time": "18:00:00"}).json()
    base = {"title": "x", "instructions": "", "recurrence": "none", "category": "Task", "submission_kind": "none"}
    assert client.put(f"/tasks/{t['id']}", headers=auth("pa"), json=base).json()["due_time"] is not None
    r = client.put(f"/tasks/{t['id']}", headers=auth("pa"), json={**base, "due_time": None})
    assert r.status_code == 200 and r.json()["due_time"] is None


def test_a_retried_create_with_the_phones_id_saves_once(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    other = make_child(db_session, p)
    body = {"id": "6f1f6c1e-6b1a-4a43-9a51-0d3f3b1c2a10", "title": "Read", "recurrence": "daily"}
    first = client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json=body)
    again = client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={**body, "title": "Changed"})
    assert first.status_code == again.status_code == 200, again.text
    assert first.json()["id"] == again.json()["id"] == body["id"]
    assert again.json()["title"] == "Read"
    assert db_session.query(models.Task).filter(models.Task.child_id == c.id).count() == 1
    # The same id can't be claimed for another child.
    assert client.post(f"/children/{other.id}/tasks", headers=auth("pa"), json=body).status_code == 409


def test_a_new_task_for_today_locks_the_phone_again(client, db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    r = client.put(f"/children/{c.id}/state", headers=auth("pa"),
                   json={"manual_lock": False, "task_gate_override": True})
    assert r.status_code == 200, r.text
    # One for another day leaves the phone open.
    client.post(f"/children/{c.id}/tasks", headers=auth("pa"),
                json={"title": "Later", "recurrence": "none", "due_date": "2099-01-01"})
    assert client.get(f"/children/{c.id}/state", headers=auth("pa")).json()["task_gate_override"] is True
    # One for today closes it.
    client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={"title": "Now", "recurrence": "daily"})
    assert client.get(f"/children/{c.id}/state", headers=auth("pa")).json()["task_gate_override"] is False



def test_a_task_gets_one_occurrence_per_day_even_when_two_requests_race(db_session, monkeypatch):
    """The occurrences list and the policy, fetched together in one sync,
    both make today's occurrences. When the other request inserts between
    this one's check and insert, the unique index refuses the second and it
    is skipped: one occurrence, the other request's, not two."""
    from sqlalchemy.exc import IntegrityError
    import routers.occurrences as occ

    parent = make_parent(db_session, "race")
    child = make_child(db_session, parent)
    task = models.Task(child_id=child.id, title="Read", recurrence="daily", gates_apps=True,
                       submission_kind="none", bucket="anytime", active=True)
    db_session.add(task)
    db_session.commit()
    today = date.today()

    # A second row for the same task and day is refused outright.
    db_session.add(models.Occurrence(task_id=task.id, child_id=child.id, due_date=today,
                                     status="approved", gates_apps=True))
    db_session.commit()
    db_session.add(models.Occurrence(task_id=task.id, child_id=child.id, due_date=today,
                                     status="pending", gates_apps=True))
    with pytest.raises(IntegrityError):
        db_session.commit()
    db_session.rollback()

    # The race: this request's check saw nothing (the other's row landed
    # just after it), so it tries to insert, and must carry on.
    real_query = db_session.query
    def query_that_misses_the_other_row(*args, **kw):
        q = real_query(*args, **kw)
        if args and args[0] is models.Occurrence:
            class Missed:
                def filter(self, *a, **k): return self
                def first(self): return None
            return Missed()
        return q
    monkeypatch.setattr(db_session, "query", query_that_misses_the_other_row)
    occ._generate_occurrences_for_date(child.id, today, db_session)
    monkeypatch.undo()

    rows = db_session.query(models.Occurrence).filter_by(task_id=task.id, due_date=today).all()
    assert [r.status for r in rows] == ["approved"]


def test_taking_back_an_approval_of_a_task_never_sent_in_puts_it_back_to_do(client, db_session):
    """The parent ticked a to-do done themselves, then changed their mind:
    the task is plain "to do" again, with no redo note for the kid to read
    as "sent back", and the bonus that approval paid is taken back."""
    c, occ = _occurrence(client, db_session)
    task_id = client.get(f"/children/{c.id}/tasks", headers=auth("pa")).json()[0]["id"]
    client.put(f"/tasks/{task_id}", headers=auth("pa"),
               json={"title": "d", "recurrence": "daily", "bonus_minutes": 15})

    assert client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa")).json()["status"] == "approved"
    r = client.put(f"/occurrences/{occ['id']}/status", headers=auth("pa"),
                   json={"status": "rejected", "rejection_note": ""}).json()
    assert r["status"] == "pending" and r["rejection_note"] is None and r["approved_at"] is None

    kid_view = client.get(f"/children/{c.id}/occurrences?target_date=2026-09-20", headers=auth("dev-kid")).json()[0]
    assert kid_view["status"] == "pending" and kid_view["rejection_note"] is None
    assert client.get(f"/children/{c.id}/time-grants", headers=auth("pa")).json()["granted_minutes"] == 0

    # Approving again pays the bonus again, once.
    client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa"))
    assert client.get(f"/children/{c.id}/time-grants", headers=auth("pa")).json()["granted_minutes"] == 15


def test_taking_back_an_approval_of_a_task_that_was_sent_in_is_a_redo(client, db_session):
    c, occ = _occurrence(client, db_session)
    client.post(f"/tasks/occurrences/{occ['id']}/submit", headers=auth("dev-kid"), json={})
    client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa"))
    r = client.put(f"/occurrences/{occ['id']}/status", headers=auth("pa"),
                   json={"status": "rejected", "rejection_note": "do it again"}).json()
    assert r["status"] == "rejected" and r["rejection_note"] == "do it again"


def test_unapproving_a_task_that_was_sent_in_puts_it_back_waiting_for_review(client, db_session):
    """Unticking an approved task the kid sent in: it's waiting for review
    again, as it was, with what they sent kept and no redo note."""
    c, occ = _occurrence(client, db_session)
    client.post(f"/tasks/occurrences/{occ['id']}/submit", headers=auth("dev-kid"), json={})
    db_session.add(models.Submission(occurrence_id=uuid.UUID(occ["id"]), kind="photo", r2_key="k/1.jpg", content_type="image/jpeg", status="uploaded"))
    db_session.commit()
    client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa"))

    r = client.post(f"/tasks/occurrences/{occ['id']}/unapprove", headers=auth("pa")).json()
    assert r["status"] == "submitted" and r["rejection_note"] is None and r["approved_at"] is None
    assert db_session.query(models.Submission).filter_by(occurrence_id=uuid.UUID(occ["id"])).count() == 1


def test_unapproving_a_task_never_sent_in_puts_it_back_to_do(client, db_session):
    c, occ = _occurrence(client, db_session)
    client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa"))
    assert client.post(f"/tasks/occurrences/{occ['id']}/unapprove", headers=auth("pa")).json()["status"] == "pending"
    # Not approved: unapproving changes nothing.
    assert client.post(f"/tasks/occurrences/{occ['id']}/unapprove", headers=auth("pa")).json()["status"] == "pending"


@pytest.mark.parametrize("icon,ok", [("🛏️", True), ("🪥", True), ("👨‍👩‍👧", True), ("", True),
                                      ("bed", False), ("🛏️ bed", False), ("12", False)])
def test_a_task_icon_is_one_emoji(client, db_session, icon, ok):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    r = client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={"title": "Make the bed", "icon": icon})
    assert (r.status_code == 200) == ok
    if ok:
        assert r.json()["icon"] == (icon or None)
