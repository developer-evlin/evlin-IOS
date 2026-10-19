"""Sign in with Apple, server side.

The app shows Apple's native sheet with a nonce and sends us Apple's identity
token, the raw nonce and a one-time authorization code. Here:

1. verify_identity_token checks the token ourselves: Apple's signature
   (their published keys), issuer, audience (our bundle id), expiry, and that
   the token's nonce is the SHA-256 of the raw nonce the app sent. The nonce
   ties the token to this sign-in, so a token lifted from elsewhere can't be
   replayed. Supabase repeats these checks when it signs the user in; doing
   them here as well means a misconfigured Supabase provider can't quietly
   accept a token we wouldn't.
2. exchange_code trades the authorization code for Apple's refresh token,
   which is stored encrypted. The App Store requires apps with Sign in with
   Apple to revoke it when the account is deleted (revoke).

Calls to Apple's token endpoints are signed with a client secret made from
the .p8 key: APPLE_TEAM_ID, APPLE_KEY_ID and APPLE_PRIVATE_KEY (the file's
contents). Without them sign-in still works. Only the code exchange and
revocation are skipped.
"""
import hashlib
import hmac
import logging
import os
import time
from typing import Optional

import httpx
import jwt
from cryptography.fernet import Fernet, InvalidToken
from jwt import PyJWKClient

from auth_secrets import fernet_key

logger = logging.getLogger(__name__)

APPLE_ISSUER = "https://appleid.apple.com"
APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys"
APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token"
APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke"

_jwks_client = PyJWKClient(APPLE_KEYS_URL)


def bundle_id() -> str:
    return os.getenv("APPLE_BUNDLE_ID", "com.evlin.ios")


def _private_key() -> Optional[str]:
    key = os.getenv("APPLE_PRIVATE_KEY")
    # Dashboards often store multi-line values with literal "\n".
    return key.replace("\\n", "\n") if key else None


def server_calls_configured() -> bool:
    return bool(os.getenv("APPLE_TEAM_ID") and os.getenv("APPLE_KEY_ID") and _private_key())


class AppleTokenError(Exception):
    pass


def hash_nonce(raw_nonce: str) -> str:
    return hashlib.sha256(raw_nonce.encode()).hexdigest()


def _signing_key(token: str):
    """Apple's public key for this token. Replaced in tests."""
    return _jwks_client.get_signing_key_from_jwt(token).key


def verify_identity_token(identity_token: str, raw_nonce: str) -> dict:
    try:
        key = _signing_key(identity_token)
        claims = jwt.decode(
            identity_token, key, algorithms=["RS256"],
            audience=bundle_id(), issuer=APPLE_ISSUER,
            options={"require": ["exp", "iat", "iss", "aud", "sub"]},
            leeway=30,
        )
    except jwt.ExpiredSignatureError:
        raise AppleTokenError("Apple sign-in expired. Try again.")
    except (jwt.PyJWTError, jwt.PyJWKClientError) as e:
        logger.warning("Rejected Apple identity token: %s: %s", type(e).__name__, e)
        raise AppleTokenError("Apple sign-in couldn't be verified.")

    token_nonce = claims.get("nonce")
    if not token_nonce or not hmac.compare_digest(str(token_nonce), hash_nonce(raw_nonce)):
        logger.warning("Rejected Apple identity token: nonce mismatch")
        raise AppleTokenError("Apple sign-in couldn't be verified.")
    return claims


def client_secret() -> str:
    """The short-lived JWT Apple's token endpoints take as client_secret."""
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["APPLE_TEAM_ID"], "iat": now, "exp": now + 300,
         "aud": APPLE_ISSUER, "sub": bundle_id()},
        _private_key(), algorithm="ES256",
        headers={"kid": os.environ["APPLE_KEY_ID"]},
    )


def exchange_code(authorization_code: str, expected_sub: str) -> Optional[str]:
    """Apple's refresh token for this sign-in, or None if it can't be had.
    The id_token Apple returns must belong to the same Apple user as the
    verified identity token, so a code from another account can't be
    attached here."""
    if not server_calls_configured():
        logger.warning("Apple server keys not set; skipping code exchange (deletion can't revoke)")
        return None
    try:
        r = httpx.post(APPLE_TOKEN_URL, data={
            "client_id": bundle_id(), "client_secret": client_secret(),
            "code": authorization_code, "grant_type": "authorization_code",
        }, timeout=10)
    except httpx.HTTPError as e:
        logger.warning("Apple code exchange unreachable: %s", type(e).__name__)
        return None
    if r.status_code != 200:
        logger.warning("Apple code exchange failed: %s %s", r.status_code, r.text[:200])
        return None
    body = r.json()
    try:
        # Straight from Apple over TLS, so the signature adds nothing; only
        # the subject is compared.
        sub = jwt.decode(body.get("id_token", ""), options={"verify_signature": False}).get("sub")
    except jwt.PyJWTError:
        sub = None
    if sub != expected_sub:
        logger.warning("Apple code exchange returned a different user; discarding")
        return None
    return body.get("refresh_token")


def revoke(refresh_token: str) -> bool:
    if not server_calls_configured():
        logger.warning("Apple server keys not set; can't revoke Sign in with Apple")
        return False
    try:
        r = httpx.post(APPLE_REVOKE_URL, data={
            "client_id": bundle_id(), "client_secret": client_secret(),
            "token": refresh_token, "token_type_hint": "refresh_token",
        }, timeout=10)
    except httpx.HTTPError as e:
        logger.warning("Apple revoke unreachable: %s", type(e).__name__)
        return False
    if r.status_code != 200:
        logger.warning("Apple revoke failed: %s %s", r.status_code, r.text[:200])
        return False
    return True


def _fernet() -> Fernet:
    return Fernet(fernet_key("apple-refresh-token"))


def encrypt_token(token: str) -> str:
    return _fernet().encrypt(token.encode()).decode()


def decrypt_token(blob: str) -> Optional[str]:
    try:
        return _fernet().decrypt(blob.encode()).decode()
    except InvalidToken:
        logger.warning("Stored Apple token can't be decrypted (AUTH_SECRET changed?)")
        return None
