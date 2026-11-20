from pydantic import BaseModel, EmailStr, Field, field_validator, model_validator
from typing import Dict, Literal, Optional, List
from datetime import datetime, date, time
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
    # The paired device has finished its setup (GET /children sets it).
    setup_complete: bool = False
    # Family Sharing's hand-off between the devices (models.Device).
    setup_stage: Optional[str] = None
    # What the paired device is, "ipad" or "iphone", from the platform it
    # paired with; None for one that paired as plain "ios" (2026-11-13).
    device_kind: Optional[str] = None
    timezone: Optional[str] = None

    class Config:
        from_attributes = True

def _real_zone(v: Optional[str]) -> Optional[str]:
    """A zone the server can't resolve would make every "is it active now"
    check for this child quietly wrong, so it's refused."""
    if v is None:
        return v
    from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
    try:
        ZoneInfo(v)
    except (ZoneInfoNotFoundError, ValueError):
        raise ValueError(f"unknown timezone {v!r}")
    return v


class ChildUpdate(BaseModel):
    name: Optional[str] = None
    color_index: Optional[int] = None
    birth_year: Optional[int] = None
    # The parent phone's own zone, used only while the child has none
    # (update_child): the kid's device, which reports its own on every
    # sync, always has the last word.
    timezone: Optional[str] = None

    @field_validator("timezone")
    @classmethod
    def _real_zone(cls, v):
        return _real_zone(v)

class PairingRequest(BaseModel):
    """Sent by the kid's device to start pairing."""
    child_name: Optional[str] = None
    # "ipad" or "iphone" (2026-11-13), "ios" from older builds.
    platform: str = Field("ios", max_length=20)

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

def _single_emoji(v):
    """A task's emoji, shown beside it on the kid's phone: one emoji (a ZWJ
    family or flag is several code points), never text. Blank means none."""
    if v is None or not v.strip():
        return None
    v = v.strip()
    if len(v) > 16 or any(c.isascii() and c.isalnum() for c in v) or not any(ord(c) > 0x238C for c in v):
        raise ValueError("icon must be a single emoji")
    return v


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

    @field_validator("icon")
    @classmethod
    def _one_emoji(cls, v):
        """The task's emoji, shown beside it on the kid's phone: one emoji
        (a ZWJ family or flag is several code points), never text. Blank
        means none."""
        return _single_emoji(v)

class TaskResponse(TaskBase):
    # ORM rows hold time/date objects; the API exposes them as strings.
    @field_validator("due_time", "due_date", "repeat_until", mode="before")
    @classmethod
    def _iso(cls, v):
        return v.isoformat() if hasattr(v, "isoformat") else v

    id: UUID
    child_id: UUID
    created_at: datetime
    # A repeating task's exceptions (models.Task): days taken out of it and
    # its last day, "YYYY-MM-DD". The phones' repeat rule reads them.
    skipped_dates: Optional[list[str]] = None
    repeat_until: Optional[str] = None
    updated_at: Optional[datetime] = None


class TaskUpdate(BaseModel):
    """An edit to a task: only the fields sent change (edits.py, per field).
    An older build sends them all, which still works."""
    title: Optional[str] = None
    instructions: Optional[str] = None
    category: Optional[str] = None
    icon: Optional[str] = None
    bucket: Optional[str] = None
    due_time: Optional[str] = None
    due_date: Optional[str] = None
    recurrence: Optional[str] = None
    gates_apps: Optional[bool] = None
    submission_kind: Optional[str] = None
    active: Optional[bool] = None
    bonus_minutes: Optional[int] = None
    created_by: Optional[str] = None

    @field_validator("title")
    @classmethod
    def _title_not_blank(cls, v):
        if v is None:
            return v
        if not v.strip():
            raise ValueError("title must not be blank")
        return v.strip()

    @field_validator("icon")
    @classmethod
    def _one_emoji(cls, v):
        return _single_emoji(v)


class TaskCut(BaseModel):
    """Days taken off a repeating task: `from` alone ("This task", with
    `through` the same day) or from that day on (`through` null)."""
    from_: date = Field(alias="from")
    through: Optional[date] = None

    model_config = {"populate_by_name": True}


class TaskSplit(TaskCut):
    """One day of a repeating task, or the rest of it, edited on its own:
    `task` is the new task holding those days (its id made on the phone),
    and what was done on them moves to it."""
    task: TaskCreate

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
    updated_at: Optional[datetime] = None

    class Config:
        from_attributes = True

class OccurrenceStatusUpdate(BaseModel):
    status: str # 'approved', 'rejected'
    rejection_note: Optional[str] = None

class OccurrenceBypassRequest(BaseModel):
    bypass_note: Optional[str] = None

class OccurrenceSubmitRequest(BaseModel):
    bypass_note: Optional[str] = None
    # The photos sent in with the task (submission ids). Each is checked in
    # R2 before it counts; left out (an older app), nothing is checked.
    photo_ids: Optional[List[UUID]] = None

class OccurrenceSubmitResponse(OccurrenceResponse):
    # Photos named in photo_ids that aren't in R2 (or aren't this task's):
    # the task is still sent in, and the phone uploads these again.
    missing_photo_ids: List[UUID] = []

# A kid's photo is made at most 1600 px on the device, a few hundred KB.
MAX_PHOTO_BYTES = 5 * 1024 * 1024

class SubmissionBase(BaseModel):
    kind: str  # 'photo'; older rows can still say 'voice'
    content_type: str
    bytes_size: Optional[int] = None

