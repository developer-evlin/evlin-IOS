from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from sqlalchemy.orm import Session
from uuid import UUID
from datetime import date, datetime, timedelta, timezone
import models, schemas
from database import get_db
from routers.auth import get_current_parent
from access import assert_parent_owns_child
from gemini_client import generate, gemini_configured, FunctionCall

router = APIRouter(tags=["chat"])

# The model never writes directly — it can only propose opening one of the
# app's existing confirm-and-submit cards (AddTaskCard / BlockAppCard). The
# parent still explicitly taps Create/Block on the card itself, same as
# today. This keeps the blast radius of a misunderstood request at "wrong
# pre-filled draft shown," never "wrong action taken" — a parental-control
# app is exactly the wrong place for an LLM tool call to silently create a
# task or block an app with no human in the loop.
_TOOLS = [
    {
        "name": "draft_task",
        "description": (
            "Pre-fill the app's Add Task card for the parent to review and confirm — does not create the task "
            "itself. Work out the concrete date, time and recurrence from what the parent said; the card is "
            "meant to arrive correct, not to be filled in by hand afterwards."
        ),
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "title": {"type": "STRING", "description": "Short task title, e.g. 'Tidy his room'"},
                "instructions": {"type": "STRING", "description": "What to actually do, if the parent said. Empty otherwise."},
                "due_date": {"type": "STRING", "description": "Resolved calendar date as YYYY-MM-DD. Empty if no specific day."},
                "due_time": {"type": "STRING", "description": "24-hour HH:MM. Empty if no specific time."},
                "recurrence": {
                    "type": "STRING",
                    "description": (
                        "'none' for a one-off, 'daily', or comma-joined weekday codes from "
                        "mon,tue,wed,thu,fri,sat,sun — e.g. 'mon,wed,fri' or 'sat,sun'. Nothing else."
                    ),
                },
                "gates_apps": {"type": "BOOLEAN", "description": "Whether not doing it should keep apps locked. Default true."},
                "bonus_minutes": {"type": "INTEGER", "description": "Extra screen-time minutes for finishing it, 0 if the parent didn't say."},
            },
            "required": ["title"],
        },
    },
    {
        "name": "ask_follow_up",
        "description": (
            "Ask the parent for one thing you need before you can draft something. Use this when a request "
            "doesn't say what the task or event actually is, or when a detail you'd otherwise have to invent "
            "is missing. A drafted card with a made-up title is worse than a question."
        ),
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "question": {"type": "STRING", "description": "One short question. Ask for a single thing, not several."},
            },
            "required": ["question"],
        },
    },
    {
        "name": "draft_event",
        "description": (
            "Pre-fill the app's Add Event card for a calendar entry — practice, an appointment, a trip. Use "
            "this for something that happens at a time, not something the child has to do and get approved "
            "(that's draft_task). Does not create the event itself."
        ),
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "title": {"type": "STRING", "description": "Short event title, e.g. 'Football practice'"},
                "start_date": {"type": "STRING", "description": "Resolved calendar date as YYYY-MM-DD"},
                "start_time": {"type": "STRING", "description": "24-hour HH:MM"},
                "end_time": {"type": "STRING", "description": "24-hour HH:MM. Assume an hour if the parent didn't say."},
                "recurrence": {
                    "type": "STRING",
                    "description": (
                        "'none', 'daily', or comma-joined weekday codes from mon,tue,wed,thu,fri,sat,sun. "
                        "Nothing else."
                    ),
                },
                "is_family": {"type": "BOOLEAN", "description": "True for a whole-family event, false when it's this child's own."},
                "note": {"type": "STRING", "description": "Anything else worth recording, or empty."},
            },
            "required": ["title", "start_date", "start_time"],
        },
    },
    {
        "name": "open_block_picker",
        "description": "Open the app's Block an App picker for the parent to choose which app and duration — does not block anything itself.",
        "parameters": {"type": "OBJECT", "properties": {}},
    },
    {
        "name": "propose_reflection",
        "description": (
            "Suggest the child be given a reflection — a video to watch plus questions to answer, which locks "
            "the device until it's done. Opens the reflection card for the parent to fill in and confirm; "
            "does not assign anything."
        ),
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "title": {"type": "STRING", "description": "What the reflection is about"},
                "reason": {"type": "STRING", "description": "Why this is being suggested now"},
            },
            "required": ["title"],
        },
    },
    {
        "name": "generate_course",
        "description": (
            "Search YouTube and assemble a vetted, ordered course on a topic, for the parent to review and "
            "approve. Nothing reaches the child until they approve it."
        ),
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "topic": {"type": "STRING", "description": "What the course should teach"},
                "video_count": {"type": "INTEGER", "description": "How many videos, 1-10. Default 4."},
            },
            "required": ["topic"],
        },
    },
    {
        "name": "draft_special_task",
        "description": (
            "Draft a task the child completes by watching a vetted course and answering its quizzes, earning "
            "bonus screen time. Builds the course and opens the card for the parent to confirm; creates nothing."
        ),
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "title": {"type": "STRING", "description": "Short task title"},
                "topic": {"type": "STRING", "description": "What the course should teach"},
                "bonus_minutes": {"type": "INTEGER", "description": "Screen-time minutes earned, 0 if none"},
                "video_count": {"type": "INTEGER", "description": "How many videos, 1-10. Default 3."},
            },
            "required": ["title", "topic"],
        },
    },
]

