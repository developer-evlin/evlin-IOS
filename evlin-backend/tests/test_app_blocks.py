"""Blocking an app for a while, or until a task is done."""
from datetime import date

from tests.conftest import auth, make_child, make_device, make_parent


def _setup(db_session):
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    make_device(db_session, c, "dev-kid")
    return p, c


def _task(client, child, title="Homework"):
    return client.post(f"/children/{child.id}/tasks", headers=auth("pa"),
                       json={"title": title, "recurrence": "daily"}).json()


def _todays_occurrence(client, child, task_id):
    occs = client.get(f"/children/{child.id}/occurrences?target_date={date.today()}",
                      headers=auth("pa")).json()
    return [o for o in occs if o["task_id"] == task_id][0]


def test_until_task_block_resolves_itself_when_that_task_is_approved(client, db_session):
    p, c = _setup(db_session)
    task = _task(client, c)
    block = client.post(f"/children/{c.id}/app-blocks", headers=auth("pa"), json={
        "app_name": "YouTube", "app_bundle_id": "com.google.ios.youtube",
        "block_type": "until_task", "until_task_id": task["id"]}).json()
    assert block["resolved"] is False

    # The kid's device sees it as active until the homework is approved.
    assert len(client.get(f"/children/{c.id}/app-blocks", headers=auth("dev-kid")).json()) == 1

    occ = _todays_occurrence(client, c, task["id"])
    client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa"))

    assert client.get(f"/children/{c.id}/app-blocks", headers=auth("dev-kid")).json() == []
    all_blocks = client.get(f"/children/{c.id}/app-blocks?active=false", headers=auth("pa")).json()
    assert all_blocks[0]["resolved"] is True and all_blocks[0]["resolved_at"]


def test_a_different_tasks_approval_leaves_the_block_alone(client, db_session):
    p, c = _setup(db_session)
    gate = _task(client, c, title="Homework")
    other = _task(client, c, title="Dishes")
    client.post(f"/children/{c.id}/app-blocks", headers=auth("pa"), json={
        "app_name": "YouTube", "block_type": "until_task", "until_task_id": gate["id"]})

    occ = _todays_occurrence(client, c, other["id"])
    client.post(f"/tasks/occurrences/{occ['id']}/approve", headers=auth("pa"))

    assert len(client.get(f"/children/{c.id}/app-blocks", headers=auth("pa")).json()) == 1


def test_rejecting_the_task_does_not_lift_the_block(client, db_session):
    p, c = _setup(db_session)
    task = _task(client, c)
    client.post(f"/children/{c.id}/app-blocks", headers=auth("pa"), json={
        "app_name": "YouTube", "block_type": "until_task", "until_task_id": task["id"]})

    occ = _todays_occurrence(client, c, task["id"])
    client.post(f"/tasks/occurrences/{occ['id']}/submit", headers=auth("dev-kid"), json={})
    client.post(f"/tasks/occurrences/{occ['id']}/reject", headers=auth("pa"))

    assert len(client.get(f"/children/{c.id}/app-blocks", headers=auth("pa")).json()) == 1


def test_block_resolution_works_through_the_put_status_route_too(client, db_session):
    p, c = _setup(db_session)
    task = _task(client, c)
    client.post(f"/children/{c.id}/app-blocks", headers=auth("pa"), json={
        "app_name": "YouTube", "block_type": "until_task", "until_task_id": task["id"]})
    occ = _todays_occurrence(client, c, task["id"])
    client.put(f"/occurrences/{occ['id']}/status", headers=auth("pa"), json={"status": "approved"})
    assert client.get(f"/children/{c.id}/app-blocks", headers=auth("pa")).json() == []


def test_duration_block_needs_a_duration_and_task_block_needs_a_task(client, db_session):
    p, c = _setup(db_session)
    assert client.post(f"/children/{c.id}/app-blocks", headers=auth("pa"), json={
        "app_name": "TikTok", "block_type": "duration"}).status_code == 422
    assert client.post(f"/children/{c.id}/app-blocks", headers=auth("pa"), json={
        "app_name": "TikTok", "block_type": "until_task"}).status_code == 422
    assert client.post(f"/children/{c.id}/app-blocks", headers=auth("pa"), json={
        "app_name": "TikTok", "block_type": "forever"}).status_code == 422


def test_cannot_gate_a_block_on_another_childs_task(client, db_session):
    p, c = _setup(db_session)
    sibling = make_child(db_session, p, name="Sib")
    their_task = client.post(f"/children/{sibling.id}/tasks", headers=auth("pa"),
                             json={"title": "Not yours", "recurrence": "daily"}).json()
    r = client.post(f"/children/{c.id}/app-blocks", headers=auth("pa"), json={
        "app_name": "YouTube", "block_type": "until_task", "until_task_id": their_task["id"]})
    assert r.status_code == 400


def test_a_parent_can_lift_a_block_early(client, db_session):
    p, c = _setup(db_session)
    block = client.post(f"/children/{c.id}/app-blocks", headers=auth("pa"), json={
        "app_name": "TikTok", "block_type": "duration", "duration_minutes": 120}).json()
    assert client.delete(f"/app-blocks/{block['id']}", headers=auth("pa")).status_code == 200
    assert client.get(f"/children/{c.id}/app-blocks", headers=auth("pa")).json() == []


def test_app_block_access_control(client, db_session):
    p, c = _setup(db_session)
    make_parent(db_session, "pb")
    block = client.post(f"/children/{c.id}/app-blocks", headers=auth("pa"), json={
        "app_name": "TikTok", "block_type": "duration", "duration_minutes": 60}).json()
    assert client.get(f"/children/{c.id}/app-blocks", headers=auth("pb")).status_code == 404
    assert client.delete(f"/app-blocks/{block['id']}", headers=auth("pb")).status_code == 404
    # The kid can see they're blocked; they can't unblock themselves.
    assert client.get(f"/children/{c.id}/app-blocks", headers=auth("dev-kid")).status_code == 200
    assert client.delete(f"/app-blocks/{block['id']}", headers=auth("dev-kid")).status_code == 401
