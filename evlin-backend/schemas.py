from pydantic import BaseModel, EmailStr, Field, field_validator, model_validator
from typing import Literal, Optional, List
from datetime import datetime, date
from uuid import UUID

class ParentBase(BaseModel):
    email: EmailStr
    plan: str = "free"

class ParentCreate(ParentBase):
    pass

class ParentUpdate(BaseModel):
    name: str

    @field_validator("name")
    @classmethod
    def _name_ok(cls, v):
        v = v.strip()
        if not v:
            raise ValueError("name must not be blank")
        return v[:60]

class ParentResponse(ParentBase):
    id: UUID
    name: Optional[str] = None
    terms_accepted_at: Optional[datetime] = None
    terms_version: Optional[int] = None

    class Config:
        from_attributes = True

class ChildBase(BaseModel):
    name: str
    birth_year: Optional[int] = None
    color_index: int = 0
    avatar_url: Optional[str] = None

class ChildCreate(ChildBase):
    pass

class ChildResponse(ChildBase):
    id: UUID
    activated_at: Optional[datetime] = None
    is_paired: bool = False
    timezone: Optional[str] = None

    class Config:
        from_attributes = True

class ChildUpdate(BaseModel):
    name: Optional[str] = None
    color_index: Optional[int] = None
    birth_year: Optional[int] = None

class PairingRequest(BaseModel):
    """Sent by the kid's device to start pairing."""
    child_name: Optional[str] = None
    platform: str = "ios"

class PairingRequestResponse(BaseModel):
    code: str
    secret: str        # kept by the device; needed to collect the token
    expires_at: datetime

class PairingClaimRequest(BaseModel):
    """Sent by a parent who scanned / typed the code shown on the kid's device.
    Neither field: use the parent's first unpaired child, else create one.
    child_id: re-pair that child.  new_child: always create another."""
    code: str
    child_id: Optional[UUID] = None
    new_child: bool = False

class PairingStatusRequest(BaseModel):
    code: str
    secret: str

class PairingStatusResponse(BaseModel):
    status: str        # "pending" | "paired"
    access_token: Optional[str] = None
    child: Optional[ChildResponse] = None

class TaskBase(BaseModel):
    title: str
    instructions: Optional[str] = None
    # Free-form UI label ("Chore", "Study", …). `bucket` still exists on the
    # wire for backward compatibility with any client that still sends it,
    # but the server no longer trusts it — see routers/tasks.py.
    category: Optional[str] = None
    icon: Optional[str] = None
    bucket: str = "anytime"
    due_time: Optional[str] = None # Will store time as string "HH:MM:SS"
    due_date: Optional[str] = None # "YYYY-MM-DD"
    recurrence: str = "daily"
    gates_apps: bool = True
    submission_kind: str = "none"
    active: bool = True
    # Awarded to the child's time_grants ledger once this task's occurrence
    # is approved — 0 (default) means no bonus, same as every task today.
    bonus_minutes: int = 0
    # 'parent' (default) | 'ai_agent' | 'system' — who authored this task's
    # content. A parent always still taps Create either way (the model
    # never writes directly, see the plan's Phase C) — this just tells an
    # AI-suggested-then-parent-confirmed task apart from a parent-typed one.
    created_by: str = "parent"

class TaskCreate(TaskBase):
    # Made on the phone, so a create retried from its outbox is recognised
    # instead of saved twice. Ignored by updates.
    id: Optional[UUID] = None

    @field_validator("title")
    @classmethod
    def _title_not_blank(cls, v):
        if not v or not v.strip():
            raise ValueError("title must not be blank")
        return v.strip()

class TaskResponse(TaskBase):
    # ORM rows hold time/date objects; the API exposes them as strings.
    @field_validator("due_time", "due_date", mode="before")
    @classmethod
    def _iso(cls, v):
        return v.isoformat() if hasattr(v, "isoformat") else v

    id: UUID
    child_id: UUID
    created_at: datetime

    class Config:
        from_attributes = True

class OccurrenceBase(BaseModel):
    status: str
    gates_apps: bool
    bypass_requested: bool
    bypass_note: Optional[str] = None
    rejection_note: Optional[str] = None

