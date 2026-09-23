from datetime import date

import models
import routers.chat as chat_router
from gemini_client import FunctionCall
from tests.conftest import auth, make_child, make_parent


def test_chat_requires_configured_key(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: False)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    r = client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "hi"})
    assert r.status_code == 503


async def _fake_plain_reply(system_prompt, messages, tools=None):
    return "Got it — here's a real, grounded reply.", None


async def _fake_task_draft(system_prompt, messages, tools=None):
    return None, FunctionCall(name="draft_task", args={"title": "Clean room", "due_hint": "6pm today"})


def test_plain_message_gets_a_real_stored_reply(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(chat_router, "generate", _fake_plain_reply)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)

    r = client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "How's my kid doing?"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["role"] == "assistant"
    assert body["text"] == "Got it — here's a real, grounded reply."
    assert body["tool_call"] is None

    # Both the user's message and the real reply are actually persisted —
    # not a mock array, a real per-child table.
    rows = db_session.query(models.ChatMessage).filter(models.ChatMessage.child_id == c.id).order_by(models.ChatMessage.created_at).all()
    assert len(rows) == 2
    assert rows[0].role == "user" and rows[0].text == "How's my kid doing?"
    assert rows[1].role == "assistant"


def test_task_shaped_request_returns_a_tool_call_not_a_write(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(chat_router, "generate", _fake_task_draft)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)

    r = client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "Add a task to clean his room at 6pm"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["tool_call"] == "draft_task"
    assert body["tool_args"] == {"title": "Clean room", "due_hint": "6pm today"}

    # The model proposing a task must never itself create one — no real
    # Task row exists just because the model called the tool.
    assert db_session.query(models.Task).filter(models.Task.child_id == c.id).count() == 0


def test_history_persists_and_returns_in_order(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(chat_router, "generate", _fake_plain_reply)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)

    client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "first"})
    client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "second"})

    history = client.get(f"/children/{c.id}/chat", headers=auth("pa")).json()
    assert [m["text"] for m in history] == ["first", "Got it — here's a real, grounded reply.", "second", "Got it — here's a real, grounded reply."]


def test_chat_access_control(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(chat_router, "generate", _fake_plain_reply)
    a, b = make_parent(db_session, "pa"), make_parent(db_session, "pb")
    kid = make_child(db_session, a)
    assert client.post(f"/children/{kid.id}/chat", headers=auth("pb"), json={"text": "hi"}).status_code == 404
    assert client.get(f"/children/{kid.id}/chat", headers=auth("pb")).status_code == 404


def test_numeric_tool_args_are_stored_as_strings(client, db_session, monkeypatch):
    # The iOS client decodes tool_args as [String: String]; a raw JSON number
    # from the model would fail the decode of the whole ChatMessage and take
    # the entire transcript down with it, not just the one card.
    async def _numeric_args(system_prompt, messages, tools=None):
        return None, FunctionCall(name="draft_task", args={"title": "Read", "bonus_minutes": 30, "nothing": None})

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(chat_router, "generate", _numeric_args)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)

    body = client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "reading task worth 30 min"}).json()
    assert body["tool_args"] == {"title": "Read", "bonus_minutes": "30", "nothing": ""}
    assert all(isinstance(v, str) for v in body["tool_args"].values())


def test_unknown_tool_does_not_borrow_another_tools_reply(client, db_session, monkeypatch):
    # Previously a binary if/else: any tool that wasn't draft_task answered
    # "which app should I block?", which gets wrong the moment a third exists.
    async def _other_tool(system_prompt, messages, tools=None):
        return None, FunctionCall(name="some_future_tool", args={})

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(chat_router, "generate", _other_tool)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)

    body = client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "do the thing"}).json()
    assert body["tool_call"] == "some_future_tool"
    assert "block" not in body["text"].lower()


def test_system_prompt_lists_the_tools_actually_passed(client, db_session, monkeypatch):
    captured = {}

    async def _capture(system_prompt, messages, tools=None):
        captured["prompt"] = system_prompt
        captured["tools"] = tools
        return "ok", None

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(chat_router, "generate", _capture)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "hi"})

    for tool in captured["tools"]:
        assert tool["name"] in captured["prompt"]
    # and no stale count claim that a new tool would falsify
    assert "two tools" not in captured["prompt"]


def test_grounding_reflects_real_tasks_not_invented_ones(client, db_session, monkeypatch):
    captured = {}

    async def _capture(system_prompt, messages, tools=None):
        captured["prompt"] = system_prompt
        return "ok", None

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(chat_router, "generate", _capture)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={
        "title": "Real task from the DB", "recurrence": "none", "due_date": str(date.today()),
    })

    client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "what's up"})
    assert "Real task from the DB" in captured["prompt"]
