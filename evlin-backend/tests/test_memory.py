"""What the assistant remembers between conversations.

Memory has no HTTP surface — it is read into the chat prompt and written
back from it, and that round trip is what these cover. Extraction is
stubbed at the gemini_client boundary; nothing here makes a real call. The
autouse fixture in conftest disables extraction by default, so these opt
back in explicitly.
"""
import asyncio
import uuid
from datetime import datetime, timedelta, timezone

import pytest

import memory as memory_router
import models
import routers.chat as chat_router
from gemini_client import FunctionCall
from tests.conftest import auth, fake_chat_model, make_child, make_parent


def _remembering(monkeypatch, facts):
    """Turn extraction on with a stubbed model that returns `facts`."""
    async def _extract(system_prompt, messages, tools=None):
        return None, FunctionCall(name="remember", args={"facts": facts})

    monkeypatch.setattr(memory_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(memory_router, "generate", _extract)


def _chatting(monkeypatch):
    async def _reply(system_prompt, messages, tools=None):
        return "Noted.", None

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _reply)


@pytest.fixture()
def family(db_session):
    p = make_parent(db_session, "pa")
    return p, make_child(db_session, p)


# ---- what reaches the model ---------------------------------------------

def test_remembered_facts_reach_the_system_prompt(client, db_session, family, monkeypatch):
    _, c = family
    db_session.add(models.ChildMemory(child_id=c.id, fact="Plays football on Tuesdays", category="routine"))
    db_session.commit()

    captured = {}

    async def _capture(system_prompt, messages, tools=None):
        captured["prompt"] = system_prompt
        return "ok", None

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _capture)
    client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "hi"})

    assert "Plays football on Tuesdays" in captured["prompt"]


def test_archived_facts_stop_reaching_the_model(client, db_session, family, monkeypatch):
    # archived_at is the kill switch for a bad fact: the row stays, so the
    # same conversation can't quietly re-extract it, but nothing it says
    # reaches the model again.
    _, c = family
    m = models.ChildMemory(child_id=c.id, fact="Plays football on Tuesdays", category="routine",
                           archived_at=datetime.now(timezone.utc))
    db_session.add(m)
    db_session.commit()

    captured = {}

    async def _capture(system_prompt, messages, tools=None):
        captured["prompt"] = system_prompt
        return "ok", None

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _capture)
    client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "hi"})

    assert "football" not in captured["prompt"].lower()


def test_the_prompt_carries_at_most_the_cap(db_session, family, monkeypatch):
    # Nothing prunes this table on a schedule, so the cap is the only thing
    # standing between a long-lived account and a system prompt that grows
    # forever. Newest win.
    _, c = family
    monkeypatch.setattr(memory_router, "MAX_FACTS_IN_PROMPT", 3)
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    for i in range(6):
        db_session.add(models.ChildMemory(child_id=c.id, fact=f"fact {i}", category="context",
                                          created_at=base + timedelta(days=i)))
    db_session.commit()

    facts = memory_router.facts_for(db_session, c.id)
    assert [f.fact for f in facts] == ["fact 3", "fact 4", "fact 5"]


def test_dedup_still_sees_facts_that_aged_out_of_the_prompt(db_session, family, monkeypatch):
    # A fact past the cap is still known. Writing it again as if it were new
    # is how the table would fill with restatements of one thing.
    _, c = family
    cid = c.id
    monkeypatch.setattr(memory_router, "MAX_FACTS_IN_PROMPT", 1)
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    db_session.add(models.ChildMemory(child_id=cid, fact="Plays football on Tuesdays",
                                      category="routine", created_at=base))
    db_session.add(models.ChildMemory(child_id=cid, fact="Newer thing", category="context",
                                      created_at=base + timedelta(days=1)))
    db_session.commit()

    _remembering(monkeypatch, [{"fact": "Plays football on Tuesdays", "category": "routine"}])
    monkeypatch.setattr("database.SessionLocal", lambda: db_session)

    assert asyncio.run(memory_router.extract_memories(cid, [{"role": "parent", "text": "football"}])) == 0


