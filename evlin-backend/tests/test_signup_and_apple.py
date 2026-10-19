"""Email sign-up codes and Sign in with Apple, including the attacks each
part is meant to stop. Supabase, Resend and Apple are faked."""
import time
import uuid
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa

import apple_auth
import email_verification as ev
import models
from routers import auth as auth_router
from tests.conftest import auth, make_parent


class FakeSupabaseAuth:
    def __init__(self):
        self.users = {}  # email -> (id, password)
        self.deleted = []
        self.id_token_calls = []
        self.admin = SimpleNamespace(create_user=self._create_user, delete_user=self._delete_user)

    def _session(self, uid, email):
        return SimpleNamespace(
            user=SimpleNamespace(id=uid, email=email),
            session=SimpleNamespace(access_token=f"at-{uid}", refresh_token=f"rt-{uid}"),
        )

    def _create_user(self, attrs):
        if attrs["email"] in self.users:
            raise Exception("A user with this email address has already been registered")
        assert attrs["email_confirm"] is True
        uid = uuid.uuid4()
        self.users[attrs["email"]] = (uid, attrs["password"])
        return SimpleNamespace(user=SimpleNamespace(id=uid, email=attrs["email"]))

    def _delete_user(self, uid):
        self.deleted.append(uid)

    def sign_in_with_password(self, creds):
        uid, pw = self.users[creds["email"]]
        assert pw == creds["password"]
        return self._session(uid, creds["email"])

    def sign_in_with_id_token(self, creds):
        self.id_token_calls.append(creds)
        return self._session(uuid.uuid4(), "relay@privaterelay.appleid.com")


@pytest.fixture()
def fake_supabase(monkeypatch):
    fake = SimpleNamespace(auth=FakeSupabaseAuth())
    monkeypatch.setattr(auth_router, "supabase", fake)
    return fake.auth


@pytest.fixture()
def outbox(monkeypatch):
    sent = []
    monkeypatch.setattr(auth_router, "send_email",
                        lambda to, subject, text, html: sent.append(SimpleNamespace(to=to, subject=subject, text=text)))
    return sent


def _code_from(mail):
    return mail.subject.split()[0]


PASSWORD = "correct horse battery"


# ---- email sign-up ---------------------------------------------------------

def test_signup_creates_the_account_only_after_the_code(client, db_session, fake_supabase, outbox):
    r = client.post("/auth/signup/start", json={"email": "Parent@Example.com "})
    assert r.status_code == 200, r.text
    assert r.json() == {"sent": True, "expires_in": 600, "resend_after": 60}
    assert fake_supabase.users == {}  # nothing exists yet
    assert outbox[0].to == "parent@example.com"
    code = _code_from(outbox[0])
    assert len(code) == 6 and code.isdigit()

    r = client.post("/auth/signup/verify", json={"email": "parent@example.com", "password": PASSWORD, "code": code})
    assert r.status_code == 200, r.text
    assert r.json()["access_token"].startswith("at-")
    assert "parent@example.com" in fake_supabase.users
    assert db_session.query(models.Parent).filter_by(email="parent@example.com").count() == 1


def test_a_code_works_once(client, fake_supabase, outbox):
    client.post("/auth/signup/start", json={"email": "a@example.com"})
    body = {"email": "a@example.com", "password": PASSWORD, "code": _code_from(outbox[0])}
    assert client.post("/auth/signup/verify", json=body).status_code == 200
    assert client.post("/auth/signup/verify", json=body).status_code == 400


def test_only_an_hmac_of_the_code_is_stored(client, db_session, fake_supabase, outbox):
    client.post("/auth/signup/start", json={"email": "a@example.com"})
    code = _code_from(outbox[0])
    row = db_session.query(models.EmailVerification).one()
    assert code not in row.code_hash
    import hashlib
    assert row.code_hash != hashlib.sha256(code.encode()).hexdigest()


def test_existing_address_gets_a_notice_and_the_same_answer(client, db_session, fake_supabase, outbox):
    make_parent(db_session, "p", email="taken@example.com")
    new = client.post("/auth/signup/start", json={"email": "fresh@example.com"})
    taken = client.post("/auth/signup/start", json={"email": "TAKEN@example.com"})
    assert new.status_code == taken.status_code == 200
    assert new.json() == taken.json()
    notice = outbox[1]
    assert notice.subject == "You already have an Evlin account"
    assert not any(ch.isdigit() for ch in notice.text)  # no code to use


def test_existing_address_cannot_be_verified_into_a_second_account(client, db_session, fake_supabase, outbox):
    make_parent(db_session, "p", email="taken@example.com")
    client.post("/auth/signup/start", json={"email": "taken@example.com"})
    for guess in ("000000", "123456"):
        r = client.post("/auth/signup/verify", json={"email": "taken@example.com", "password": PASSWORD, "code": guess})
        assert r.status_code == 400
    assert fake_supabase.users == {}


