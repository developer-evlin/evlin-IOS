import uuid
from datetime import date, timedelta

import models
import routers.chat as chat_router
from gemini_client import FunctionCall
from tests.conftest import auth, fake_chat_model, make_child, make_parent


def test_chat_requires_configured_key(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: False)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    r = client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "hi"})
    assert r.status_code == 503


async def _fake_plain_reply(system_prompt, messages, tools=None):
    return "Got it — here's a real, grounded reply.", None


# A day that's always ahead, so the draft is complete and becomes a card.
SOON = (date.today() + timedelta(days=2)).isoformat()


async def _fake_task_draft(system_prompt, messages, tools=None):
    return None, FunctionCall(name="draft_task", args={"title": "Clean room", "due_date": SOON, "due_time": "18:00"})


def test_plain_message_gets_a_real_stored_reply(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _fake_plain_reply)
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
    fake_chat_model(monkeypatch, _fake_task_draft)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)

    r = client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "Add a task to clean his room at 6pm"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["tool_call"] == "draft_task"
    assert body["tool_args"] == {"title": "Clean room", "due_date": SOON, "due_time": "18:00"}

    # The model proposing a task must never itself create one — no real
    # Task row exists just because the model called the tool.
    assert db_session.query(models.Task).filter(models.Task.child_id == c.id).count() == 0


def test_history_persists_and_returns_in_order(client, db_session, monkeypatch):
    # A client that says nothing about conversations keeps appending to the
    # running thread — the behaviour every build shipped before threading
    # depends on.
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _fake_plain_reply)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)

    client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "first"})
    client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "second"})

    history = client.get(f"/children/{c.id}/chat", headers=auth("pa")).json()
    assert [m["text"] for m in history] == ["first", "Got it — here's a real, grounded reply.", "second", "Got it — here's a real, grounded reply."]


def test_chat_access_control(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _fake_plain_reply)
    a, b = make_parent(db_session, "pa"), make_parent(db_session, "pb")
    kid = make_child(db_session, a)
    assert client.post(f"/children/{kid.id}/chat", headers=auth("pb"), json={"text": "hi"}).status_code == 404
    assert client.get(f"/children/{kid.id}/chat", headers=auth("pb")).status_code == 404


def test_numeric_tool_args_are_stored_as_strings(client, db_session, monkeypatch):
    # The iOS client decodes tool_args as [String: String]; a raw JSON number
    # from the model would fail the decode of the whole ChatMessage and take
    # the entire transcript down with it, not just the one card.
    async def _numeric_args(system_prompt, messages, tools=None):
        return None, FunctionCall(name="draft_task", args={"title": "Read", "due_date": SOON, "bonus_minutes": 30, "nothing": None})

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _numeric_args)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)

    body = client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "reading task worth 30 min"}).json()
    assert body["tool_args"] == {"title": "Read", "due_date": SOON, "bonus_minutes": "30", "nothing": ""}
    assert all(isinstance(v, str) for v in body["tool_args"].values())


def test_unknown_tool_does_not_borrow_another_tools_reply(client, db_session, monkeypatch):
    # Previously a binary if/else: any tool that wasn't draft_task answered
    # "which app should I block?", which gets wrong the moment a third exists.
    async def _other_tool(system_prompt, messages, tools=None):
        return None, FunctionCall(name="some_future_tool", args={})

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _other_tool)
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
    fake_chat_model(monkeypatch, _capture)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "hi"})

    for tool in captured["tools"]:
        assert tool["name"] in captured["prompt"]
    # and no stale count claim that a new tool would falsify
    assert "two tools" not in captured["prompt"]


