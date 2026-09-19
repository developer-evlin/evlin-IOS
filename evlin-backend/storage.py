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

def generate_presigned_upload_url(object_name: str, content_type: str, expiration=3600):
    """
    Generate a presigned URL to upload a file directly to R2.
    """
    s3_client = get_s3_client()
    try:
        response = s3_client.generate_presigned_url(
            'put_object',
            Params={
                'Bucket': R2_BUCKET_NAME,
                'Key': object_name,
                'ContentType': content_type
            },
            ExpiresIn=expiration
        )
        return response
    except Exception as e:
        print(f"Error generating presigned upload URL: {e}")
        return None

def generate_presigned_download_url(object_name: str, expiration=3600):
    """
    Generate a presigned URL to securely download a file from R2.
    """
    s3_client = get_s3_client()
    try:
        response = s3_client.generate_presigned_url(
            'get_object',
            Params={
                'Bucket': R2_BUCKET_NAME,
                'Key': object_name
            },
            ExpiresIn=expiration
        )
        return response
    except Exception as e:
        print(f"Error generating presigned download URL: {e}")
        return None
