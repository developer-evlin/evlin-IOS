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
    # A "special task": completed by finishing this course rather than by
    # photo/voice evidence (submission_kind == 'course'). Paired with
    # bonus_minutes, that's "watch this and answer the quizzes to earn screen
    # time" — and the reward needs no new code, since approving any task with
    # bonus_minutes already writes to the ledger.
    course_assignment_id = Column(UUID(as_uuid=True), ForeignKey("app.course_assignments.id", ondelete="SET NULL"))
    # Approving this task's occurrence ticks the tagged milestone's progress.
    # SET NULL on both: without it, deleting a milestone or an assignment
    # would fail while any task still points at it.
    milestone_id = Column(UUID(as_uuid=True), ForeignKey("app.milestones.id", ondelete="SET NULL"))
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

class ChatMessage(Base):
    """One running conversation per child (not per-parent, not per-thread)
    — matches how the UI already frames it ("your child"). Scoped by
    child_id like everything else in this backend, no new family_id
    concept. See gemini_client.py / routers/chat.py — this table has no
    idea an LLM produced the assistant rows, it's just a transcript."""
    __tablename__ = "chat_messages"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    parent_id = Column(UUID(as_uuid=True), ForeignKey("app.parents.id"))
    role = Column(String, nullable=False)  # 'user' | 'assistant'
    text = Column(String, nullable=False)
    tool_call = Column(String)             # 'draft_task' | 'open_block_picker' | null
    tool_args = Column(JSON)
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())

class Course(Base):
    """A vetted, ordered sequence of YouTube videos — shared library content,
    deliberately with no child_id.

    Vetting a course is the expensive part (a real YouTube search plus an LLM
    pass over the candidates' real metadata), so it happens once and any
    number of children can then be assigned to the same course. That split is
    the whole reason this is two pairs of tables: Course/CourseItem is the
    content, CourseAssignment/CourseItemProgress is one child's journey
    through it. A shared row is never mutated by a child's progress.

    Same no-owner shape as SlideLesson/ComicGuide. created_by_parent_id is
    attribution only and is ON DELETE SET NULL: a course outliving the parent
    who requested it is correct for a shared library, and without that the
    row would block account deletion (courses aren't reachable by the
    child-cascade that clears everything else).
    """
    __tablename__ = "courses"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    title = Column(String, nullable=False)
    topic = Column(String)
    category = Column(String)
    # 'pending_review' until a parent approves it — nothing reaches a child
    # from an unapproved course. Then 'published' (browsable/assignable) or
    # 'archived'.
    status = Column(String, nullable=False, default="pending_review")
    created_by = Column(String, nullable=False, default="ai_agent")  # 'parent' | 'ai_agent'
    created_by_parent_id = Column(UUID(as_uuid=True), ForeignKey("app.parents.id", ondelete="SET NULL"))
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    published_at = Column(DateTime(timezone=True))


class CourseItem(Base):
    """One video in a course. Shared content: no per-child state lives here —
    that's CourseItemProgress. `quiz` is optional; an empty list means the
    video alone completes the item."""
    __tablename__ = "course_items"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    course_id = Column(UUID(as_uuid=True), ForeignKey("app.courses.id", ondelete="CASCADE"), nullable=False)
    order_index = Column(Integer, nullable=False)
    video_id = Column(String, nullable=False)   # YouTube video id — the only source
    video_title = Column(String)
    channel_title = Column(String)
    # Why the vetting pass picked this one (age-appropriateness, channel,
    # topic match) — shown to the parent on the approval card.
    vetting_notes = Column(String)
    quiz = Column(JSON, nullable=False, default=list)  # [{question, options, correct_index}]
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())


class CourseAssignment(Base):
    """One child working through one course.

    Claimed by exactly one consumer — a reflection, a task, or a milestone —
    or by nothing at all for a course assigned straight from the library.
    Never shared between two of them: if a reflection and a task pointed at
    the same assignment, finishing it for one would silently finish the
    other. Assigning the same course to the same child twice for two
    purposes is fine — that's two assignments, two independent progress
    tracks, one shared course.
    """
    __tablename__ = "course_assignments"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    course_id = Column(UUID(as_uuid=True), ForeignKey("app.courses.id"), nullable=False)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    status = Column(String, nullable=False, default="active")  # 'active' | 'completed'
    assigned_by = Column(String, nullable=False, default="parent")
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    completed_at = Column(DateTime(timezone=True))