# What the assistant says while the card it just opened does the rest. Keyed
# by tool name rather than an if/else so adding a tool can't silently answer
# with another tool's line.
_TOOL_REPLIES = {
    "draft_task": "Sure — let's set that up.",
    "draft_event": "Here's the event — check the details before you add it.",
    "open_block_picker": "Sure — which app should I block?",
    "propose_reflection": "Good idea — here's a reflection to set up.",
    "generate_course": "I found some videos — have a look before I send them over.",
    "draft_special_task": "Here's a task built around a course — check the videos before you create it.",
}
_DEFAULT_TOOL_REPLY = "Sure — let's set that up."

# ask_follow_up carries its own text: the question the model wrote is the
# message, so a canned line in front of it would just be noise.
_TOOLS_THAT_SPEAK_FOR_THEMSELVES = {"ask_follow_up"}

# Tools whose handler does real work server-side before replying (searching
# YouTube, running a vetting pass) rather than just signalling the client to
# open a card. Kept apart because they're slow and can fail for reasons the
# parent needs told about.
_COURSE_BUILDING_TOOLS = ("generate_course", "draft_special_task")


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


async def _build_course_for_tool(db: Session, child: models.Child, tool_name: str,
                                 args: dict, parent: models.Parent) -> dict:
    """Run the real search-and-vet pipeline for a course-building tool call.

    The course is saved as a draft (pending_review) and its id handed back on
    the chat message, so the card the parent sees is backed by real, checked
    videos rather than titles the model made up. Approving the card — or
    creating the task from it — is what publishes it.
    """
    from routers.courses import generate_and_vet_course

    default_count = 3 if tool_name == "draft_special_task" else 4
    try:
        video_count = int(args.get("video_count") or default_count)
    except (TypeError, ValueError):
        video_count = default_count
    video_count = max(1, min(video_count, 10))

    topic = (args.get("topic") or args.get("title") or "").strip()
    course = await generate_and_vet_course(
        db, topic, video_count=video_count, child=child,
        created_by_parent_id=parent.id,
    )
    db.commit()
    db.refresh(course)

    args["course_id"] = str(course.id)
    args["course_title"] = course.title
    return args


