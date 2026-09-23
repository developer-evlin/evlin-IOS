from pydantic import BaseModel, EmailStr, field_validator, model_validator
from typing import Optional, List
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
    # Makes this a "special task": the course is assigned to the child and
    # the task is completed by finishing it. A course still awaiting review
    # is published by this same call — the parent tapping Create on the
    # proposal card *is* the approval, and doing it in one transaction means
    # there's no window where a task points at an unpublished course.
    course_id: Optional[UUID] = None
    # Tag this task toward a milestone: approving its occurrence ticks that
    # milestone's progress_count.
    milestone_id: Optional[UUID] = None

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
    course_assignment_id: Optional[UUID] = None
    milestone_id: Optional[UUID] = None

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

class SubmissionCreate(BaseModel):
    kind: str # 'photo' or 'voice'
    content_type: str
    bytes_size: Optional[int] = None
    duration_seconds: Optional[int] = None

class SubmissionResponse(SubmissionCreate):
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
    is_parent_only: bool = False
    category: Optional[str] = None
    note: Optional[str] = None
    recurrence: str = "none"

class EventCreate(EventBase):
    child_id: Optional[UUID] = None # null = family-wide

class EventResponse(EventBase):
    id: UUID
    child_id: Optional[UUID] = None
    ics_feed_id: Optional[UUID] = None
    external_uid: Optional[str] = None

    class Config:
        from_attributes = True

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
    # Computed, not a column: whether an unresolved reflection is holding the
    # gate closed. The client ORs this with its own task check — a pending
    # reflection locks the device regardless of task status, and clearing it
    # doesn't satisfy outstanding tasks. Defaults False so a response built
    # straight from the ORM row (where this attribute doesn't exist) still
    # validates.
    has_open_reflection: bool = False

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

class QuizQuestion(BaseModel):
    question: str
    options: List[str]
    correct_index: int


class CourseItemResponse(BaseModel):
    id: UUID
    order_index: int
    video_id: str
    video_title: Optional[str] = None
    channel_title: Optional[str] = None
    vetting_notes: Optional[str] = None
    quiz: List[dict] = []

    class Config:
        from_attributes = True


class CourseResponse(BaseModel):
    id: UUID
    title: str
    topic: Optional[str] = None
    category: Optional[str] = None
    status: str
    created_by: str
    created_at: datetime
    published_at: Optional[datetime] = None
    items: List[CourseItemResponse] = []

    class Config:
        from_attributes = True


class CourseGenerateRequest(BaseModel):
    topic: str
    video_count: int = 4
    # Optional: generating from a child's context lets the vetting prompt
    # mention their age. A course is still shared library content either way.
    child_id: Optional[UUID] = None

    @field_validator("topic")
    @classmethod
    def _topic_not_blank(cls, v):
        if not v or not v.strip():
            raise ValueError("topic must not be blank")
        return v.strip()

    @field_validator("video_count")
    @classmethod
    def _sane_count(cls, v):
        if not 1 <= v <= 10:
            raise ValueError("video_count must be between 1 and 10")
        return v


class CourseApproveRequest(BaseModel):
    # Approving from a child's context both publishes the course to the
    # shared library and assigns it to that child, so the parent doesn't
    # have to do it in two steps. Omit to publish only.
    assign_to_child_id: Optional[UUID] = None


class SingleVideoCourseRequest(BaseModel):
    """A parent picking one specific video — no vetting pass, published
    immediately, because they chose it themselves."""
    video_id: str
    video_title: Optional[str] = None
    channel_title: Optional[str] = None
    quiz: List[dict] = []
    title: Optional[str] = None


class CourseAssignRequest(BaseModel):
    course_id: UUID


class CourseItemProgressResponse(BaseModel):
    id: UUID
    assignment_id: UUID
    course_item_id: UUID
    status: str
    quiz_answers: Optional[list] = None
    quiz_score: Optional[int] = None
    completed_at: Optional[datetime] = None

    class Config:
        from_attributes = True


class CourseAssignmentResponse(BaseModel):
    id: UUID
    course_id: UUID
    child_id: UUID
    status: str
    assigned_by: str
    created_at: datetime
    completed_at: Optional[datetime] = None
    course: Optional[CourseResponse] = None
    progress: List[CourseItemProgressResponse] = []

    class Config:
        from_attributes = True


class CourseItemCompleteRequest(BaseModel):
    quiz_answers: Optional[List[int]] = None


class AppBlockCreate(BaseModel):
    app_name: str
    app_bundle_id: Optional[str] = None
    block_type: str  # 'duration' | 'until_task'
    duration_minutes: Optional[int] = None
    until_task_id: Optional[UUID] = None
    created_by: str = "parent"

    @field_validator("block_type")
    @classmethod
    def _known_type(cls, v):
        if v not in ("duration", "until_task"):
            raise ValueError("block_type must be 'duration' or 'until_task'")
        return v

    @model_validator(mode="after")
    def _type_has_what_it_needs(self):
        if self.block_type == "until_task" and not self.until_task_id:
            raise ValueError("an until_task block needs until_task_id")
        if self.block_type == "duration" and not self.duration_minutes:
            raise ValueError("a duration block needs duration_minutes")
        return self