def test_the_assistant_has_exactly_the_task_and_calendar_tools(client, db_session, monkeypatch):
    # Courses, reflections and app blocks are off the assistant: it assigns
    # tasks and manages the calendar, and asks when it can't tell which.
    captured = {}

    async def _capture(system_prompt, messages, tools=None):
        captured["prompt"] = system_prompt
        captured["tools"] = [t["name"] for t in tools or []]
        return "ok", None

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _capture)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "hi"})

    assert captured["tools"] == ["draft_task", "draft_event", "ask_follow_up"]
    # Blocking still exists in the app, so the model points there rather
    # than claiming it did it — and no longer says it can't do calendars.
    assert "Block an app card" in captured["prompt"]
    assert "adding a calendar event" not in captured["prompt"]


def test_every_tool_has_its_own_reply_or_speaks_for_itself():
    import tool_calls
    for name in tool_calls.NAMES:
        assert name in tool_calls.REPLIES or name in tool_calls.SPEAKS_FOR_ITSELF, name


def test_grounding_reflects_real_tasks_not_invented_ones(client, db_session, monkeypatch):
    captured = {}

    async def _capture(system_prompt, messages, tools=None):
        captured["prompt"] = system_prompt
        return "ok", None

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _capture)
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
    fake_chat_model(monkeypatch, _fake_plain_reply)
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
    fake_chat_model(monkeypatch, _capture)

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
    fake_chat_model(monkeypatch, _capture)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "hi"})

    # The child's date, not the server machine's: this used to compare with
    # date.today(), which is the bug itself, and failed every evening in
    # California once the prompt stopped using the server's clock.
    from blocks import local_now
    assert local_now(c).date().isoformat() in captured["prompt"]


def test_draft_task_args_survive_as_structured_values(client, db_session, monkeypatch):
    # The card reads these keys directly now. They used to be flattened into
    # an English sentence and re-parsed with string matching, which produced
    # an empty card on every real tool call.
    async def _draft(system_prompt, messages, tools=None):
        return None, FunctionCall(name="draft_task", args={
            "title": "Tidy his room", "instructions": "Floor and desk",
            "due_date": SOON, "due_time": "18:00",
            "recurrence": "mon,wed,fri", "gates_apps": True, "bonus_minutes": 15,
        })

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _draft)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)

    args = client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                       json={"text": "tidy his room mon wed fri at 6"}).json()["tool_args"]
    assert args["title"] == "Tidy his room"
    assert args["due_date"] == SOON
    assert args["due_time"] == "18:00"
    assert args["recurrence"] == "mon,wed,fri"
    assert args["bonus_minutes"] == "15"


def test_draft_task_schema_asks_for_dates_not_free_text():
    # The free-text due_hint/repeats_hint are what forced the re-parsing.
    draft = next(t for t in chat_router._TOOLS if t["name"] == "draft_task")
    props = draft["parameters"]["properties"]
    assert "due_date" in props and "due_time" in props and "recurrence" in props
    assert "due_hint" not in props and "repeats_hint" not in props


def test_follow_up_question_becomes_the_message_text(client, db_session, monkeypatch):
    # The model's question is the message; a canned "Sure — let's set that
    # up." in front of it would just be noise.
    async def _ask(system_prompt, messages, tools=None):
        return None, FunctionCall(name="ask_follow_up", args={
            "question": "What task would you like to add?"})

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _ask)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)

    body = client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                       json={"text": "I'd like to add a task"}).json()
    assert body["tool_call"] == "ask_follow_up"
    assert body["text"] == "What task would you like to add?"


def test_asking_is_available_as_a_tool_not_a_prompt_instruction(client, db_session, monkeypatch):
    # The mechanism is a typed tool the model can call, not prose telling it
    # to "ask if unsure" — which is what this replaced.
    assert any(t["name"] == "ask_follow_up" for t in chat_router._TOOLS)


# ---- several cards, asking when, and the child's clock ---------------------

def _calls(*calls):
    async def _model(system_prompt, messages, tools=None):
        return None, list(calls)
    return _model


def _send(client, c, text):
    r = client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": text})
    assert r.status_code == 200, r.text
    return r.json()


