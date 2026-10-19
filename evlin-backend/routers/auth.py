from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.orm import Session
from pydantic import BaseModel
import os
import uuid
import random
import string
import hashlib
import secrets
import logging
import re
import jwt
from jwt import PyJWKClient
from datetime import datetime, timedelta, timezone
from typing import Optional
from supabase import create_client, Client, ClientOptions
from supabase_auth.errors import AuthApiError
from database import get_db
import models, schemas
import apple_auth
import email_verification as ev
from email_sender import EmailNotConfigured, EmailSendFailed, send_email
from slowapi import Limiter
from slowapi.util import get_remote_address

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/auth", tags=["auth"])

# ---------------------------------------------------------------------------
# Rate limiter — shared instance imported by main.py to attach to the app.
# ---------------------------------------------------------------------------
def client_ip(request: Request) -> str:
    """The caller's address for rate limiting. Render's proxy appends the
    address it saw to X-Forwarded-For and never strips what the client sent,
    so only the last entry can be trusted; the first one is whatever the
    caller chose to write. Locally there's no proxy and no header."""
    forwarded = request.headers.get("x-forwarded-for", "")
    parts = [p.strip() for p in forwarded.split(",") if p.strip()]
    return parts[-1] if parts else get_remote_address(request)


limiter = Limiter(key_func=client_ip)

# ---------------------------------------------------------------------------
# Supabase client
# ---------------------------------------------------------------------------
SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_KEY")
# One client shared by every request, so it must hold no one's session. By
# default supabase-py keeps the last session it handled (a sign-in, a
# refresh) and renews it on a timer just before it expires: here, on the
# server, with the refresh token it had just handed to a phone. The phone's
# copy was then spent, its next refresh looked like a stolen token being
# reused, and Supabase revoked the whole session: the parent was signed out
# a few hours after every sign-in. Sessions are the app's to renew, through
# /auth/refresh, and only there.
_CLIENT_OPTIONS = ClientOptions(auto_refresh_token=False, persist_session=False)
supabase: Client = (create_client(SUPABASE_URL, SUPABASE_KEY, options=_CLIENT_OPTIONS)
                    if SUPABASE_URL and SUPABASE_KEY else None)

security = HTTPBearer()

# This project's Supabase JWTs are ES256-signed against a public JWKS
# (confirmed live at {SUPABASE_URL}/auth/v1/.well-known/jwks.json, no
# secret required to fetch) — PyJWKClient fetches and caches it in-process,
# only re-fetching if a request's `kid` isn't in the cached set (a real
# key rotation), not on every call. See _verify_parent_jwt_locally below
# for why this exists.
_jwks_client = PyJWKClient(f"{SUPABASE_URL}/auth/v1/.well-known/jwks.json") if SUPABASE_URL else None

def _verify_parent_jwt_locally(token: str) -> Optional[str]:
    """Verifies a Supabase access token's signature locally instead of the
    live supabase.auth.get_user() round trip get_current_parent used to
    make on *every single call*. A parent-side sync pass fans out to ~10
    endpoints back to back (rules, state, tasks, occurrences, one more per
    task with photos) — multiplying a live Supabase Auth round trip
    by that many turned any slow moment (a Render cold start, an ordinary
    network blip) into a real chance of blowing past the client's 15s
    per-request timeout on at least one of them, which is what made a
    fully-synced, correctly-paired child intermittently fall back to
    AppSync's placeholder/stale state. Returns the user id (`sub`) on a
    verified token, or None for anything that should fall back to the
    live check instead of failing outright (an unrecognized `kid`, the
    JWKS fetch itself failing, anything unexpected) — never used to
    *reject* a token on its own, only to skip the slow path when it can.
    """
    if not _jwks_client:
        return None
    try:
        signing_key = _jwks_client.get_signing_key_from_jwt(token)
        payload = jwt.decode(token, signing_key.key, algorithms=["ES256"], audience="authenticated")
        return payload.get("sub")
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expired")
    except jwt.PyJWKClientError as e:
        # JWKS fetch/cache failure — expected on first boot or during key
        # rotation. Fall back to the live Supabase check; log so it's visible.
        logger.warning("JWKS client error (falling back to live check): %s", e)
        return None
    except Exception as e:
        # Unexpected error — log the type so programming mistakes aren't
        # silently swallowed, but still fall back to the live check.
        logger.warning("Unexpected JWT local-verify error %s: %s", type(e).__name__, e)
        return None


