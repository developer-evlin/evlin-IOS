from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from uuid import UUID, uuid4
from datetime import datetime, timezone
import models, schemas
from database import get_db
from routers.auth import get_current_device
import storage
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

def confirm_in_storage(submission: models.Submission) -> bool:
    """Marks a photo uploaded once R2 really has it (not on the phone's
    word alone). False when the file isn't there. Doesn't commit; raises
    503 when R2 couldn't be asked, so the phone tries again."""
    if submission.status == "uploaded":
        return True
    if not storage_configured():
        return False
    try:
        size = storage.object_size(submission.r2_key)
    except storage.StorageUnavailable:
        raise HTTPException(status_code=503, detail="Couldn't check the photo just now")
    if size is None:
        return False
    submission.status = "uploaded"
    submission.bytes_size = size
    submission.uploaded_at = datetime.now(timezone.utc)
    return True


@router.post("/occurrences/{occurrence_id}/submissions", response_model=schemas.SubmissionUploadResponse)
def create_submission(
    occurrence_id: UUID,
    sub_req: schemas.SubmissionCreate,
    current_device: models.Device = Depends(get_current_device),
    db: Session = Depends(get_db)
):
    """A place for one photo, and a link to upload it straight to R2. The
    photo isn't the task's until R2 has it: Send (or complete) checks.

    The phone names the photo (`id`), so asking again, a retry or a link
    that expired, answers with the same photo and a fresh link."""
    occurrence = db.query(models.Occurrence).filter(models.Occurrence.id == occurrence_id).first()
    if not occurrence:
        raise HTTPException(status_code=404, detail="Occurrence not found")
    if occurrence.child_id != current_device.child_id:
        raise HTTPException(status_code=403, detail="Not your occurrence")
    if not storage_configured():
        raise HTTPException(status_code=503, detail="Photo uploads aren't configured on the server yet (missing R2 credentials).")

    submission = None
    if sub_req.id is not None:
        submission = db.query(models.Submission).filter(models.Submission.id == sub_req.id).first()
        if submission is not None and submission.occurrence_id != occurrence.id:
            raise HTTPException(status_code=409, detail="That photo belongs to another task")
    if submission is None:
        photo_id = sub_req.id or uuid4()
        ext = sub_req.content_type.split('/')[-1] if '/' in sub_req.content_type else 'bin'
        submission = models.Submission(
            id=photo_id,
            occurrence_id=occurrence.id,
            kind=sub_req.kind,
            r2_key=f"submissions/{occurrence.child_id}/{occurrence.id}/{photo_id}.{ext}",
            content_type=sub_req.content_type,
            bytes_size=sub_req.bytes_size,
            status="pending",
        )
        db.add(submission)
    elif sub_req.bytes_size is not None and submission.status != "uploaded":
        # The same photo, saved again on the phone (a different size).
        submission.bytes_size = sub_req.bytes_size

    upload_url = generate_presigned_upload_url(submission.r2_key, submission.content_type,
                                               content_length=sub_req.bytes_size)
    if not upload_url:
        raise HTTPException(status_code=500, detail="Failed to generate upload URL")
    db.commit()
    db.refresh(submission)
    return {"submission": submission, "upload_url": upload_url}


@router.post("/submissions/{submission_id}/complete", response_model=schemas.SubmissionResponse)
def complete_submission(
    submission_id: UUID,
    current_device: models.Device = Depends(get_current_device),
    db: Session = Depends(get_db)
):
    """The photo is in R2, checked there. It doesn't send the task in: only
    the kid's Send does (POST /tasks/occurrences/{id}/submit). Apps that
    send photo_ids with Send never call this."""
    submission = db.query(models.Submission).filter(models.Submission.id == submission_id).first()
    if not submission:
        raise HTTPException(status_code=404, detail="Submission not found")
    occurrence = db.query(models.Occurrence).filter(models.Occurrence.id == submission.occurrence_id).first()
    if not occurrence or occurrence.child_id != current_device.child_id:
        raise HTTPException(status_code=403, detail="Not your submission")
    if storage_configured() and not confirm_in_storage(submission):
        raise HTTPException(status_code=409, detail="The photo hasn't arrived")
    if not storage_configured():
        submission.status = "uploaded"
        submission.uploaded_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(submission)
    return submission
