import uuid
from sqlalchemy import (UniqueConstraint, CheckConstraint, ForeignKeyConstraint, Index, Column, String, Integer,
                        BigInteger, Boolean, DateTime, Time, Date, ForeignKey, JSON, text)
from sqlalchemy.dialects.postgresql import UUID, ARRAY
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
from database import Base

class Parent(Base):
    __tablename__ = "parents"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    email = Column(String, nullable=False)
    name = Column(String)
    plan = Column(String, nullable=False, default="free")
    terms_accepted_at = Column(DateTime(timezone=True))
    terms_version = Column(Integer)
    # Apple's refresh token for this account, encrypted (apple_auth.py). It
    # is kept only so deleting the account can revoke Sign in with Apple, as
    # the App Store requires. Null for email and Google accounts.
    apple_refresh_token_enc = Column(String)

class EmailVerification(Base):
    """A pending email sign-up: the code sent to `email`, waiting to be typed
    back. The Supabase account is created only once the code matches, so an
    address can't be claimed by someone who doesn't read its inbox.

    One row per (email, purpose). Only an HMAC of the code is stored
    (email_verification.py). `attempts` caps guesses at this code;
    `send_count` and `window_started_at` cap how many codes one address can
    be sent per hour, so the endpoint can't be used to flood an inbox.
    """
    __tablename__ = "email_verifications"
    __table_args__ = (UniqueConstraint("email", "purpose"), {"schema": "app"})

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    email = Column(String, nullable=False)
    purpose = Column(String, nullable=False, default="signup")
    code_hash = Column(String, nullable=False)
    attempts = Column(Integer, nullable=False, default=0)
    send_count = Column(Integer, nullable=False, default=0)
    window_started_at = Column(DateTime(timezone=True), nullable=False)
    last_sent_at = Column(DateTime(timezone=True))
    expires_at = Column(DateTime(timezone=True), nullable=False)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())


class Child(Base):
    __tablename__ = "children"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String, nullable=False)
    birth_year = Column(Integer)
    color_index = Column(Integer, nullable=False, default=0)
    avatar_url = Column(String)
    activated_at = Column(DateTime(timezone=True))
    # IANA name ("Europe/London"), reported by the child's own device. What
    # "today" and "right now" mean for this child — a scheduled block's
    # window, which day a grant lands on — rather than the server's UTC.
    timezone = Column(String)
    # The child's profile as picked on their device in setup (2026-11-20):
    # an age bracket ("4-6", "7-9", "10-12", "13-17"), never a birthdate,
    # and "female" | "male" | "other". The parent can change both.
    age_range = Column(String)
    gender = Column(String)
    # When the family added the child: the free plan covers the first one.
    # Not "created_at": an old migration drops children.created_at on every
    # boot (main.py), and a rolled-back server would run it again.
    added_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    updated_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), onupdate=func.now())
    # Per-field last write wins, as on tasks (edits.py).
    field_edits = Column(JSON)

class AccessCode(Base):
    """The screen time access code (2026-11-19): six random digits a parent
    types on their child's device to get into its settings. One parent's
    code opens any of their children's devices. Made on the server when the
    parent's phone asks (routers/access_codes.py), good for a minute and
    once only, and checked only here: it never lives on a device."""
    __tablename__ = "access_codes"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    parent_id = Column(UUID(as_uuid=True), ForeignKey("app.parents.id", ondelete="CASCADE"), nullable=False)
    code = Column(String, nullable=False)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    expires_at = Column(DateTime(timezone=True), nullable=False)
    # Typed on a child's device: it opens nothing again.
    used_at = Column(DateTime(timezone=True))


class ParentChild(Base):
    __tablename__ = "parent_children"
    __table_args__ = {"schema": "app"}

    parent_id = Column(UUID(as_uuid=True), ForeignKey("app.parents.id", ondelete="CASCADE"), primary_key=True)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), primary_key=True)
    role = Column(String, nullable=False, default="primary")
    invited_at = Column(DateTime(timezone=True))
    accepted_at = Column(DateTime(timezone=True))