def _supabase_refused(e: Exception) -> bool:
    """True when Supabase itself said the token is no good. Anything else (a
    timeout, a 5xx, a rate limit, Render failing to reach Supabase) says
    nothing about the token, and must not be answered with a 401: the app
    signs out on a 401 it can't refresh past."""
    return isinstance(e, AuthApiError) and e.status in (400, 401, 403, 404)


def _unavailable(e: Exception) -> HTTPException:
    logger.warning("Supabase auth unavailable (%s): %s", type(e).__name__, e)
    return HTTPException(status_code=503, detail="Sign-in is unavailable for a moment. Try again.")


def _parent_for_session_token(db: Session, token: str) -> Optional[models.Parent]:
    """The parent a phone's own session token belongs to (models.ParentSession),
    or None. A read only: nothing is stamped on use, since a read that writes
    would announce a live update."""
    row = db.query(models.ParentSession).filter(
        models.ParentSession.token_hash == hash_token(token),
        models.ParentSession.revoked_at == None,  # noqa: E711
    ).first()
    if not row:
        return None
    return db.query(models.Parent).filter(models.Parent.id == row.parent_id).first()


def get_current_parent(credentials: HTTPAuthorizationCredentials = Depends(security), db: Session = Depends(get_db)) -> models.Parent:
    """The signed-in parent: from the phone's own session token, or from a
    Supabase access token (right after sign-in, and older app versions)."""
    token = credentials.credentials
    if token.count(".") != 2:
        # Not a JWT, so a session token. Decided here, in our own database,
        # with no call to Supabase: an outage can't sign anyone out.
        parent = _parent_for_session_token(db, token)
        if not parent:
            raise HTTPException(status_code=401, detail="Signed out on this phone")
        return parent

    if not supabase:
        raise HTTPException(status_code=500, detail="Supabase client not configured")

    user_id = _verify_parent_jwt_locally(credentials.credentials)
    if user_id is None:
        # Local verification couldn't confirm this token (first JWKS
        # fetch failing, a real key rotation, anything unexpected) — the
        # slower live check is still correct, just not fast, and is the
        # same check this dependency always used to make.
        try:
            user_res = supabase.auth.get_user(credentials.credentials)
            user = user_res.user
            user_id = user.id if user else None
        except Exception as e:
            if _supabase_refused(e):
                raise HTTPException(status_code=401, detail=str(e))
            raise _unavailable(e)
        if user_id is None:
            raise HTTPException(status_code=401, detail="Invalid token")

    parent = db.query(models.Parent).filter(models.Parent.id == user_id).first()
    if not parent:
        raise HTTPException(status_code=401, detail="Parent account not initialized")
    return parent


class VerifyTokenRequest(BaseModel):
    access_token: str


# ---------------------------------------------------------------------------
# H-2: account-enumeration fix — register and login return an identical
# AuthResponse shape; the caller can't tell which path was taken.
# ---------------------------------------------------------------------------

def _ensure_parent(db: Session, user_id, email: Optional[str]) -> models.Parent:
    parent = db.query(models.Parent).filter(models.Parent.id == user_id).first()
    if not parent:
        parent = models.Parent(id=user_id, email=email or "", plan="free")
        db.add(parent)
        db.commit()
        db.refresh(parent)
    return parent


@router.post("/register")
def register_retired():
    """Created accounts without proving the address belonged to the caller,
    which let anyone claim an email before its owner did. Replaced by
    /signup/start and /signup/verify."""
    raise HTTPException(status_code=410, detail="Update Evlin to create an account.")


# ---------------------------------------------------------------------------
# Email sign-up: a code goes to the address, and the account is created only
# when it comes back. Throttling and the threat model: email_verification.py.
# ---------------------------------------------------------------------------

@router.post("/signup/start", response_model=schemas.SignupStartResponse)
@limiter.limit("5/minute;30/hour")
def signup_start(request: Request, body: schemas.SignupStartRequest, db: Session = Depends(get_db)):
    email = ev.normalize_email(body.email)
    exists = ev.parent_exists_with_email(db, email)
    try:
        issued = ev.issue(db, email, ev.SIGNUP, account_exists=exists)
    except ev.Throttled as t:
        raise HTTPException(status_code=429, detail=t.message,
                            headers={"Retry-After": str(t.retry_after)})

    subject, text, html = (ev.signup_code_message(issued.code) if issued.code
                           else ev.already_registered_message())
    try:
        send_email(email, subject, text, html)
    except EmailNotConfigured:
        ev.release_cooldown(db, issued.row_id)
        logger.error("Email sign-up requested but email sending isn't configured")
        raise HTTPException(status_code=503, detail="Email sign-up isn't available right now. Try Apple or Google.")
    except EmailSendFailed:
        ev.release_cooldown(db, issued.row_id)
        raise HTTPException(status_code=503, detail="Couldn't send the email. Try again in a moment.")

    return {"sent": True,
            "expires_in": int(ev.CODE_TTL.total_seconds()),
            "resend_after": int(ev.RESEND_COOLDOWN.total_seconds())}