class OccurrenceResponse(OccurrenceBase):
    # Same gap TaskResponse already closed for its own due_time/due_date —
    # this one just never got it: the ORM row holds a real datetime.time,
    # and a bare Optional[str] here rejects it outright (a Pydantic
    # ResponseValidationError, which FastAPI turns into a 500) rather than
    # converting it. Dormant until an occurrence actually carried a real
    # due_time, which is why this shipped unnoticed.
    @field_validator("due_time", mode="before")
    @classmethod
    def _iso(cls, v):
        return v.isoformat() if hasattr(v, "isoformat") else v

    id: UUID
    task_id: UUID
    child_id: UUID
    due_date: datetime # or date, keeping datetime for standard json parsing
    due_time: Optional[str] = None
    completed_at: Optional[datetime] = None
    approved_at: Optional[datetime] = None

    class Config:
        from_attributes = True

class OccurrenceStatusUpdate(BaseModel):
    status: str # 'approved', 'rejected'
    rejection_note: Optional[str] = None

class OccurrenceBypassRequest(BaseModel):
    bypass_note: Optional[str] = None

class SubmissionBase(BaseModel):
    kind: str  # 'photo'; older rows can still say 'voice'
    content_type: str
    bytes_size: Optional[int] = None

class SubmissionCreate(SubmissionBase):
    # Voice notes were removed: a new piece of evidence is a photo. Checked
    # here and not on SubmissionBase, so listing a task that still has an
    # old voice submission keeps working.
    @field_validator("kind")
    @classmethod
    def _photo_only(cls, v):
        if v != "photo":
            raise ValueError("kind must be 'photo'")
        return v

class SubmissionResponse(SubmissionBase):
    id: UUID
    occurrence_id: UUID
    r2_key: str
    status: str
    created_at: datetime
    uploaded_at: Optional[datetime] = None

    class Config:
        from_attributes = True

class SubmissionUploadResponse(BaseModel):
    submission: SubmissionResponse
    upload_url: str

class SubmissionListItem(SubmissionResponse):
    # Only present once status == "uploaded" — a still-pending submission
    # has nothing in R2 yet to generate a link for.
    download_url: Optional[str] = None

class EventBase(BaseModel):
    title: str
    start_at: datetime
    end_at: datetime
    gates_apps: bool = False
    location_or_link: Optional[str] = None
    source: str = "manual"
    category: Optional[str] = None
    note: Optional[str] = None
    recurrence: str = "none"

class EventCreate(EventBase):
    # Every event belongs to one child; there are no family-wide events.
    child_id: UUID
    # Made on the phone (see TaskCreate.id). Ignored by updates.
    id: Optional[UUID] = None

class EventResponse(EventBase):
    id: UUID
    child_id: UUID
    ics_feed_id: Optional[UUID] = None
    external_uid: Optional[str] = None
    created_by: str = "parent"
    status: str = "approved"
    review_note: Optional[str] = None

    class Config:
        from_attributes = True

class PlanCreate(BaseModel):
    """A child's plan for one day: no repeats, no app gating."""
    # Made on the phone (see TaskCreate.id). Ignored by updates.
    id: Optional[UUID] = None
    title: str
    start_at: datetime
    end_at: datetime
    location_or_link: Optional[str] = None
    category: Optional[str] = None
    note: Optional[str] = None

    @field_validator("title")
    @classmethod
    def _title_not_blank(cls, v):
        if not v or not v.strip():
            raise ValueError("title must not be blank")
        return v.strip()

class PlanDecline(BaseModel):
    note: Optional[str] = None

class ChildRuleBase(BaseModel):
    daily_limit_minutes: int
    downtime_enabled: bool
    downtime_start: Optional[str] = None
    downtime_end: Optional[str] = None

class ChildRuleUpdate(BaseModel):
    daily_limit_minutes: int
    downtime_enabled: bool
    downtime_start: Optional[str] = None
    downtime_end: Optional[str] = None
    daily_limit_enabled: Optional[bool] = None
    custom_rules: Optional[List[dict]] = None
    # True when the parent deleted the Downtime rule: forgets its times.
    downtime_clear: Optional[bool] = None
    # Calendar-style override: {"mon": 120, ...}, weekday codes matching
    # tasks' own recurrence vocabulary. Omitted/None leaves it untouched;
    # an explicit {} clears it back to "use daily_limit_minutes every day".
    weekly_schedule: Optional[dict] = None