def test_several_requests_in_one_message_become_one_card_each(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _calls(
        FunctionCall(name="draft_task", args={"title": "Piano practice", "due_date": SOON, "due_time": "17:00"}),
        FunctionCall(name="draft_event", args={"title": "Dentist", "start_date": SOON, "start_time": "15:00"}),
    ))
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)

    body = _send(client, c, "piano practice at 5 and the dentist at 3")
    assert body["tool_call"] == "draft_task"
    assert [m["tool_call"] for m in body["extra_messages"]] == ["draft_event"]
    # One line above the cards, not the canned reply under each.
    assert "2 things" in body["text"]
    assert body["extra_messages"][0]["text"] == ""

    # A reopened thread shows the same cards in the same order.
    history = client.get(f"/children/{c.id}/chat", headers=auth("pa")).json()
    assert [m["tool_call"] for m in history] == [None, "draft_task", "draft_event"]
    # Still nothing written until the parent taps.
    assert db_session.query(models.Task).filter(models.Task.child_id == c.id).count() == 0
    assert db_session.query(models.Event).filter(models.Event.child_id == c.id).count() == 0


def test_the_same_card_twice_is_shown_once(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    same = {"title": "Tidy room", "due_date": SOON}
    fake_chat_model(monkeypatch, _calls(FunctionCall(name="draft_task", args=same),
                                        FunctionCall(name="draft_task", args=dict(same))))
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    body = _send(client, c, "tidy room")
    assert body["tool_call"] == "draft_task" and body["extra_messages"] == []
    assert body["text"] == "Sure — let's set that up."


def test_a_task_with_no_day_asks_when_instead_of_picking_one(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _calls(FunctionCall(name="draft_task", args={"title": "Tidy room", "due_date": ""})))
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p, name="Mia")

    body = _send(client, c, "add a task to tidy her room")
    assert body["tool_call"] == "ask_follow_up"
    assert body["text"] == "When should Mia do “Tidy room”?"
    assert body["tool_args"] == {"question": body["text"]}


def test_a_repeating_task_needs_no_start_day(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _calls(FunctionCall(name="draft_task", args={
        "title": "Piano practice", "due_time": "17:00", "recurrence": "mon,tue,wed,thu,fri"})))
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    assert _send(client, c, "piano every weekday at 5")["tool_call"] == "draft_task"


def test_a_past_day_is_asked_about_not_drafted(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    past = (date.today() - timedelta(days=3)).isoformat()
    fake_chat_model(monkeypatch, _calls(FunctionCall(name="draft_task", args={"title": "Read", "due_date": past})))
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    body = _send(client, c, "reading")
    assert body["tool_call"] == "ask_follow_up" and "already passed" in body["text"]


def test_an_event_without_a_start_time_asks_for_it(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _calls(FunctionCall(name="draft_event", args={"title": "Dentist", "start_date": SOON})))
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    body = _send(client, c, "dentist on friday")
    assert body["tool_call"] == "ask_follow_up"
    assert body["text"] == "What time does “Dentist” start?"


def test_one_incomplete_item_means_a_question_and_no_cards(client, db_session, monkeypatch):
    # Half the request as cards and half as a question leaves the parent
    # unsure what's been set up; the model redrafts all of it from the answer.
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _calls(
        FunctionCall(name="draft_event", args={"title": "Dentist", "start_date": SOON, "start_time": "15:00"}),
        FunctionCall(name="draft_task", args={"title": "Homework"}),
    ))
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p, name="Mia")
    body = _send(client, c, "dentist at 3 and homework")
    assert body["tool_call"] == "ask_follow_up" and body["extra_messages"] == []
    assert "Homework" in body["text"]


def test_the_models_own_question_wins_over_its_drafts(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _calls(
        FunctionCall(name="draft_task", args={"title": "Tidy room", "due_date": SOON}),
        FunctionCall(name="ask_follow_up", args={"question": "Which day is the recital?"}),
    ))
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    body = _send(client, c, "tidy room and the recital")
    assert body["tool_call"] == "ask_follow_up" and body["extra_messages"] == []
    assert body["text"] == "Which day is the recital?"


