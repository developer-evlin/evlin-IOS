from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from sqlalchemy.orm import Session
from uuid import UUID
from datetime import date, datetime, timedelta, timezone
import models, schemas
from database import get_db
from routers.auth import get_current_parent
from access import assert_parent_owns_child
from blocks import local_now
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
from gemini_client import generate_all, gemini_configured, FunctionCall
import tool_calls

router = APIRouter(tags=["chat"])

# The tools, their replies and which ones speak for themselves all live in
# tool_calls/ — see its README for the list. The model never writes: each
# tool pre-fills a card or asks a question, and the parent's tap creates.
_TOOLS = tool_calls.TOOLS

# How many of a thread's messages the model is sent, newest first. Parent's
# and assistant's both count; the current message is one of them.
HISTORY_WINDOW = 50


def _stringify_tool_args(args: dict | None) -> dict:
    """Every tool arg is persisted as a string.

    The iOS client decodes tool_args as [String: String] (APIModels.swift),
    so a single numeric value — which Gemini returns as a JSON number for
    any numeric parameter — fails the decode of the *entire* ChatMessage,
    taking the whole transcript with it, not just that one card. Coercing
    here keeps that contract true no matter what a tool's schema declares.
    """
    out = {}
    for k, v in (args or {}).items():
        if v is None:
            out[k] = ""
        elif isinstance(v, (list, tuple)):
            # Joined rather than str()'d, so the client gets something it can
            # split instead of a Python repr with brackets and quotes in it.
            out[k] = "\n".join(str(x) for x in v)
        else:
            out[k] = str(v)
    return out


