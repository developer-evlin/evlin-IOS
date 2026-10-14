"""Live updates: who hears about a change, and what the stream sends.

The broker is swapped for a recorder in the routing tests, so those check
the commit hook's decisions without any streaming. The stream tests drive
the generator directly — TestClient buffers a response body until it ends,
and this one never ends.
"""
import asyncio
import threading
from datetime import date, datetime, timezone

import pytest

import live_updates
import models
from live_updates import broker, child_topic, parent_topic
from tests.conftest import auth, make_child, make_device, make_parent

READY = "event: ready\ndata: {}\n\n"
CHANGED = "event: changed\ndata: {}\n\n"
PING = ": ping\n\n"


@pytest.fixture()
def family(db_session):
    p = make_parent(db_session, "pa")
    return p, make_child(db_session, p)


@pytest.fixture()
def announced(family, monkeypatch):
    """Every set of topics the commit hook publishes, from here on."""
    calls: list[set] = []
    monkeypatch.setattr(broker, "publish", lambda topics: calls.append(set(topics)))
    return calls


def _heard(calls):
    return set().union(*calls) if calls else set()


def _task(db, child, title="Homework"):
    t = models.Task(child_id=child.id, title=title)
    db.add(t)
    db.commit()
    return t


# ---- who is told ---------------------------------------------------------

def test_a_write_tells_the_child_and_every_parent_of_that_child(db_session, family, announced):
    p, c = family
    co = make_parent(db_session, "co")
    db_session.add(models.ParentChild(parent_id=co.id, child_id=c.id, role="co"))
    db_session.commit()
    announced.clear()

    _task(db_session, c)

    assert announced == [{child_topic(c.id), parent_topic(p.id), parent_topic(co.id)}]


def test_other_families_hear_nothing(db_session, family, announced):
    _, c = family
    other = make_parent(db_session, "pb")
    their_child = make_child(db_session, other)
    announced.clear()

    _task(db_session, c)

    assert child_topic(their_child.id) not in _heard(announced)
    assert parent_topic(other.id) not in _heard(announced)


def test_a_rolled_back_write_tells_no_one(db_session, family, announced):
    _, c = family
    announced.clear()

    db_session.add(models.Task(child_id=c.id, title="Never saved"))
    db_session.flush()
    db_session.rollback()
    # The next commit, even an empty one, mustn't carry the rolled-back
    # write's topics along with it.
    db_session.commit()

    assert announced == []


def test_chat_and_memory_writes_wake_no_one(db_session, family, announced):
    # Shown by the request that wrote them, never on the other device.
    p, c = family
    announced.clear()

    conv = models.ChatConversation(child_id=c.id, parent_id=p.id, title="Bedtime")
    db_session.add(conv)
    db_session.flush()
    db_session.add(models.ChatMessage(child_id=c.id, conversation_id=conv.id, role="user", text="hi"))
    db_session.add(models.ChildMemory(child_id=c.id, fact="Plays football on Tuesdays"))
    db_session.commit()

    assert announced == []


def test_a_submission_is_traced_to_its_child_through_the_occurrence(db_session, family, announced):
    # Submission has no child_id of its own.
    _, c = family
    t = _task(db_session, c)
    occ = models.Occurrence(task_id=t.id, child_id=c.id, due_date=date.today(), gates_apps=True)
    db_session.add(occ)
    db_session.commit()
    announced.clear()

    db_session.add(models.Submission(occurrence_id=occ.id, kind="photo", r2_key="k", content_type="image/jpeg"))
    db_session.commit()

    assert child_topic(c.id) in _heard(announced)


def test_an_event_is_announced_to_its_childs_family(db_session, family, announced):
    # Every event belongs to a child, so its family is always known.
    p, c = family
    announced.clear()
    now = datetime.now(timezone.utc)

    db_session.add(models.Event(child_id=c.id, title="Swim", start_at=now, end_at=now))
    db_session.commit()

    assert child_topic(c.id) in _heard(announced)
    assert parent_topic(p.id) in _heard(announced)


