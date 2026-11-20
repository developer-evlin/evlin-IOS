"""One day of a repeating task, or the rest of it, deleted or edited on its
own (routers/tasks.py cut and split), and the repeat rule that reads it
(routers/occurrences.py task_applies_on). The phones' CalendarSync.RepeatRule
must agree day for day (EvlinTests/RepeatAddedDayTests)."""
import uuid
from datetime import date, datetime, timezone

import models
from routers.occurrences import task_applies_on
from tests.conftest import auth, make_child, make_device, make_parent

# 2026-11-17 is a Tuesday; 11-20 a Friday.
TUE, WED, FRI, NEXT_TUE, NEXT_FRI = (date(2026, 11, 17), date(2026, 11, 18), date(2026, 11, 20),
                                     date(2026, 11, 24), date(2026, 11, 27))


def T(rec, due=None, skipped=None, until=None):
    return models.Task(recurrence=rec, due_date=due, skipped_dates=skipped, repeat_until=until,
                       created_at=datetime(2026, 11, 1, tzinfo=timezone.utc))


# ---- the repeat rule ----------------------------------------------------

def test_a_repeating_task_falls_on_the_day_it_was_added_for():
    t = T("fri", due=TUE)
    assert task_applies_on(t, TUE)          # the day it was added
    assert not task_applies_on(t, WED)
    assert task_applies_on(t, FRI)          # this Friday
    assert task_applies_on(t, NEXT_FRI)     # every Friday after
    assert not task_applies_on(t, NEXT_TUE)  # not the Tuesdays after
    assert not task_applies_on(t, date(2026, 11, 13))  # nor a Friday before


def test_a_one_off_is_unchanged():
    t = T("none", due=TUE)
    assert task_applies_on(t, TUE) and not task_applies_on(t, FRI)


def test_a_skipped_day_and_the_last_day():
    t = T("daily", due=TUE, skipped=["2026-11-18"], until=FRI)
    assert task_applies_on(t, TUE)
    assert not task_applies_on(t, WED)      # taken out
    assert task_applies_on(t, FRI)          # its last day
    assert not task_applies_on(t, date(2026, 11, 21))


def test_skipping_the_day_it_was_added_for_wins():
    assert not task_applies_on(T("fri", due=TUE, skipped=["2026-11-17"]), TUE)


# ---- helpers ------------------------------------------------------------

def _family(client, db_session, recurrence="daily", start=TUE):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    make_device(db_session, c, "dev-kid")
    task = client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Water the plants", "recurrence": recurrence, "due_date": start.isoformat()}).json()
    return c, task


def _occ(client, c, day, who="pa"):
    rows = client.get(f"/children/{c.id}/occurrences", headers=auth(who),
                      params={"target_date": day.isoformat()}).json()
    return rows


def _status(client, occ_id, status):
    if status in ("submitted", "approved"):
        client.post(f"/tasks/occurrences/{occ_id}/submit", headers=auth("dev-kid"), json={})
    if status == "approved":
        client.post(f"/tasks/occurrences/{occ_id}/approve", headers=auth("pa"))


# ---- delete: cut --------------------------------------------------------

def test_deleting_one_day_takes_it_off_whatever_was_done_on_it(client, db_session):
    c, task = _family(client, db_session)
    wed = _occ(client, c, WED)[0]
    _status(client, wed["id"], "approved")
    r = client.post(f"/tasks/{task['id']}/cut", headers=auth("pa"), json={"from": "2026-11-18", "through": "2026-11-18"})
    assert r.status_code == 200, r.text
    assert r.json()["skipped_dates"] == ["2026-11-18"] and r.json()["repeat_until"] is None
    # Gone for both phones, and not made again on the next read.
    assert _occ(client, c, WED) == [] and _occ(client, c, WED, who="dev-kid") == []
    assert len(_occ(client, c, FRI)) == 1


def test_deleting_from_a_day_on_ends_the_series_the_day_before(client, db_session):
    c, task = _family(client, db_session)
    for d in (WED, FRI):
        _occ(client, c, d)
    client.post(f"/tasks/{task['id']}/cut", headers=auth("pa"), json={"from": "2026-11-18", "through": "2026-11-18"})
    r = client.post(f"/tasks/{task['id']}/cut", headers=auth("pa"), json={"from": "2026-11-20"})
    body = r.json()
    assert body["repeat_until"] == "2026-11-19"
    assert body["skipped_dates"] == ["2026-11-18"]  # a skip before the end stays
    assert _occ(client, c, FRI) == [] and _occ(client, c, NEXT_FRI) == []
    assert len(_occ(client, c, TUE)) == 1
    # Sent twice (the outbox retries): the same answer.
    again = client.post(f"/tasks/{task['id']}/cut", headers=auth("pa"), json={"from": "2026-11-20"}).json()
    assert again["repeat_until"] == "2026-11-19"


