import uuid
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
    # A client that says nothing about conversations keeps appending to the
    # running thread — the behaviour every build shipped before threading
    # depends on.
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


def _mock_course_pipeline(monkeypatch):
    import routers.courses as courses_router

    async def _search(query, max_results=10):
        return [{"video_id": "vid1", "title": "Fractions", "channel_title": "MathCo",
                 "description": "", "duration": "PT5M", "made_for_kids": True,
                 "content_rating": {}, "embeddable": True, "thumbnail_url": "t"}]

    async def _vet(system_prompt, messages, tools=None):
        return None, FunctionCall(name="propose_course", args={
            "title": "Fractions basics",
            "items": [{"video_id": "vid1", "reason": "age-appropriate", "quiz": []}]})

    monkeypatch.setattr(courses_router, "youtube_configured", lambda: True)
    monkeypatch.setattr(courses_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(courses_router, "search_with_details", _search)
    monkeypatch.setattr(courses_router, "generate", _vet)


def test_course_tool_builds_a_real_draft_course_and_returns_its_id(client, db_session, monkeypatch):
    async def _call_course_tool(system_prompt, messages, tools=None):
        return None, FunctionCall(name="generate_course", args={"topic": "fractions", "video_count": 1})

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(chat_router, "generate", _call_course_tool)
    _mock_course_pipeline(monkeypatch)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)

    body = client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                       json={"text": "make a course about fractions"}).json()
    assert body["tool_call"] == "generate_course"
    course_id = body["tool_args"]["course_id"]

    # Backed by a real, checked course — not titles the model made up.
    course = client.get(f"/courses/{course_id}", headers=auth("pa")).json()
    assert course["items"][0]["video_id"] == "vid1"
    # Still a draft: a chat message can't put videos in front of a child.
    assert course["status"] == "pending_review"
    assert client.get(f"/children/{c.id}/course-assignments", headers=auth("pa")).json() == []


def test_special_task_tool_carries_its_course_and_bonus_to_the_card(client, db_session, monkeypatch):
    async def _call_special_task(system_prompt, messages, tools=None):
        return None, FunctionCall(name="draft_special_task", args={
            "title": "Learn fractions", "topic": "fractions", "bonus_minutes": 30})

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(chat_router, "generate", _call_special_task)
    _mock_course_pipeline(monkeypatch)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)

    body = client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                       json={"text": "task worth 30 min to learn fractions"}).json()
    assert body["tool_call"] == "draft_special_task"
    assert body["tool_args"]["bonus_minutes"] == "30"
    assert body["tool_args"]["course_id"]
    # Proposing is not creating.
    assert db_session.query(models.Task).filter(models.Task.child_id == c.id).count() == 0


def test_proposing_a_reflection_assigns_nothing(client, db_session, monkeypatch):
    async def _propose(system_prompt, messages, tools=None):
        return None, FunctionCall(name="propose_reflection",
                                  args={"title": "Being kind online", "reason": "argument at school"})

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(chat_router, "generate", _propose)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)

    body = client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                       json={"text": "he was mean online today"}).json()
    assert body["tool_call"] == "propose_reflection"
    assert client.get(f"/children/{c.id}/reflections", headers=auth("pa")).json() == []
    # And the device isn't locked off the back of a chat message.
    assert client.get(f"/children/{c.id}/state", headers=auth("pa")).json()["has_open_reflection"] is False


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


# ---- real threads --------------------------------------------------------

def _threaded(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(chat_router, "generate", _fake_plain_reply)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    return p, c


def test_first_message_creates_a_thread_titled_from_what_was_asked(client, db_session, monkeypatch):
    p, c = _threaded(client, db_session, monkeypatch)
    client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                json={"text": "Lock all apps at 9pm on school nights"})

    convs = client.get(f"/children/{c.id}/conversations", headers=auth("pa")).json()
    assert len(convs) == 1
    assert convs[0]["title"] == "Lock all apps at 9pm on school nights"


def test_a_long_first_message_is_trimmed_into_a_title(client, db_session, monkeypatch):
    p, c = _threaded(client, db_session, monkeypatch)
    client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                json={"text": "x" * 200})
    title = client.get(f"/children/{c.id}/conversations", headers=auth("pa")).json()[0]["title"]
    assert len(title) <= 41 and title.endswith("…")


def test_new_thread_does_not_inherit_the_other_threads_context(client, db_session, monkeypatch):
    # The property that makes threads worth having. Previously every message
    # for the child went into the prompt, so separate threads would have
    # silently shared context.
    captured = {}

    async def _capture(system_prompt, messages, tools=None):
        captured["messages"] = messages
        return "ok", None

    p, c = _threaded(client, db_session, monkeypatch)
    monkeypatch.setattr(chat_router, "generate", _capture)

    first = client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                        json={"text": "about bedtime"}).json()
    assert [m["text"] for m in captured["messages"]] == ["about bedtime"]

    second = client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                         json={"text": "about tiktok", "new_conversation": True}).json()
    assert second["conversation_id"] != first["conversation_id"]
    assert [m["text"] for m in captured["messages"]] == ["about tiktok"]

    # Continuing the first thread sees its own history and nothing else.
    client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                json={"text": "and weekends?", "conversation_id": first["conversation_id"]})
    texts = [m["text"] for m in captured["messages"]]
    assert "about bedtime" in texts and "about tiktok" not in texts


def test_messages_are_fetchable_per_thread(client, db_session, monkeypatch):
    p, c = _threaded(client, db_session, monkeypatch)
    a = client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "first thread"}).json()
    client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                json={"text": "second thread", "new_conversation": True})

    msgs = client.get(f"/conversations/{a['conversation_id']}/messages", headers=auth("pa")).json()
    assert [m["text"] for m in msgs] == ["first thread", "Got it — here's a real, grounded reply."]


