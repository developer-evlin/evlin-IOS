"""A refresh only ends the session when Supabase refused the token. A
timeout or outage answers 503, so the app keeps its tokens and retries."""
from unittest.mock import MagicMock

import pytest
from fastapi import HTTPException
from supabase_auth.errors import AuthApiError, AuthRetryableError

from routers import auth
import schemas


def _refresh_raising(monkeypatch, exc):
    client = MagicMock()
    client.auth.refresh_session.side_effect = exc
    monkeypatch.setattr(auth, "supabase", client)
    with pytest.raises(HTTPException) as info:
        auth.refresh(schemas.RefreshRequest(refresh_token="r"))
    return info.value.status_code


def test_refused_refresh_token_is_401(monkeypatch):
    err = AuthApiError("Invalid Refresh Token: Already Used", 400, "refresh_token_already_used")
    assert _refresh_raising(monkeypatch, err) == 401


def test_supabase_unreachable_is_503(monkeypatch):
    assert _refresh_raising(monkeypatch, AuthRetryableError("timed out", 0)) == 503
    assert _refresh_raising(monkeypatch, TimeoutError()) == 503


def test_supabase_server_error_is_503(monkeypatch):
    assert _refresh_raising(monkeypatch, AuthApiError("boom", 500, None)) == 503


def test_successful_refresh_returns_both_tokens(monkeypatch):
    client = MagicMock()
    client.auth.refresh_session.return_value.session.access_token = "a2"
    client.auth.refresh_session.return_value.session.refresh_token = "r2"
    monkeypatch.setattr(auth, "supabase", client)
    assert auth.refresh(schemas.RefreshRequest(refresh_token="r")) == {"access_token": "a2", "refresh_token": "r2"}


def test_shared_supabase_client_never_renews_sessions_itself():
    # The server's client renewing a session behind the phone's back spends
    # the phone's refresh token, and Supabase then revokes the session.
    from supabase import create_client
    client = create_client("https://example.supabase.co", "x" * 40, options=auth._CLIENT_OPTIONS)
    assert client.auth._auto_refresh_token is False
    assert client.auth._persist_session is False


def test_handling_a_session_starts_no_renewal_timer():
    from supabase import create_client
    from supabase_auth.types import Session, User
    import time
    client = create_client("https://example.supabase.co", "x" * 40, options=auth._CLIENT_OPTIONS)
    user = User(id="u", app_metadata={}, user_metadata={}, aud="authenticated", created_at="2026-01-01T00:00:00Z")
    session = Session(access_token="a", refresh_token="r", expires_in=3600,
                      expires_at=int(time.time()) + 3600, token_type="bearer", user=user)
    client.auth._save_session(session)
    assert client.auth._refresh_token_timer is None