def test_a_cut_only_takes_one_day_or_from_a_day_on(client, db_session):
    c, task = _family(client, db_session)
    r = client.post(f"/tasks/{task['id']}/cut", headers=auth("pa"), json={"from": "2026-11-18", "through": "2026-11-20"})
    assert r.status_code == 400


def test_only_the_childs_parent_can_cut_or_split(client, db_session):
    c, task = _family(client, db_session)
    make_parent(db_session, "pb")
    assert client.post(f"/tasks/{task['id']}/cut", headers=auth("pb"), json={"from": "2026-11-18"}).status_code == 404
    assert client.post(f"/tasks/{task['id']}/cut", headers=auth("dev-kid"), json={"from": "2026-11-18"}).status_code == 401
    split = {"from": "2026-11-18", "task": {"id": str(uuid.uuid4()), "title": "x", "recurrence": "daily"}}
    assert client.post(f"/tasks/{task['id']}/split", headers=auth("pb"), json=split).status_code == 404


# ---- edit: split --------------------------------------------------------

def test_editing_one_day_moves_it_to_a_task_of_its_own_with_what_was_done(client, db_session):
    c, task = _family(client, db_session)
    wed = _occ(client, c, WED)[0]
    _status(client, wed["id"], "submitted")
    new_id = str(uuid.uuid4())
    r = client.post(f"/tasks/{task['id']}/split", headers=auth("pa"), json={
        "from": "2026-11-18", "through": "2026-11-18",
        "task": {"id": new_id, "title": "Water the garden", "recurrence": "none", "due_date": "2026-11-18"}})
    assert r.status_code == 200, r.text
    assert r.json()["id"] == new_id and r.json()["title"] == "Water the garden"
    rows = _occ(client, c, WED, who="dev-kid")
    # One row that day: the kid's sent-in work, now under the edited task.
    assert [(o["task_id"], o["status"]) for o in rows] == [(new_id, "submitted")]
    old = db_session.get(models.Task, uuid.UUID(task["id"]))
    db_session.refresh(old)
    assert old.skipped_dates == ["2026-11-18"]
    # The series keeps the other days.
    assert [o["task_id"] for o in _occ(client, c, FRI)] == [task["id"]]


def test_editing_from_a_day_on_hands_over_the_rest(client, db_session):
    c, task = _family(client, db_session)
    tue = _occ(client, c, TUE)[0]
    _status(client, tue["id"], "approved")
    fri = _occ(client, c, FRI)[0]
    _status(client, fri["id"], "approved")
    new_id = str(uuid.uuid4())
    # A row for the new task already made on Friday (a read between the
    # phone's writes): the old one's, with its approval, wins.
    split = {"from": "2026-11-20", "task": {"id": new_id, "title": "Water the plants", "recurrence": "fri",
                                            "due_date": "2026-11-20"}}
    r = client.post(f"/tasks/{task['id']}/split", headers=auth("pa"), json=split)
    assert r.status_code == 200, r.text
    assert [(o["task_id"], o["status"]) for o in _occ(client, c, FRI)] == [(new_id, "approved")]
    assert [o["task_id"] for o in _occ(client, c, TUE)] == [task["id"]]   # earlier days stay
    assert _occ(client, c, date(2026, 11, 21)) == []                       # new repeat: Fridays only
    assert [o["task_id"] for o in _occ(client, c, NEXT_FRI)] == [new_id]
    # Sent twice: nothing made twice, nothing moved back.
    again = client.post(f"/tasks/{task['id']}/split", headers=auth("pa"), json=split)
    assert again.status_code == 200
    assert db_session.query(models.Task).filter_by(child_id=c.id).count() == 2
    assert [(o["task_id"], o["status"]) for o in _occ(client, c, FRI)] == [(new_id, "approved")]


def test_the_phones_list_of_tasks_carries_the_exceptions(client, db_session):
    c, task = _family(client, db_session)
    client.post(f"/tasks/{task['id']}/cut", headers=auth("pa"), json={"from": "2026-11-18", "through": "2026-11-18"})
    client.post(f"/tasks/{task['id']}/cut", headers=auth("pa"), json={"from": "2026-11-27"})
    listed = client.get(f"/children/{c.id}/tasks", headers=auth("dev-kid")).json()[0]
    assert listed["skipped_dates"] == ["2026-11-18"] and listed["repeat_until"] == "2026-11-26"