def _system_prompt(child: models.Child, tasks: list[models.Task], occurrences: list[models.Occurrence],
                   rule: models.ChildRule | None, memories: list | None = None,
                   now: datetime | None = None, completed: list | None = None,
                   apps: list[str] | None = None, blocked: list[str] | None = None) -> str:
    today_occ_by_task = {o.task_id: o for o in occurrences}
    lines = [f"You are Evlin, a parental-control assistant helping a parent manage {child.name}'s tasks and screen time."]
    # Without this the model resolves "tomorrow at 6pm" against its training
    # cutoff — i.e. guesses. Most of what a parent says about scheduling is
    # relative, so every date it produces was unreliable until this was here.
    # The child's clock, not the server's: on Render that's UTC, which is
    # already tomorrow for a Pacific family every evening after 5pm.
    now = now or local_now(child)
    today = now.date()
    tomorrow = today + timedelta(days=1)
    lines.append(
        f"\nToday is {today:%A, %-d %B %Y} ({today.isoformat()}) and it's {now:%H:%M} where {child.name} is. "
        f"Tomorrow is {tomorrow:%A} ({tomorrow.isoformat()}). "
        "Resolve any relative date the parent uses against these, and emit real calendar dates."
    )
    # Listed from _TOOLS rather than restated in prose, so the prompt can't
    # drift into describing a tool set the model wasn't actually given.
    tool_names = " or ".join(t["name"] for t in _TOOLS)
    lines.append(f"You can have a normal conversation, or call one of the tools you're given — {tool_names}.")
    lines.append("If the parent asks for several things in one message, call the tool once for each of them, "
                  "all in the same reply. Never pick a day or time the parent didn't give: if you'd have to "
                  "guess when, call ask_follow_up and ask.")
    # One chat is about one child, so there's nothing to ask about whose a
    # task is. Evlin has no calendar: events and appointments aren't kept.
    lines.append(f"Everything you draft is for {child.name}. Don't ask who it's for. Evlin has no calendar: "
                  "if the parent wants to add an event or appointment, say in one sentence that Evlin keeps tasks, "
                  "not a calendar, and offer a task instead only if it's something the child does.")
    lines.append("Never claim you created a task — you draft it, and the parent confirms. "
                  "If asked for something you have no tool for — a bedtime/downtime rule, or extra screen time (both in "
                  "the child's profile) — say plainly that you can't do that and where in the app it's done, rather than "
                  "pretending it's done.")
    # Blocking: what the child's phone can block and what already is, so the
    # agent names a real app and doesn't block one twice.
    if apps is not None:
        lines.append(f"Apps on {child.name}'s list: {', '.join(apps) if apps else 'none yet'}. "
                      "Any app in Evlin's catalog can be blocked; Block adds it to the list.")
    if blocked:
        lines.append(f"Blocked right now: {'; '.join(blocked)}.")
    # Videos are lessons in the kid's Library, not something this assistant
    # finds or picks, so it says so rather than half-answering.
    lines.append(f"Choosing YouTube videos for {child.name} isn't done in this chat. If the parent asks about videos, "
                  "say so in one sentence; never suggest or name specific videos or channels yourself.")
    # The chat shows replies as plain text, so a markdown list with bold
    # labels reads as a wall. The app already lists what Evlin can do, with
    # icons, behind the ? button.
    # Emoji the way Notion's assistant uses them: one that says what's
    # happening, and beside each task's name, never as decoration. A task
    # drafted with draft_task carries its own emoji for the child's phone.
    lines.append("Write with emoji the way Notion's assistant does: start each reply with one emoji that says what "
                  "you're doing (📝 drafting a task, ⛔ blocking an app, ❓ asking, 💡 suggesting), and put a task's emoji "
                  "beside its name when you mention it. One or two per reply, never a row of them, never mid-word. "
                  "Every draft_task gets an emoji for the child's phone: the most specific one for the task.")
    lines.append("Keep replies short and conversational: one to three sentences, no bullet lists, headings or bold labels. "
                  "If asked what you can do, say in one sentence that you draft tasks and app blocks "
                  "for the parent to confirm, and that the ? button at the top of the chat lists everything.")
    # Suggesting something to do: a real habit a parent can check, built on
    # what the child already does. The tile has its own faster path
    # (_suggest_activities); this covers asking in your own words.
    age = _age(child, today)
    if age is not None:
        lines.append(f"\n{child.name} is about {age} years old.")
    lines.append(ACTIVITY_RULE.format(name=child.name))
    lines.append(TASK_RULE.format(name=child.name,
                                  age=f"a {age}-year-old" if age is not None else "the child's age"))
    if completed:
        lines.append(f"{child.name} already does: {', '.join(completed)}.")

    lines.append(f"\nToday's real tasks for {child.name}:")
    if tasks:
        for t in tasks:
            occ = today_occ_by_task.get(t.id)
            status = occ.status if occ else "not scheduled today"
            lines.append(f"- {t.title} ({status})")
    else:
        lines.append("- (none yet)")
    if rule:
        lines.append(f"\nDaily screen time limit: {rule.daily_limit_minutes} minutes.")
        if rule.downtime_enabled:
            days = ", ".join(rule.downtime_days) if rule.downtime_days else "every day"
            if rule.downtime_schedule:
                hours = "; ".join(f"{d} {s['start']}–{s['end']}" for d, s in rule.downtime_schedule.items())
                lines.append(f"Downtime, by day: {hours}.")
            else:
                lines.append(f"Downtime: {rule.downtime_start}–{rule.downtime_end}, {days}.")

    # Everything above is current state, queried live. This is the only part
    # that's remembered rather than looked up, so it's labelled as such —
    # the model shouldn't treat a months-old note as today's truth.
    if memories:
        lines.append(f"\nThings you've learned about {child.name} in past conversations:")
        for m in memories:
            lines.append(f"- {m.fact}")
        lines.append("Treat these as background, not as current settings — rules and tasks above are authoritative.")
    return "\n".join(lines)


def _chat_now(child: models.Child, parent_zone: str | None) -> datetime:
    """Now, for resolving "today" and "tomorrow" in chat.

    The child's zone when their device has reported one, as everywhere else.
    Before that, the zone of the parent's phone sending the message: without
    it the server fell back to UTC, which is already tomorrow for a family
    in California every evening, so "today" landed a day late.
    """
    if child.timezone:
        return local_now(child)
    if parent_zone:
        try:
            return datetime.now(timezone.utc).astimezone(ZoneInfo(parent_zone))
        except (ZoneInfoNotFoundError, ValueError):
            pass
    return local_now(child)


def _get_conversation_for_parent(db: Session, parent: models.Parent,
                                 conversation_id: UUID) -> models.ChatConversation:
    conversation = db.query(models.ChatConversation).filter(
        models.ChatConversation.id == conversation_id
    ).first()
    if not conversation:
        raise HTTPException(status_code=404, detail="Conversation not found")
    assert_parent_owns_child(db, parent, conversation.child_id)
    return conversation