def test_rename_and_delete_are_real(client, db_session, monkeypatch):
    p, c = _threaded(client, db_session, monkeypatch)
    sent = client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "rename me"}).json()
    cid = sent["conversation_id"]

    renamed = client.put(f"/conversations/{cid}", headers=auth("pa"),
                         json={"title": "Bedtime rules"}).json()
    assert renamed["title"] == "Bedtime rules"
    assert client.get(f"/children/{c.id}/conversations", headers=auth("pa")).json()[0]["title"] == "Bedtime rules"

    assert client.delete(f"/conversations/{cid}", headers=auth("pa")).status_code == 200
    assert client.get(f"/children/{c.id}/conversations", headers=auth("pa")).json() == []
    # Its messages go with it rather than being orphaned.
    assert db_session.query(models.ChatMessage).filter(
        models.ChatMessage.conversation_id == uuid.UUID(cid)).count() == 0


def test_blank_rename_is_rejected(client, db_session, monkeypatch):
    p, c = _threaded(client, db_session, monkeypatch)
    sent = client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "x"}).json()
    assert client.put(f"/conversations/{sent['conversation_id']}", headers=auth("pa"),
                      json={"title": "   "}).status_code == 422


def test_child_chat_endpoint_returns_the_most_recent_thread(client, db_session, monkeypatch):
    p, c = _threaded(client, db_session, monkeypatch)
    client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "older"})
    client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                json={"text": "newer", "new_conversation": True})

    opened = client.get(f"/children/{c.id}/chat", headers=auth("pa")).json()
    assert [m["text"] for m in opened][0] == "newer"


def test_threads_are_scoped_to_the_owning_parent(client, db_session, monkeypatch):
    p, c = _threaded(client, db_session, monkeypatch)
    make_parent(db_session, "pb")
    sent = client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "private"}).json()
    cid = sent["conversation_id"]

    assert client.get(f"/children/{c.id}/conversations", headers=auth("pb")).status_code == 404
    assert client.get(f"/conversations/{cid}/messages", headers=auth("pb")).status_code == 404
    assert client.put(f"/conversations/{cid}", headers=auth("pb"), json={"title": "mine now"}).status_code == 404
    assert client.delete(f"/conversations/{cid}", headers=auth("pb")).status_code == 404
    # And you can't post into someone else's thread.
    assert client.post(f"/children/{c.id}/chat", headers=auth("pb"),
                       json={"text": "hi", "conversation_id": cid}).status_code == 404


def test_active_thread_rises_to_the_top(client, db_session, monkeypatch):
    p, c = _threaded(client, db_session, monkeypatch)
    first = client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "older thread"}).json()
    client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "newer thread"})
    client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                json={"text": "bump", "conversation_id": first["conversation_id"]})

    convs = client.get(f"/children/{c.id}/conversations", headers=auth("pa")).json()
    assert convs[0]["id"] == first["conversation_id"]


def test_a_client_that_knows_nothing_about_threads_keeps_one_conversation(client, db_session, monkeypatch):
    # Deploy-ordering guard: the shipped iOS build sends no conversation_id.
    # If that meant "new thread", every message would land in its own and the
    # assistant would forget the previous turn.
    p, c = _threaded(client, db_session, monkeypatch)
    for text in ("one", "two", "three"):
        client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": text})

    convs = client.get(f"/children/{c.id}/conversations", headers=auth("pa")).json()
    assert len(convs) == 1
    assert len(client.get(f"/conversations/{convs[0]['id']}/messages", headers=auth("pa")).json()) == 6


def test_system_prompt_tells_the_model_todays_date(client, db_session, monkeypatch):
    # Without this the model resolves "tomorrow at 6pm" against its training
    # cutoff, so every relative date it produced was a guess.
    from datetime import date as _date
    captured = {}

    async def _capture(system_prompt, messages, tools=None):
        captured["prompt"] = system_prompt
        return "ok", None

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(chat_router, "generate", _capture)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "hi"})

    assert _date.today().isoformat() in captured["prompt"]


def test_draft_task_args_survive_as_structured_values(client, db_session, monkeypatch):
    # The card reads these keys directly now. They used to be flattened into
    # an English sentence and re-parsed with string matching, which produced
    # an empty card on every real tool call.
    async def _draft(system_prompt, messages, tools=None):
        return None, FunctionCall(name="draft_task", args={
            "title": "Tidy his room", "instructions": "Floor and desk",
            "due_date": "2026-09-24", "due_time": "18:00",
            "recurrence": "mon,wed,fri", "gates_apps": True, "bonus_minutes": 15,
        })

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    monkeypatch.setattr(chat_router, "generate", _draft)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)

    args = client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                       json={"text": "tidy his room mon wed fri at 6"}).json()["tool_args"]
    assert args["title"] == "Tidy his room"
    assert args["due_date"] == "2026-09-24"
    assert args["due_time"] == "18:00"
    assert args["recurrence"] == "mon,wed,fri"
    assert args["bonus_minutes"] == "15"


def test_draft_task_schema_asks_for_dates_not_free_text():
    # The free-text due_hint/repeats_hint are what forced the re-parsing.
    draft = next(t for t in chat_router._TOOLS if t["name"] == "draft_task")
    props = draft["parameters"]["properties"]
    assert "due_date" in props and "due_time" in props and "recurrence" in props
    assert "due_hint" not in props and "repeats_hint" not in props