class Device(Base):
    __tablename__ = "devices"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    platform = Column(String, nullable=False)
    token_hash = Column(String, nullable=False)
    desired_version = Column(Integer, nullable=False, default=0)
    acked_version = Column(Integer, nullable=False, default=0)
    paired_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    revoked_at = Column(DateTime(timezone=True))
    # When the kid finished setting this device up (permissions, apps to
    # lock). Until then the parent's onboarding waits; a new pairing is a
    # new row, so it waits again.
    setup_completed_at = Column(DateTime(timezone=True))
    # Where the kid's device is in setting up Family Sharing (2026-11-11):
    # "account_created" once the parent has made the child's Apple Account
    # (the parent's phone then shows how to sign this device in with it);
    # NULL otherwise. Only onboarding reads it.
    setup_stage = Column(String)
    # Whether Evlin still has Screen Time access on this device, as the
    # device last reported it (NULL: not reported yet). A change to false
    # tells the parents (notifications, "screen_time_off").
    screen_time_access = Column(Boolean)
    # Who signed it out, with revoked_at: "child_device" (Log out on it) or
    # "parent", so a parent isn't told about their own unpair.
    signed_out_by = Column(String)
    # When the device last synced, for "Mia's iPad · updated 2 h ago". Must
    # be written with a plain UPDATE, never through the ORM object: a
    # Device change announces a live update, which makes the device sync,
    # which would write it again.
    last_synced_at = Column(DateTime(timezone=True))

class ParentSession(Base):
    """A parent's phone, signed in. Like a kid's device token: issued once
    after sign-in (POST /auth/session), stored hashed, never expires and is
    never renewed. It ends only on Sign out (POST /auth/logout) or when the
    account is deleted, so a parent signs in once per phone. Supabase still
    proves who they are at sign-in; it isn't what keeps them signed in."""
    __tablename__ = "parent_sessions"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    parent_id = Column(UUID(as_uuid=True), ForeignKey("app.parents.id", ondelete="CASCADE"), nullable=False)
    token_hash = Column(String, nullable=False, unique=True)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    revoked_at = Column(DateTime(timezone=True))

class PairingCode(Base):
    __tablename__ = "pairing_codes"
    __table_args__ = {"schema": "app"}

    code = Column(String, primary_key=True)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    parent_id = Column(UUID(as_uuid=True), ForeignKey("app.parents.id", ondelete="CASCADE"), nullable=False)
    expires_at = Column(DateTime(timezone=True), nullable=False)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())

class DevicePairing(Base):
    """A pairing started by the kid's device: it shows `code` (as text and a
    QR) and waits. A parent claims it, which fills in child_id; the device then
    trades its `secret` for a long-lived token."""
    __tablename__ = "device_pairings"
    __table_args__ = {"schema": "app"}

    code = Column(String, primary_key=True)
    secret_hash = Column(String, nullable=False)
    child_name = Column(String)
    platform = Column(String, nullable=False, default="ios")
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"))
    expires_at = Column(DateTime(timezone=True), nullable=False)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())

class Task(Base):
    __tablename__ = "tasks"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    title = Column(String, nullable=False)
    instructions = Column(String)
    # Free-form UI label ("Chore", "Study", …) for icon/badge display — not
    # the same thing as `bucket` below, which the DB constrains to a fixed
    # time-of-day vocabulary and is derived server-side (see routers/tasks.py).
    category = Column(String)
    # Reserved for a future kid-side per-task icon picker — nothing sets or
    # reads this yet, kept nullable/free-form on purpose so that feature can
    # land without another migration (an SF Symbol name or an asset key,
    # whichever the UI ends up using).
    icon = Column(String)
    bucket = Column(String, nullable=False, default="anytime")
    due_time = Column(Time)
    # Day a one-off task is for / the day a repeating task starts. NULL means
    # "the day it was created".
    due_date = Column(Date)
    recurrence = Column(String, nullable=False, default="daily")
    # A repeating task's exceptions, as calendars keep them: the days taken
    # out of it ("This task" deleted or edited on its own), as a list of
    # "YYYY-MM-DD", and its last day ("This and following tasks"). NULL for
    # none. Written only by routers/tasks.py's cut and split.
    skipped_dates = Column(JSON)
    repeat_until = Column(Date)
    # The task this one was split from ("This task" or "This and following
    # tasks" edited), so a child's device that sends in a day under the old
    # task's id, offline meanwhile, can be followed to this one.
    split_from = Column(UUID(as_uuid=True), ForeignKey("app.tasks.id", ondelete="SET NULL"))
    gates_apps = Column(Boolean, nullable=False, default=True)
    submission_kind = Column(String, nullable=False, default="none")
    active = Column(Boolean, nullable=False, default=True)
    # Screen-time minutes awarded to the child's time_grants ledger the
    # moment this task's occurrence is approved — see TimeGrant below.
    # Zero (the default) means "no bonus," same as every other task today.
    bonus_minutes = Column(Integer, nullable=False, default=0)
    # 'parent' | 'ai_agent' | 'system' — who/what authored this task.
    created_by = Column(String, nullable=False, default="parent")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    # When it last changed, and when each field last changed by the phone's
    # edit time (edits.py: per-field last write wins).
    updated_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), onupdate=func.now())
    field_edits = Column(JSON)