def test_today_in_the_prompt_is_the_childs_not_the_servers(client, db_session, monkeypatch):
    # 25 hours apart, so these two are never on the same date.
    from blocks import local_now
    captured = {}

    async def _capture(system_prompt, messages, tools=None):
        captured["prompt"] = system_prompt
        return "ok", None

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _capture)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    c.timezone = "Pacific/Kiritimati"
    db_session.commit()
    _send(client, c, "hi")

    far_east = local_now(c).date().isoformat()
    far_west = local_now(models.Child(timezone="Pacific/Pago_Pago")).date().isoformat()
    assert f"({far_east})" in captured["prompt"]
    assert far_west not in captured["prompt"]


def test_a_one_off_task_with_no_day_is_for_the_childs_today(client, db_session, monkeypatch):
    # It used to fall back to created_at's UTC date: tomorrow, for a Pacific
    # family adding a task any evening after 5pm.
    from blocks import local_now
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    c.timezone = "Pacific/Kiritimati"
    db_session.commit()

    r = client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={"title": "Feed the cat", "recurrence": "none"})
    assert r.status_code == 200, r.text
    assert r.json()["due_date"] == local_now(c).date().isoformat()

    # A repeating task with no start day is left alone.
    r = client.post(f"/children/{c.id}/tasks", headers=auth("pa"), json={"title": "Read", "recurrence": "daily"})
    assert r.json()["due_date"] is None


# ---- the history window, and keeping videos out of chat --------------------

def test_the_model_sees_only_the_newest_50_messages_of_a_thread(client, db_session, monkeypatch):
    from datetime import datetime, timezone
    captured = {}

    async def _capture(system_prompt, messages, tools=None):
        captured["messages"] = messages
        return "ok", None

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _capture)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    conv = models.ChatConversation(child_id=c.id, parent_id=p.id, title="long")
    db_session.add(conv)
    db_session.flush()
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    for i in range(120):
        db_session.add(models.ChatMessage(child_id=c.id, conversation_id=conv.id, parent_id=p.id,
                                          role="user" if i % 2 == 0 else "assistant", text=f"m{i}",
                                          created_at=base + timedelta(minutes=i)))
    db_session.commit()

    client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                json={"text": "latest", "conversation_id": str(conv.id)})

    sent = captured["messages"]
    assert len(sent) <= chat_router.HISTORY_WINDOW
    assert sent[-1]["text"] == "latest"
    assert sent[0]["role"] == "user"
    assert "m0" not in [m["text"] for m in sent]
    # The parent still has the whole thread.
    shown = client.get(f"/conversations/{conv.id}/messages", headers=auth("pa")).json()
    assert len(shown) == 122


def test_chat_has_no_video_tools_and_hands_videos_to_the_library(client, db_session, monkeypatch):
    # Videos are the YouTube agent's, behind the Library tab — a separate
    # pipeline. Chat neither drafts them nor names any.
    captured = {}

    async def _capture(system_prompt, messages, tools=None):
        captured["prompt"] = system_prompt
        captured["tools"] = [t["name"] for t in tools or []]
        return "ok", None

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _capture)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "find her some videos"})

    assert not any("video" in name for name in captured["tools"])
    assert "Library tab" in captured["prompt"]


# ---- whose "today" chat uses -------------------------------------------------

def _prompt_for(client, db_session, monkeypatch, child_zone, parent_zone):
    captured = {}

    async def _capture(system_prompt, messages, tools=None):
        captured["prompt"] = system_prompt
        return "ok", None

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _capture)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    c.timezone = child_zone
    db_session.commit()
    body = {"text": "hi"}
    if parent_zone is not None:
        body["timezone"] = parent_zone
    assert client.post(f"/children/{c.id}/chat", headers=auth("pa"), json=body).status_code == 200
    return captured["prompt"]


