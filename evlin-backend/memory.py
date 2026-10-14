"""What the assistant remembers about a child between conversations.

Chat history is per-thread; this is what survives across all of them. It's
deliberately small and readable — see models.py's ChildMemory for why rows
rather than embeddings.

Entirely internal: nothing here is exposed over HTTP. Chat reads the facts
into its system prompt and hands each exchange back for extraction, which
runs after the reply has already been sent so it never adds latency to a
message.
"""
from uuid import UUID

from sqlalchemy.orm import Session

import models
from gemini_client import gemini_configured, generate

# Keeping the prompt honest about what's already a database column is the
# whole game here: a remembered copy of the bedtime rule is a second source
# of truth that goes stale the moment a parent changes the real one.
_REMEMBER_TOOL = {
    "name": "remember",
    "description": "Record durable facts worth knowing in future conversations. Call with an empty list if nothing qualifies.",
    "parameters": {
        "type": "OBJECT",
        "properties": {
            "facts": {
                "type": "ARRAY",
                "description": "Zero or more short, concrete facts.",
                "items": {
                    "type": "OBJECT",
                    "properties": {
                        "fact": {"type": "STRING", "description": "One short sentence, specific and checkable."},
                        "category": {
                            "type": "STRING",
                            "description": "routine, preference, context or what_worked",
                        },
                    },
                    "required": ["fact"],
                },
            }
        },
        "required": ["facts"],
    },
}

_EXTRACTION_PROMPT = """You decide what is worth remembering about a child between conversations.

Record only things that would still be useful weeks from now and that a parent would
recognise as true:
- routines and circumstances ("plays football Tuesdays", "stays at his dad's every other weekend")
- preferences and what motivates them ("will read fantasy but not non-fiction")
- what worked or didn't ("losing screen time escalated things; a timer warning didn't")

Do not record:
- Anything the app already stores: screen-time limits, downtime hours, the task list,
  calendar events. Those are looked up live and a copy here would go stale.
- Judgements about the child's character. "Struggles to focus after school" is an
  observation; "is lazy" or "is defiant" is a label that would colour every future
  answer. Never write the second kind.
- Anything transient — what happened once today, or what the parent is doing right now.
- Anything already in the existing facts below. Do not restate or slightly reword them.

Most exchanges contain nothing worth keeping. Returning an empty list is the normal,
correct outcome — do not invent something to record."""


# Every one of these goes into every system prompt, so this is a hard
# ceiling on what memory can cost — in tokens and in dilution. Nothing
# prunes this table on a schedule, so without a cap the prompt would grow
# for the life of the account. Newest wins: if a child has more than this
# many durable facts, the stale ones are the old ones.
MAX_FACTS_IN_PROMPT = 40


def facts_for(db: Session, child_id: UUID) -> list[models.ChildMemory]:
    """The most recent live facts, returned oldest-first for the prompt.

    Archived ones stay gone. Nothing writes archived_at automatically — it's
    the manual kill switch for a bad fact, and it survives re-extraction
    where a DELETE wouldn't.
    """
    newest_first = _live_facts_query(db, child_id).order_by(
        models.ChildMemory.created_at.desc()
    ).limit(MAX_FACTS_IN_PROMPT).all()
    return list(reversed(newest_first))


def _live_facts_query(db: Session, child_id: UUID):
    return db.query(models.ChildMemory).filter(
        models.ChildMemory.child_id == child_id,
        models.ChildMemory.archived_at.is_(None),
    )


def _all_live_facts(db: Session, child_id: UUID) -> list[models.ChildMemory]:
    """Uncapped — for deduplication, which has to see everything."""
    return _live_facts_query(db, child_id).order_by(models.ChildMemory.created_at).all()


def forget_from_conversation(db: Session, conversation_id: UUID) -> int:
    """Drop the facts extracted from one thread. Returns how many went.

    Must run before that thread's messages are deleted, while
    source_message_id still points at something — afterwards the FK nulls
    out and the fact is left live with no provenance, which is how a parent
    ends up unable to get rid of something they thought they had deleted.

    A hard delete rather than an archive, unlike the manual kill switch: the
    parent removed the transcript, so keeping a derived copy of it is the
    surprising outcome, and with the transcript gone there is nothing left
    to re-extract it from anyway.
    """
    message_ids = [row.id for row in db.query(models.ChatMessage.id).filter(
        models.ChatMessage.conversation_id == conversation_id
    ).all()]
    if not message_ids:
        return 0
    return db.query(models.ChildMemory).filter(
        models.ChildMemory.source_message_id.in_(message_ids)
    ).delete(synchronize_session=False)


async def extract_memories(child_id: UUID, exchange: list[dict], source_message_id: UUID | None = None) -> int:
    """Look at one exchange and store anything durable.

    Opens its own session on purpose: this runs as a background task after
    the response has been returned, by which point the request's session is
    closed. Returns how many facts were written.
    """
    if not gemini_configured():
        return 0

    try:
        return await _extract(child_id, exchange, source_message_id)
    except Exception as e:
        # Memory is an enhancement running after the parent already has their
        # reply. Nothing that happens here may surface to them or take down
        # the request, so this swallows — but loudly, because a silently
        # broken memory would look exactly like a model that never learns.
        print(f"Memory extraction failed for child {child_id}: {type(e).__name__}: {e}")
        return 0


async def _extract(child_id: UUID, exchange: list[dict], source_message_id: UUID | None) -> int:
    from database import SessionLocal

    db = SessionLocal()
    try:
        # Every live fact, not the capped prompt window: a fact that has aged
        # out of the prompt is still known, and must not be written a second
        # time as if it were new.
        existing = _all_live_facts(db, child_id)
        known = "\n".join(f"- {m.fact}" for m in existing) or "- (nothing yet)"
        transcript = "\n".join(f"{m['role']}: {m['text']}" for m in exchange)

        _text, call = await generate(
            _EXTRACTION_PROMPT,
            [{"role": "user", "text": f"Already known:\n{known}\n\nThe exchange:\n{transcript}"}],
            tools=[_REMEMBER_TOOL],
        )

        if call is None or call.name != "remember":
            return 0

        seen = {m.fact.strip().lower() for m in existing}
        written = 0
        for item in (call.args.get("facts") or []):
            fact = (item.get("fact") or "").strip()
            if not fact or fact.lower() in seen:
                continue
            seen.add(fact.lower())
            db.add(models.ChildMemory(
                child_id=child_id, fact=fact,
                category=(item.get("category") or "context").strip().lower(),
                source_message_id=source_message_id,
            ))
            written += 1

        if written:
            db.commit()
        return written
    finally:
        db.close()