class CourseItemProgress(Base):
    """One child's state on one video of one course — the per-child half of
    the split described on Course. Seeded one row per item when the
    assignment is created: the lowest order_index starts 'available', the
    rest 'locked', and completing one unlocks exactly the next."""
    __tablename__ = "course_item_progress"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    assignment_id = Column(UUID(as_uuid=True), ForeignKey("app.course_assignments.id", ondelete="CASCADE"), nullable=False)
    course_item_id = Column(UUID(as_uuid=True), ForeignKey("app.course_items.id"), nullable=False)
    status = Column(String, nullable=False, default="locked")  # 'locked' | 'available' | 'completed'
    quiz_answers = Column(JSON)
    quiz_score = Column(Integer)
    completed_at = Column(DateTime(timezone=True))


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

    Display/state only for now: real per-app shielding needs
    ManagedSettingsStore and an ApplicationToken, which is deliberately not
    part of this pass. Nothing here has to change when it lands.
    """
    __tablename__ = "app_blocks"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    app_name = Column(String, nullable=False)
    app_bundle_id = Column(String)
    block_type = Column(String, nullable=False)  # 'duration' | 'until_task'
    duration_minutes = Column(Integer)
    until_task_id = Column(UUID(as_uuid=True), ForeignKey("app.tasks.id", ondelete="SET NULL"))
    resolved = Column(Boolean, nullable=False, default=False)
    created_by = Column(String, nullable=False, default="parent")  # 'parent' | 'ai_agent'
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    resolved_at = Column(DateTime(timezone=True))


class Milestone(Base):
    """A longer-arc goal with a prize, tracked separately from day-to-day
    tasks.

    Two shapes of progress, deliberately not merged: 'count'/'streak' tick up
    as tagged tasks get approved (tasks.milestone_id is what makes a task
    count toward one — without that linkage nothing would ever increment it),
    while 'course' is achieved by finishing an assigned course, reusing the
    same completion check reflections and special tasks use.

    The prize pays out through the existing time-grant ledger
    (source='milestone'), which has had a source_ref_id with no FK reserved
    for exactly this since before milestones existed.
    """
    __tablename__ = "milestones"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    title = Column(String, nullable=False)
    description = Column(String)
    kind = Column(String, nullable=False, default="count")  # 'count' | 'streak' | 'course' | 'custom'
    target_count = Column(Integer)
    progress_count = Column(Integer, nullable=False, default=0)
    course_assignment_id = Column(UUID(as_uuid=True), ForeignKey("app.course_assignments.id"))
    prize_text = Column(String)
    prize_minutes = Column(Integer, nullable=False, default=0)
    status = Column(String, nullable=False, default="active")  # 'active' | 'achieved' | 'expired'
    created_by = Column(String, nullable=False, default="parent")  # 'parent' | 'ai_agent'
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    achieved_at = Column(DateTime(timezone=True))


class Reflection(Base):
    """A gate the child clears by watching and answering, then writing.

    Priority 0: while one is open the device is locked regardless of task
    status, and clearing it doesn't satisfy outstanding tasks either — the
    two gates are independent (see the iOS lock logic).

    The video+quiz half is a course assignment rather than columns on this
    table, so there's exactly one implementation of "watch, answer, unlock"
    shared with special tasks and milestones. Usually that's a one-video
    course created on the spot; it can equally be a full vetted course.

    Note the original evlin-tables.sql had an unrelated, never-wired
    app.reflections — see the rename guard in main.py's migrations.
    """
    __tablename__ = "reflections"
    __table_args__ = {"schema": "app"}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    child_id = Column(UUID(as_uuid=True), ForeignKey("app.children.id", ondelete="CASCADE"), nullable=False)
    course_assignment_id = Column(UUID(as_uuid=True), ForeignKey("app.course_assignments.id"), nullable=False)
    written_prompt = Column(String)
    written_response = Column(String)
    # 'pending' | 'submitted' | 'approved' | 'needs_redo'. Only 'approved'
    # closes the gate; 'needs_redo' sends it back to 'pending'.
    status = Column(String, nullable=False, default="pending")
    review_note = Column(String)
    created_by = Column(String, nullable=False, default="parent")  # 'parent' | 'ai_agent'
    created_at = Column(DateTime(timezone=True), nullable=False, server_default=func.now())
    submitted_at = Column(DateTime(timezone=True))
    reviewed_at = Column(DateTime(timezone=True))


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
