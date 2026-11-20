"""Every queued write from a phone is safe to send twice (2026-11-19).

The phones' outbox retries a write whose answer was lost (a dropped
connection, the app suspended or force-quit mid-request). Each one carries
an `Idempotency-Key` header, the outbox entry's own id. The first time a
key is seen, the request runs and its answer is kept here for a day; a
repeat of the same key from the same caller gets that answer back without
running again, so extra time is never granted twice and nothing is made
twice. Server errors (5xx) aren't kept: those are meant to be retried.

A pure ASGI middleware (not BaseHTTPMiddleware), so the live-updates stream
and every request without a key pass straight through untouched.
"""
import hashlib
from datetime import datetime, timedelta, timezone

from sqlalchemy.exc import IntegrityError
from starlette.concurrency import run_in_threadpool

import models
from database import SessionLocal, get_db

KEEP = timedelta(days=1)
_WRITES = {b"POST", b"PUT", b"PATCH", b"DELETE"}


def _session(app):
    """The request's database: the tests' stand-in when one is set."""
    override = getattr(app, "dependency_overrides", {}).get(get_db)
    if override is not None:
        return override(), False
    return SessionLocal(), True


def _lookup(app, caller: str, key: str):
    db, own = _session(app)
    try:
        row = db.query(models.IdempotencyKey).filter_by(caller=caller, key=key).first()
        return None if row is None else (row.method, row.path, row.status, row.body)
    finally:
        if own:
            db.close()


def _keep(app, caller: str, key: str, method: str, path: str, status: int, body: bytes):
    db, own = _session(app)
    now = datetime.now(timezone.utc)
    try:
        db.query(models.IdempotencyKey).filter(models.IdempotencyKey.caller == caller,
                                               models.IdempotencyKey.created_at < now - KEEP
                                               ).delete(synchronize_session=False)
        db.add(models.IdempotencyKey(caller=caller, key=key, method=method, path=path, status=status,
                                     body=body.decode("utf-8", "replace"), created_at=now))
        db.commit()
    except IntegrityError:
        # The same key finished twice at once: the first one's answer stands.
        db.rollback()
    finally:
        if own:
            db.close()


class IdempotencyMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"].encode() not in _WRITES:
            return await self.app(scope, receive, send)
        headers = dict(scope.get("headers") or [])
        key = headers.get(b"idempotency-key", b"").decode("latin-1").strip()
        if not key or len(key) > 100:
            return await self.app(scope, receive, send)
        # Whose key: the token's hash, so one family's key never answers another's.
        caller = hashlib.sha256(headers.get(b"authorization", b"")).hexdigest()
        method, path, app = scope["method"], scope["path"], scope.get("app")

        seen = await run_in_threadpool(_lookup, app, caller, key)
        if seen is not None and seen[0] == method and seen[1] == path:
            await send({"type": "http.response.start", "status": seen[2],
                        "headers": [(b"content-type", b"application/json"), (b"idempotent-replay", b"true")]})
            await send({"type": "http.response.body", "body": (seen[3] or "").encode()})
            return

        status, chunks = None, []

        async def capture(message):
            nonlocal status
            if message["type"] == "http.response.start":
                status = message["status"]
            elif message["type"] == "http.response.body":
                chunks.append(message.get("body", b""))
            await send(message)

        await self.app(scope, receive, capture)
        if status is not None and status < 500:
            await run_in_threadpool(_keep, app, caller, key, method, path, status, b"".join(chunks))
