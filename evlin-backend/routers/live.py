"""The live-updates stream. See live_updates.py for the design."""
from fastapi import APIRouter, Depends, Request
from fastapi.responses import StreamingResponse
from fastapi.security import HTTPAuthorizationCredentials
from sqlalchemy.orm import Session

import live_updates
import models
from access import resolve_caller
from database import get_db
from routers.auth import security

router = APIRouter(tags=["live"])


@router.get("/live")
def live(request: Request, credentials: HTTPAuthorizationCredentials = Depends(security),
         db: Session = Depends(get_db)):
    """A kid device hears about its own child; a parent about every child in
    their family, including one added after the stream opened."""
    caller = resolve_caller(db, credentials)
    if isinstance(caller, models.Device):
        topic = live_updates.child_topic(caller.child_id)
    else:
        topic = live_updates.parent_topic(caller.id)

    # Released explicitly, before the stream starts. A stream stays open for
    # as long as the app is in the foreground, and whether FastAPI tears a
    # yield-dependency down before or after a streaming body has changed
    # between versions. Holding a pooled connection per open app would run
    # the pool dry at a handful of families.
    db.close()

    return StreamingResponse(
        live_updates.stream(request, topic),
        media_type="text/event-stream",
        # no-transform/X-Accel-Buffering: a proxy that buffers the body turns
        # "the moment it changes" back into "whenever the buffer fills".
        headers={"Cache-Control": "no-cache, no-transform", "X-Accel-Buffering": "no"},
    )
