from pydantic import BaseModel, EmailStr, field_validator
from typing import Optional, List
from datetime import datetime
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
    created_at: datetime

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
    created_at: datetime

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
    bucket: str = "anytime"
    due_time: Optional[str] = None # Will store time as string "HH:MM:SS"
    due_date: Optional[str] = None # "YYYY-MM-DD"
    recurrence: str = "daily"
    gates_apps: bool = True
    points: int = 0
    submission_kind: str = "none"
    active: bool = True

class TaskCreate(TaskBase):
    pass

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
    comic_id: Optional[UUID] = None
    created_at: datetime

    class Config:
        from_attributes = True

class OccurrenceBase(BaseModel):
    status: str
    gates_apps: bool
    points: int
    bypass_requested: bool
    bypass_note: Optional[str] = None
    rejection_note: Optional[str] = None

class OccurrenceResponse(OccurrenceBase):
    id: UUID
    task_id: UUID
    child_id: UUID
    due_date: datetime # or date, keeping datetime for standard json parsing
    due_time: Optional[str] = None
    completed_at: Optional[datetime] = None
    approved_at: Optional[datetime] = None
    created_at: datetime

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
    created_at: datetime

    class Config:
        from_attributes = True

class ChildRuleBase(BaseModel):
    daily_limit_minutes: int
    downtime_enabled: bool
    downtime_start: Optional[str] = None
    downtime_end: Optional[str] = None
    bedtime_enabled: bool
    bedtime_start: Optional[str] = None
    bedtime_end: Optional[str] = None
    blocked_categories: List[str]

class ChildRuleUpdate(BaseModel):
    # Only the daily limit and downtime switch are required: the app doesn't
    # send bedtime/blocked categories, and omitting them must leave them as-is.
    daily_limit_minutes: int
    downtime_enabled: bool
    downtime_start: Optional[str] = None
    downtime_end: Optional[str] = None
    bedtime_enabled: Optional[bool] = None
    bedtime_start: Optional[str] = None
    bedtime_end: Optional[str] = None
    blocked_categories: Optional[List[str]] = None
    daily_limit_enabled: Optional[bool] = None
    custom_rules: Optional[List[dict]] = None
    # True when the parent deleted the Downtime rule: forgets its times.
    downtime_clear: Optional[bool] = None

class ChildRuleResponse(ChildRuleBase):
    # ORM rows hold time objects; the API exposes "HH:MM:SS" strings.
    @field_validator("downtime_start", "downtime_end", "bedtime_start", "bedtime_end", mode="before")
    @classmethod
    def _iso_time(cls, v):
        return v.isoformat() if hasattr(v, "isoformat") else v

    daily_limit_enabled: bool = True
    custom_rules: List[dict] = []
    child_id: UUID
    updated_at: datetime

    class Config:
        from_attributes = True

class ChildStateBase(BaseModel):
    manual_lock: bool
    task_gate_override: bool
    last_tripwire_minutes: Optional[int] = None

class ChildStateUpdate(ChildStateBase):
    pass

class ChildStateResponse(ChildStateBase):
    child_id: UUID
    last_tripwire_at: Optional[datetime] = None
    updated_at: datetime

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
