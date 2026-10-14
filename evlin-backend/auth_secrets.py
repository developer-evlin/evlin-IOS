"""Server-side keys for auth: the HMAC key for email codes and the encryption
key for stored Apple tokens.

Both are derived from one secret, AUTH_SECRET, with a different label each, so
a leak of one derived key says nothing about the other. Set AUTH_SECRET in
production (any long random string, e.g. `python3 -c "import secrets;
print(secrets.token_urlsafe(48))"`). Changing it invalidates codes in flight
and makes stored Apple tokens unreadable, so set it once.

Without AUTH_SECRET this falls back to a key derived from SUPABASE_KEY (also
server-only), and failing that to a random key per process, which is only
fit for tests.
"""
import base64
import hashlib
import hmac
import logging
import os
import secrets

logger = logging.getLogger(__name__)

_random_fallback = secrets.token_bytes(32)


def _root_secret() -> bytes:
    explicit = os.getenv("AUTH_SECRET")
    if explicit:
        return explicit.encode()
    supabase_key = os.getenv("SUPABASE_KEY")
    if supabase_key:
        return b"evlin-auth-from-supabase-key:" + supabase_key.encode()
    logger.warning("AUTH_SECRET is not set; using a random per-process auth key")
    return _random_fallback


def derive_key(label: str) -> bytes:
    """A 32-byte key for one purpose, e.g. "email-code" or "apple-token"."""
    return hmac.new(_root_secret(), f"evlin:{label}".encode(), hashlib.sha256).digest()


def fernet_key(label: str) -> bytes:
    return base64.urlsafe_b64encode(derive_key(label))
