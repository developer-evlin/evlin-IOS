"""The chat agent drafting app blocks: by time, one card per app, matched to
Evlin's catalog. Nothing is blocked until the parent taps Block."""
from datetime import datetime, timedelta, timezone

import pytest

import app_catalog
import models
import routers.chat as chat_router
from gemini_client import FunctionCall
from tests.conftest import auth, fake_chat_model, make_child, make_parent


@pytest.fixture
def mia(db_session, monkeypatch):
    app_catalog.seed(db_session)
    monkeypatch.setattr(chat_router, "gemini_configured", lambda: True)
    p = make_parent(db_session, "pa")
    return make_child(db_session, p, name="Mia")


def _model(*calls):
    async def _fake(system_prompt, messages, tools=None):
        return None, list(calls)
    return _fake


def _send(client, child, text, **extra):
    r = client.post(f"/children/{child.id}/chat", headers=auth("pa"), json={"text": text, **extra})
    assert r.status_code == 200, r.text
    return r.json()


def _app(db_session, name):
    return db_session.query(models.App).filter(models.App.name == name).one()


def test_a_nickname_becomes_the_catalog_app_on_a_card(client, db_session, monkeypatch, mia):
    fake_chat_model(monkeypatch, _model(FunctionCall("draft_app_block", {
        "app": "yt", "length": "rest_of_today",
        "reason": "Blocking YouTube for the rest of today, since it's nearly bedtime."})))
    body = _send(client, mia, "no more yt tonight")

    assert body["tool_call"] == "draft_app_block"
    args = body["tool_args"]
    assert args["app_id"] == str(_app(db_session, "YouTube").id)
    assert args["app_name"] == "YouTube"
    assert args["length"] == "rest_of_today"
    assert args["on_list"] == "False"   # Block adds it to Mia's list
    # The model's own reason introduces the card.
    assert body["text"] == "Blocking YouTube for the rest of today, since it's nearly bedtime."
    # Drafted, not done.
    assert db_session.query(models.AppBlock).count() == 0


def test_an_app_not_in_the_catalog_is_asked_about_not_guessed(client, monkeypatch, mia):
    fake_chat_model(monkeypatch, _model(FunctionCall("draft_app_block", {"app": "Wizzle", "length": "1_hour"})))
    body = _send(client, mia, "block wizzle")
    assert body["tool_call"] == "ask_follow_up"
    assert "couldn't find “Wizzle”" in body["text"]


def test_no_app_named_means_a_question(client, monkeypatch, mia):
    fake_chat_model(monkeypatch, _model(FunctionCall("draft_app_block", {"app": "", "length": "1_hour"})))
    body = _send(client, mia, "block something")
    assert body["text"] == "Which app should I block for Mia?"


def test_an_app_already_blocked_isnt_blocked_twice(client, db_session, monkeypatch, mia):
    yt = _app(db_session, "YouTube")
    db_session.add(models.AppBlock(child_id=mia.id, app_id=yt.id, app_name="YouTube", block_type="indefinite"))
    db_session.commit()
    fake_chat_model(monkeypatch, _model(FunctionCall("draft_app_block", {"app": "YouTube", "length": "1_hour"})))
    body = _send(client, mia, "block youtube")
    assert body["tool_call"] == "ask_follow_up"
    assert body["text"].startswith("YouTube is already blocked for Mia")


def test_several_apps_are_one_card_each(client, db_session, monkeypatch, mia):
    fake_chat_model(monkeypatch, _model(
        FunctionCall("draft_app_block", {"app": "TikTok", "length": "1_hour", "reason": "TikTok for an hour."}),
        FunctionCall("draft_app_block", {"app": "Roblox", "length": "30_minutes", "reason": "Roblox for half an hour."}),
    ))
    body = _send(client, mia, "block tiktok and roblox for a bit")
    assert body["tool_args"]["app_name"] == "TikTok"
    assert [m["tool_args"]["app_name"] for m in body["extra_messages"]] == ["Roblox"]
    # Each card keeps its own reason; nothing canned in between.
    assert body["text"] == "TikTok for an hour."
    assert body["extra_messages"][0]["text"] == "Roblox for half an hour."


def test_lengths_are_settled_before_the_card(client, monkeypatch, mia):
    fake_chat_model(monkeypatch, _model(
        FunctionCall("draft_app_block", {"app": "Fortnite", "length": "custom", "minutes": 2}),
        FunctionCall("draft_app_block", {"app": "Minecraft", "length": "until_homework"}),
    ))
    body = _send(client, mia, "fortnite briefly, minecraft until homework")
    assert body["tool_args"]["minutes"] == "5"           # at least 5 minutes
    extra = body["extra_messages"][0]["tool_args"]
    assert extra["length"] == "1_hour"                    # never tied to a task
    assert "minutes" not in extra


def test_the_block_tile_asks_which_app_without_the_model(client, monkeypatch, mia):
    called = []

    async def _never(*a, **k):
        called.append(1)
        return "x", None

    fake_chat_model(monkeypatch, _never)
    body = _send(client, mia, "Block an app for Mia", shortcut="block_app")
    assert called == []
    assert body["text"] == "Which app should I block for Mia, and for how long?"


def test_the_agent_knows_the_list_and_what_is_blocked(client, db_session, monkeypatch, mia):
    yt, roblox = _app(db_session, "YouTube"), _app(db_session, "Roblox")
    db_session.add(models.ChildApp(child_id=mia.id, app_id=roblox.id))
    db_session.add(models.AppBlock(child_id=mia.id, app_id=yt.id, app_name="YouTube", block_type="duration",
                                   ends_at=datetime.now(timezone.utc) + timedelta(minutes=40)))
    db_session.commit()
    captured = {}

    async def _capture(system_prompt, messages, tools=None):
        captured["prompt"] = system_prompt
        return "ok", None

    fake_chat_model(monkeypatch, _capture)
    _send(client, mia, "what's blocked?")
    assert "Apps on Mia's list: Roblox." in captured["prompt"]
    assert "Blocked right now: YouTube:" in captured["prompt"]