class AppBlockResponse(BaseModel):
    id: UUID
    child_id: UUID
    app_name: str
    app_bundle_id: Optional[str] = None
    block_type: str
    duration_minutes: Optional[int] = None
    until_task_id: Optional[UUID] = None
    resolved: bool
    created_by: str
    created_at: datetime
    resolved_at: Optional[datetime] = None

    class Config:
        from_attributes = True


class MilestoneCreate(BaseModel):
    title: str
    description: Optional[str] = None
    kind: str = "count"
    target_count: Optional[int] = None
    prize_text: Optional[str] = None
    prize_minutes: int = 0
    created_by: str = "parent"
    # For kind='course': the course whose completion achieves this milestone.
    course_id: Optional[UUID] = None

    @field_validator("title")
    @classmethod
    def _title_not_blank(cls, v):
        if not v or not v.strip():
            raise ValueError("title must not be blank")
        return v.strip()

    @field_validator("kind")
    @classmethod
    def _known_kind(cls, v):
        if v not in ("count", "streak", "course", "custom"):
            raise ValueError("kind must be count, streak, course or custom")
        return v

    @model_validator(mode="after")
    def _kind_has_what_it_needs(self):
        if self.kind == "course" and not self.course_id:
            raise ValueError("a course milestone needs a course_id")
        if self.kind in ("count", "streak") and not self.target_count:
            raise ValueError("a count/streak milestone needs a target_count")
        return self


class MilestoneResponse(BaseModel):
    id: UUID
    child_id: UUID
    title: str
    description: Optional[str] = None
    kind: str
    target_count: Optional[int] = None
    progress_count: int
    course_assignment_id: Optional[UUID] = None
    prize_text: Optional[str] = None
    prize_minutes: int
    status: str
    created_by: str
    created_at: datetime
    achieved_at: Optional[datetime] = None
    # Computed: whether the thing this milestone asks for is actually done.
    # For count/streak that's progress vs target; for a course it's the
    # assignment being finished — two different questions, one answer the
    # client can just read.
    achievable: bool = False
    assignment: Optional[CourseAssignmentResponse] = None

    class Config:
        from_attributes = True


class MilestoneGenerateRequest(BaseModel):
    hint: Optional[str] = None


class ReflectionCreate(BaseModel):
    """Either path to the video+quiz content: a specific video the parent
    picked (the common case — a one-video course is made for it), or an
    existing/generated course to assign."""
    video_id: Optional[str] = None
    video_title: Optional[str] = None
    channel_title: Optional[str] = None
    quiz: List[dict] = []
    course_id: Optional[UUID] = None
    written_prompt: Optional[str] = None

    @model_validator(mode="after")
    def _one_content_source(self):
        if bool(self.video_id) == bool(self.course_id):
            raise ValueError("give exactly one of video_id or course_id")
        return self


class ReflectionSubmit(BaseModel):
    written_response: Optional[str] = None


class ReflectionReview(BaseModel):
    status: str  # 'approved' | 'needs_redo'
    review_note: Optional[str] = None

    @field_validator("status")
    @classmethod
    def _reviewable(cls, v):
        if v not in ("approved", "needs_redo"):
            raise ValueError("status must be 'approved' or 'needs_redo'")
        return v


class ReflectionResponse(BaseModel):
    id: UUID
    child_id: UUID
    course_assignment_id: UUID
    written_prompt: Optional[str] = None
    written_response: Optional[str] = None
    status: str
    review_note: Optional[str] = None
    created_by: str
    created_at: datetime
    submitted_at: Optional[datetime] = None
    reviewed_at: Optional[datetime] = None
    assignment: Optional[CourseAssignmentResponse] = None

    class Config:
        from_attributes = True


class ChatSendRequest(BaseModel):
    text: str

    @field_validator("text")
    @classmethod
    def _not_blank(cls, v):
        if not v or not v.strip():
            raise ValueError("text must not be blank")
        return v.strip()

class ChatMessageResponse(BaseModel):
    id: UUID
    child_id: UUID
    role: str
    text: str
    tool_call: Optional[str] = None
    tool_args: Optional[dict] = None
    created_at: datetime

    class Config:
        from_attributes = True

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

class AuthResponse(BaseModel):
    access_token: str
    refresh_token: Optional[str] = None
    parent: ParentResponse


class RefreshRequest(BaseModel):
    refresh_token: str

class RefreshResponse(BaseModel):
    access_token: str
    refresh_token: Optional[str] = None