def _title_from(text: str) -> str:
    """A thread's name, taken from what was actually asked.

    Deterministic rather than a second Gemini call: titling every new thread
    with the model would add latency and cost to the first message of every
    conversation for something a trim does well enough.
    """
    cleaned = " ".join(text.split())
    return cleaned[:40].rstrip() + "…" if len(cleaned) > 40 else (cleaned or "New chat")


@router.get("/children/{child_id}/conversations", response_model=list[schemas.ChatConversationResponse])
def list_conversations(child_id: UUID, current_parent: models.Parent = Depends(get_current_parent),
                       db: Session = Depends(get_db)):
    """Most recently active first — what the sidebar orders by."""
    assert_parent_owns_child(db, current_parent, child_id)
    return db.query(models.ChatConversation).filter(
        models.ChatConversation.child_id == child_id
    ).order_by(models.ChatConversation.updated_at.desc()).all()


@router.get("/conversations/{conversation_id}/messages", response_model=list[schemas.ChatMessageResponse])
def get_conversation_messages(conversation_id: UUID,
                              current_parent: models.Parent = Depends(get_current_parent),
                              db: Session = Depends(get_db)):
    _get_conversation_for_parent(db, current_parent, conversation_id)
    return db.query(models.ChatMessage).filter(
        models.ChatMessage.conversation_id == conversation_id
    ).order_by(models.ChatMessage.created_at).all()


@router.put("/conversations/{conversation_id}", response_model=schemas.ChatConversationResponse)
def rename_conversation(conversation_id: UUID, body: schemas.ChatConversationRename,
                        current_parent: models.Parent = Depends(get_current_parent),
                        db: Session = Depends(get_db)):
    conversation = _get_conversation_for_parent(db, current_parent, conversation_id)
    conversation.title = body.title
    db.commit()
    db.refresh(conversation)
    return conversation


@router.delete("/conversations/{conversation_id}")
def delete_conversation(conversation_id: UUID,
                        current_parent: models.Parent = Depends(get_current_parent),
                        db: Session = Depends(get_db)):
    conversation = _get_conversation_for_parent(db, current_parent, conversation_id)
    # Before the messages go, while the facts can still be traced back to
    # them: deleting a thread has to unlearn what was learned from it, or
    # the transcript disappears and the assistant keeps quoting it.
    from memory import forget_from_conversation
    forget_from_conversation(db, conversation_id)
    # Messages go with it via ON DELETE CASCADE in Postgres; deleted here
    # explicitly too because SQLite (the test harness) doesn't enforce it.
    db.query(models.ChatMessage).filter(
        models.ChatMessage.conversation_id == conversation_id
    ).delete(synchronize_session=False)
    db.delete(conversation)
    db.commit()
    return {"detail": "Conversation deleted"}