def test_a_parent_hears_about_a_child_joining_their_family(db_session, family, announced):
    p, _ = family
    newcomer = models.Child(name="New", birth_year=2016, color_index=1, avatar_url="")
    db_session.add(newcomer)
    db_session.commit()
    announced.clear()

    db_session.add(models.ParentChild(parent_id=p.id, child_id=newcomer.id, role="primary"))
    db_session.commit()

    assert parent_topic(p.id) in _heard(announced)


def test_a_parent_hears_about_a_child_leaving_their_family(db_session, family, announced):
    # The link is already gone by the time anyone could look it up, so the
    # parent has to be named from the deleted row itself.
    p, c = family
    link = db_session.query(models.ParentChild).filter_by(parent_id=p.id, child_id=c.id).one()
    announced.clear()

    db_session.delete(link)
    db_session.commit()

    assert parent_topic(p.id) in _heard(announced)


def test_a_sync_that_changes_nothing_announces_nothing(client, db_session, family, announced):
    # Reads that create-if-missing (today's occurrences, default rules) do
    # write, once. If a read ever wrote every time — a last_seen stamp, say —
    # each sync would announce a change, and that announcement would cause
    # the next sync: a device refreshing itself in a loop.
    _, c = family
    cid = c.id
    make_device(db_session, c, "kid")
    client.post(f"/children/{cid}/tasks", headers=auth("pa"), json={"title": "Read", "recurrence": "daily"})

    def sync():
        for path in (f"/children/{cid}/occurrences?target_date={date.today()}",
                     f"/children/{cid}/rules", f"/children/{cid}/state", f"/children/{cid}/tasks"):
            client.get(path, headers=auth("kid"))

    sync()  # the first read of the day may materialize today's occurrence
    announced.clear()
    sync()

    assert announced == []


# ---- the endpoint --------------------------------------------------------

def test_the_stream_is_scoped_to_whoever_opens_it(client, db_session, family, monkeypatch):
    p, c = family
    pid, cid = p.id, c.id
    make_device(db_session, c, "kid")
    opened = []

    async def one_message(request, topic, heartbeat=None):
        opened.append(topic)
        yield READY

    monkeypatch.setattr(live_updates, "stream", one_message)

    r = client.get("/live", headers=auth("pa"))
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/event-stream")
    assert r.text == READY
    client.get("/live", headers=auth("kid"))

    assert opened == [parent_topic(pid), child_topic(cid)]


def test_the_stream_needs_a_real_caller(client, db_session, family):
    assert client.get("/live").status_code in (401, 403)
    assert client.get("/live", headers=auth("nobody")).status_code == 401


# ---- the stream ----------------------------------------------------------

class _Request:
    def __init__(self):
        self.gone = False

    async def is_disconnected(self):
        return self.gone


def test_ready_comes_first_then_one_changed_per_burst():
    async def run():
        gen = live_updates.stream(_Request(), "child:a", heartbeat=0.05)
        assert await gen.__anext__() == READY

        broker.publish({"child:a"})
        broker.publish({"child:a"})
        broker.publish({"child:someone-else"})
        await asyncio.sleep(0)  # let the queued wake-ups land

        assert await gen.__anext__() == CHANGED
        # The second publish was folded into that one rather than queued
        # behind it, and the third was for someone else: all that's left is
        # the idle heartbeat.
        assert await gen.__anext__() == PING
        await gen.aclose()

    asyncio.run(run())
    assert broker.subscriber_count() == 0


def test_a_commit_on_another_thread_wakes_the_stream():
    # Sync routes commit on FastAPI's threadpool, not the stream's loop.
    async def run():
        gen = live_updates.stream(_Request(), "child:b", heartbeat=5)
        await gen.__anext__()
        threading.Thread(target=lambda: broker.publish({"child:b"})).start()
        assert await asyncio.wait_for(gen.__anext__(), timeout=2) == CHANGED
        await gen.aclose()

    asyncio.run(run())


def test_an_idle_stream_pings_and_ends_when_the_client_leaves():
    async def run():
        request = _Request()
        gen = live_updates.stream(request, "child:c", heartbeat=0.01)
        await gen.__anext__()
        assert await gen.__anext__() == PING

        request.gone = True
        with pytest.raises(StopAsyncIteration):
            await gen.__anext__()

    asyncio.run(run())
    assert broker.subscriber_count() == 0