def _today_in(zone):
    from blocks import local_now
    return local_now(models.Child(timezone=zone)).date().isoformat()


def test_without_a_child_zone_chat_uses_the_parents_phone(client, db_session, monkeypatch):
    # UTC was already tomorrow for a California family every evening, so
    # "today" landed a day late. 25 hours apart: never the same date.
    prompt = _prompt_for(client, db_session, monkeypatch, None, "Pacific/Kiritimati")
    assert f"({_today_in('Pacific/Kiritimati')})" in prompt
    assert _today_in("Pacific/Pago_Pago") not in prompt


def test_the_childs_own_zone_wins_over_the_parents(client, db_session, monkeypatch):
    prompt = _prompt_for(client, db_session, monkeypatch, "Pacific/Pago_Pago", "Pacific/Kiritimati")
    assert f"({_today_in('Pacific/Pago_Pago')})" in prompt


def test_a_nonsense_zone_falls_back_instead_of_failing(client, db_session, monkeypatch):
    prompt = _prompt_for(client, db_session, monkeypatch, None, "Mars/Olympus_Mons")
    assert f"({_today_in('UTC')})" in prompt


# ---- spending less on each reply ---------------------------------------------

def test_every_request_asks_for_low_thinking():
    # Measured: all chat cases still right, thinking down 50-80%, ~1.7 s faster.
    import gemini_client
    body = gemini_client.request_body("sys", [{"role": "user", "text": "hi"}], tools=chat_router._TOOLS)
    assert body["generationConfig"] == {"thinkingConfig": {"thinkingLevel": "low"}}


def test_the_thinking_level_can_be_switched_off(monkeypatch):
    import gemini_client
    monkeypatch.setattr(gemini_client, "_THINKING_LEVEL", "")
    assert "generationConfig" not in gemini_client.request_body("sys", [], None)


def test_a_tile_shortcut_asks_its_question_without_the_model(client, db_session, monkeypatch):
    called = []

    async def _model(system_prompt, messages, tools=None):
        called.append(1)
        return "ok", None

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _model)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p, name="Mia")

    body = client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                       json={"text": "I'd like to add a task", "shortcut": "add_task"}).json()
    assert called == []
    assert body["tool_call"] == "ask_follow_up"
    assert body["text"] == "What should Mia do, and when?"

    # The parent's answer goes to the model, which sees the question asked.
    seen = {}

    async def _answer(system_prompt, messages, tools=None):
        seen["messages"] = [m["text"] for m in messages]
        return "ok", None

    fake_chat_model(monkeypatch, _answer)
    client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                json={"text": "tidy her room on Saturday", "conversation_id": body["conversation_id"]})
    assert seen["messages"] == ["I'd like to add a task", "What should Mia do, and when?", "tidy her room on Saturday"]


def test_an_unknown_shortcut_is_refused(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    r = client.post(f"/children/{c.id}/chat", headers=auth("pa"), json={"text": "x", "shortcut": "delete_everything"})
    assert r.status_code == 422


# ---- "Try again" ---------------------------------------------------------------

def test_try_again_replaces_the_reply_instead_of_repeating_the_question(client, db_session, monkeypatch):
    replies = iter(["First answer.", "Second answer."])
    seen = {}

    async def _model(system_prompt, messages, tools=None):
        seen["messages"] = [m["text"] for m in messages]
        return next(replies), None

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _model)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    conv = _send(client, c, "what should she do today?")["conversation_id"]

    again = client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                        json={"text": "what should she do today?", "conversation_id": conv, "regenerate": True})
    assert again.status_code == 200, again.text
    assert again.json()["text"] == "Second answer."
    # The model saw the question once, not the first answer.
    assert seen["messages"] == ["what should she do today?"]
    # The thread holds one question and one answer.
    thread = client.get(f"/conversations/{conv}/messages", headers=auth("pa")).json()
    assert [m["text"] for m in thread] == ["what should she do today?", "Second answer."]


