"""The YouTube agent's short memory, and keeping the two assistants apart."""
import sys
import types
from datetime import datetime, timedelta, timezone

import agent_sessions as s
import models
import routers.chat as chat_router
from tests.conftest import auth, fake_chat_model, make_child, make_parent

T0 = datetime(2026, 10, 7, 15, 0, tzinfo=timezone.utc)


def _msg(i, role, text, agent="youtube", minutes=None, tool_call=None, tool_args=None):
    return models.ChatMessage(role=role, text=text, agent=agent, tool_call=tool_call, tool_args=tool_args,
                              created_at=T0 + timedelta(minutes=i if minutes is None else minutes))


def _exchanges(n, start=0, parent="shorter ones", reply="Here are some shorter ones."):
    out = []
    for k in range(n):
        out += [_msg(start + 2 * k, "user", f"{parent} {k}"), _msg(start + 2 * k + 1, "assistant", f"{reply} {k}")]
    return out


# ---- the session --------------------------------------------------------

def test_a_main_chat_message_ends_the_youtube_session():
    rows = _exchanges(2) + [_msg(10, "user", "add a task", agent="chat"),
                            _msg(11, "assistant", "Sure", agent="chat")] + _exchanges(1, start=12, parent="dinosaurs")
    session = s.current_session(rows)
    assert [m.text for m in session] == ["dinosaurs 0", "Here are some shorter ones. 0"]


def test_a_long_pause_starts_a_fresh_session():
    rows = [_msg(0, "user", "volcano videos"), _msg(1, "assistant", "Here you go"),
            _msg(0, "user", "dinosaur videos", minutes=60 * 5)]
    assert [m.text for m in s.current_session(rows)] == ["dinosaur videos"]


def test_no_session_when_the_thread_ends_in_main_chat():
    rows = _exchanges(2) + [_msg(10, "user", "add a task", agent="chat")]
    assert s.current_session(rows) == []


# ---- the window ---------------------------------------------------------

def test_a_short_session_is_sent_whole():
    rows = _exchanges(3)
    assert [m["text"] for m in s.window(rows)] == [m.text for m in rows]


def test_the_floor_is_kept_however_long_the_messages_are():
    long = "x" * 4000  # ~1,000 tokens each: six of these are far over budget
    rows = _exchanges(5, parent=long, reply=long)
    sent = s.window(rows)
    # goal + note + the last three exchanges
    assert len(sent) == 2 + s.FLOOR_MESSAGES
    assert sent[1]["text"] == s.OMITTED


def test_short_messages_buy_more_memory_than_long_ones():
    short = s.window(_exchanges(40, parent="ok", reply="Done."))
    long = s.window(_exchanges(40, parent="y" * 400, reply="z" * 400))
    assert len(short) > len(long) >= s.FLOOR_MESSAGES


def test_the_goal_is_kept_after_it_leaves_the_window():
    rows = [_msg(0, "user", "Find calm nature videos for bedtime")] + _exchanges(60, start=1, parent="y" * 200)
    sent = s.window(rows)
    assert sent[0] == {"role": "user", "text": "Find calm nature videos for bedtime"}
    assert sent[1] == {"role": "model", "text": s.OMITTED}
    assert sent[2]["role"] == "user"
    assert sent[-1]["text"] == rows[-1].text


def test_what_is_sent_starts_with_the_parent_and_alternates():
    rows = _exchanges(60, parent="y" * 300)
    sent = s.window(rows)
    roles = [m["role"] for m in sent]
    assert roles[0] == "user"
    assert all(a != b for a, b in zip(roles, roles[1:]))


# ---- through the API ----------------------------------------------------

def _chat(client, c, text, agent="chat", conversation_id=None):
    body = {"text": text, "agent": agent}
    if conversation_id:
        body["conversation_id"] = conversation_id
    r = client.post(f"/children/{c.id}/chat", headers=auth("pa"), json=body)
    assert r.status_code == 200, r.text
    return r.json()


def _install_agent(monkeypatch, respond):
    mod = types.ModuleType("youtube_agent")
    mod.respond = respond
    monkeypatch.setitem(sys.modules, "youtube_agent", mod)