# ---- deleting the source ------------------------------------------------

def test_deleting_a_thread_forgets_what_it_taught(client, db_session, family, monkeypatch):
    # Otherwise the transcript disappears and the assistant carries on
    # quoting what it drew from it, with no way left to remove that.
    _, c = family
    _chatting(monkeypatch)
    sent = client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                       json={"text": "he's at his dad's every other weekend"}).json()

    db_session.add(models.ChildMemory(child_id=c.id, fact="Stays at his dad's every other weekend",
                                      category="context", source_message_id=uuid.UUID(sent["id"])))
    db_session.add(models.ChildMemory(child_id=c.id, fact="Plays football on Tuesdays", category="routine"))
    db_session.commit()
    assert len(memory_router.facts_for(db_session, c.id)) == 2

    assert client.delete(f"/conversations/{sent['conversation_id']}", headers=auth("pa")).status_code == 200

    # The fact from that thread is gone outright, not archived with a
    # dangling null source. Facts from elsewhere are untouched.
    assert [f.fact for f in memory_router.facts_for(db_session, c.id)] == ["Plays football on Tuesdays"]
    assert db_session.query(models.ChildMemory).count() == 1


# ---- extraction ----------------------------------------------------------
#
# extract_memories opens and closes its own session (it runs as a background
# task in production, after the request's session is gone). Pointed at the
# test session it closes that too, detaching every ORM object — so these grab
# the child id up front rather than touching the instance afterwards.

def test_extraction_writes_facts(db_session, family, monkeypatch):
    _, c = family
    cid = c.id
    _remembering(monkeypatch, [{"fact": "Stays at his dad's every other weekend", "category": "context"}])
    monkeypatch.setattr("database.SessionLocal", lambda: db_session)

    written = asyncio.run(memory_router.extract_memories(
        cid, [{"role": "parent", "text": "he's at his dad's every other weekend"},
              {"role": "assistant", "text": "Noted."}]))
    assert written == 1
    assert memory_router.facts_for(db_session, cid)[0].fact == "Stays at his dad's every other weekend"


def test_extraction_does_not_restate_what_it_already_knows(db_session, family, monkeypatch):
    _, c = family
    cid = c.id
    db_session.add(models.ChildMemory(child_id=cid, fact="Plays football on Tuesdays", category="routine"))
    db_session.commit()

    # Same fact, different capitalisation and spacing.
    _remembering(monkeypatch, [{"fact": "  plays football on tuesdays  ", "category": "routine"}])
    monkeypatch.setattr("database.SessionLocal", lambda: db_session)

    written = asyncio.run(memory_router.extract_memories(cid, [{"role": "parent", "text": "football again"}]))
    assert written == 0
    assert len(memory_router.facts_for(db_session, cid)) == 1


def test_extraction_failure_is_swallowed(db_session, family, monkeypatch):
    # It runs after the parent already has their reply, so nothing it does
    # may surface to them.
    _, c = family
    cid = c.id

    async def _boom(system_prompt, messages, tools=None):
        raise RuntimeError("the model fell over")

    monkeypatch.setattr(memory_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(memory_router, "generate", _boom)
    monkeypatch.setattr("database.SessionLocal", lambda: db_session)

    assert asyncio.run(memory_router.extract_memories(cid, [{"role": "parent", "text": "x"}])) == 0


def test_nothing_worth_remembering_writes_nothing(db_session, family, monkeypatch):
    _, c = family
    cid = c.id
    _remembering(monkeypatch, [])
    monkeypatch.setattr("database.SessionLocal", lambda: db_session)

    assert asyncio.run(memory_router.extract_memories(cid, [{"role": "parent", "text": "thanks!"}])) == 0
    assert memory_router.facts_for(db_session, cid) == []
