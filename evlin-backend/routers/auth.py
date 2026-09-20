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
    """Generate a unique 6-digit pairing code"""
    while True:
        code = ''.join(random.choices(string.digits, k=6))
        # Check if the code is already active
        existing = db.query(models.PairingCode).filter(models.PairingCode.code == code).first()
        if not existing:
            return code

def _create_placeholder_child(db: Session, parent: models.Parent) -> models.Child:
    count = db.query(models.ParentChild).filter(models.ParentChild.parent_id == parent.id).count()
    new_child = models.Child(name="Your Child", birth_year=2015, color_index=count % 8, avatar_url="")
    db.add(new_child)
    db.commit()
    db.refresh(new_child)

    db.add(models.ParentChild(parent_id=parent.id, child_id=new_child.id, role="primary"))
    db.add(models.ChildRule(child_id=new_child.id, daily_limit_minutes=60, downtime_enabled=False, bedtime_enabled=False, blocked_categories=[]))
    db.add(models.ChildState(child_id=new_child.id, manual_lock=False, task_gate_override=False))
    db.commit()
    return new_child


@router.post("/generate-pairing-code", response_model=schemas.GeneratePairingCodeResponse)
def generate_pairing_code(request: Optional[schemas.GeneratePairingCodeRequest] = None,
                          current_parent: models.Parent = Depends(get_current_parent),
                          db: Session = Depends(get_db)):
    """Parent generates a pairing code for a child (see GeneratePairingCodeRequest)."""
    request = request or schemas.GeneratePairingCodeRequest()

    if request.child_id:
        link = db.query(models.ParentChild).filter(
            models.ParentChild.parent_id == current_parent.id,
            models.ParentChild.child_id == request.child_id,
        ).first()
        if not link:
            raise HTTPException(status_code=404, detail="Child not found")
        child_id = link.child_id
    elif request.new_child:
        child_id = _create_placeholder_child(db, current_parent).id
    else:
        first = db.query(models.ParentChild).filter(models.ParentChild.parent_id == current_parent.id).first()
        child_id = first.child_id if first else _create_placeholder_child(db, current_parent).id

    now = datetime.now(timezone.utc)
    db.query(models.PairingCode).filter(models.PairingCode.expires_at < now).delete()
    
    code = generate_unique_pairing_code(db)
    expires_at = now + timedelta(minutes=15)
    
    pairing_code = models.PairingCode(
        code=code,
        child_id=child_id,
        parent_id=current_parent.id,
        expires_at=expires_at
    )
    
    db.add(pairing_code)
    db.commit()
    
    return {"pairing_code": code, "expires_at": expires_at, "child_id": child_id}


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()

@router.get("/check-pairing/{code}")
def check_pairing(code: str, child_id: Optional[uuid.UUID] = None,
                  current_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """Has the device for this code paired yet?

    With child_id (what the app sends) the answer is whether that child has a
    device — a code that merely expired is *not* "paired". Without it, fall
    back to the old behaviour: the code being consumed means paired.
    """
    pairing_code = db.query(models.PairingCode).filter(models.PairingCode.code == code).first()
    if child_id is None:
        link = db.query(models.ParentChild).filter(models.ParentChild.parent_id == current_parent.id).first()
        child_id = pairing_code.child_id if pairing_code else (link.child_id if link else None)
    if child_id is None:
        return {"paired": False}

    owns = db.query(models.ParentChild).filter(
        models.ParentChild.parent_id == current_parent.id,
        models.ParentChild.child_id == child_id,
    ).first()
    if not owns:
        raise HTTPException(status_code=404, detail="Child not found")

    child = db.query(models.Child).filter(models.Child.id == child_id).first()
    has_device = db.query(models.Device).filter(
        models.Device.child_id == child_id, models.Device.revoked_at == None  # noqa: E711
    ).count() > 0
    if has_device and pairing_code is None:
        return {"paired": True, "kid_name": child.name if child and child.name else "Your child"}
    return {"paired": False}

@router.post("/pair-child", response_model=schemas.PairChildResponse)
def pair_child(request: schemas.PairChildRequest, db: Session = Depends(get_db)):
    """Child enters the code to authenticate their device"""
    # 1. Find the code
    pairing_code = db.query(models.PairingCode).filter(
        models.PairingCode.code == request.pairing_code
    ).first()
    
    now = datetime.now(timezone.utc)
    
    if not pairing_code or pairing_code.expires_at < now:
        raise HTTPException(status_code=400, detail="Invalid or expired pairing code")
    
    # 2. Get the child
    child = db.query(models.Child).filter(models.Child.id == pairing_code.child_id).first()
    if not child:
        raise HTTPException(status_code=404, detail="Child not found")
        
    # Update child name if provided from the pairing device
    # A name with no letters ("423186") is a mistyped pairing code, not a
    # name — keep whatever the profile already had.
    if request.child_name and any(ch.isalpha() for ch in request.child_name):
        child.name = request.child_name.strip()[:60]
        db.commit()
        db.refresh(child)
        
    # 3. Generate a secure long-lived token
    access_token = secrets.token_urlsafe(32)
    token_hash = hash_token(access_token)
    
    # 4. Create the device record (enforce 1 active device by clearing old ones for MVP)
    db.query(models.Device).filter(models.Device.child_id == child.id).delete()
    
    device = models.Device(
        child_id=child.id,
        platform=request.platform,
        token_hash=token_hash
    )
    db.add(device)
    
    # 5. Delete the pairing code (first-come, first-served)
    db.delete(pairing_code)
    db.commit()
    
    return {
        "access_token": access_token,
        "child": child
    }

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
