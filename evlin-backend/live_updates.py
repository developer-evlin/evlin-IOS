"""Live updates: tell a device the moment something it shows has changed.

Server-sent events, and deliberately content-free. A message says only
"something changed for you — sync"; the client already knows how to sync,
so this replaces *when* it does that, not *what* it fetches. Two things
follow from that:
- No family data ever goes over the stream, so a routing mistake leaks at
  most the fact that something happened, never what.
- There is no second read path to keep consistent with the REST API.

Routes don't publish. A commit hook looks at what the transaction actually
wrote and works out whose data it was, so a new route can't forget to
notify anyone — the same reason every approval goes through one _review.
Only committed work is announced; a rolled-back write tells no one.

Single-process by design. The broker lives in memory, which is correct for
the one uvicorn process Render runs. A second instance would each see only
its own commits; the fix then is Postgres LISTEN/NOTIFY behind the same
publish()/subscribe(), with no change to routes or clients.
"""
import asyncio
import threading
from uuid import UUID

from sqlalchemy import event, select
from sqlalchemy.orm import Session

import models

# Idle proxies drop quiet connections, and a client can't tell a silent
# stream from a dead one. The iOS client reconnects after 45s of nothing,
# so this has to stay comfortably under that.
HEARTBEAT_SECONDS = 20

# Written by the request that shows them, and never displayed on the other
# device: chat is request/response, memory is internal. Announcing these
# would only wake every device for a sync that finds nothing new.
_SILENT = (models.ChatMessage, models.ChatConversation, models.ChildMemory, models.AuditLog)

_PENDING = "live_updates_topics"


def child_topic(child_id: UUID) -> str:
    return f"child:{child_id}"


def parent_topic(parent_id: UUID) -> str:
    return f"parent:{parent_id}"


class _Subscriber:
    def __init__(self, topic: str, loop: asyncio.AbstractEventLoop):
        self.topic = topic
        self.loop = loop
        self.queue: asyncio.Queue = asyncio.Queue()


class Broker:
    def __init__(self):
        self._lock = threading.Lock()
        self._by_topic: dict[str, set[_Subscriber]] = {}

    def subscribe(self, topic: str) -> _Subscriber:
        """Call from the stream's own event loop — it's where wake-ups land."""
        sub = _Subscriber(topic, asyncio.get_running_loop())
        with self._lock:
            self._by_topic.setdefault(topic, set()).add(sub)
        return sub

    def unsubscribe(self, sub: _Subscriber) -> None:
        with self._lock:
            subs = self._by_topic.get(sub.topic)
            if subs is not None:
                subs.discard(sub)
                if not subs:
                    del self._by_topic[sub.topic]

    def publish(self, topics: set[str]) -> None:
        """Safe from any thread. Sync routes commit from FastAPI's threadpool,
        not the loop the streams run on, so wake-ups are handed across with
        call_soon_threadsafe rather than touching a queue directly."""
        with self._lock:
            targets = {sub for topic in topics for sub in self._by_topic.get(topic, ())}
        for sub in targets:
            try:
                sub.loop.call_soon_threadsafe(sub.queue.put_nowait, None)
            except RuntimeError:
                pass  # that stream's loop is closed; it's already gone

    def subscriber_count(self) -> int:
        with self._lock:
            return sum(len(subs) for subs in self._by_topic.values())


broker = Broker()


# ---- deciding who to tell ------------------------------------------------

@event.listens_for(Session, "after_flush")
def _collect(session: Session, _flush_context) -> None:
    """Work out whose data this flush touched. Runs per flush; a transaction
    can flush several times, so topics accumulate until it commits."""
    child_ids: set = set()
    parent_ids: set = set()
    occurrence_ids: set = set()

    # session.dirty also holds objects that were assigned their current
    # value — no UPDATE is issued for those, and announcing them would turn
    # every idempotent write (a device re-sending its timezone) into a sync
    # that re-sends it again.
    dirty = [obj for obj in session.dirty if session.is_modified(obj, include_collections=False)]
    for obj in (*session.new, *dirty, *session.deleted):
        if isinstance(obj, _SILENT):
            continue
        if isinstance(obj, models.Child):
            child_ids.add(obj.id)
        elif isinstance(obj, models.Submission):
            occurrence_ids.add(obj.occurrence_id)
        elif getattr(obj, "child_id", None) is not None:
            child_ids.add(obj.child_id)

        if isinstance(obj, models.ParentChild):
            # Named directly rather than found by the lookup below: a link
            # being deleted is already gone from the table, and the parent
            # still needs to hear that a child left their family.
            parent_ids.add(obj.parent_id)

    with session.no_autoflush:
        if occurrence_ids:
            child_ids |= set(session.execute(
                select(models.Occurrence.child_id).where(models.Occurrence.id.in_(occurrence_ids))
            ).scalars())
        # Resolved now, not when the stream connected, so a child added to a
        # family after its parent's app opened the stream is still covered.
        if child_ids:
            parent_ids |= set(session.execute(
                select(models.ParentChild.parent_id).where(models.ParentChild.child_id.in_(child_ids))
            ).scalars())

    if child_ids or parent_ids:
        pending = session.info.setdefault(_PENDING, set())
        pending |= {child_topic(c) for c in child_ids}
        pending |= {parent_topic(p) for p in parent_ids}


@event.listens_for(Session, "after_commit")
def _announce(session: Session) -> None:
    topics = session.info.pop(_PENDING, None)
    if topics:
        broker.publish(topics)


@event.listens_for(Session, "after_rollback")
def _discard(session: Session) -> None:
    session.info.pop(_PENDING, None)


# ---- the stream ----------------------------------------------------------

async def stream(request, topic: str, heartbeat: float = HEARTBEAT_SECONDS):
    """One client's SSE body.

    "ready" is sent only after subscribing. A client that syncs on "ready"
    therefore can't miss a change committed between its sync and the
    subscription: anything earlier is in the sync, anything later arrives
    as "changed".
    """
    sub = broker.subscribe(topic)
    try:
        yield "event: ready\ndata: {}\n\n"
        while True:
            try:
                await asyncio.wait_for(sub.queue.get(), timeout=heartbeat)
            except asyncio.TimeoutError:
                if await request.is_disconnected():
                    return
                yield ": ping\n\n"
                continue
            # A burst of commits (one request often commits twice) is one
            # sync on the device, not several.
            while not sub.queue.empty():
                sub.queue.get_nowait()
            yield "event: changed\ndata: {}\n\n"
    finally:
        broker.unsubscribe(sub)
