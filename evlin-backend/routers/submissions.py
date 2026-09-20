from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from uuid import UUID, uuid4
from datetime import datetime, timezone
import models, schemas
from database import get_db
from routers.auth import get_current_device
from storage import generate_presigned_upload_url, storage_configured, generate_presigned_download_url
from access import get_occurrence_for_device_or_parent

router = APIRouter(tags=["submissions"])


@router.get("/occurrences/{occurrence_id}/submissions", response_model=list[schemas.SubmissionListItem])
def list_submissions(
    occurrence: models.Occurrence = Depends(get_occurrence_for_device_or_parent),
    db: Session = Depends(get_db),
):
    """Real evidence for one occurrence — the child's own device (to show what
    it already turned in after relaunching, with nothing left in local
    memory) or that child's parent (to actually see it, not a placeholder)."""
    subs = db.query(models.Submission).filter(
        models.Submission.occurrence_id == occurrence.id
    ).order_by(models.Submission.created_at).all()
    out = []
    for s in subs:
        item = schemas.SubmissionListItem.model_validate(s)
        if s.status == "uploaded":
            item.download_url = generate_presigned_download_url(s.r2_key)
        out.append(item)
    return out

@router.post("/occurrences/{occurrence_id}/submissions", response_model=schemas.SubmissionUploadResponse)
def create_submission(
    occurrence_id: UUID, 
    sub_req: schemas.SubmissionCreate,
    current_device: models.Device = Depends(get_current_device),
    db: Session = Depends(get_db)
):
    """Child begins a submission (photo/voice) and gets a presigned Cloudflare R2 upload URL"""
    
    # 1. Verify the occurrence exists and belongs to this child
    occurrence = db.query(models.Occurrence).filter(models.Occurrence.id == occurrence_id).first()
    if not occurrence:
        raise HTTPException(status_code=404, detail="Occurrence not found")
    if occurrence.child_id != current_device.child_id:
        raise HTTPException(status_code=403, detail="Not your occurrence")
        
    # 2. Generate a secure, unique R2 object key
    ext = sub_req.content_type.split('/')[-1] if '/' in sub_req.content_type else 'bin'
    r2_key = f"submissions/{occurrence.child_id}/{occurrence_id}/{uuid4()}.{ext}"
    
    # 3. Generate the presigned URL via our storage module
    if not storage_configured():
        raise HTTPException(status_code=503, detail="Photo/voice uploads aren't configured on the server yet (missing R2 credentials).")
    presigned_url = generate_presigned_upload_url(r2_key, sub_req.content_type)
    if not presigned_url:
        raise HTTPException(status_code=500, detail="Failed to generate upload URL")
        
    # 4. Create the pending submission row in the database
    submission = models.Submission(
        occurrence_id=occurrence_id,
        kind=sub_req.kind,
        r2_key=r2_key,
        content_type=sub_req.content_type,
        bytes_size=sub_req.bytes_size,
        duration_seconds=sub_req.duration_seconds,
        status="pending"
    )
    db.add(submission)
    db.commit()
    db.refresh(submission)
    
    return {
        "submission": submission,
        "upload_url": presigned_url
    }

@router.post("/submissions/{submission_id}/complete", response_model=schemas.SubmissionResponse)
def complete_submission(
    submission_id: UUID,
    current_device: models.Device = Depends(get_current_device),
    db: Session = Depends(get_db)
):
    """Child notifies the backend that they successfully uploaded the file to R2"""
    submission = db.query(models.Submission).filter(models.Submission.id == submission_id).first()
    if not submission:
        raise HTTPException(status_code=404, detail="Submission not found")
        
    # Verify ownership
    occurrence = db.query(models.Occurrence).filter(models.Occurrence.id == submission.occurrence_id).first()
    if not occurrence or occurrence.child_id != current_device.child_id:
        raise HTTPException(status_code=403, detail="Not your submission")
        
    # Mark as uploaded
    submission.status = "uploaded"
    submission.uploaded_at = datetime.now(timezone.utc)
    
    # Automatically move the occurrence to "submitted" if it was pending or rejected
    if occurrence.status in ["pending", "rejected"]:
        occurrence.status = "submitted"
        
    db.commit()
    db.refresh(submission)
    
    return submission
