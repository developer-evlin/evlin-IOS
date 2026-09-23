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
]

# What the assistant says while the card it just opened does the rest. Keyed
# by tool name rather than an if/else so adding a tool can't silently answer
# with another tool's line.
_TOOL_REPLIES = {
    "draft_task": "Sure — let's set that up.",
    "open_block_picker": "Sure — which app should I block?",
}
_DEFAULT_TOOL_REPLY = "Sure — let's set that up."


def _stringify_tool_args(args: dict | None) -> dict:
    """Every tool arg is persisted as a string.

    The iOS client decodes tool_args as [String: String] (APIModels.swift),
    so a single numeric value — which Gemini returns as a JSON number for
    any numeric parameter — fails the decode of the *entire* ChatMessage,
    taking the whole transcript with it, not just that one card. Coercing
    here keeps that contract true no matter what a tool's schema declares.
    """
    return {k: ("" if v is None else str(v)) for k, v in (args or {}).items()}


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
        assistant_row = models.ChatMessage(
            child_id=child_id, role="assistant",
            text=_TOOL_REPLIES.get(call.name, _DEFAULT_TOOL_REPLY),
            tool_call=call.name, tool_args=_stringify_tool_args(call.args),
        )
    else:
        assistant_row = models.ChatMessage(child_id=child_id, role="assistant", text=text or "...")

    db.add(assistant_row)
    db.commit()
    db.refresh(assistant_row)
    return assistant_row