def _system_prompt(child: models.Child, tasks: list[models.Task], occurrences: list[models.Occurrence],
                   rule: models.ChildRule | None, memories: list | None = None) -> str:
    today_occ_by_task = {o.task_id: o for o in occurrences}
    lines = [f"You are Evlin, a parental-control assistant helping a parent manage {child.name}'s tasks and screen time."]
    # Without this the model resolves "tomorrow at 6pm" against its training
    # cutoff — i.e. guesses. Most of what a parent says about scheduling is
    # relative, so every date it produces was unreliable until this was here.
    today = date.today()
    tomorrow = today + timedelta(days=1)
    lines.append(
        f"\nToday is {today:%A, %-d %B %Y} ({today.isoformat()}). "
        f"Tomorrow is {tomorrow:%A} ({tomorrow.isoformat()}). "
        "Resolve any relative date the parent uses against these, and emit real calendar dates."
    )
    # Listed from _TOOLS rather than restated in prose, so the prompt can't
    # drift into describing a tool set the model wasn't actually given.
    tool_names = " or ".join(t["name"] for t in _TOOLS)
    lines.append(f"You can have a normal conversation, or call one of the tools you're given — {tool_names}.")
    lines.append("Never claim you created a task, blocked an app, changed a rule, or granted time — you can't do any of that directly. "
                  "If asked for something you have no tool for (a bedtime/downtime rule, adding a calendar event, granting extra screen "
                  "time), say plainly that you can't do that yet and suggest where in the app to do it, rather than pretending it's done.")
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
            lines.append(f"Downtime: {rule.downtime_start}–{rule.downtime_end}.")

    # Everything above is current state, queried live. This is the only part
    # that's remembered rather than looked up, so it's labelled as such —
    # the model shouldn't treat a months-old note as today's truth.
    if memories:
        lines.append(f"\nThings you've learned about {child.name} in past conversations:")
        for m in memories:
            lines.append(f"- {m.fact}")
        lines.append("Treat these as background, not as current settings — rules and tasks above are authoritative.")
    return "\n".join(lines)


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


@router.post("/children/{child_id}/chat", response_model=schemas.ChatMessageResponse)
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

    user_row = models.ChatMessage(child_id=child_id, conversation_id=conversation.id,
                                  parent_id=current_parent.id, role="user", text=body.text)
    db.add(user_row)
    conversation.updated_at = datetime.now(timezone.utc)
    db.commit()

    tasks = db.query(models.Task).filter(models.Task.child_id == child_id, models.Task.active == True).all()  # noqa: E712
    occurrences = db.query(models.Occurrence).filter(
        models.Occurrence.child_id == child_id, models.Occurrence.due_date == date.today()
    ).all()
    rule = db.query(models.ChildRule).filter(models.ChildRule.child_id == child_id).first()

    # Scoped to this thread, not the child. Sending every message the child
    # ever generated would make separate threads share context — defeating
    # the point of having them — and grow the prompt without bound.
    history_rows = db.query(models.ChatMessage).filter(
        models.ChatMessage.conversation_id == conversation.id
    ).order_by(models.ChatMessage.created_at).all()
    messages = [{"role": "user" if r.role == "user" else "model", "text": r.text} for r in history_rows if r.text]

    from routers.memory import facts_for
    memories = facts_for(db, child_id)

    try:
        text, call = await generate(_system_prompt(child, tasks, occurrences, rule, memories),
                                     messages, tools=_TOOLS)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Chat request failed: {e}")

    if isinstance(call, FunctionCall):
        args = dict(call.args)
        if call.name in _COURSE_BUILDING_TOOLS:
            args = await _build_course_for_tool(db, child, call.name, args, current_parent)
        if call.name in _TOOLS_THAT_SPEAK_FOR_THEMSELVES:
            reply_text = (args.get("question") or "").strip() or _DEFAULT_TOOL_REPLY
        else:
            reply_text = _TOOL_REPLIES.get(call.name, _DEFAULT_TOOL_REPLY)
        assistant_row = models.ChatMessage(
            child_id=child_id, conversation_id=conversation.id, role="assistant",
            text=reply_text,
            tool_call=call.name, tool_args=_stringify_tool_args(args),
        )
    else:
        assistant_row = models.ChatMessage(child_id=child_id, conversation_id=conversation.id,
                                           role="assistant", text=text or "...")

    db.add(assistant_row)
    conversation.updated_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(assistant_row)

    # After the reply is on its way, so remembering costs the parent nothing
    # in latency. Runs on its own session — this one is closed by then.
    from routers.memory import extract_memories
    background.add_task(
        extract_memories, child_id,
        [{"role": "parent", "text": body.text},
         {"role": "assistant", "text": assistant_row.text}],
        assistant_row.id,
    )
    return assistant_row
