"""Email sign-up codes: issue, throttle, check.

Threat model and what answers it:

- Claiming someone else's address (account pre-hijacking). The Supabase
  account is created only after the code sent to the address comes back, so
  nobody gets an account for an inbox they can't read.
- Guessing the code. Six random digits, valid 10 minutes, at most 5 guesses
  per code, at most 5 codes per address per hour: about 25 guesses an hour
  against a million possibilities. The guess counter is incremented with a
  conditional UPDATE before comparing, so parallel requests can't exceed it.
- A database leak. Only an HMAC of (purpose, email, code) under a server key
  is stored; six digits alone would fall to a plain hash in milliseconds.
- Flooding an inbox. One code per address per minute and five per hour, on
  top of the per-IP limits on the routes.
- Finding out who has an account. Starting a sign-up answers the same way
  for every address. An address that already has an account is sent a note
  saying so instead of a code, so only the inbox owner learns it.
"""
import hashlib
import hmac
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Optional

from sqlalchemy import func, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

import models
from auth_secrets import derive_key

CODE_DIGITS = 6
CODE_TTL = timedelta(minutes=10)
RESEND_COOLDOWN = timedelta(seconds=60)
SEND_WINDOW = timedelta(hours=1)
MAX_SENDS_PER_WINDOW = 5
MAX_ATTEMPTS = 5

SIGNUP = "signup"


def normalize_email(email: str) -> str:
    return email.strip().lower()


def _aware(dt: Optional[datetime]) -> Optional[datetime]:
    # SQLite hands back naive datetimes; Postgres timestamptz aware ones.
    if dt is None or dt.tzinfo:
        return dt
    return dt.replace(tzinfo=timezone.utc)


def _hash_code(email: str, purpose: str, code: str) -> str:
    msg = f"{purpose}\n{email}\n{code}".encode()
    return hmac.new(derive_key("email-code"), msg, hashlib.sha256).hexdigest()


def _new_code() -> str:
    return f"{secrets.randbelow(10 ** CODE_DIGITS):0{CODE_DIGITS}d}"


class Throttled(Exception):
    def __init__(self, retry_after: int, message: str):
        super().__init__(message)
        self.retry_after = retry_after
        self.message = message


@dataclass
class IssuedCode:
    code: Optional[str]  # None when the address already has an account
    row_id: object


def issue(db: Session, email: str, purpose: str, account_exists: bool,
          now: Optional[datetime] = None) -> IssuedCode:
    """Records a new code for `email` and returns it for sending, or raises
    Throttled. For an address that already has an account, a code nobody is
    ever told is stored instead, so the throttles and the response are the
    same either way, and that address can't be "verified" into a second
    account."""
    now = now or datetime.now(timezone.utc)
    row = db.query(models.EmailVerification).filter_by(email=email, purpose=purpose).first()

    if row is not None:
        last = _aware(row.last_sent_at)
        if last and now - last < RESEND_COOLDOWN:
            wait = int((RESEND_COOLDOWN - (now - last)).total_seconds()) + 1
            raise Throttled(wait, f"Wait {wait} seconds before asking for another code.")
        window_start = _aware(row.window_started_at)
        if now - window_start >= SEND_WINDOW:
            row.window_started_at = now
            row.send_count = 0
        elif row.send_count >= MAX_SENDS_PER_WINDOW:
            wait = int((SEND_WINDOW - (now - window_start)).total_seconds()) + 1
            raise Throttled(wait, "Too many codes were sent to this address. Try again later.")
    else:
        row = models.EmailVerification(email=email, purpose=purpose, window_started_at=now,
                                       send_count=0, attempts=0)
        db.add(row)

    code = _new_code()
    row.code_hash = _hash_code(email, purpose, code)
    row.attempts = 0
    row.send_count = (row.send_count or 0) + 1
    row.last_sent_at = now
    row.expires_at = now + CODE_TTL
    try:
        db.commit()
    except IntegrityError:
        # Two requests for the same address at once: the other one won.
        db.rollback()
        raise Throttled(int(RESEND_COOLDOWN.total_seconds()),
                        "A code was just sent. Wait a minute before asking again.")
    return IssuedCode(code=None if account_exists else code, row_id=row.id)