class ChildRuleResponse(ChildRuleBase):
    # ORM rows hold time objects; the API exposes "HH:MM:SS" strings.
    @field_validator("downtime_start", "downtime_end", mode="before")
    @classmethod
    def _iso_time(cls, v):
        return v.isoformat() if hasattr(v, "isoformat") else v

    daily_limit_enabled: bool = True
    custom_rules: List[dict] = []
    weekly_schedule: Optional[dict] = None
    child_id: UUID
    updated_at: datetime

    class Config:
        from_attributes = True

class ChildStateBase(BaseModel):
    manual_lock: bool
    task_gate_override: bool

class ChildStateUpdate(ChildStateBase):
    pass

class ChildStateResponse(ChildStateBase):
    child_id: UUID
    updated_at: datetime

    class Config:
        from_attributes = True

class TimeGrantCreate(BaseModel):
    # Signed: positive grants time, negative deducts it — same ledger,
    # same no-lost-update reasoning either direction (see models.py).
    minutes: int
    reason: Optional[str] = None

    @field_validator("minutes")
    @classmethod
    def _not_zero(cls, v):
        if v == 0:
            raise ValueError("minutes can't be 0 — that's not a real change to log")
        return v

class TimeGrantResponse(BaseModel):
    id: UUID
    child_id: UUID
    minutes: int
    source: str
    reason: Optional[str] = None
    created_by: str = "parent"
    granted_by_parent_id: Optional[UUID] = None
    source_ref_id: Optional[UUID] = None
    credited_date: date
    created_at: datetime

    class Config:
        from_attributes = True

class TimeGrantsSummary(BaseModel):
    date: date
    daily_limit_minutes: int
    granted_minutes: int
    available_minutes: int
    grants: List[TimeGrantResponse]

class AppResponse(BaseModel):
    id: UUID
    name: str
    aliases: List[str] = []
    category: Optional[str] = None

    class Config:
        from_attributes = True


class ChildAppsUpdate(BaseModel):
    app_ids: List[UUID]


class DeviceUpdate(BaseModel):
    timezone: Optional[str] = None

    @field_validator("timezone")
    @classmethod
    def _real_zone(cls, v):
        # A zone the server can't resolve would make every "is it active
        # now" check for this child quietly wrong, so it's refused here.
        if v is None:
            return v
        from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
        try:
            ZoneInfo(v)
        except (ZoneInfoNotFoundError, ValueError):
            raise ValueError(f"unknown timezone {v!r}")
        return v


class AppBlockCreate(BaseModel):
    """One request, one row per app. The kinds and what they need:
    duration → duration_minutes; until_task → until_task_id;
    scheduled → schedule_days + schedule_start + schedule_end;
    indefinite → nothing else."""
    app_ids: List[UUID]
    block_type: str
    duration_minutes: Optional[int] = None
    until_task_id: Optional[UUID] = None
    schedule_days: Optional[str] = None     # "mon,tue,wed,thu,sun"
    schedule_start: Optional[str] = None    # "HH:MM", child-local
    schedule_end: Optional[str] = None
    # Put any app that isn't on the child's lockable list onto it first.
    # Without it, such an app is refused rather than silently added.
    add_to_list: bool = False
    created_by: str = "parent"

    @field_validator("block_type")
    @classmethod
    def _known_type(cls, v):
        import blocks
        if v not in blocks.KINDS:
            raise ValueError(f"block_type must be one of {', '.join(blocks.KINDS)}")
        return v

    @model_validator(mode="after")
    def _type_has_what_it_needs(self):
        import blocks
        if not self.app_ids:
            raise ValueError("choose at least one app")
        if self.block_type == "duration" and not (self.duration_minutes and self.duration_minutes > 0):
            raise ValueError("a duration block needs duration_minutes")
        if self.block_type == "until_task" and self.until_task_id is None:
            raise ValueError("an until_task block needs until_task_id")
        if self.block_type == "scheduled":
            self.schedule_days = ",".join(blocks.parse_days(self.schedule_days))
            start = blocks.parse_clock(self.schedule_start)
            end = blocks.parse_clock(self.schedule_end)
            if start == end:
                raise ValueError("a scheduled block's window can't start and end at the same time")
            self.schedule_start, self.schedule_end = start.strftime("%H:%M"), end.strftime("%H:%M")
        return self


