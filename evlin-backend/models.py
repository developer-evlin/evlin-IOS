import uuid
from sqlalchemy import UniqueConstraint, Column, String, Integer, Boolean, DateTime, Time, Date, ForeignKey, JSON
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
    push_token = Column(String)
    desired_version = Column(Integer, nullable=False, default=0)
    acked_version = Column(Integer, nullable=False, default=0)
    paired_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
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

class Occurrence(Base):
    __tablename__ = "occurrences"
    __table_args__ = {"schema": "app"}

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
    updated_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())

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
    tool_call = Column(String)             # 'draft_task' | 'draft_event' | 'ask_follow_up' | null — see tool_calls/
    tool_args = Column(JSON)
    # Which assistant this message is part of: 'chat' (the main assistant)
    # or 'youtube' (the YouTube agent, run inside the same thread). Each one
    # is only ever sent its own messages — see agent_sessions.py.
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


class ChildVideoProfile(Base):
    """What this child's videos may be: which categories, how long, and what
    to keep out. One row per child, created on first save; a child with no
    row gets video_filter's defaults (every category allowed).

    Channels are stored as [{"id", "title"}] so a list can be shown without
    asking YouTube; the id is what filtering matches.
    """
    __tablename__ = "child_video_profiles"
    __table_args__ = {"schema": "app"}

    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), primary_key=True)
    allowed_categories = Column(JSON, nullable=False, default=list)
    blocked_keywords = Column(JSON, nullable=False, default=list)
    allowed_channels = Column(JSON, nullable=False, default=list)
    blocked_channels = Column(JSON, nullable=False, default=list)
    daily_minutes = Column(Integer, nullable=False, default=30)
    max_video_minutes = Column(Integer, nullable=False, default=10)
    updated_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())


class VideoQueueItem(Base):
    """One video on a child's list for one day — the only videos the child's
    device will play.

    Only a parent's approval writes these (POST /children/{id}/video-queue,
    from the chat card or the profile). The metadata is a snapshot taken
    when it was approved, so the child's device never talks to YouTube's API
    and a later title change can't alter what the parent agreed to.
    local_date is the child's day (blocks.local_now), not the server's.
    How much of today's allowance is left is computed from watched_seconds
    on read, never stored.
    """
    __tablename__ = "video_queue_items"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    local_date = Column(Date, nullable=False)
    position = Column(Integer, nullable=False, default=0)
    video_id = Column(String, nullable=False)
    title = Column(String, nullable=False)
    channel_id = Column(String)
    channel_title = Column(String)
    thumbnail_url = Column(String)
    duration_seconds = Column(Integer, nullable=False)
    category = Column(String)
    added_by_parent_id = Column(UUID(as_uuid=True), ForeignKey("app.parents.id", ondelete="SET NULL"))
    watched_seconds = Column(Integer, nullable=False, default=0)
    completed_at = Column(DateTime(timezone=True))
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())


class ICSFeed(Base):
    __tablename__ = "ics_feeds"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    parent_id = Column(UUID(as_uuid=True), ForeignKey("app.parents.id", ondelete="CASCADE"), nullable=False)
    feed_url = Column(String, nullable=False)
    last_synced_at = Column(DateTime(timezone=True))
    active = Column(Boolean, nullable=False, default=True)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())

class Event(Base):
    __tablename__ = "events"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    # Every event is one child's. Evlin manages the children's calendars
    # only: there are no parent or family-wide events.
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    title = Column(String, nullable=False)
    start_at = Column(DateTime(timezone=True), nullable=False)
    end_at = Column(DateTime(timezone=True), nullable=False)
    gates_apps = Column(Boolean, nullable=False, default=False)
    location_or_link = Column(String)
    source = Column(String, nullable=False, default="manual")
    category = Column(String)
    note = Column(String)
    # Comma-joined weekday codes ("mon,wed") or "none".
    recurrence = Column(String, nullable=False, default="none")
    ics_feed_id = Column(UUID(as_uuid=True), ForeignKey("app.ics_feeds.id", ondelete="CASCADE"))
    external_uid = Column(String)
    # 'parent' | 'child'. A child's event is their own plan.
    created_by = Column(String, nullable=False, default="parent")
    # 'approved' (on the calendar) | 'proposed' (a child's plan waiting on
    # the parent) | 'declined' (the parent said "Not this one"; it stays,
    # with review_note, until the child dismisses it).
    status = Column(String, nullable=False, default="approved")
    review_note = Column(String)

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