class Occurrence(Base):
    __tablename__ = "occurrences"
    # One per task per day (main.py's occurrences_task_day_uniq).
    __table_args__ = (UniqueConstraint("task_id", "due_date", name="occurrences_task_day_uniq"),
                      {"schema": "app"})

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    task_id = Column(UUID(as_uuid=True), ForeignKey("app.tasks.id", ondelete="CASCADE"), nullable=False)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    due_date = Column(Date, nullable=False)
    due_time = Column(Time)
    status = Column(String, nullable=False, default="pending")
    gates_apps = Column(Boolean, nullable=False)
    completed_at = Column(DateTime(timezone=True))
    approved_at = Column(DateTime(timezone=True))
    approved_by = Column(UUID(as_uuid=True), ForeignKey("app.parents.id"))
    rejection_note = Column(String)
    bypass_requested = Column(Boolean, nullable=False, default=False)
    bypass_note = Column(String)
    updated_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), onupdate=func.now())

class Submission(Base):
    __tablename__ = "submissions"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    occurrence_id = Column(UUID(as_uuid=True), ForeignKey("app.occurrences.id", ondelete="CASCADE"), nullable=False)
    kind = Column(String, nullable=False)
    r2_key = Column(String, nullable=False)
    content_type = Column(String, nullable=False)
    bytes_size = Column("bytes", Integer) # Maps the 'bytes' db column to bytes_size to avoid python keyword conflict
    status = Column(String, nullable=False, default="pending")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    uploaded_at = Column(DateTime(timezone=True))

class ChildRule(Base):
    __tablename__ = "child_rules"
    __table_args__ = {"schema": "app"}

    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), primary_key=True)
    daily_limit_minutes = Column(Integer, nullable=False, default=60)
    downtime_enabled = Column(Boolean, nullable=False, default=False)
    downtime_start = Column(Time)
    downtime_end = Column(Time)
    # Calendar-style override: {"mon": 120, ...}. NULL (every child today)
    # means "use daily_limit_minutes every day" — see routers/time_grants.py.
    weekly_schedule = Column(JSON)
    # The weekdays downtime runs on, as ["mon", ...] (tasks' and
    # weekly_schedule's codes). NULL means every day.
    downtime_days = Column(JSON)
    # Each day's own downtime hours, when they differ by day:
    # {"mon": {"start": "20:00", "end": "07:00"}, ...}. NULL means every day
    # it runs uses downtime_start/downtime_end.
    downtime_schedule = Column(JSON)
    # Whether the daily screen-time limit is switched on, and the parent's
    # free-form rules (from chat): [{"id","title","detail","icon","on"}].
    daily_limit_enabled = Column(Boolean, nullable=False, default=True)
    custom_rules = Column(JSON, nullable=False, default=list)
    updated_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())

class ChildState(Base):
    __tablename__ = "child_state"
    __table_args__ = {"schema": "app"}

    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), primary_key=True)
    manual_lock = Column(Boolean, nullable=False, default=False)
    task_gate_override = Column(Boolean, nullable=False, default=False)
    # Work sent in opens the device, without waiting for the parent's approval.
    instant_unlock = Column(Boolean, nullable=False, default=False)
    updated_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    # Per-field last write wins for the lock flags (edits.py).
    field_edits = Column(JSON)
    # Instant unlock (instant_unlock.py): earned by 3 approved days, counted
    # from `instant_unlock_reset_on` (turning it off restarts the count);
    # the server refuses "on" until `instant_unlock_earned_at` is set.
    instant_unlock_earned_at = Column(DateTime(timezone=True))
    instant_unlock_reset_on = Column(Date)
    instant_unlock_changed_by = Column(UUID(as_uuid=True), ForeignKey("app.parents.id", ondelete="SET NULL"))

