from pydantic import BaseModel, EmailStr, field_validator
from typing import Optional, List
from datetime import datetime
from uuid import UUID

class ParentBase(BaseModel):
    email: EmailStr
    plan: str = "free"

class ParentCreate(ParentBase):
    pass

class ParentResponse(ParentBase):
    id: UUID
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

class GeneratePairingCodeRequest(BaseModel):
    # Neither set: pair the parent's first child, creating a placeholder if
    # they have none (onboarding). child_id: re-pair that existing child.
    # new_child: create another child for this parent and pair that one.
    child_id: Optional[UUID] = None
    new_child: bool = False

class GeneratePairingCodeResponse(BaseModel):
    pairing_code: str
    expires_at: datetime
    child_id: Optional[UUID] = None

class PairChildRequest(BaseModel):
    pairing_code: str
    platform: str = "ios" # Add platform, defaults to ios
    child_name: Optional[str] = None

class PairChildResponse(BaseModel):
    access_token: str
    child: ChildResponse

class TaskBase(BaseModel):
    title: str
    instructions: Optional[str] = None
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

class ChildRuleResponse(ChildRuleBase):
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