def test_five_wrong_guesses_burn_the_code(client, fake_supabase, outbox):
    client.post("/auth/signup/start", json={"email": "a@example.com"})
    right = _code_from(outbox[0])
    wrong = "000000" if right != "000000" else "111111"
    for _ in range(ev.MAX_ATTEMPTS):
        assert client.post("/auth/signup/verify", json={"email": "a@example.com", "password": PASSWORD, "code": wrong}).status_code == 400
    r = client.post("/auth/signup/verify", json={"email": "a@example.com", "password": PASSWORD, "code": right})
    assert r.status_code == 400
    assert "Too many" in r.json()["detail"]
    assert fake_supabase.users == {}


def test_expired_code_is_rejected(client, db_session, fake_supabase, outbox):
    client.post("/auth/signup/start", json={"email": "a@example.com"})
    row = db_session.query(models.EmailVerification).one()
    row.expires_at = datetime.now(timezone.utc) - timedelta(seconds=1)
    db_session.commit()
    r = client.post("/auth/signup/verify", json={"email": "a@example.com", "password": PASSWORD, "code": _code_from(outbox[0])})
    assert r.status_code == 400


def test_a_new_code_replaces_the_old_one(client, db_session, fake_supabase, outbox):
    client.post("/auth/signup/start", json={"email": "a@example.com"})
    row = db_session.query(models.EmailVerification).one()
    row.last_sent_at = datetime.now(timezone.utc) - timedelta(minutes=2)
    db_session.commit()
    client.post("/auth/signup/start", json={"email": "a@example.com"})
    old, new = _code_from(outbox[0]), _code_from(outbox[1])
    if old != new:
        assert client.post("/auth/signup/verify", json={"email": "a@example.com", "password": PASSWORD, "code": old}).status_code == 400
    assert client.post("/auth/signup/verify", json={"email": "a@example.com", "password": PASSWORD, "code": new}).status_code == 200


def test_resend_cooldown_and_hourly_cap_stop_inbox_flooding(client, db_session, fake_supabase, outbox):
    assert client.post("/auth/signup/start", json={"email": "a@example.com"}).status_code == 200
    r = client.post("/auth/signup/start", json={"email": "a@example.com"})
    assert r.status_code == 429 and int(r.headers["Retry-After"]) > 0
    assert len(outbox) == 1

    for _ in range(ev.MAX_SENDS_PER_WINDOW - 1):
        row = db_session.query(models.EmailVerification).one()
        row.last_sent_at = datetime.now(timezone.utc) - timedelta(minutes=2)
        db_session.commit()
        auth_router.limiter.reset()
        assert client.post("/auth/signup/start", json={"email": "a@example.com"}).status_code == 200
    row = db_session.query(models.EmailVerification).one()
    row.last_sent_at = datetime.now(timezone.utc) - timedelta(minutes=2)
    db_session.commit()
    auth_router.limiter.reset()
    r = client.post("/auth/signup/start", json={"email": "a@example.com"})
    assert r.status_code == 429
    assert len(outbox) == ev.MAX_SENDS_PER_WINDOW


def test_ip_rate_limit_on_start(client, fake_supabase, outbox):
    codes = [client.post("/auth/signup/start", json={"email": f"x{i}@example.com"}).status_code for i in range(6)]
    assert codes[:5] == [200] * 5 and codes[5] == 429


def test_unconfigured_email_fails_cleanly_and_allows_retry(client, db_session, fake_supabase, monkeypatch):
    from email_sender import EmailNotConfigured

    def boom(*a, **k):
        raise EmailNotConfigured()
    monkeypatch.setattr(auth_router, "send_email", boom)
    r = client.post("/auth/signup/start", json={"email": "a@example.com"})
    assert r.status_code == 503
    assert db_session.query(models.EmailVerification).one().last_sent_at is None


def test_weak_and_overlong_passwords_are_refused(client, fake_supabase, outbox):
    client.post("/auth/signup/start", json={"email": "a@example.com"})
    code = _code_from(outbox[0])
    for pw in ("short", "x" * 73):
        r = client.post("/auth/signup/verify", json={"email": "a@example.com", "password": pw, "code": code})
        assert r.status_code == 422


def test_old_register_route_is_retired(client, fake_supabase):
    r = client.post("/auth/register", json={"email": "a@example.com", "password": PASSWORD})
    assert r.status_code == 410
    assert fake_supabase.users == {}


def test_rate_limit_key_ignores_a_spoofed_forwarded_for():
    req = SimpleNamespace(headers={"x-forwarded-for": "1.2.3.4, 203.0.113.9"},
                          client=SimpleNamespace(host="10.0.0.1"))
    assert auth_router.client_ip(req) == "203.0.113.9"