class TimeGrant(Base):
    """One append-only entry in a child's screen-time pool — never a
    mutable balance. Two independently-offline devices (a parent granting
    while the kid has no signal, or vice versa) each just insert their own
    row on next sync; nothing ever overwrites another row, so there's no
    lost-update race the way a single mutable balance field would have.
    `available_today` for a child is daily_limit_minutes (child_rules) +
    SUM(minutes WHERE credited_date = today) — see routers/time_grants.py.
    """
    __tablename__ = "time_grants"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    # Signed: a deduction (an agent or a parent taking time away) is a
    # negative row, same ledger, same no-lost-update reasoning as a grant.
    minutes = Column(Integer, nullable=False)
    source = Column(String, nullable=False)  # 'manual' | 'task_bonus' | 'ai_agent'
    reason = Column(String)
    # 'parent' | 'ai_agent' | 'system' — distinct from `source` (why), this
    # is *what kind of actor* made the change.
    created_by = Column(String, nullable=False, default="parent")
    granted_by_parent_id = Column(UUID(as_uuid=True), ForeignKey("app.parents.id"))
    # Deliberately not a real FK: it points at whatever earned the grant (an
    # occurrence, for a task bonus), so a new kind of reward can write here
    # with no migration to this table.
    source_ref_id = Column(UUID(as_uuid=True))
    credited_date = Column(Date, nullable=False)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())

class ChildMemory(Base):
    """One durable fact about a child, extracted from conversation.

    Plain rows rather than embeddings, and that's a product decision before
    it's a technical one: a parent has to be able to read and delete what
    this system believes about their child, and you cannot show someone a
    vector. At a few dozen facts per child, retrieval is "put them all in the
    prompt" — semantic search would solve a problem that doesn't exist here.

    What belongs here is only what has no column of its own. Bedtime lives in
    child_rules.downtime_start; a remembered copy would be a second source of
    truth that silently goes stale. This is for preferences, family context,
    and what worked last time.

    Archived rather than deleted, so a fact a parent removed can't be
    re-extracted and quietly reappear.
    """
    __tablename__ = "child_memory"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    fact = Column(String, nullable=False)
    category = Column(String)  # routine | preference | context | what_worked
    source_message_id = Column(UUID(as_uuid=True), ForeignKey("app.chat_messages.id", ondelete="SET NULL"))
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    archived_at = Column(DateTime(timezone=True))


class ChatConversation(Base):
    """One thread of chat about one child.

    Chat used to be a single continuous transcript per child, which the
    history sidebar had always been designed against as separate named
    threads — so that UI ran on mock data and couldn't rename, delete or
    search anything for real. This table is what makes it real.

    Unrelated to the legacy chat.conversations in evlin-tables.sql, which
    models 'setup' vs 'kid_agent' surfaces and is dead (no model, no router,
    nothing writes it). Different schema, so no collision.

    parent_id is attribution only, and ON DELETE SET NULL so it can't block
    deleting an account.
    """
    __tablename__ = "chat_conversations"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    parent_id = Column(UUID(as_uuid=True), ForeignKey("app.parents.id", ondelete="SET NULL"))
    title = Column(String, nullable=False)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    # What the sidebar orders by — bumped on every message, so an active
    # thread rises to the top.
    updated_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())


class ChatMessage(Base):
    """One message in one conversation.

    This table has no idea an LLM produced the assistant rows — it's just a
    transcript. See gemini_client.py / routers/chat.py.

    conversation_id is nullable only so the backfill of pre-threading rows
    can't leave the table unwritable if it half-fails; the API always sets
    it. child_id is kept alongside it (rather than reached through the
    conversation) because every access check in this backend is child-scoped
    and this keeps those checks one query.
    """
    __tablename__ = "chat_messages"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    conversation_id = Column(UUID(as_uuid=True), ForeignKey("app.chat_conversations.id", ondelete="CASCADE"))
    parent_id = Column(UUID(as_uuid=True), ForeignKey("app.parents.id"))
    role = Column(String, nullable=False)  # 'user' | 'assistant'
    text = Column(String, nullable=False)
    tool_call = Column(String)             # 'draft_task' | 'draft_app_block' | 'ask_follow_up' | null — see tool_calls/
    tool_args = Column(JSON)
    # Which assistant this message is part of. Always 'chat' now; older
    # threads also hold 'youtube' rows from the removed YouTube agent, which
    # chat leaves out of what it sends the model.
    agent = Column(String, nullable=False, default="chat", server_default="chat")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())

