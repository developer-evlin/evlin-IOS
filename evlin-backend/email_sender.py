"""Sends transactional email through Resend's HTTPS API.

Render's free web services block outbound SMTP ports, so this uses HTTPS.
Needs RESEND_API_KEY and EMAIL_FROM (an address on a domain verified in
Resend, e.g. "Evlin <no-reply@mail.example.com>").
"""
import logging
import os

import httpx

logger = logging.getLogger(__name__)

RESEND_URL = "https://api.resend.com/emails"


class EmailNotConfigured(RuntimeError):
    pass


class EmailSendFailed(RuntimeError):
    pass


def email_configured() -> bool:
    return bool(os.getenv("RESEND_API_KEY") and os.getenv("EMAIL_FROM"))


def send_email(to: str, subject: str, text: str, html: str) -> None:
    if not email_configured():
        raise EmailNotConfigured("RESEND_API_KEY and EMAIL_FROM must be set")
    try:
        r = httpx.post(
            RESEND_URL,
            headers={"Authorization": f"Bearer {os.environ['RESEND_API_KEY']}"},
            json={"from": os.environ["EMAIL_FROM"], "to": [to], "subject": subject,
                  "text": text, "html": html},
            timeout=10,
        )
    except httpx.HTTPError as e:
        raise EmailSendFailed(f"Resend unreachable: {type(e).__name__}") from e
    if r.status_code >= 300:
        # Resend's body explains the failure (unverified domain, bad key).
        # It never contains the message itself, so it's safe to log.
        logger.error("Resend rejected an email: %s %s", r.status_code, r.text[:300])
        raise EmailSendFailed(f"Resend returned {r.status_code}")
