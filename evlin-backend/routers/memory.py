"""What the assistant remembers about a child between conversations.

Chat history is per-thread; this is what survives across all of them. It's
deliberately small and readable — see models.py's ChildMemory for why rows
rather than embeddings.

Extraction runs after the reply has already been sent, so it never adds
latency to a message.
"""
from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

import models
import schemas
from access import assert_parent_owns_child
from database import get_db
from gemini_client import gemini_configured, generate
from routers.auth import get_current_parent

router = APIRouter(tags=["memory"])

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
  milestones. Those are looked up live and a copy here would go stale.
- Judgements about the child's character. "Struggles to focus after school" is an
  observation; "is lazy" or "is defiant" is a label that would colour every future
  answer. Never write the second kind.
- Anything transient — what happened once today, or what the parent is doing right now.
- Anything already in the existing facts below. Do not restate or slightly reword them.

Most exchanges contain nothing worth keeping. Returning an empty list is the normal,
correct outcome — do not invent something to record."""


def facts_for(db: Session, child_id: UUID) -> list[models.ChildMemory]:
    """Live facts, oldest first. Archived ones stay gone."""
    return db.query(models.ChildMemory).filter(
        models.ChildMemory.child_id == child_id,
        models.ChildMemory.archived_at.is_(None),
    ).order_by(models.ChildMemory.created_at).all()


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
        existing = facts_for(db, child_id)
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


@router.get("/children/{child_id}/memory", response_model=list[schemas.ChildMemoryResponse])
def list_memory(child_id: UUID, current_parent: models.Parent = Depends(get_current_parent),
                db: Session = Depends(get_db)):
    """Everything the assistant is working from — a parent can always see it."""
    assert_parent_owns_child(db, current_parent, child_id)
    return facts_for(db, child_id)


@router.delete("/memory/{memory_id}")
def forget(memory_id: UUID, current_parent: models.Parent = Depends(get_current_parent),
           db: Session = Depends(get_db)):
    """Archived, not deleted, so extraction can't quietly re-learn something
    a parent has explicitly removed."""
    row = db.query(models.ChildMemory).filter(models.ChildMemory.id == memory_id).first()
    if not row:
        raise HTTPException(status_code=404, detail="Not found")
    assert_parent_owns_child(db, current_parent, row.child_id)
    row.archived_at = datetime.now(timezone.utc)
    db.commit()
    return {"detail": "Forgotten"}