class AppBlockResponse(BaseModel):
    @field_validator("schedule_start", "schedule_end", mode="before")
    @classmethod
    def _clock(cls, v):
        return v.strftime("%H:%M") if hasattr(v, "strftime") else v

    id: UUID
    child_id: UUID
    app_id: Optional[UUID] = None
    app_name: str
    block_type: str
    duration_minutes: Optional[int] = None
    ends_at: Optional[datetime] = None
    until_task_id: Optional[UUID] = None
    schedule_days: Optional[str] = None
    schedule_start: Optional[str] = None
    schedule_end: Optional[str] = None
    resolved: bool
    resolved_reason: Optional[str] = None
    created_by: str
    created_at: datetime
    resolved_at: Optional[datetime] = None
    # Computed for "now" in the child's timezone — see blocks.py.
    state: str = "active"            # active | off_window | expired | lifted | done
    description: str = ""            # "until 'Homework' is approved", "school nights 19:00–07:00"

    class Config:
        from_attributes = True


class ChatSendRequest(BaseModel):
    text: str
    conversation_id: Optional[UUID] = None
    # Starting a thread is opt-in so that a client which knows nothing about
    # conversations (every build shipped before threading) keeps appending to
    # the running one instead of silently starting a new thread per message
    # and losing all continuity.
    new_conversation: bool = False
    # Which assistant this message is for: the main chat, or the YouTube
    # agent the parent switched to with the YouTube tile. Same thread.
    agent: Literal["chat", "youtube"] = "chat"
    # The parent's phone's IANA zone ("America/Los_Angeles"). Only used when
    # the child has no zone yet: a kid's device reports theirs, and that wins.
    timezone: Optional[str] = None
    # Set by a chat tile whose first reply is always the same question
    # ("Add a task", "Update the calendar"): the server asks it straight
    # away instead of waiting seconds for the model to. Older servers ignore it.
    shortcut: Optional[Literal["add_task", "add_event", "suggest_activity"]] = None
    # "Try again": answer the parent's last message in this conversation
    # afresh, replacing the reply it got. No new parent message is stored:
    # the saved one is answered, whatever `text` says. Needs conversation_id.
    regenerate: bool = False

    @field_validator("text")
    @classmethod
    def _not_blank(cls, v):
        if not v or not v.strip():
            raise ValueError("text must not be blank")
        return v.strip()


class ChatConversationResponse(BaseModel):
    id: UUID
    child_id: UUID
    title: str
    created_at: datetime
    updated_at: datetime

    class Config:
        from_attributes = True


class ChatConversationRename(BaseModel):
    title: str

    @field_validator("title")
    @classmethod
    def _not_blank(cls, v):
        if not v or not v.strip():
            raise ValueError("title must not be blank")
        return v.strip()[:120]

class ChatMessageResponse(BaseModel):
    id: UUID
    child_id: UUID
    conversation_id: Optional[UUID] = None
    role: str
    text: str
    tool_call: Optional[str] = None
    tool_args: Optional[dict] = None
    agent: str = "chat"
    created_at: datetime

    class Config:
        from_attributes = True


class ChatSendResponse(ChatMessageResponse):
    """The reply to a sent message. Itself the first assistant message, so
    a client that predates several cards per reply still decodes it as
    before; extra_messages holds the rest, in order, when the parent asked
    for several things at once."""
    extra_messages: list[ChatMessageResponse] = []

class ConsentCreate(BaseModel):
    toggle_key: str
    granted: bool
    version: int = 1

class AuditLogCreate(BaseModel):
    kind: str
    metadata: Optional[dict] = None


class EmailAuthRequest(BaseModel):
    email: EmailStr
    password: str

    @field_validator("password")
    @classmethod
    def _password_strength(cls, v: str) -> str:
        # M-6: enforce minimum on the server — the iOS client also checks
        # this, but a direct API call would bypass a client-only check.
        if len(v) < 8:
            raise ValueError("Password must be at least 8 characters")
        # Supabase hashes with bcrypt, which ignores everything past 72
        # bytes; a cap also keeps a huge body from costing hashing time.
        if len(v.encode()) > 72:
            raise ValueError("Password must be at most 72 characters")
        return v


class SignupStartRequest(BaseModel):
    email: EmailStr


class SignupStartResponse(BaseModel):
    """The same for every address, whether or not it has an account."""
    sent: bool = True
    expires_in: int
    resend_after: int


class SignupVerifyRequest(EmailAuthRequest):
    code: str = Field(min_length=1, max_length=12)