@router.post("/signup/verify", response_model=schemas.AuthResponse)
@limiter.limit("10/minute")
def signup_verify(request: Request, body: schemas.SignupVerifyRequest, db: Session = Depends(get_db)):
    if not supabase:
        raise HTTPException(status_code=500, detail="Supabase client not configured")
    email = ev.normalize_email(body.email)
    try:
        ev.check(db, email, ev.SIGNUP, body.code)
    except ev.CodeRejected as r:
        raise HTTPException(status_code=400, detail=r.message)

    # The caller has now shown they read this inbox, so the address can be
    # marked confirmed.
    try:
        res = supabase.auth.admin.create_user({
            "email": email, "password": body.password, "email_confirm": True,
        })
    except Exception as e:
        message = getattr(e, "message", None) or str(e)
        if "already" in message.lower():
            raise HTTPException(status_code=409, detail="This email already has an account. Sign in instead.")
        logger.error("Supabase create_user failed: %s", message)
        raise HTTPException(status_code=400, detail="Couldn't create the account. Try again.")

    try:
        login_res = supabase.auth.sign_in_with_password({"email": email, "password": body.password})
    except Exception as e:
        logger.error("Sign-in right after sign-up failed: %s", e)
        raise HTTPException(status_code=500, detail="Account created. Sign in to continue.")

    parent = _ensure_parent(db, res.user.id, res.user.email)
    return {"access_token": login_res.session.access_token,
            "refresh_token": login_res.session.refresh_token, "parent": parent}


# ---------------------------------------------------------------------------
# Sign in with Apple. Checks and their reasons: apple_auth.py.
# ---------------------------------------------------------------------------

@router.post("/apple", response_model=schemas.AuthResponse)
@limiter.limit("10/minute")
def sign_in_with_apple(request: Request, body: schemas.AppleSignInRequest, db: Session = Depends(get_db)):
    if not supabase:
        raise HTTPException(status_code=500, detail="Supabase client not configured")
    try:
        claims = apple_auth.verify_identity_token(body.identity_token, body.nonce)
    except apple_auth.AppleTokenError as e:
        raise HTTPException(status_code=401, detail=str(e))

    try:
        res = supabase.auth.sign_in_with_id_token({
            "provider": "apple", "token": body.identity_token, "nonce": body.nonce,
        })
    except Exception as e:
        logger.error("Supabase rejected an Apple token we accepted: %s", getattr(e, "message", None) or e)
        raise HTTPException(status_code=401, detail="Apple sign-in couldn't be completed. Try again.")
    if not res.session or not res.user:
        raise HTTPException(status_code=401, detail="Apple sign-in couldn't be completed. Try again.")

    parent = _ensure_parent(db, res.user.id, res.user.email or claims.get("email"))
    if body.full_name and not (parent.name or "").strip():
        name = _sanitize_name(body.full_name.strip())[:60]
        if name:
            parent.name = name
    if body.authorization_code:
        refresh_token = apple_auth.exchange_code(body.authorization_code, claims["sub"])
        if refresh_token:
            parent.apple_refresh_token_enc = apple_auth.encrypt_token(refresh_token)
    db.commit()
    db.refresh(parent)
    return {"access_token": res.session.access_token,
            "refresh_token": res.session.refresh_token, "parent": parent}


@router.post("/login", response_model=schemas.AuthResponse)
@limiter.limit("5/minute")  # H-1: rate limit
def login(request: Request, body: schemas.EmailAuthRequest, db: Session = Depends(get_db)):
    return _do_login(body, db)