class App(Base):
    """One app in Evlin's own catalog — see app_catalog.py.

    Global, not child-scoped: "YouTube" is one row for every family. A
    child's lockable apps and every block point here, so a parent, the AI
    and a later enforcement layer all mean the same thing by "YouTube".
    """
    __tablename__ = "apps"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String, nullable=False)
    aliases = Column(JSON, nullable=False, default=list)
    category = Column(String)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())


class ChildApp(Base):
    """An app on this child's lockable list: what locks when the device is
    locked, and what a block can be about."""
    __tablename__ = "child_apps"
    __table_args__ = {"schema": "app"}

    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), primary_key=True)
    app_id = Column(UUID(as_uuid=True), ForeignKey("app.apps.id", ondelete="CASCADE"), primary_key=True)
    added_by = Column(String, nullable=False, default="parent")  # 'parent' | 'ai_agent'
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())


class AppBlock(Base):
    """One app blocked for this child, either for a while or until a task is
    done.

    The app already had a way to "block an app": a free-text sentence in
    child_rules.custom_rules ("Block TikTok, Blocked for 2h"). That's fine
    for showing a parent what they asked for and useless for anything else —
    no bundle id, no expiry, no task link, nothing a "has this resolved yet"
    check or an enforcement layer could ever read. This is the structured
    version, so "no YouTube until homework is done" can actually resolve
    itself when the homework is approved.

    One row per app. The app is Evlin's own catalog row (app_id) — never a
    platform identifier; app_name is a snapshot for display. Four kinds, and
    what each means at a given moment, live in blocks.py. Expiry is computed
    there, not written: `resolved` is only ever a decision (task_approved,
    parent_lifted).
    """
    __tablename__ = "app_blocks"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    app_id = Column(UUID(as_uuid=True), ForeignKey("app.apps.id", ondelete="SET NULL"))
    app_name = Column(String, nullable=False)
    app_bundle_id = Column(String)  # legacy, no longer written
    block_type = Column(String, nullable=False)  # 'duration' | 'until_task' | 'indefinite' | 'scheduled'
    duration_minutes = Column(Integer)
    ends_at = Column(DateTime(timezone=True))  # duration: fixed at creation
    until_task_id = Column(UUID(as_uuid=True), ForeignKey("app.tasks.id", ondelete="SET NULL"))
    # scheduled: weekday codes the window *starts* on, and child-local times.
    # A window with end <= start runs past midnight.
    schedule_days = Column(String)
    schedule_start = Column(Time)
    schedule_end = Column(Time)
    resolved = Column(Boolean, nullable=False, default=False)
    resolved_reason = Column(String)  # 'task_approved' | 'parent_lifted'
    created_by = Column(String, nullable=False, default="parent")  # 'parent' | 'ai_agent'
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    resolved_at = Column(DateTime(timezone=True))


class Consent(Base):
    __tablename__ = "consent"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    parent_id = Column(UUID(as_uuid=True), ForeignKey("app.parents.id"), nullable=False)
    toggle_key = Column(String, nullable=False)
    granted = Column(Boolean, nullable=False)
    version = Column(Integer, nullable=False, default=1)
    granted_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())

class AuditLog(Base):
    __tablename__ = "audit_log"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id"))
    kind = Column(String, nullable=False)
    payload = Column(JSON, nullable=False, default=dict)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())


class IdempotencyKey(Base):
    """A phone's write already answered (idempotency.py): the same key from
    the same caller gets this answer back instead of running again. Kept a
    day."""
    __tablename__ = "idempotency_keys"
    __table_args__ = {"schema": "app"}

    caller = Column(String, primary_key=True)
    key = Column(String, primary_key=True)
    method = Column(String, nullable=False)
    path = Column(String, nullable=False)
    status = Column(Integer, nullable=False)
    body = Column(String)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())


