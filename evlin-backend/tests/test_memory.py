"""What the assistant remembers between conversations.

Extraction is stubbed at the gemini_client boundary; nothing here makes a
real call. The autouse fixture in conftest disables extraction by default,
so these opt back in explicitly.
"""
import asyncio

import pytest

import models
import routers.chat as chat_router
import routers.memory as memory_router
from gemini_client import FunctionCall
from tests.conftest import auth, make_child, make_parent


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
    monkeypatch.setattr(chat_router, "generate", _reply)


@pytest.fixture()
def family(db_session):
    p = make_parent(db_session, "pa")
    return p, make_child(db_session, p)


# ---- reading and forgetting ---------------------------------------------

def test_memory_starts_empty_and_lists_what_was_learned(client, db_session, family):
    _, c = family
    assert client.get(f"/children/{c.id}/memory", headers=auth("pa")).json() == []

    db_session.add(models.ChildMemory(child_id=c.id, fact="Plays football on Tuesdays", category="routine"))
    db_session.commit()

    rows = client.get(f"/children/{c.id}/memory", headers=auth("pa")).json()
    assert [r["fact"] for r in rows] == ["Plays football on Tuesdays"]


def test_forgetting_archives_rather_than_deletes(client, db_session, family):
    # A deleted fact could be re-extracted from the same conversation and
    # quietly come back; an archived one is a decision that sticks.
    _, c = family
    m = models.ChildMemory(child_id=c.id, fact="Hates broccoli", category="preference")
    db_session.add(m)
    db_session.commit()
    mid = str(m.id)

    assert client.delete(f"/memory/{mid}", headers=auth("pa")).status_code == 200
    assert client.get(f"/children/{c.id}/memory", headers=auth("pa")).json() == []
    assert db_session.query(models.ChildMemory).filter(models.ChildMemory.id == m.id).first() is not None


def test_memory_is_private_to_the_family(client, db_session, family):
    _, c = family
    make_parent(db_session, "pb")
    m = models.ChildMemory(child_id=c.id, fact="Private", category="context")
    db_session.add(m)
    db_session.commit()

    assert client.get(f"/children/{c.id}/memory", headers=auth("pb")).status_code == 404
    assert client.delete(f"/memory/{m.id}", headers=auth("pb")).status_code == 404


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
    monkeypatch.setattr(chat_router, "generate", _capture)
    client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "hi"})

    assert "Plays football on Tuesdays" in captured["prompt"]


def test_forgotten_facts_stop_reaching_the_model(client, db_session, family, monkeypatch):
    _, c = family
    m = models.ChildMemory(child_id=c.id, fact="Plays football on Tuesdays", category="routine")
    db_session.add(m)
    db_session.commit()
    client.delete(f"/memory/{m.id}", headers=auth("pa"))

    captured = {}

    async def _capture(system_prompt, messages, tools=None):
        captured["prompt"] = system_prompt
        return "ok", None

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(chat_router, "generate", _capture)
    client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "hi"})

    assert "football" not in captured["prompt"].lower()


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