def release_cooldown(db: Session, row_id) -> None:
    """The email didn't go out: let the user ask again right away. The send
    still counts toward the hourly cap."""
    row = db.query(models.EmailVerification).filter_by(id=row_id).first()
    if row:
        row.last_sent_at = None
        db.commit()


class CodeRejected(Exception):
    def __init__(self, message: str):
        super().__init__(message)
        self.message = message


WRONG_OR_EXPIRED = "That code is wrong or has expired. Check the email or ask for a new code."


def check(db: Session, email: str, purpose: str, code: str,
          now: Optional[datetime] = None) -> None:
    """Spends one guess on `code`. Returns on a match and deletes the row,
    so a code works once. Raises CodeRejected otherwise."""
    now = now or datetime.now(timezone.utc)
    code = code.strip()
    row = db.query(models.EmailVerification).filter_by(email=email, purpose=purpose).first()
    if row is None or not code.isdigit() or len(code) != CODE_DIGITS:
        raise CodeRejected(WRONG_OR_EXPIRED)
    if _aware(row.expires_at) < now:
        raise CodeRejected(WRONG_OR_EXPIRED)

    # Take the guess before looking at the code, atomically, so N parallel
    # requests can't each see attempts < MAX and all get to compare.
    taken = db.execute(
        update(models.EmailVerification)
        .where(models.EmailVerification.id == row.id,
               models.EmailVerification.attempts < MAX_ATTEMPTS)
        .values(attempts=models.EmailVerification.attempts + 1)
    ).rowcount
    db.commit()
    if not taken:
        raise CodeRejected("Too many wrong tries. Ask for a new code.")

    db.refresh(row)
    if not hmac.compare_digest(row.code_hash, _hash_code(email, purpose, code)):
        if row.attempts >= MAX_ATTEMPTS:
            raise CodeRejected("Too many wrong tries. Ask for a new code.")
        raise CodeRejected(WRONG_OR_EXPIRED)

    db.delete(row)
    db.commit()


def parent_exists_with_email(db: Session, email: str) -> bool:
    return db.query(models.Parent).filter(func.lower(models.Parent.email) == email).first() is not None


# ---- messages ------------------------------------------------------------

def signup_code_message(code: str) -> tuple[str, str, str]:
    minutes = int(CODE_TTL.total_seconds() // 60)
    subject = f"{code} is your Evlin code"
    text = (f"Your Evlin sign-up code is {code}.\n\n"
            f"It expires in {minutes} minutes. Type it into the Evlin app to finish "
            "creating your account.\n\n"
            "If you didn't try to sign up, you can ignore this email. Nobody can "
            "use your address without this code.\n\n"
            "Evlin will never ask you for this code by phone, text or email.")
    html = (f"<p>Your Evlin sign-up code is</p>"
            f"<p style=\"font-size:28px;font-weight:700;letter-spacing:6px\">{code}</p>"
            f"<p>It expires in {minutes} minutes. Type it into the Evlin app to finish "
            "creating your account.</p>"
            "<p>If you didn't try to sign up, you can ignore this email. Nobody can use "
            "your address without this code.</p>"
            "<p>Evlin will never ask you for this code by phone, text or email.</p>")
    return subject, text, html


def already_registered_message() -> tuple[str, str, str]:
    subject = "You already have an Evlin account"
    text = ("Someone just tried to create an Evlin account with this email address, "
            "but you already have one.\n\n"
            "If that was you, open Evlin and sign in instead. If it wasn't, you can "
            "ignore this email. Your account hasn't changed.")
    html = ("<p>Someone just tried to create an Evlin account with this email address, "
            "but you already have one.</p>"
            "<p>If that was you, open Evlin and sign in instead. If it wasn't, you can "
            "ignore this email. Your account hasn't changed.</p>")
    return subject, text, html
