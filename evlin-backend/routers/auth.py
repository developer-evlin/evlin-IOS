from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.orm import Session
from pydantic import BaseModel
import os
import uuid
import random
import string
import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from typing import Optional
from supabase import create_client, Client
from database import get_db
import models, schemas

router = APIRouter(prefix="/auth", tags=["auth"])

# Initialize Supabase client
SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_KEY")
supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY) if SUPABASE_URL and SUPABASE_KEY else None

security = HTTPBearer()

def get_current_parent(credentials: HTTPAuthorizationCredentials = Depends(security), db: Session = Depends(get_db)) -> models.Parent:
    """Dependency to verify the Supabase JWT token and return the current Parent."""
    if not supabase:
        raise HTTPException(status_code=500, detail="Supabase client not configured")
        
    try:
        user_res = supabase.auth.get_user(credentials.credentials)
        user = user_res.user
        if not user:
            raise HTTPException(status_code=401, detail="Invalid token")
            
        parent = db.query(models.Parent).filter(models.Parent.id == user.id).first()
        if not parent:
            raise HTTPException(status_code=401, detail="Parent account not initialized")
            
        return parent
    except Exception as e:
        raise HTTPException(status_code=401, detail=str(e))

class VerifyTokenRequest(BaseModel):
    access_token: str


@router.post("/register", response_model=schemas.AuthResponse)
def register(request: schemas.EmailAuthRequest, db: Session = Depends(get_db)):
    if not supabase:
        raise HTTPException(status_code=500, detail="Supabase client not configured")
    try:
        try:
            # MVP: Use the admin API to bypass Supabase's strict email rate limits and auto-confirm the user
            res = supabase.auth.admin.create_user({
                "email": request.email,
                "password": request.password,
                "email_confirm": True
            })
            user_id = res.user.id
            user_email = res.user.email
        except Exception as e:
            error_str = str(e)
            if hasattr(e, 'message'):
                error_str = e.message
            if "Email address already registered" in error_str or "already registered" in error_str:
                return login(request, db)
            raise e
            
        # Log in immediately to get a real valid JWT token (since we auto-confirmed them)
        login_res = supabase.auth.sign_in_with_password({"email": request.email, "password": request.password})
        access_token = login_res.session.access_token
        
        # Create local parent record
        parent = db.query(models.Parent).filter(models.Parent.id == user_id).first()
        if not parent:
            parent = models.Parent(id=user_id, email=user_email, plan="free")
            db.add(parent)
            db.commit()
            db.refresh(parent)
            
        return {"access_token": access_token, "refresh_token": login_res.session.refresh_token, "parent": parent}
    except Exception as e:
        # Pass up specific supabase errors
        error_msg = str(e)
        if hasattr(e, 'message'):
            error_msg = e.message
        raise HTTPException(status_code=400, detail=error_msg)

@router.post("/login", response_model=schemas.AuthResponse)
def login(request: schemas.EmailAuthRequest, db: Session = Depends(get_db)):
    if not supabase:
        raise HTTPException(status_code=500, detail="Supabase client not configured")
    try:
        res = supabase.auth.sign_in_with_password({"email": request.email, "password": request.password})
        if not res.user:
            raise HTTPException(status_code=401, detail="Invalid credentials")
            
        parent = db.query(models.Parent).filter(models.Parent.id == res.user.id).first()
        if not parent:
            parent = models.Parent(id=res.user.id, email=res.user.email, plan="free")
            db.add(parent)
            db.commit()
            db.refresh(parent)
            
        return {"access_token": res.session.access_token, "refresh_token": res.session.refresh_token, "parent": parent}
    except Exception as e:
        raise HTTPException(status_code=401, detail=str(e))

@router.get("/me", response_model=schemas.ParentResponse)
def get_me(current_parent: models.Parent = Depends(get_current_parent)):
    """The signed-in parent's own profile."""
    return current_parent


@router.put("/me", response_model=schemas.ParentResponse)
def update_me(update: schemas.ParentUpdate, current_parent: models.Parent = Depends(get_current_parent),
              db: Session = Depends(get_db)):
    current_parent.name = update.name
    db.commit()
    db.refresh(current_parent)
    return current_parent


