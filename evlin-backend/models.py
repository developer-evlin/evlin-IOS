import uuid
from sqlalchemy import Column, String, Integer, Boolean, DateTime, Time, Date, ForeignKey, JSON
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

class Child(Base):
    __tablename__ = "children"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String, nullable=False)
    birth_year = Column(Integer)
    color_index = Column(Integer, nullable=False, default=0)
    avatar_url = Column(String)
    activated_at = Column(DateTime(timezone=True))

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
    duration_seconds = Column(Integer)
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
    source = Column(String, nullable=False)  # 'manual' | 'task_bonus' | 'milestone' | 'ai_agent'
    reason = Column(String)
    # 'parent' | 'ai_agent' | 'system' — distinct from `source` (why), this
    # is *what kind of actor* made the change.
    created_by = Column(String, nullable=False, default="parent")
    granted_by_parent_id = Column(UUID(as_uuid=True), ForeignKey("app.parents.id"))
    # Deliberately not a real FK: this row may point at an occurrence today
    # and, later, a not-yet-built milestone — decoupling means that feature
    # can start writing here with zero migration to this table.
    source_ref_id = Column(UUID(as_uuid=True))
    credited_date = Column(Date, nullable=False)
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
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE")) # null = family-wide
    title = Column(String, nullable=False)
    start_at = Column(DateTime(timezone=True), nullable=False)
    end_at = Column(DateTime(timezone=True), nullable=False)
    gates_apps = Column(Boolean, nullable=False, default=False)
    location_or_link = Column(String)
    source = Column(String, nullable=False, default="manual")
    # True for the parent's own personal lane; False (and child_id is null)
    # for a genuinely family-wide event. Both cases have child_id = null, so
    # this is the only thing telling them apart — it used to be smuggled
    # into `source`, which the DB restricts to ('manual','ics_import') and
    # rejected anything else outright.
    is_parent_only = Column(Boolean, nullable=False, default=False)
    category = Column(String)
    note = Column(String)
    # Comma-joined weekday codes ("mon,wed") or "none".
    recurrence = Column(String, nullable=False, default="none")
    ics_feed_id = Column(UUID(as_uuid=True), ForeignKey("app.ics_feeds.id", ondelete="CASCADE"))
    external_uid = Column(String)

class EventProposal(Base):
    __tablename__ = "event_proposals"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    title = Column(String, nullable=False)
    start_at = Column(DateTime(timezone=True), nullable=False)
    end_at = Column(DateTime(timezone=True), nullable=False)
    recurrence = Column(String)
    conflicts = Column(JSON)
    status = Column(String, nullable=False, default="pending")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())

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

class ComicGuide(Base):
    __tablename__ = "comic_guides"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    title = Column(String, nullable=False)
    blurb = Column(String)
    emoji = Column(String)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())

class ComicPanel(Base):
    __tablename__ = "comic_panels"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    guide_id = Column(UUID(as_uuid=True), ForeignKey("app.comic_guides.id", ondelete="CASCADE"), nullable=False)
    step = Column(Integer, nullable=False)
    r2_key = Column(String, nullable=False)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())

class SlideLesson(Base):
    __tablename__ = "slide_lessons"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    category = Column(String, nullable=False)
    title = Column(String, nullable=False)
    subtitle = Column(String, nullable=False)
    cover_r2_key = Column(String)
    accent_hex = Column(String)
    icon = Column(String)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())

class LessonSlide(Base):
    __tablename__ = "lesson_slides"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    lesson_id = Column(UUID(as_uuid=True), ForeignKey("app.slide_lessons.id", ondelete="CASCADE"), nullable=False)
    kind = Column(String, nullable=False, default="body")
    step = Column(Integer, nullable=False)
    kicker = Column(String, nullable=False)
    headline = Column(String, nullable=False)
    body = Column(String)
    sub = Column(String)
    points = Column(ARRAY(String))
    icon = Column(String)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
