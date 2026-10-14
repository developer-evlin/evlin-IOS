"""Which messages each assistant in a thread is sent.

One thread can hold two assistants' messages: the main chat ('chat') and
the YouTube agent ('youtube'), which the parent switches to with the
YouTube tile. Each is only ever sent its own messages: the main chat never
sees the video back-and-forth, and the YouTube agent never sees tasks and
calendar. Neither one's turns reach the other's prompt or cost.

The main chat's window is a plain count (chat.HISTORY_WINDOW). The YouTube
agent's memory is shaped around how a parent actually uses it instead:

- A YouTube session is a short burst around one goal: "dinosaur videos for
  Mia" -> "shorter ones" -> "not that channel" -> "more like the second
  one" -> approve. A handful of turns, then the parent leaves.
- What follow-ups refer to is the session's goal (its first request) and
  the last few turns, especially the latest card ("the second one"). The
  turns in between matter much less.
- The next session, hours or days later, is a new goal. Its old transcript
  would be noise, and cost on every message. What should carry over is
  outcomes — approved videos, blocked channels — and those are data the
  agent looks up, not conversation it remembers.

So the agent gets:
1. Only the current session: the unbroken run of YouTube messages at the
   end of the thread. A main-chat message, or a pause longer than
   IDLE_GAP, starts the next YouTube message on a fresh session.
2. The session's first request, always: it's the goal everything after
   it refines, however long ago it was said.
3. At least the last FLOOR_MESSAGES messages, always, however long they
   are: enough to follow a refinement and reason about it.
4. Older turns of the session only while they fit RECENT_BUDGET_TOKENS.
   A budget rather than a count: ten one-word refinements cost less than
   two long paragraphs, so short messages buy more memory.
5. The latest card's contents, even once its message has left the window,
   so "the second one" always has something to point at.
"""
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from uuid import UUID

from sqlalchemy.orm import Session

import models

AGENTS = ("chat", "youtube")

# A parent who comes back after this long is starting something new.
IDLE_GAP = timedelta(hours=2)
# The last three exchanges, kept whatever their length.
FLOOR_MESSAGES = 6
# Older turns of the session, beyond the floor, fit into this. Roughly
# twenty short exchanges; the system prompt is far larger.
RECENT_BUDGET_TOKENS = 1500

# What the agent is told stands in for the turns left out of the middle.
OMITTED = "(Earlier messages in this search are left out.)"


@dataclass
class AgentContext:
    """What the YouTube agent is given for one turn."""
    # role 'user' | 'model', oldest first, starting with the parent: the
    # shape gemini_client.generate_all takes.
    messages: list[dict] = field(default_factory=list)
    # (tool_call, tool_args) of the newest card in this session, or None.
    latest_card: tuple[str, dict] | None = None
    # How many messages the session has in all, including any left out.
    session_length: int = 0
    session_started_at: datetime | None = None


def _aware(dt: datetime) -> datetime:
    # SQLite (the test harness) hands back naive datetimes.
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _tokens(text: str) -> int:
    # Close enough to Gemini's count for English, and free.
    return len(text) // 4 + 1


def current_session(rows: list[models.ChatMessage], agent: str = "youtube") -> list[models.ChatMessage]:
    """The trailing run of `agent`'s messages in a thread (rows oldest
    first): stops at the first message from another assistant, or at a
    pause longer than IDLE_GAP. Empty when the thread's newest message
    isn't `agent`'s."""
    session: list[models.ChatMessage] = []
    for row in reversed(rows):
        if (row.agent or "chat") != agent:
            break
        if session and _aware(session[-1].created_at) - _aware(row.created_at) > IDLE_GAP:
            break
        session.append(row)
    session.reverse()
    return session


def window(session: list[models.ChatMessage]) -> list[dict]:
    """The messages the agent is sent from one session — see the module
    docstring for the rules."""
    texts = [m for m in session if m.text]
    if not texts:
        return []

    recent: list[models.ChatMessage] = []
    used = 0
    for m in reversed(texts):
        cost = _tokens(m.text)
        if len(recent) >= FLOOR_MESSAGES and used + cost > RECENT_BUDGET_TOKENS:
            break
        recent.append(m)
        used += cost
    recent.reverse()

    def as_turn(m):
        return {"role": "user" if m.role == "user" else "model", "text": m.text}

    anchor = next((m for m in texts if m.role == "user"), None)
    out: list[dict] = []
    if anchor is not None and anchor not in recent:
        out = [as_turn(anchor), {"role": "model", "text": OMITTED}]
        # Keep the turns alternating after the note.
        while recent and recent[0].role != "user":
            recent.pop(0)
    out += [as_turn(m) for m in recent]
    while out and out[0]["role"] != "user":
        out.pop(0)
    return out


def youtube_context(db: Session, conversation_id: UUID) -> AgentContext:
    """Everything the YouTube agent is given for its next turn in this
    thread. Call after the parent's new message is saved."""
    rows = db.query(models.ChatMessage).filter(
        models.ChatMessage.conversation_id == conversation_id,
    ).order_by(models.ChatMessage.created_at).all()
    session = current_session(rows, "youtube")
    card = next(((m.tool_call, dict(m.tool_args or {})) for m in reversed(session)
                 if m.role != "user" and m.tool_call), None)
    return AgentContext(
        messages=window(session),
        latest_card=card,
        session_length=len(session),
        session_started_at=session[0].created_at if session else None,
    )