@router.post("/refresh", response_model=schemas.RefreshResponse)
def refresh(request: schemas.RefreshRequest):
    """Trade a Supabase refresh token for a fresh access token. Access tokens
    only live about an hour, so without this every session died after that."""
    if not supabase:
        raise HTTPException(status_code=500, detail="Supabase client not configured")
    try:
        res = supabase.auth.refresh_session(request.refresh_token)
        if not res.session:
            raise HTTPException(status_code=401, detail="Session expired")
        return {"access_token": res.session.access_token, "refresh_token": res.session.refresh_token}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=401, detail=str(e))

@router.post("/verify-parent", response_model=schemas.ParentResponse)
def verify_parent(request: VerifyTokenRequest, db: Session = Depends(get_db)):
    """Used initially to sync the Supabase auth user into our local database"""
    if not supabase:
        raise HTTPException(status_code=500, detail="Supabase client not configured")
        
    try:
        user_res = supabase.auth.get_user(request.access_token)
        user = user_res.user
        if not user:
            raise HTTPException(status_code=401, detail="Invalid token")
            
        parent = db.query(models.Parent).filter(models.Parent.id == user.id).first()
        if not parent:
            parent = models.Parent(id=user.id, email=user.email, plan="free")
            db.add(parent)
            db.commit()
            db.refresh(parent)
            
        return parent
    except Exception as e:
        raise HTTPException(status_code=401, detail=str(e))

def generate_unique_pairing_code(db: Session) -> str:
    """A 6-digit code not currently used by any live pairing."""
    while True:
        code = "".join(random.choices(string.digits, k=6))
        if not db.query(models.DevicePairing).filter(models.DevicePairing.code == code).first():
            return code


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def _create_placeholder_child(db: Session, parent: models.Parent, name: str = "Your Child") -> models.Child:
    count = db.query(models.ParentChild).filter(models.ParentChild.parent_id == parent.id).count()
    new_child = models.Child(name=name, birth_year=2015, color_index=count % 8, avatar_url="")
    db.add(new_child)
    db.commit()
    db.refresh(new_child)

    db.add(models.ParentChild(parent_id=parent.id, child_id=new_child.id, role="primary"))
    db.add(models.ChildRule(child_id=new_child.id, daily_limit_minutes=60, downtime_enabled=False, bedtime_enabled=False, blocked_categories=[]))
    db.add(models.ChildState(child_id=new_child.id, manual_lock=False, task_gate_override=False))
    db.commit()
    return new_child


def _usable_name(name: Optional[str]) -> Optional[str]:
    # A name with no letters ("423186") is a mistyped code, not a name.
    if name and any(ch.isalpha() for ch in name):
        return name.strip()[:60]
    return None


def _live_pairing(db: Session, code: str) -> Optional[models.DevicePairing]:
    p = db.query(models.DevicePairing).filter(models.DevicePairing.code == code).first()
    if not p:
        return None
    exp = p.expires_at if p.expires_at.tzinfo else p.expires_at.replace(tzinfo=timezone.utc)
    return p if exp >= datetime.now(timezone.utc) else None


@router.post("/pairing/request", response_model=schemas.PairingRequestResponse)
def request_pairing(request: schemas.PairingRequest, db: Session = Depends(get_db)):
    """Kid's device: start pairing. Show `code` (text + QR) and poll /pairing/status."""
    now = datetime.now(timezone.utc)
    for old in db.query(models.DevicePairing).all():
        exp = old.expires_at if old.expires_at.tzinfo else old.expires_at.replace(tzinfo=timezone.utc)
        if exp < now:
            db.delete(old)
    db.commit()

    code = generate_unique_pairing_code(db)
    secret = secrets.token_urlsafe(32)
    pairing = models.DevicePairing(
        code=code,
        secret_hash=hash_token(secret),
        child_name=_usable_name(request.child_name),
        platform=request.platform,
        expires_at=now + timedelta(minutes=15),
    )
    db.add(pairing)
    db.commit()
    return {"code": code, "secret": secret, "expires_at": pairing.expires_at}


