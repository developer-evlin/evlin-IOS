from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from uuid import UUID
from datetime import date, timezone
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
        "description": "Pre-fill the app's Add Task card for the parent to review and confirm — does not create the task itself.",
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "title": {"type": "STRING", "description": "Short task title"},
                "due_hint": {"type": "STRING", "description": "Free-text due time/date hint, e.g. '6pm today', or empty if none"},
                "repeats_hint": {"type": "STRING", "description": "Free-text recurrence hint, e.g. 'every Saturday', or empty if one-time"},
            },
            "required": ["title"],
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
    "open_block_picker": "Sure — which app should I block?",
    "propose_reflection": "Good idea — here's a reflection to set up.",
    "generate_course": "I found some videos — have a look before I send them over.",
    "draft_special_task": "Here's a task built around a course — check the videos before you create it.",
}
_DEFAULT_TOOL_REPLY = "Sure — let's set that up."

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
    return {k: ("" if v is None else str(v)) for k, v in (args or {}).items()}


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


def _system_prompt(child: models.Child, tasks: list[models.Task], occurrences: list[models.Occurrence], rule: models.ChildRule | None) -> str:
    today_occ_by_task = {o.task_id: o for o in occurrences}
    lines = [f"You are Evlin, a parental-control assistant helping a parent manage {child.name}'s tasks and screen time."]
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
    return "\n".join(lines)


@router.get("/children/{child_id}/chat", response_model=list[schemas.ChatMessageResponse])
def get_chat_history(child_id: UUID, current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    assert_parent_owns_child(db, current_parent, child_id)
    return db.query(models.ChatMessage).filter(
        models.ChatMessage.child_id == child_id
    ).order_by(models.ChatMessage.created_at).all()


@router.post("/children/{child_id}/chat", response_model=schemas.ChatMessageResponse)
async def send_chat_message(
    child_id: UUID,
    body: schemas.ChatSendRequest,
    current_parent: models.Parent = Depends(get_current_parent),
    db: Session = Depends(get_db),
):
    assert_parent_owns_child(db, current_parent, child_id)
    if not gemini_configured():
        raise HTTPException(status_code=503, detail="Chat isn't configured yet (no GEMINI_API_KEY)")

    child = db.query(models.Child).filter(models.Child.id == child_id).first()
    if not child:
        raise HTTPException(status_code=404, detail="Child not found")

    user_row = models.ChatMessage(child_id=child_id, parent_id=current_parent.id, role="user", text=body.text)
    db.add(user_row)
    db.commit()

    tasks = db.query(models.Task).filter(models.Task.child_id == child_id, models.Task.active == True).all()  # noqa: E712
    occurrences = db.query(models.Occurrence).filter(
        models.Occurrence.child_id == child_id, models.Occurrence.due_date == date.today()
    ).all()
    rule = db.query(models.ChildRule).filter(models.ChildRule.child_id == child_id).first()

    history_rows = db.query(models.ChatMessage).filter(
        models.ChatMessage.child_id == child_id
    ).order_by(models.ChatMessage.created_at).all()
    messages = [{"role": "user" if r.role == "user" else "model", "text": r.text} for r in history_rows if r.text]

    try:
        text, call = await generate(_system_prompt(child, tasks, occurrences, rule), messages, tools=_TOOLS)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Chat request failed: {e}")

    if isinstance(call, FunctionCall):
        args = dict(call.args)
        if call.name in _COURSE_BUILDING_TOOLS:
            args = await _build_course_for_tool(db, child, call.name, args, current_parent)
        assistant_row = models.ChatMessage(
            child_id=child_id, role="assistant",
            text=_TOOL_REPLIES.get(call.name, _DEFAULT_TOOL_REPLY),
            tool_call=call.name, tool_args=_stringify_tool_args(args),
        )
    else:
        assistant_row = models.ChatMessage(child_id=child_id, role="assistant", text=text or "...")

    db.add(assistant_row)
    db.commit()
    db.refresh(assistant_row)
    return assistant_row