class AppleSignInRequest(BaseModel):
    identity_token: str = Field(min_length=20, max_length=8192)
    # The raw nonce; Apple's token carries its SHA-256.
    nonce: str = Field(min_length=32, max_length=128)
    authorization_code: Optional[str] = Field(default=None, max_length=1024)
    # Apple sends the name only on the first sign-in, to the device.
    full_name: Optional[str] = Field(default=None, max_length=80)

class AuthResponse(BaseModel):
    access_token: str
    refresh_token: Optional[str] = None
    parent: ParentResponse


class RefreshRequest(BaseModel):
    refresh_token: str

class ParentSessionResponse(BaseModel):
    session_token: str

class RefreshResponse(BaseModel):
    access_token: str
    refresh_token: Optional[str] = None


# ---- Today's videos -------------------------------------------------------

class VideoChannel(BaseModel):
    id: str
    title: str = ""


class VideoProfileResponse(BaseModel):
    child_id: UUID
    allowed_categories: List[str]
    blocked_keywords: List[str]
    allowed_channels: List[VideoChannel]
    blocked_channels: List[VideoChannel]
    daily_minutes: int
    max_video_minutes: int
    # Every category a parent can choose from, so the app's chips come from
    # the same list the server filters by.
    all_categories: List[str]


class VideoProfileUpdate(BaseModel):
    allowed_categories: Optional[List[str]] = None
    blocked_keywords: Optional[List[str]] = None
    allowed_channels: Optional[List[VideoChannel]] = None
    blocked_channels: Optional[List[VideoChannel]] = None
    daily_minutes: Optional[int] = None
    max_video_minutes: Optional[int] = None

    @field_validator("daily_minutes")
    @classmethod
    def _daily(cls, v):
        if v is not None and not 5 <= v <= 240:
            raise ValueError("daily_minutes must be between 5 and 240")
        return v

    @field_validator("max_video_minutes")
    @classmethod
    def _per_video(cls, v):
        if v is not None and not 1 <= v <= 60:
            raise ValueError("max_video_minutes must be between 1 and 60")
        return v

    @field_validator("blocked_keywords")
    @classmethod
    def _keywords(cls, v):
        if v is None:
            return v
        out = []
        for k in v:
            k = " ".join(k.split())[:40]
            if k and k.lower() not in (o.lower() for o in out):
                out.append(k)
        return out[:50]


class VideoQueueAdd(BaseModel):
    """One video the parent approved, as the chat card showed it."""
    video_id: str
    title: str
    channel_id: Optional[str] = None
    channel_title: Optional[str] = None
    thumbnail_url: Optional[str] = None
    duration_seconds: int
    category: Optional[str] = None

    @field_validator("video_id")
    @classmethod
    def _real_id(cls, v):
        # A YouTube id: 11 URL-safe characters. Anything else would only
        # fail later, inside the child's player.
        import re
        if not re.fullmatch(r"[A-Za-z0-9_-]{11}", v or ""):
            raise ValueError("not a YouTube video id")
        return v

    @field_validator("duration_seconds")
    @classmethod
    def _length(cls, v):
        if not 1 <= v <= 4 * 3600:
            raise ValueError("duration_seconds out of range")
        return v


class VideoQueueCreate(BaseModel):
    videos: List[VideoQueueAdd]
    # True replaces whatever is still unwatched today; false adds to the end.
    replace: bool = False


class VideoQueueOrder(BaseModel):
    item_ids: List[UUID]


class VideoProgress(BaseModel):
    watched_seconds: int
    completed: bool = False

    @field_validator("watched_seconds")
    @classmethod
    def _non_negative(cls, v):
        if v < 0:
            raise ValueError("watched_seconds can't be negative")
        return v


class VideoQueueItemResponse(BaseModel):
    id: UUID
    child_id: UUID
    local_date: date
    position: int
    video_id: str
    title: str
    channel_id: Optional[str] = None
    channel_title: Optional[str] = None
    thumbnail_url: Optional[str] = None
    duration_seconds: int
    category: Optional[str] = None
    watched_seconds: int
    completed_at: Optional[datetime] = None

    class Config:
        from_attributes = True


class VideoQueueResponse(BaseModel):
    child_id: UUID
    local_date: date
    daily_minutes: int
    watched_seconds: int
    remaining_seconds: int
    items: List[VideoQueueItemResponse]