class Habit(Base):
    """A habit the parent set for a child (routers/habits.py; "goal" in the
    app's code). Counted only by the parent approving the child's check-ins:
    `done` is kept by the server, and `finished_at` makes it a completed
    milestone."""
    __tablename__ = "habits"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    title = Column(String, nullable=False)
    # The drawing (HabitArt key, or "leaf"); NULL: the title's own drawing.
    picture = Column(String)
    target = Column(Integer, nullable=False)
    # "days" (one a day), "times", or "streak" (days in a row; a missed day
    # starts it again).
    unit = Column(String, nullable=False, default="days")
    prize = Column(String, nullable=False, default="")
    color_index = Column(Integer, nullable=False, default=0)
    done = Column(Integer, nullable=False, default=0)
    # The child's local day of the last approved check-in (the streak rule).
    last_counted_day = Column(Date)
    finished_at = Column(DateTime(timezone=True))
    created_by = Column(String, nullable=False, default="parent")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    updated_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), onupdate=func.now())
    field_edits = Column(JSON)


class HabitCheckIn(Base):
    """The child's "I did it" on a habit, one a day, waiting until the
    parent approves it."""
    __tablename__ = "habit_checkins"
    __table_args__ = (UniqueConstraint("habit_id", "day", name="habit_checkins_habit_day_uniq"),
                      {"schema": "app"})

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    habit_id = Column(UUID(as_uuid=True), ForeignKey("app.habits.id", ondelete="CASCADE"), nullable=False)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    # The child's local day it's for.
    day = Column(Date, nullable=False)
    at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    # "waiting" | "approved"
    status = Column(String, nullable=False, default="waiting")
    reviewed_at = Column(DateTime(timezone=True))
    reviewed_by = Column(UUID(as_uuid=True), ForeignKey("app.parents.id", ondelete="SET NULL"))
    updated_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), onupdate=func.now())


# ---- Notifications to parents (2026-11-20) ---------------------------------
# Parents only, about their children: the day's chores sent in, a habit
# checked in, and the child's device signed out of Evlin (Log out, Screen
# Time access off, Evlin deleted). Children never get one; their devices
# get silent "sync now" pushes only.

class PushToken(Base):
    """Where to send: one phone or iPad. A parent's phone hangs off its
    sign-in (Sign out ends it); a child's device off the device (unpairing
    ends it), for silent pushes only."""
    __tablename__ = "push_tokens"
    __table_args__ = (CheckConstraint("(parent_session_id IS NULL) <> (device_id IS NULL)",
                                      name="push_tokens_one_owner"),
                      {"schema": "app"})

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    parent_session_id = Column(UUID(as_uuid=True), ForeignKey("app.parent_sessions.id", ondelete="CASCADE"))
    device_id = Column(UUID(as_uuid=True), ForeignKey("app.devices.id", ondelete="CASCADE"))
    # The APNs device token.
    token = Column(String, nullable=False, unique=True)
    # "sandbox" (run from Xcode) or "production" (TestFlight, App Store).
    environment = Column(String, nullable=False, default="production")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    last_seen_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    # Apple said the token is dead (410, BadDeviceToken): never sent to again.
    disabled_at = Column(DateTime(timezone=True))


class Notification(Base):
    """What to send a parent, and what happened: the outbox and the log.
    Written in the same transaction as the change that causes it, sent
    after the commit, kept 30 days."""
    __tablename__ = "notifications"
    __table_args__ = (Index("notifications_pending_idx", "send_after",
                            postgresql_where=text("status = 'pending'"),
                            sqlite_where=text("status = 'pending'")),
                      {"schema": "app"})

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    # "all_sent_in" | "habit_checked_in" | "device_signed_out" |
    # "screen_time_off" | "evlin_removed" (checked in code, so a new kind
    # needs no migration).
    kind = Column(String, nullable=False)
    parent_id = Column(UUID(as_uuid=True), ForeignKey("app.parents.id", ondelete="CASCADE"), nullable=False)
    # Who it's about.
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"))
    device_id = Column(UUID(as_uuid=True), ForeignKey("app.devices.id", ondelete="SET NULL"))
    # The child's day.
    day = Column(Date)
    # Unique: an insert that hits it does nothing (sent once).
    dedupe_key = Column(String, nullable=False, unique=True)
    title = Column(String, nullable=False)
    body = Column(String, nullable=False, default="")
    # Where a tap opens.
    data = Column(JSON)
    send_after = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    # "pending" | "sent" | "skipped" (turned off, no phone) | "failed"
    status = Column(String, nullable=False, default="pending")
    attempts = Column(Integer, nullable=False, default=0)
    last_error = Column(String)
    sent_at = Column(DateTime(timezone=True))
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())


