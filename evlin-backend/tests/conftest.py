"""Offline test harness: the real FastAPI app on an in-memory SQLite database.

Postgres-only bits are swapped out just for tests (the `app` schema is an
ATTACHed database, ARRAY columns become JSON, server-side now() becomes a
Python default). Supabase auth is replaced by a token -> parent map; device
tokens use the real hashing/lookup code.
"""
import os
import sys
import uuid
from datetime import datetime, timezone

os.environ.setdefault("DATABASE_URL", "sqlite://")
# generate_presigned_url is pure local signing (no network call), so the
# submissions/content routers are fully testable with made-up credentials.
os.environ.setdefault("R2_ACCOUNT_ID", "test-account")
os.environ.setdefault("R2_ACCESS_KEY_ID", "test-key")
os.environ.setdefault("R2_SECRET_ACCESS_KEY", "test-secret")
os.environ.setdefault("R2_BUCKET_NAME", "test-bucket")
os.environ.setdefault("R2_PUBLIC_BUCKET_NAME", "test-public")
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

import pytest
from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials
from fastapi.testclient import TestClient
from sqlalchemy import JSON, ColumnDefault, create_engine, event
from sqlalchemy.dialects.postgresql import ARRAY
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

import access
import models
from database import Base, get_db
from routers import auth as auth_router
from routers.auth import hash_token, security
import main


def _sqlite_ready_metadata():
    for table in Base.metadata.tables.values():
        for col in table.columns:
            if isinstance(col.type, ARRAY):
                col.type = JSON()
            if col.server_default is not None:
                col.server_default = None
                col.default = ColumnDefault(lambda: datetime.now(timezone.utc))


_sqlite_ready_metadata()

PARENT_TOKENS: dict[str, uuid.UUID] = {}


@pytest.fixture()
def db_session():
    engine = create_engine("sqlite://", poolclass=StaticPool, connect_args={"check_same_thread": False})

    @event.listens_for(engine, "connect")
    def _attach(dbapi_conn, _):
        dbapi_conn.execute("ATTACH DATABASE ':memory:' AS app")

    Base.metadata.create_all(engine)
    Session = sessionmaker(bind=engine, autoflush=False, autocommit=False)
    session = Session()
    yield session
    session.close()
    engine.dispose()


@pytest.fixture()
def client(db_session):
    PARENT_TOKENS.clear()

    def fake_get_current_parent(credentials: HTTPAuthorizationCredentials = Depends(security), db=Depends(get_db)):
        from fastapi import HTTPException
        pid = PARENT_TOKENS.get(credentials.credentials)
        parent = db.query(models.Parent).filter(models.Parent.id == pid).first() if pid else None
        if not parent:
            raise HTTPException(status_code=401, detail="Invalid token")
        return parent

    main.app.dependency_overrides[get_db] = lambda: db_session
    main.app.dependency_overrides[auth_router.get_current_parent] = fake_get_current_parent
    # access.py calls get_current_parent directly (not as a dependency).
    original = access.get_current_parent
    access.get_current_parent = fake_get_current_parent
    yield TestClient(main.app)
    access.get_current_parent = original
    main.app.dependency_overrides.clear()


# ---- data helpers -------------------------------------------------------

def make_parent(db, token, email=None):
    p = models.Parent(id=uuid.uuid4(), email=email or f"{token}@example.com")
    db.add(p)
    db.commit()
    PARENT_TOKENS[token] = p.id
    return p


def make_child(db, parent, name="Kid"):
    c = models.Child(name=name, birth_year=2015, color_index=0, avatar_url="")
    db.add(c)
    db.commit()
    db.add(models.ParentChild(parent_id=parent.id, child_id=c.id, role="primary"))
    db.add(models.ChildRule(child_id=c.id, daily_limit_minutes=60, downtime_enabled=False))
    db.add(models.ChildState(child_id=c.id, manual_lock=False, task_gate_override=False))
    db.commit()
    return c


def make_device(db, child, token):
    d = models.Device(child_id=child.id, platform="ios", token_hash=hash_token(token))
    db.add(d)
    db.commit()
    return d


def auth(token):
    return {"Authorization": f"Bearer {token}"}


# SQLite returns naive datetimes; Postgres (timestamptz) returns aware ones.
@event.listens_for(models.PairingCode, "load")
def _aware_pairing_code(target, _ctx):
    if target.expires_at is not None and target.expires_at.tzinfo is None:
        target.expires_at = target.expires_at.replace(tzinfo=timezone.utc)