def test_without_the_agent_built_youtube_turns_say_so(client, db_session, monkeypatch):
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    monkeypatch.setitem(sys.modules, "youtube_agent", None)  # import fails like a missing package
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    body = _chat(client, c, "dinosaur videos", agent="youtube")
    assert body["agent"] == "youtube"
    assert body["text"] == chat_router.YOUTUBE_NOT_READY


def test_each_assistant_only_sees_its_own_messages(client, db_session, monkeypatch):
    seen = {}

    async def _main(system_prompt, messages, tools=None):
        seen["chat"] = [m["text"] for m in messages]
        return "ok", None

    async def _youtube(db, child, context, now):
        seen["youtube"] = [m["text"] for m in context.messages]
        return [("Here are 3 dinosaur videos.", "youtube_proposal", {"videos": "[]"})]

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    fake_chat_model(monkeypatch, _main)
    _install_agent(monkeypatch, _youtube)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)

    conv = _chat(client, c, "add homework at 4 tomorrow")["conversation_id"]
    yt = _chat(client, c, "dinosaur videos", agent="youtube", conversation_id=conv)
    assert yt["agent"] == "youtube" and yt["tool_call"] == "youtube_proposal"
    assert seen["youtube"] == ["dinosaur videos"]

    _chat(client, c, "and tidy her room on saturday", conversation_id=conv)
    assert "dinosaur videos" not in seen["chat"]
    assert "Here are 3 dinosaur videos." not in seen["chat"]
    assert seen["chat"][0] == "add homework at 4 tomorrow"

    # Back to YouTube after main chat: a fresh session.
    _chat(client, c, "space videos", agent="youtube", conversation_id=conv)
    assert seen["youtube"] == ["space videos"]

    # The parent sees everything, in order, labelled by assistant.
    shown = client.get(f"/conversations/{conv}/messages", headers=auth("pa")).json()
    assert [m["agent"] for m in shown] == ["chat", "chat", "youtube", "youtube", "chat", "chat", "youtube", "youtube"]


def test_the_latest_card_is_given_even_after_it_leaves_the_window(client, db_session, monkeypatch):
    got = {}

    async def _youtube(db, child, context, now):
        got["card"] = context.latest_card
        got["length"] = context.session_length
        return [("Okay.", None, None)]

    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    _install_agent(monkeypatch, _youtube)
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    conv = models.ChatConversation(child_id=c.id, parent_id=p.id, title="videos")
    db_session.add(conv)
    db_session.flush()
    db_session.add_all([
        models.ChatMessage(child_id=c.id, conversation_id=conv.id, role="user", text="dinosaur videos",
                           agent="youtube", created_at=datetime.now(timezone.utc) - timedelta(minutes=30)),
        models.ChatMessage(child_id=c.id, conversation_id=conv.id, role="assistant", text="Here are three.",
                           agent="youtube", tool_call="youtube_proposal", tool_args={"videos": "[1,2,3]"},
                           created_at=datetime.now(timezone.utc) - timedelta(minutes=29)),
    ] + [models.ChatMessage(child_id=c.id, conversation_id=conv.id, role="user" if i % 2 == 0 else "assistant",
                            text="w" * 2000, agent="youtube",
                            created_at=datetime.now(timezone.utc) - timedelta(minutes=28 - i)) for i in range(20)])
    db_session.commit()

    _chat(client, c, "the second one is perfect", agent="youtube", conversation_id=str(conv.id))
    assert got["card"] == ("youtube_proposal", {"videos": "[1,2,3]"})
    assert got["length"] == 23


def test_youtube_turns_do_not_feed_chats_long_term_memory(client, db_session, monkeypatch):
    calls = []
    import memory

    async def _record(*args, **kwargs):
        calls.append(args)
        return 0

    monkeypatch.setattr(memory, "extract_memories", _record)
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    _install_agent(monkeypatch, lambda *a: _async([("Here you go.", None, None)]))
    p = make_parent(db_session, "pa")
    c = make_child(db_session, p)
    _chat(client, c, "Mia loves dinosaurs, find videos", agent="youtube")
    assert calls == []


async def _async(value):
    return value