class NotificationPref(Base):
    """A kind a parent turned off ("tasks", "habits"). Only changes from
    the default (on) have a row. Signed-out warnings can't be turned off."""
    __tablename__ = "notification_prefs"
    __table_args__ = {"schema": "app"}

    parent_id = Column(UUID(as_uuid=True), ForeignKey("app.parents.id", ondelete="CASCADE"), primary_key=True)
    kind = Column(String, primary_key=True)
    enabled = Column(Boolean, nullable=False, default=True)
    updated_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), onupdate=func.now())


# ---- Payments: entitlements (2026-11-20; tables only, not wired yet) --------
# The server decides what a family may do; Apple only takes the money. The
# code asks "what is this family allowed?" (limits by key), never "which
# product did they buy?". Plans are versioned so a subscriber keeps what they
# bought; the free trial and promos are grants; usage is metered.

class Plan(Base):
    """A plan at one version ("free" v1, "pro" v1). New limits are a new
    version; a subscription points at the version it bought."""
    __tablename__ = "plans"
    __table_args__ = {"schema": "app"}

    code = Column(String, primary_key=True)
    version = Column(Integer, primary_key=True)
    name = Column(String, nullable=False)
    is_free = Column(Boolean, nullable=False, default=False)
    # Offered to new buyers; an older version stays for those who have it.
    active = Column(Boolean, nullable=False, default=True)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())


class PlanLimit(Base):
    """One limit of a plan version, by key ("children", "ai_tokens",
    "notify:tasks" …). value NULL is unlimited."""
    __tablename__ = "plan_limits"
    __table_args__ = (ForeignKeyConstraint(["plan_code", "plan_version"], ["app.plans.code", "app.plans.version"],
                                           ondelete="CASCADE"),
                      {"schema": "app"})

    plan_code = Column(String, primary_key=True)
    plan_version = Column(Integer, primary_key=True)
    key = Column(String, primary_key=True)
    value = Column(BigInteger)


class StoreProduct(Base):
    """A store's product (an App Store product id) and the plan version it
    buys. `offered`: shown on the plan page, so prices can change without an
    app release."""
    __tablename__ = "store_products"
    __table_args__ = (ForeignKeyConstraint(["plan_code", "plan_version"], ["app.plans.code", "app.plans.version"]),
                      {"schema": "app"})

    store = Column(String, primary_key=True, default="app_store")
    product_id = Column(String, primary_key=True)
    plan_code = Column(String, nullable=False)
    plan_version = Column(Integer, nullable=False)
    # "monthly" | "yearly"
    period = Column(String, nullable=False)
    offered = Column(Boolean, nullable=False, default=True)


class BillingAccount(Base):
    """Who pays: a family's account. Each parent gets one; later two
    parents can share one (billing_account_members). A purchase's
    appAccountToken is this id, not a parent's."""
    __tablename__ = "billing_accounts"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())


class BillingAccountMember(Base):
    """A parent in a billing account; one account per parent."""
    __tablename__ = "billing_account_members"
    __table_args__ = {"schema": "app"}

    parent_id = Column(UUID(as_uuid=True), ForeignKey("app.parents.id", ondelete="CASCADE"), primary_key=True)
    billing_account_id = Column(UUID(as_uuid=True), ForeignKey("app.billing_accounts.id", ondelete="CASCADE"),
                                nullable=False, index=True)
    # "owner" | "member"
    role = Column(String, nullable=False, default="owner")
    joined_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())


class Subscription(Base):
    """A store subscription as it is now, kept current from Apple's own
    answer (Get All Subscription Statuses) on every notification, verify
    and restore. A purchase covers one account at a time; a family-shared
    copy (Apple's Family Sharing) may cover another."""
    __tablename__ = "subscriptions"
    __table_args__ = (ForeignKeyConstraint(["plan_code", "plan_version"], ["app.plans.code", "app.plans.version"]),
                      Index("subscriptions_purchase_uniq", "store", "original_transaction_id", unique=True,
                            postgresql_where=text("ownership = 'purchased'"),
                            sqlite_where=text("ownership = 'purchased'")),
                      {"schema": "app"})

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    billing_account_id = Column(UUID(as_uuid=True), ForeignKey("app.billing_accounts.id", ondelete="CASCADE"),
                                index=True)
    store = Column(String, nullable=False, default="app_store")
    original_transaction_id = Column(String, nullable=False)
    product_id = Column(String, nullable=False)
    plan_code = Column(String, nullable=False)
    plan_version = Column(Integer, nullable=False)
    # "active" | "grace" | "billing_retry" | "expired" | "revoked"
    status = Column(String, nullable=False)
    # "purchased" | "family_shared"
    ownership = Column(String, nullable=False, default="purchased")
    # "sandbox" | "production"
    environment = Column(String, nullable=False, default="production")
    app_account_token = Column(UUID(as_uuid=True))
    auto_renews = Column(Boolean, nullable=False, default=True)
    current_period_ends_at = Column(DateTime(timezone=True))
    grace_ends_at = Column(DateTime(timezone=True))
    started_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    updated_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), onupdate=func.now())