def _do_login(body: schemas.EmailAuthRequest, db: Session) -> dict:
    """Shared login logic used by both /login and the register-on-existing path."""
    if not supabase:
        raise HTTPException(status_code=500, detail="Supabase client not configured")
    try:
        res = supabase.auth.sign_in_with_password({"email": body.email, "password": body.password})
        if not res.user:
            raise HTTPException(status_code=401, detail="Invalid credentials")

        parent = db.query(models.Parent).filter(models.Parent.id == res.user.id).first()
        if not parent:
            parent = models.Parent(id=res.user.id, email=res.user.email, plan="free")
            db.add(parent)
            db.commit()
            db.refresh(parent)

        return {"access_token": res.session.access_token, "refresh_token": res.session.refresh_token, "parent": parent}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=401, detail=str(e))


@router.get("/me", response_model=schemas.ParentResponse)
def get_me(current_parent: models.Parent = Depends(get_current_parent)):
    """The signed-in parent's own profile."""
    return current_parent


@router.put("/me", response_model=schemas.ParentResponse)
def update_me(update: schemas.ParentUpdate, current_parent: models.Parent = Depends(get_current_parent),
              db: Session = Depends(get_db)):
    current_parent.name = update.name
    db.commit()
    db.refresh(current_parent)
    return current_parent


# ---------------------------------------------------------------------------
# M-1: Terms acceptance — write terms_accepted_at and terms_version to DB.
# ---------------------------------------------------------------------------

class TermsAcceptRequest(BaseModel):
    version: int = 1


@router.post("/terms-accept", response_model=schemas.ParentResponse)
def accept_terms(
    body: TermsAcceptRequest,
    current_parent: models.Parent = Depends(get_current_parent),
    db: Session = Depends(get_db),
):
    """Record that the parent has accepted the current terms and privacy policy.
    Called at the end of ParentBetaAgreementStep before advancing. Idempotent:
    calling it again updates the timestamp (useful if the terms version changes).
    """
    current_parent.terms_accepted_at = datetime.now(timezone.utc)
    current_parent.terms_version = body.version
    db.commit()
    db.refresh(current_parent)
    return current_parent


@router.post("/session", response_model=schemas.ParentSessionResponse)
def start_parent_session(current_parent: models.Parent = Depends(get_current_parent),
                         db: Session = Depends(get_db)):
    """Trades the sign-in (a Supabase access token) for this phone's own
    session token, which keeps the parent signed in until they sign out."""
    token = secrets.token_urlsafe(32)
    db.add(models.ParentSession(parent_id=current_parent.id, token_hash=hash_token(token)))
    db.commit()
    return {"session_token": token}


@router.post("/logout")
def end_parent_session(credentials: HTTPAuthorizationCredentials = Depends(security),
                       db: Session = Depends(get_db)):
    """Sign out on this phone: its session token stops working. Other phones
    stay signed in."""
    row = db.query(models.ParentSession).filter(
        models.ParentSession.token_hash == hash_token(credentials.credentials),
        models.ParentSession.revoked_at == None,  # noqa: E711
    ).first()
    if row:
        row.revoked_at = datetime.now(timezone.utc)
        db.commit()
    return {"detail": "Signed out"}


@router.post("/refresh", response_model=schemas.RefreshResponse)
def refresh(request: schemas.RefreshRequest):
    """Trade a Supabase refresh token for a fresh access token. Access tokens
    only live about an hour, so without this every session died after that."""
    if not supabase:
        raise HTTPException(status_code=500, detail="Supabase client not configured")
    try:
        res = supabase.auth.refresh_session(request.refresh_token)
    except Exception as e:
        # Only a refusal ends the session. The app keeps its refresh token
        # through a 503 and tries again later.
        if _supabase_refused(e):
            raise HTTPException(status_code=401, detail=str(e))
        raise _unavailable(e)
    if not res.session:
        raise HTTPException(status_code=401, detail="Session expired")
    return {"access_token": res.session.access_token, "refresh_token": res.session.refresh_token}


@router.post("/verify-parent", response_model=schemas.ParentResponse)
def verify_parent(request: VerifyTokenRequest, db: Session = Depends(get_db)):
    """Used initially to sync the Supabase auth user into our local database"""
    if not supabase:
        raise HTTPException(status_code=500, detail="Supabase client not configured")

    try:
        user_res = supabase.auth.get_user(request.access_token)
        user = user_res.user
        if not user:
            raise HTTPException(status_code=401, detail="Invalid token")

        parent = db.query(models.Parent).filter(models.Parent.id == user.id).first()
        if not parent:
            parent = models.Parent(id=user.id, email=user.email, plan="free")
            db.add(parent)
            db.commit()
            db.refresh(parent)

        return parent
    except Exception as e:
        raise HTTPException(status_code=401, detail=str(e))


