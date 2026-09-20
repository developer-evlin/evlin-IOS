import os
import boto3
from botocore.config import Config
from dotenv import load_dotenv

load_dotenv()

R2_ACCOUNT_ID = os.getenv("R2_ACCOUNT_ID")
R2_ACCESS_KEY_ID = os.getenv("R2_ACCESS_KEY_ID")
R2_SECRET_ACCESS_KEY = os.getenv("R2_SECRET_ACCESS_KEY")
R2_BUCKET_NAME = os.getenv("R2_BUCKET_NAME")
R2_PUBLIC_BUCKET_NAME = os.getenv("R2_PUBLIC_BUCKET_NAME")

def storage_configured() -> bool:
    """Whether R2 credentials are present at all — lets a route tell "not
    configured yet" apart from "configured but the signing call itself
    failed", which are different problems with different fixes."""
    return all([R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY])


def get_s3_client():
    if not all([R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY]):
        raise ValueError("Cloudflare R2 credentials are not fully set in .env")

    return boto3.client(
        "s3",
        endpoint_url=f"https://{R2_ACCOUNT_ID}.r2.cloudflarestorage.com",
        aws_access_key_id=R2_ACCESS_KEY_ID,
        aws_secret_access_key=R2_SECRET_ACCESS_KEY,
        config=Config(signature_version="s3v4"),
        region_name="auto",
    )

def generate_presigned_upload_url(object_name: str, content_type: str, expiration=3600, bucket_name=None):
    """
    Generate a presigned URL to upload a file directly to R2. Returns None on
    any failure — including missing/misconfigured credentials (get_s3_client
    raises before this even reaches R2), which used to propagate uncaught
    out of get_s3_client() and turn into a bare, undiagnosable 500 on every
    single upload/submission route. The caller decides what to tell the
    client; this function just never lets a config problem crash the process.
    """
    if bucket_name is None:
        bucket_name = R2_BUCKET_NAME
    try:
        s3_client = get_s3_client()
        response = s3_client.generate_presigned_url(
            'put_object',
            Params={
                'Bucket': bucket_name,
                'Key': object_name,
                'ContentType': content_type
            },
            ExpiresIn=expiration
        )
        return response
    except Exception as e:
        print(f"Error generating presigned upload URL: {e}")
        return None

def generate_presigned_download_url(object_name: str, expiration=3600, bucket_name=None):
    """
    Generate a presigned URL to securely download a file from R2. Same
    all-failures-return-None contract as generate_presigned_upload_url.
    """
    if bucket_name is None:
        bucket_name = R2_BUCKET_NAME
    try:
        s3_client = get_s3_client()
        response = s3_client.generate_presigned_url(
            'get_object',
            Params={
                'Bucket': bucket_name,
                'Key': object_name
            },
            ExpiresIn=expiration
        )
        return response
    except Exception as e:
        print(f"Error generating presigned download URL: {e}")
        return None