class SubscriptionEvent(Base):
    """Every store event, stored once: Apple's notifications (by their
    notificationUUID, so a resend is recognised), and our own verify,
    restore, transfer and daily reconcile. The current state can be rebuilt
    from them."""
    __tablename__ = "subscription_events"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    store = Column(String, nullable=False, default="app_store")
    # "notification" | "verify" | "restore" | "transfer" | "reconcile"
    source = Column(String, nullable=False)
    notification_uuid = Column(String, unique=True)
    type = Column(String)
    subtype = Column(String)
    original_transaction_id = Column(String, index=True)
    billing_account_id = Column(UUID(as_uuid=True), ForeignKey("app.billing_accounts.id", ondelete="SET NULL"))
    signed_payload = Column(String)
    received_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    processed_at = Column(DateTime(timezone=True))
    error = Column(String)


class EntitlementGrant(Base):
    """Access given without a purchase: the free trial (once per account,
    ever), a promo, support extending a trial, a referral. Either a whole
    plan version for a while, or one limit raised."""
    __tablename__ = "entitlement_grants"
    __table_args__ = (CheckConstraint("plan_code IS NOT NULL OR limit_key IS NOT NULL", name="entitlement_grants_what"),
                      ForeignKeyConstraint(["plan_code", "plan_version"], ["app.plans.code", "app.plans.version"]),
                      Index("entitlement_grants_one_trial", "billing_account_id", unique=True,
                            postgresql_where=text("source = 'trial'"), sqlite_where=text("source = 'trial'")),
                      {"schema": "app"})

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    billing_account_id = Column(UUID(as_uuid=True), ForeignKey("app.billing_accounts.id", ondelete="CASCADE"),
                                nullable=False)
    # "trial" | "promo" | "support" | "referral"
    source = Column(String, nullable=False)
    plan_code = Column(String)
    plan_version = Column(Integer)
    limit_key = Column(String)
    limit_value = Column(BigInteger)
    starts_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    ends_at = Column(DateTime(timezone=True))
    note = Column(String)
    created_by = Column(UUID(as_uuid=True), ForeignKey("app.parents.id", ondelete="SET NULL"))
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())


class UsageEvent(Base):
    """One metered use (a Chat reply's tokens), append-only. The id is made
    by the caller, so a retry counts once."""
    __tablename__ = "usage_events"
    __table_args__ = (Index("usage_events_account_meter_idx", "billing_account_id", "meter", "occurred_at"),
                      {"schema": "app"})

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    billing_account_id = Column(UUID(as_uuid=True), ForeignKey("app.billing_accounts.id", ondelete="CASCADE"),
                                nullable=False)
    parent_id = Column(UUID(as_uuid=True), ForeignKey("app.parents.id", ondelete="SET NULL"))
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="SET NULL"))
    # "ai_tokens", later others.
    meter = Column(String, nullable=False)
    quantity = Column(BigInteger, nullable=False)
    occurred_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    # Model, input and output tokens, and the like.
    meta = Column(JSON)


class UsageCounter(Base):
    """The running total per account, meter and billing period, updated in
    the same transaction as each usage event: a limit check is one row."""
    __tablename__ = "usage_counters"
    __table_args__ = {"schema": "app"}

    billing_account_id = Column(UUID(as_uuid=True), ForeignKey("app.billing_accounts.id", ondelete="CASCADE"),
                                primary_key=True)
    meter = Column(String, primary_key=True)
    period_start = Column(DateTime(timezone=True), primary_key=True)
    total = Column(BigInteger, nullable=False, default=0)
    updated_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now(), onupdate=func.now())