def test_try_again_forgets_what_the_replaced_reply_taught(client, db_session, monkeypatch):
    async def _model(system_prompt, messages, tools=None):
        return "ok", None

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _model)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    first = _send(client, c, "she loves dinosaurs")
    db_session.add(models.ChildMemory(child_id=c.id, fact="Loves dinosaurs", category="preference",
                                      source_message_id=uuid.UUID(first["id"])))
    db_session.commit()

    client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                json={"text": "she loves dinosaurs", "conversation_id": first["conversation_id"], "regenerate": True})
    db_session.expire_all()
    assert db_session.query(models.ChildMemory).filter(models.ChildMemory.child_id == c.id).count() == 0


def test_try_again_needs_a_conversation_with_a_question(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    assert client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                       json={"text": "again", "regenerate": True}).status_code == 400


# ---- suggesting real activities ----------------------------------------------

def _child_with_history(db_session):
    from datetime import date as _d
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p, name="Mia")  # born 2015
    bed = models.Task(child_id=c.id, title="Make your bed", recurrence="daily", active=False)
    cat = models.Task(child_id=c.id, title="Feed the cat", recurrence="daily", active=False)
    teeth = models.Task(child_id=c.id, title="Brush teeth", recurrence="daily", active=True)
    db_session.add_all([bed, cat, teeth])
    db_session.flush()
    today = _d.today()
    for i in range(3):
        db_session.add(models.Occurrence(task_id=bed.id, child_id=c.id, due_date=today - timedelta(days=i + 1),
                                         status="approved", gates_apps=True))
    # Not approved, and an approval too long ago: neither counts.
    db_session.add(models.Occurrence(task_id=cat.id, child_id=c.id, due_date=today - timedelta(days=1),
                                     status="submitted", gates_apps=True))
    db_session.add(models.Occurrence(task_id=cat.id, child_id=c.id, due_date=today - timedelta(days=60),
                                     status="approved", gates_apps=True))
    db_session.commit()
    return c


def test_chat_knows_age_and_what_the_child_already_does_by_name(client, db_session, monkeypatch):
    captured = {}

    async def _capture(system_prompt, messages, tools=None):
        captured["prompt"] = system_prompt
        return "ok", None

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _capture)
    c = _child_with_history(db_session)
    _send(client, c, "anything she could do this afternoon?")
    prompt = captured["prompt"]
    assert "Mia is about" in prompt
    # Names only, one short line: approved lately, then active tasks.
    assert "Mia already does: Make your bed, Brush teeth." in prompt
    assert "Never play, games, walks or screens" in prompt


def test_the_activity_tile_uses_a_short_prompt_and_only_the_task_tool(client, db_session, monkeypatch):
    captured = {}

    async def _model(system_prompt, messages, tools=None):
        captured.update(prompt=system_prompt, messages=messages, tools=[t["name"] for t in tools or []])
        return None, [FunctionCall("draft_task", {"title": "Tidy bedroom floor", "recurrence": "daily",
                                                 "instructions": "Nothing left on the floor."}),
                      FunctionCall("draft_task", {"title": "Read 15 minutes", "recurrence": "daily"})]

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _model)
    c = _child_with_history(db_session)
    body = client.post(f"/children/{c.id}/chat", headers=auth("pa"),
                       json={"text": "Suggest something Mia can do instead of screen time",
                             "shortcut": "suggest_activity"}).json()

    assert captured["tools"] == ["draft_task"]
    assert len(captured["messages"]) == 1           # no thread history
    assert len(captured["prompt"]) < 900            # short: nothing but what it needs
    assert "Make your bed, Brush teeth" in captured["prompt"]
    assert body["tool_call"] == "draft_task" and body["text"] == "A few habits that fit Mia:"
    assert [m["tool_call"] for m in body["extra_messages"]] == ["draft_task"]
    # Still nothing created until the parent taps.
    assert db_session.query(models.Task).filter(models.Task.title == "Tidy bedroom floor").count() == 0