# ---- Sign in with Apple ----------------------------------------------------

APPLE_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
NONCE = "n" * 40


@pytest.fixture()
def apple_keys(monkeypatch):
    monkeypatch.setattr(apple_auth, "_signing_key", lambda token: APPLE_KEY.public_key())


def _apple_token(key=APPLE_KEY, **overrides):
    now = int(time.time())
    claims = {"iss": apple_auth.APPLE_ISSUER, "aud": "com.evlin.ios", "sub": "apple-user-1",
              "iat": now, "exp": now + 600, "nonce": apple_auth.hash_nonce(NONCE),
              "email": "relay@privaterelay.appleid.com"}
    claims.update(overrides)
    claims = {k: v for k, v in claims.items() if v is not None}
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": "k"})


def test_apple_sign_in_creates_the_parent(client, db_session, fake_supabase, apple_keys):
    token = _apple_token()
    r = client.post("/auth/apple", json={"identity_token": token, "nonce": NONCE, "full_name": "Sam Lee"})
    assert r.status_code == 200, r.text
    assert r.json()["parent"]["name"] == "Sam Lee"
    assert fake_supabase.id_token_calls == [{"provider": "apple", "token": token, "nonce": NONCE}]


@pytest.mark.parametrize("bad", [
    dict(nonce=apple_auth.hash_nonce("someone-elses-nonce-xxxxxxxxxxxxxxxxx")),  # replayed token
    dict(aud="com.attacker.app"),          # token minted for another app
    dict(iss="https://evil.example.com"),  # not Apple
    dict(exp=int(time.time()) - 120),      # expired
    dict(nonce=None),                      # no nonce at all
])
def test_apple_rejects_tampered_tokens(client, fake_supabase, apple_keys, bad):
    token = _apple_token(**bad)
    r = client.post("/auth/apple", json={"identity_token": token, "nonce": NONCE})
    assert r.status_code == 401
    assert fake_supabase.id_token_calls == []  # never forwarded


def test_apple_rejects_a_forged_signature(client, fake_supabase, apple_keys):
    r = client.post("/auth/apple", json={"identity_token": _apple_token(key=OTHER_KEY), "nonce": NONCE})
    assert r.status_code == 401
    assert fake_supabase.id_token_calls == []


def test_apple_refresh_token_is_stored_encrypted_and_revoked_on_delete(client, db_session, fake_supabase, apple_keys, monkeypatch):
    monkeypatch.setattr(apple_auth, "exchange_code", lambda code, sub: "apple-refresh-123" if sub == "apple-user-1" else None)
    revoked = []
    monkeypatch.setattr(apple_auth, "revoke", lambda token: revoked.append(token) or True)

    r = client.post("/auth/apple", json={"identity_token": _apple_token(), "nonce": NONCE, "authorization_code": "c0de"})
    assert r.status_code == 200
    parent = db_session.query(models.Parent).one()
    assert "apple-refresh-123" not in parent.apple_refresh_token_enc
    assert apple_auth.decrypt_token(parent.apple_refresh_token_enc) == "apple-refresh-123"

    from tests.conftest import PARENT_TOKENS
    PARENT_TOKENS["apple"] = parent.id
    assert client.delete("/auth/account", headers=auth("apple")).status_code == 200
    assert revoked == ["apple-refresh-123"]
    assert fake_supabase.deleted == [str(parent.id)]


def test_code_exchange_refuses_another_users_code(monkeypatch):
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption()).decode()
    monkeypatch.setenv("APPLE_TEAM_ID", "TEAM123456")
    monkeypatch.setenv("APPLE_KEY_ID", "KEY1234567")
    monkeypatch.setenv("APPLE_PRIVATE_KEY", pem.replace("\n", "\\n"))

    posted = {}

    def fake_post(url, data, timeout):
        posted.update(data)
        id_token = jwt.encode({"sub": "someone-else"}, "x", algorithm="HS256")
        return SimpleNamespace(status_code=200, json=lambda: {"id_token": id_token, "refresh_token": "rt"}, text="")
    monkeypatch.setattr(apple_auth.httpx, "post", fake_post)

    assert apple_auth.exchange_code("code", expected_sub="apple-user-1") is None

    # The client secret Apple receives is an ES256 JWT signed by the .p8 key.
    secret = posted["client_secret"]
    assert jwt.get_unverified_header(secret)["kid"] == "KEY1234567"
    claims = jwt.decode(secret, key.public_key(), algorithms=["ES256"], audience=apple_auth.APPLE_ISSUER)
    assert claims["iss"] == "TEAM123456" and claims["sub"] == "com.evlin.ios"
    assert claims["exp"] - claims["iat"] <= 300