def generate_unique_pairing_code(db: Session) -> str:
    """A 6-digit code not currently used by any live pairing."""
    while True:
        code = "".join(random.choices(string.digits, k=6))
        if not db.query(models.DevicePairing).filter(models.DevicePairing.code == code).first():
            return code


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


# ---------------------------------------------------------------------------
# L-1: child_name sanitization — strip to safe characters only.
# ---------------------------------------------------------------------------
_SAFE_NAME_RE = re.compile(r"[^a-zA-Z0-9 '\-.,!?]")


def _sanitize_name(name: str) -> str:
    """Remove characters outside a safe allowlist, collapse whitespace."""
    cleaned = _SAFE_NAME_RE.sub("", name)
    return " ".join(cleaned.split())


def _create_placeholder_child(db: Session, parent: models.Parent, name: str = "Your Child") -> models.Child:
    count = db.query(models.ParentChild).filter(models.ParentChild.parent_id == parent.id).count()
    new_child = models.Child(name=name, birth_year=2015, color_index=count % 8, avatar_url="")
    db.add(new_child)
    db.commit()
    db.refresh(new_child)

    db.add(models.ParentChild(parent_id=parent.id, child_id=new_child.id, role="primary"))
    db.add(models.ChildRule(child_id=new_child.id, daily_limit_minutes=60, downtime_enabled=False))
    db.add(models.ChildState(child_id=new_child.id, manual_lock=False, task_gate_override=False))
    db.commit()
    return new_child


def _usable_name(name: Optional[str]) -> Optional[str]:
    # A name with no letters ("423186") is a mistyped code, not a name.
    if name and any(ch.isalpha() for ch in name):
        # L-1: sanitize before storing
        return _sanitize_name(name.strip())[:60]
    return None


def _live_pairing(db: Session, code: str) -> Optional[models.DevicePairing]:
    p = db.query(models.DevicePairing).filter(models.DevicePairing.code == code).first()
    if not p:
        return None
    exp = p.expires_at if p.expires_at.tzinfo else p.expires_at.replace(tzinfo=timezone.utc)
    return p if exp >= datetime.now(timezone.utc) else None


@router.post("/pairing/request", response_model=schemas.PairingRequestResponse)
@limiter.limit("10/minute")  # H-1: rate limit — prevents pairing-code flood
def request_pairing(request: Request, body: schemas.PairingRequest, db: Session = Depends(get_db)):
    """Kid's device: start pairing. Show `code` (text + QR) and poll /pairing/status."""
    now = datetime.now(timezone.utc)
    # L-2: delete only already-expired rows directly instead of loading all
    # rows into Python first (avoids an O(n) full-table scan on every request).
    db.query(models.DevicePairing).filter(models.DevicePairing.expires_at < now).delete(synchronize_session=False)
    db.commit()

    code = generate_unique_pairing_code(db)
    secret = secrets.token_urlsafe(32)
    pairing = models.DevicePairing(
        code=code,
        secret_hash=hash_token(secret),
        child_name=_usable_name(body.child_name),
        platform=body.platform,
        expires_at=now + timedelta(minutes=15),
    )
    db.add(pairing)
    db.commit()
    return {"code": code, "secret": secret, "expires_at": pairing.expires_at}


@router.post("/pairing/claim", response_model=schemas.ChildResponse)
@limiter.limit("10/minute")  # H-1: rate limit — slows pairing-code brute-force
def claim_pairing(request: Request, body: schemas.PairingClaimRequest,
                  current_parent: models.Parent = Depends(get_current_parent),
                  db: Session = Depends(get_db)):
    """Parent: attach the device showing `code` to one of their children."""
    pairing = _live_pairing(db, body.code.strip())
    if not pairing:
        raise HTTPException(status_code=400, detail="Invalid or expired code")
    if pairing.child_id is not None:
        raise HTTPException(status_code=409, detail="That code was already used")

    kid_name = pairing.child_name
    if body.child_id:
        link = db.query(models.ParentChild).filter(
            models.ParentChild.parent_id == current_parent.id,
            models.ParentChild.child_id == body.child_id,
        ).first()
        if not link:
            raise HTTPException(status_code=404, detail="Child not found")
        child = db.query(models.Child).filter(models.Child.id == body.child_id).first()
    elif body.new_child:
        child = _create_placeholder_child(db, current_parent, kid_name or "Your Child")
    else:
        # Reuse a child that has no device yet (e.g. profile made earlier), else make one.
        child = None
        for link in db.query(models.ParentChild).filter(models.ParentChild.parent_id == current_parent.id).all():
            has_device = db.query(models.Device).filter(models.Device.child_id == link.child_id, models.Device.revoked_at == None).first()  # noqa: E711
            if not has_device:
                child = db.query(models.Child).filter(models.Child.id == link.child_id).first()
                break
        if child is None:
            child = _create_placeholder_child(db, current_parent, kid_name or "Your Child")

    # The kid typed their own name on their device; use it unless the parent
    # already gave this profile a real one.
    if kid_name and child.name in ("Your Child", "Child", ""):
        child.name = kid_name
    pairing.child_id = child.id
    db.commit()
    db.refresh(child)
    child.is_paired = False  # becomes true once the device collects its token
    return child