@router.post("/pairing/claim", response_model=schemas.ChildResponse)
def claim_pairing(request: schemas.PairingClaimRequest,
                  current_parent: models.Parent = Depends(get_current_parent),
                  db: Session = Depends(get_db)):
    """Parent: attach the device showing `code` to one of their children."""
    pairing = _live_pairing(db, request.code.strip())
    if not pairing:
        raise HTTPException(status_code=400, detail="Invalid or expired code")
    if pairing.child_id is not None:
        raise HTTPException(status_code=409, detail="That code was already used")

    kid_name = pairing.child_name
    if request.child_id:
        link = db.query(models.ParentChild).filter(
            models.ParentChild.parent_id == current_parent.id,
            models.ParentChild.child_id == request.child_id,
        ).first()
        if not link:
            raise HTTPException(status_code=404, detail="Child not found")
        child = db.query(models.Child).filter(models.Child.id == request.child_id).first()
    elif request.new_child:
        child = _create_placeholder_child(db, current_parent, kid_name or "Your Child")
    else:
        # Reuse a child that has no device yet (e.g. profile made earlier), else make one.
        child = None
        for link in db.query(models.ParentChild).filter(models.ParentChild.parent_id == current_parent.id).all():
            has_device = db.query(models.Device).filter(models.Device.child_id == link.child_id, models.Device.revoked_at == None).first()  # noqa: E711
            if not has_device:
                child = db.query(models.Child).filter(models.Child.id == link.child_id).first()
                break
        if child is None:
            child = _create_placeholder_child(db, current_parent, kid_name or "Your Child")

    # The kid typed their own name on their device; use it unless the parent
    # already gave this profile a real one.
    if kid_name and child.name in ("Your Child", "Child", ""):
        child.name = kid_name
    pairing.child_id = child.id
    db.commit()
    db.refresh(child)
    child.is_paired = False  # becomes true once the device collects its token
    return child


@router.post("/pairing/status", response_model=schemas.PairingStatusResponse)
def pairing_status(request: schemas.PairingStatusRequest, db: Session = Depends(get_db)):
    """Kid's device: has a parent claimed my code? If so, returns the device
    token exactly once."""
    pairing = _live_pairing(db, request.code.strip())
    if not pairing or not secrets.compare_digest(pairing.secret_hash, hash_token(request.secret)):
        raise HTTPException(status_code=404, detail="Pairing not found or expired")
    if pairing.child_id is None:
        return {"status": "pending"}

    child = db.query(models.Child).filter(models.Child.id == pairing.child_id).first()
    access_token = secrets.token_urlsafe(32)
    # MVP: one active device per child.
    db.query(models.Device).filter(models.Device.child_id == child.id).delete()
    db.add(models.Device(child_id=child.id, platform=pairing.platform, token_hash=hash_token(access_token)))
    db.delete(pairing)
    db.commit()
    child.is_paired = True
    return {"status": "paired", "access_token": access_token, "child": child}


def get_current_device(credentials: HTTPAuthorizationCredentials = Depends(security), db: Session = Depends(get_db)) -> models.Device:
    """Dependency to authenticate child devices using the token generated during pairing"""
    token_hash = hash_token(credentials.credentials)
    
    device = db.query(models.Device).filter(
        models.Device.token_hash == token_hash,
        models.Device.revoked_at == None
    ).first()
    
    if not device:
        raise HTTPException(status_code=401, detail="Invalid or revoked device token")
        
    return device

@router.delete("/account")
def delete_account(current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    # Cascade delete is usually handled by the DB, but let's manually clean up the main links
    child_ids = [pc.child_id for pc in db.query(models.ParentChild).filter(models.ParentChild.parent_id == current_parent.id).all()]
    db.query(models.ParentChild).filter(models.ParentChild.parent_id == current_parent.id).delete()
    # Children (and their tasks/devices, via FK cascade) no other parent still
    # links to would otherwise be left orphaned with a live device token.
    for cid in child_ids:
        if not db.query(models.ParentChild).filter(models.ParentChild.child_id == cid).first():
            db.query(models.Child).filter(models.Child.id == cid).delete()
    db.delete(current_parent)
    db.commit()
    return {"message": "Account deleted successfully"}