@router.get("/children/{child_id}/chat", response_model=list[schemas.ChatMessageResponse])
def get_chat_history(child_id: UUID, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """The most recent thread — what the app opens on.

    Still keyed by child rather than conversation so an older client that
    doesn't know about threads keeps working; it just sees the latest one.
    """
    assert_parent_owns_child(db, current_parent, child_id)
    latest = db.query(models.ChatConversation).filter(
        models.ChatConversation.child_id == child_id
    ).order_by(models.ChatConversation.updated_at.desc()).first()
    if latest is None:
        return []
    return db.query(models.ChatMessage).filter(
        models.ChatMessage.conversation_id == latest.id
    ).order_by(models.ChatMessage.created_at).all()


@router.post("/children/{child_id}/chat", response_model=schemas.ChatSendResponse)
async def send_chat_message(
    child_id: UUID,
    body: schemas.ChatSendRequest,
    background: BackgroundTasks,
    current_parent: models.Parent = Depends(get_current_parent),
    db: Session = Depends(get_db),
):
    assert_parent_owns_child(db, current_parent, child_id)
    if not gemini_configured():
        raise HTTPException(status_code=503, detail="Chat isn't configured yet (no GEMINI_API_KEY)")

    child = db.query(models.Child).filter(models.Child.id == child_id).first()
    if not child:
        raise HTTPException(status_code=404, detail="Child not found")

    conversation = None
    if body.conversation_id is not None:
        conversation = _get_conversation_for_parent(db, current_parent, body.conversation_id)
    elif not body.new_conversation:
        # Fall back to the running thread. This is what keeps a client that
        # predates threading working unchanged — without it, every message
        # from such a client would start its own thread and the assistant
        # would forget the previous turn.
        conversation = db.query(models.ChatConversation).filter(
            models.ChatConversation.child_id == child_id
        ).order_by(models.ChatConversation.updated_at.desc()).first()

    if conversation is None:
        # Created on the first message rather than when the client taps New
        # chat, so a stray tap doesn't leave an empty thread behind.
        conversation = models.ChatConversation(
            child_id=child_id, parent_id=current_parent.id, title=_title_from(body.text),
        )
        db.add(conversation)
        db.flush()

    db.add(models.ChatMessage(child_id=child_id, conversation_id=conversation.id,
                              parent_id=current_parent.id, role="user", text=body.text,
                              agent=body.agent))
    conversation.updated_at = datetime.now(timezone.utc)
    db.commit()

    now = _chat_now(child, body.timezone)
    if body.shortcut == "suggest_activity" and body.agent == "chat":
        return await _suggest_activities(db, child, conversation, now)
    if body.shortcut and body.agent == "chat":
        return _shortcut_reply(db, child, conversation, body.shortcut)

    tasks = db.query(models.Task).filter(models.Task.child_id == child_id, models.Task.active == True).all()  # noqa: E712
    occurrences = db.query(models.Occurrence).filter(
        models.Occurrence.child_id == child_id, models.Occurrence.due_date == now.date()
    ).all()
    rule = db.query(models.ChildRule).filter(models.ChildRule.child_id == child_id).first()
    completed = _done_lately(db, child_id, now)

    # Scoped to this thread, not the child: sending every message the child
    # ever generated would make separate threads share context, defeating
    # the point of having them. And only the newest HISTORY_WINDOW of it.
    # The whole thread is resent on every message, so without a window a
    # month in one thread costs in proportion to its length squared. The
    # parent still sees the whole thread; the model sees the recent part,
    # and anything durable from before it reaches the model as memory.
    newest_first = db.query(models.ChatMessage).filter(
        models.ChatMessage.conversation_id == conversation.id,
        models.ChatMessage.agent == "chat",  # the YouTube agent's turns are its own
        models.ChatMessage.text != "",  # a second card's row has no text
    ).order_by(models.ChatMessage.created_at.desc()).limit(HISTORY_WINDOW).all()
    messages = [{"role": "user" if r.role == "user" else "model", "text": r.text}
                for r in reversed(newest_first)]
    # A cut can land on an assistant reply; the conversation the model sees
    # should open with what the parent said.
    while messages and messages[0]["role"] != "user":
        messages.pop(0)

    from memory import facts_for
    memories = facts_for(db, child_id)
    try:
        apps, blocked = _app_context(db, child, now)
        text, calls = await generate_all(_system_prompt(child, tasks, occurrences, rule, memories, now, completed,
                                                        apps, blocked),
                                         messages, tools=_TOOLS)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Chat request failed: {e}")

    replies = await _replies(db, child, text, calls, now.date())
    rows = _store_replies(db, child, conversation, replies, "chat")

    # After the reply is on its way, so remembering costs the parent nothing
    # in latency. Runs on its own session — this one is closed by then.
    from memory import extract_memories
    background.add_task(
        extract_memories, child_id,
        [{"role": "parent", "text": body.text},
         {"role": "assistant", "text": rows[0].text}],
        rows[0].id,
    )
    return _send_response(rows)


# What a suggested activity has to be. Evlin is about doing real things:
# something a parent can check, that builds a habit. Without this the model
# offered "a LEGO build or a walk around the block".
ACTIVITY_RULE = (
    "When asked for an activity or something {name} can do instead of screen time, draft 2 or 3 tasks with "
    "draft_task: real habits a parent can check by eye or photo (chores, self-care, tidying, helping at home, "
    "pet or plant care, practice that leaves something to show). Never play, games, walks or screens. Build on "
    "what {name} already does without repeating it. Each repeats daily or on set weekdays. Keep it short: a "
    "title of 2 to 5 words naming the exact thing, never a vague one ('Fold and put away laundry', not 'Help "
    "with chores'; 'Wipe the kitchen table', not 'Clean up'), and instructions of at most 8 words saying what "
    "done looks like, or none if the title already says it. No explanation of why unless the parent asks."
)


# What any task has to be, and what to do with a request that doesn't say.
# "Add three tasks" used to come back as three invented ones; vague titles
# ("Be productive") gave a parent nothing to check.
TASK_RULE = (
    "Every task is a physical thing {name} does that a parent can check by eye or photo, sized for {age}: "
    "'Read 10 pages', 'Wipe the kitchen table', 'Make your bed', 'Practise piano 15 minutes'. Never vague or "
    "abstract ('Be productive', 'Learn something', 'Help out', 'Practise mindfulness'). If the parent asks for "
    "tasks without saying what kind ('add three tasks'), don't invent them: call ask_follow_up with one short "
    "question, like 'What kind: chores, reading, homework, or should I pick?'. If they're unsure or say you "
    "pick, draft that many chores that fit {age}, one card each, with titles of 2 to 5 words, repeating daily "
    "or on set weekdays unless they gave a day."
)


def _age(child: models.Child, today: date) -> int | None:
    return today.year - child.birth_year if getattr(child, "birth_year", None) else None


def _done_lately(db: Session, child_id, now: datetime, limit: int = 12) -> list[str]:
    """Names only, short: the child's active tasks and anything approved in
    the last 30 days, most recent first, without repeats."""
    approved = db.query(models.Task.title).join(
        models.Occurrence, models.Occurrence.task_id == models.Task.id
    ).filter(
        models.Occurrence.child_id == child_id,
        models.Occurrence.status == "approved",
        models.Occurrence.due_date >= now.date() - timedelta(days=30),
    ).order_by(models.Occurrence.due_date.desc()).limit(50).all()
    active = db.query(models.Task.title).filter(
        models.Task.child_id == child_id, models.Task.active == True,  # noqa: E712
    ).all()
    names: list[str] = []
    for (title,) in [*approved, *active]:
        t = (title or "").strip()
        if t and t.lower() not in {n.lower() for n in names}:
            names.append(t)
    return names[:limit]


async def _suggest_activities(db: Session, child: models.Child, conversation: models.ChatConversation,
                              now: datetime) -> schemas.ChatSendResponse:
    """The activity tile's fast path. One short prompt (name, age, the names
    of what the child already does, the rule) and one tool, instead of the
    whole chat prompt, thread and memory: it doesn't need them, and less to
    read is a quicker answer. The thread still records it, so a follow-up in
    chat sees what was suggested."""
    age = _age(child, now.date())
    done = _done_lately(db, child.id, now)
    prompt = (
        f"You suggest habits for {child.name}" + (f", age {age}" if age is not None else "") + ". "
        + ACTIVITY_RULE.format(name=child.name)
        + (f" {child.name} already does: {', '.join(done)}." if done else "")
    )
    draft_tool = next(t for t in _TOOLS if t["name"] == "draft_task")
    try:
        text, calls = await generate_all(prompt, [{"role": "user", "text": "Suggest something to do instead of screen time."}],
                                         tools=[draft_tool])
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Chat request failed: {e}")
    calls = [c for c in calls if c.name == "draft_task"][:3]
    replies = await _replies(db, child, text, calls, now.date()) if calls else [(text or "...", None, None)]
    if len(replies) > 1 and replies[0][1] == "draft_task":
        replies[0] = (f"A few habits that fit {child.name}:", replies[0][1], replies[0][2])
    return _send_response(_store_replies(db, child, conversation, replies, "chat"))


# What each tile shortcut asks. These are what the model asked anyway, every
# time, after 4-5 seconds: a tile's sentence never says what or when.
SHORTCUT_QUESTIONS = {
    "add_task": "What should {name} do, and when?",
    "block_app": "Which app should I block for {name}, and for how long?",
}


def _app_context(db: Session, child: models.Child, now: datetime) -> tuple[list[str], list[str]]:
    """The child's lockable apps by name, and what's blocked right now in
    the app's own words ("YouTube: for 40 more minutes")."""
    import blocks
    from routers.app_blocks import blocks_in_force
    from routers.apps import child_apps
    names = [a.name for a in child_apps(db, child.id)]
    by_id = {a.id: a.name for a in db.query(models.App).all()}
    blocked = [f"{by_id.get(b.app_id, 'an app')}: {blocks.describe(b, now)}" for b in blocks_in_force(db, child, now)]
    return names, blocked


def _shortcut_reply(db: Session, child: models.Child, conversation: models.ChatConversation,
                    shortcut: str) -> schemas.ChatSendResponse:
    """A tile's first question, without calling the model.

    Stored as an ordinary ask_follow_up, so the thread reads the same and the
    model sees the question when the parent answers it. No memory extraction:
    the tile's fixed sentence teaches nothing about the child.
    """
    question = SHORTCUT_QUESTIONS[shortcut].format(name=child.name)
    rows = _store_replies(db, child, conversation, [(question, "ask_follow_up", {"question": question})], "chat")
    return _send_response(rows)


def _store_replies(db: Session, child: models.Child, conversation: models.ChatConversation,
                   replies: list[tuple[str, str | None, dict | None]], agent: str) -> list[models.ChatMessage]:
    # Stamped here rather than left to the column default: Postgres's now()
    # is the transaction's start, so every card would share one timestamp
    # and come back from the history in no particular order.
    stamp = datetime.now(timezone.utc)
    rows = [models.ChatMessage(child_id=child.id, conversation_id=conversation.id, role="assistant",
                               text=reply_text, tool_call=name, agent=agent,
                               tool_args=_stringify_tool_args(args) if name else None,
                               created_at=stamp + timedelta(microseconds=i))
            for i, (reply_text, name, args) in enumerate(replies)]
    db.add_all(rows)
    conversation.updated_at = datetime.now(timezone.utc)
    db.commit()
    for row in rows:
        db.refresh(row)
    return rows


def _send_response(rows: list[models.ChatMessage]) -> schemas.ChatSendResponse:
    response = schemas.ChatSendResponse.model_validate(rows[0])
    response.extra_messages = [schemas.ChatMessageResponse.model_validate(r) for r in rows[1:]]
    return response


async def _replies(db: Session, child: models.Child, text: str | None, calls: list[FunctionCall],
                   today: date) -> list[tuple[str, str | None, dict | None]]:
    """What to store for one model reply: (text, tool name, args) per
    message, in order. Usually one; one per card when the parent asked for
    several things at once.

    A question wins over cards. If the model asked one, or any draft is
    missing something only the parent can say (when, mostly), the reply is
    that one question and no cards — half the request as cards and half as
    a question would leave the parent unsure what's been set up. The model
    redrafts everything from the parent's answer.
    """
    if not calls:
        return [(text or "...", None, None)]

    drafts, seen = [], set()
    for call in calls:
        args = dict(call.args or {})
        key = (call.name, repr(sorted(args.items())))
        if key in seen:  # the same card twice is the model repeating itself
            continue
        seen.add(key)
        if call.name in tool_calls.SPEAKS_FOR_ITSELF:
            question = (args.get("question") or "").strip() or tool_calls.DEFAULT_REPLY
            return [(question, call.name, args)]
        check = tool_calls.FOLLOW_UPS.get(call.name)
        question = check(args, child.name, today) if check else None
        resolve = tool_calls.RESOLVERS.get(call.name)
        if not question and resolve is not None:
            question = resolve(db, child, args)
        if question:
            return [(question, "ask_follow_up", {"question": question})]
        drafts.append((call.name, args))

    out = []
    for name, args in drafts:
        said = str(args.get(tool_calls.REPLY_ARGS.get(name, "")) or "").strip()
        out.append((said or tool_calls.REPLIES.get(name, tool_calls.DEFAULT_REPLY), name, args))

    if len(out) > 1:
        # One line above the cards, not the same canned line repeated under
        # each.
        canned = set(tool_calls.REPLIES.values()) | {tool_calls.DEFAULT_REPLY}
        out = [(t if t not in canned else "", n, a) for t, n, a in out]
        if not out[0][0]:
            out[0] = (f"Here are {len(out)} things to add — check each one before you add it.",
                      out[0][1], out[0][2])
    return out