@router.post("/pairing/status", response_model=schemas.PairingStatusResponse)
@limiter.limit("30/minute")  # H-1: rate limit — kid device polls this; 30/min = every 2s headroom
def pairing_status(request: Request, body: schemas.PairingStatusRequest, db: Session = Depends(get_db)):
    """Kid's device: has a parent claimed my code? If so, returns the device
    token exactly once."""
    pairing = _live_pairing(db, body.code.strip())
    if not pairing or not secrets.compare_digest(pairing.secret_hash, hash_token(body.secret)):
        raise HTTPException(status_code=404, detail="Pairing not found or expired")
    if pairing.child_id is None:
        return {"status": "pending"}

    child = db.query(models.Child).filter(models.Child.id == pairing.child_id).first()
    access_token = secrets.token_urlsafe(32)
    # MVP: one active device per child.
    db.query(models.Device).filter(models.Device.child_id == child.id).delete()
    db.add(models.Device(
        child_id=child.id,
        platform=pairing.platform,
        token_hash=hash_token(access_token),
        # H-4: record when this device token was last used; used by
        # get_current_device to enforce DEVICE_TOKEN_EXPIRY_DAYS.
        paired_at=datetime.now(timezone.utc),
    ))
    db.delete(pairing)
    db.commit()
    child.is_paired = True
    return {"status": "paired", "access_token": access_token, "child": child}


def get_current_device(credentials: HTTPAuthorizationCredentials = Depends(security), db: Session = Depends(get_db)) -> models.Device:
    """Dependency to authenticate child devices using the token generated during pairing."""
    token_hash = hash_token(credentials.credentials)

    device = db.query(models.Device).filter(
        models.Device.token_hash == token_hash,
        models.Device.revoked_at == None  # noqa: E711
    ).first()

    if not device:
        raise HTTPException(status_code=401, detail="Invalid or revoked device token")

    # No expiry: a kid's device stays paired until the parent unpairs it
    # (DELETE /children/{id}/device), removes the child, or pairs another
    # device. It used to lapse 90 days after pairing, however much it was used.
    return device


@router.delete("/account")
def delete_account(current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    # Sign in with Apple must be revoked on deletion (App Store 5.1.1(v)).
    # Best effort: a failure is logged and the deletion goes ahead.
    if current_parent.apple_refresh_token_enc:
        token = apple_auth.decrypt_token(current_parent.apple_refresh_token_enc)
        if token:
            apple_auth.revoke(token)
    parent_id = str(current_parent.id)
    # Cascade delete is usually handled by the DB, but let's manually clean up the main links
    child_ids = [pc.child_id for pc in db.query(models.ParentChild).filter(models.ParentChild.parent_id == current_parent.id).all()]
    db.query(models.ParentChild).filter(models.ParentChild.parent_id == current_parent.id).delete()
    # Children (and their tasks/devices, via FK cascade) no other parent still
    # links to would otherwise be left orphaned with a live device token.
    for cid in child_ids:
        if not db.query(models.ParentChild).filter(models.ParentChild.child_id == cid).first():
            db.query(models.Child).filter(models.Child.id == cid).delete()
    db.delete(current_parent)
    db.commit()
    # The sign-in itself, so the email is free again and the password, Apple
    # or Google login stops working. Our data is already gone either way.
    if supabase:
        try:
            supabase.auth.admin.delete_user(parent_id)
        except Exception as e:
            logger.error("Deleted parent %s but not their Supabase user: %s", parent_id, e)
    return {"message": "Account deleted successfully"}
