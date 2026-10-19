"""A parent's phone stays signed in on its own session token, until Sign out."""
import pytest
from fastapi import HTTPException
from fastapi.security import HTTPAuthorizationCredentials

from routers import auth
from tests.conftest import auth as bearer, make_parent


def _real_parent(db, token):
    return auth.get_current_parent(HTTPAuthorizationCredentials(scheme="Bearer", credentials=token), db)


def _start(client, parent_token="pa"):
    r = client.post("/auth/session", headers=bearer(parent_token))
    assert r.status_code == 200, r.text
    return r.json()["session_token"]


def test_sign_in_is_traded_for_a_session_token_that_identifies_the_parent(client, db_session):
    p = make_parent(db_session, "pa")
    token = _start(client)
    assert "." not in token  # never mistaken for a Supabase JWT
    assert _real_parent(db_session, token).id == p.id


def test_session_token_needs_no_supabase(client, db_session, monkeypatch):
    make_parent(db_session, "pa")
    token = _start(client)

    class Down:
        def __getattr__(self, name):
            raise AssertionError("Supabase must not be called for a session token")
    monkeypatch.setattr(auth, "supabase", Down())

    assert _real_parent(db_session, token) is not None


def test_sign_out_ends_only_that_phone(client, db_session):
    make_parent(db_session, "pa")
    phone, ipad = _start(client), _start(client)

    assert client.post("/auth/logout", headers=bearer(phone)).status_code == 200

    with pytest.raises(HTTPException) as info:
        _real_parent(db_session, phone)
    assert info.value.status_code == 401
    assert _real_parent(db_session, ipad) is not None


def test_unknown_session_token_is_refused(client, db_session):
    with pytest.raises(HTTPException) as info:
        _real_parent(db_session, "not-a-session-token")
    assert info.value.status_code == 401


def test_session_token_is_stored_hashed(client, db_session):
    import models
    make_parent(db_session, "pa")
    token = _start(client)
    row = db_session.query(models.ParentSession).one()
    assert row.token_hash != token and row.token_hash == auth.hash_token(token)