class SubmissionCreate(SubmissionBase):
    # Made on the phone, so a retry answers with the same photo, not a new
    # one. Older apps leave it out.
    id: Optional[UUID] = None

    # Voice notes were removed: a new piece of evidence is a photo. Checked
    # here and not on SubmissionBase, so listing a task that still has an
    # old voice submission keeps working.
    @field_validator("kind")
    @classmethod
    def _photo_only(cls, v):
        if v != "photo":
            raise ValueError("kind must be 'photo'")
        return v

    @field_validator("content_type")
    @classmethod
    def _image_only(cls, v):
        if not v.startswith("image/"):
            raise ValueError("content_type must be an image")
        return v

    @field_validator("bytes_size")
    @classmethod
    def _small_enough(cls, v):
        if v is not None and not (0 < v <= MAX_PHOTO_BYTES):
            raise ValueError(f"a photo must be under {MAX_PHOTO_BYTES // (1024 * 1024)} MB")
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
    # The weekdays downtime runs on (["mon", ...]). Omitted/None leaves it
    # untouched; an explicit [] (or all seven) means every day again.
    downtime_days: Optional[List[str]] = None
    # Each day's own hours: {"mon": {"start": "20:00", "end": "07:00"}, ...}.
    # Omitted/None leaves it untouched; an explicit {} clears it (one set of
    # hours, downtime_start/end, every day it runs).
    downtime_schedule: Optional[Dict[str, Dict[str, str]]] = None

    @field_validator("downtime_schedule")
    @classmethod
    def _day_hours(cls, v):
        if v is None:
            return v
        codes = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
        out = {}
        for day, span in v.items():
            if day not in codes:
                raise ValueError("downtime_schedule days must be weekday codes: mon..sun")
            start, end = span.get("start"), span.get("end")
            try:
                start_t, end_t = time.fromisoformat(start), time.fromisoformat(end)
            except (TypeError, ValueError):
                raise ValueError("downtime_schedule hours must be HH:MM")
            out[day] = {"start": start_t.strftime("%H:%M"), "end": end_t.strftime("%H:%M")}
        return {d: out[d] for d in codes if d in out}

    @field_validator("downtime_days")
    @classmethod
    def _weekday_codes(cls, v):
        if v is None:
            return v
        codes = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
        if any(d not in codes for d in v):
            raise ValueError("downtime_days must be weekday codes: mon..sun")
        return [d for d in codes if d in v]

class ChildRuleResponse(ChildRuleBase):
    # ORM rows hold time objects; the API exposes "HH:MM:SS" strings.
    @field_validator("downtime_start", "downtime_end", mode="before")
    @classmethod
    def _iso_time(cls, v):
        return v.isoformat() if hasattr(v, "isoformat") else v

    daily_limit_enabled: bool = True
    custom_rules: List[dict] = []
    weekly_schedule: Optional[dict] = None
    downtime_days: Optional[List[str]] = None
    downtime_schedule: Optional[dict] = None
    child_id: UUID
    updated_at: datetime

    class Config:
        from_attributes = True

class ChildStateBase(BaseModel):
    manual_lock: bool
    task_gate_override: bool

class ChildStateUpdate(BaseModel):
    # Only the flags sent change (edits.py, per field); an older app sends
    # the lock and unlock together, which still works.
    manual_lock: Optional[bool] = None
    task_gate_override: Optional[bool] = None
    instant_unlock: Optional[bool] = None

class ChildStateResponse(ChildStateBase):
    instant_unlock: bool = False
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


class ParentSetupStage(BaseModel):
    """The parent's side of Family Sharing's hand-off: "I've created the
    account", tapped on the parent's phone instead of the kid's device."""
    setup_stage: Literal["account_created"]


class DeviceUpdate(BaseModel):
    timezone: Optional[str] = None
    # The child's name, typed on the kid's device after pairing (the kid's
    # setup pairs first, then asks the name, 2026-11-09).
    name: Optional[str] = None
    # The kid's device has finished its setup. Only ever true.
    setup_complete: Optional[bool] = None
    # Family Sharing's hand-off (models.Device.setup_stage); "" clears it.
    # "creating_account": the kid's device shows how to make the child's
    # Apple Account; "account_created": it's made, sign the device in.
    setup_stage: Optional[Literal["", "creating_account", "account_created", "signed_in"]] = None

    @field_validator("timezone")
    @classmethod
    def _real_zone(cls, v):
        return _real_zone(v)


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
    # Always "chat" from the app now. "youtube" is still accepted from
    # older builds (the removed YouTube agent) and answered by chat.
    agent: Literal["chat", "youtube"] = "chat"
    # The parent's phone's IANA zone ("America/Los_Angeles"). Only used when
    # the child has no zone yet: a kid's device reports theirs, and that wins.
    timezone: Optional[str] = None
    # Set by a chat tile whose first reply is always the same question
    # ("Add a task", "Update the calendar"): the server asks it straight
    # away instead of waiting seconds for the model to. Older servers ignore it.
    shortcut: Optional[Literal["add_task", "suggest_activity", "block_app"]] = None

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


class AccessCodeResponse(BaseModel):
    """The parent's screen time access code (routers/access_codes.py)."""
    code: str
    expires_at: datetime
    # From the server's clock, so a phone whose clock is off still counts
    # down right.
    seconds_left: float
    lifetime: float


class AccessCodeCheck(BaseModel):
    code: str


class AccessCodeCheckResponse(BaseModel):
    ok: bool
