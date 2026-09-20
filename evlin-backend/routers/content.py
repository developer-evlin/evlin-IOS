from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
import models
from routers.auth import get_current_device
from storage import generate_presigned_upload_url, generate_presigned_download_url, storage_configured, R2_PUBLIC_BUCKET_NAME
from uuid import uuid4

router = APIRouter(prefix="/content", tags=["content"])

class UploadRequest(BaseModel):
    content_type: str

class UploadResponse(BaseModel):
    upload_url: str
    object_key: str

class DownloadResponse(BaseModel):
    download_url: str

@router.post("/upload-url", response_model=UploadResponse)
def get_upload_url(
    req: UploadRequest,
    current_device: models.Device = Depends(get_current_device)
):
    """Generate a pre-signed URL for uploading content to the public bucket"""
    if not storage_configured():
        raise HTTPException(status_code=503, detail="Uploads aren't configured on the server yet (missing R2 credentials).")
    ext = req.content_type.split('/')[-1] if '/' in req.content_type else 'bin'
    object_key = f"content/{current_device.child_id}/{uuid4()}.{ext}"
    
    url = generate_presigned_upload_url(
        object_key, 
        req.content_type, 
        bucket_name=R2_PUBLIC_BUCKET_NAME
    )
    if not url:
        raise HTTPException(status_code=500, detail="Could not generate upload URL")
        
    return {"upload_url": url, "object_key": object_key}

@router.get("/{object_key:path}/url", response_model=DownloadResponse)
def get_content_url(
    object_key: str,
    current_device: models.Device = Depends(get_current_device)
):
    """Fetch a pre-signed download URL for a specific content object"""
    if not storage_configured():
        raise HTTPException(status_code=503, detail="Downloads aren't configured on the server yet (missing R2 credentials).")
    url = generate_presigned_download_url(
        object_key,
        bucket_name=R2_PUBLIC_BUCKET_NAME
    )
    if not url:
        raise HTTPException(status_code=404, detail="Could not generate download URL")
        
    return {"download_url": url}
