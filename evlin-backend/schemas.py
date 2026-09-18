from pydantic import BaseModel, EmailStr
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
    created_at: datetime

    class Config:
        from_attributes = True

class GeneratePairingCodeRequest(BaseModel):
    child_id: UUID

class GeneratePairingCodeResponse(BaseModel):
    pairing_code: str
    expires_at: datetime

class PairChildRequest(BaseModel):
    pairing_code: str
    platform: str = "ios" # Add platform, defaults to ios

class PairChildResponse(BaseModel):
    access_token: str
    child: ChildResponse

class TaskBase(BaseModel):
    title: str
    instructions: Optional[str] = None
    bucket: str = "anytime"
    due_time: Optional[str] = None # Will store time as string "HH:MM:SS"
    recurrence: str = "daily"
    gates_apps: bool = True
    points: int = 0
    submission_kind: str = "none"
    active: bool = True

class TaskCreate(TaskBase):
    pass

class TaskResponse(TaskBase):
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

class EventCreate(EventBase):
    pass

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

class ChildRuleUpdate(ChildRuleBase):
    pass

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

