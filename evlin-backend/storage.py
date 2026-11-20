import os
import boto3
from botocore.config import Config
from dotenv import load_dotenv

load_dotenv()

R2_ACCOUNT_ID = os.getenv("R2_ACCOUNT_ID")
R2_ACCESS_KEY_ID = os.getenv("R2_ACCESS_KEY_ID")
R2_SECRET_ACCESS_KEY = os.getenv("R2_SECRET_ACCESS_KEY")
R2_BUCKET_NAME = os.getenv("R2_BUCKET_NAME")

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

def generate_presigned_upload_url(object_name: str, content_type: str, expiration=3600,
                                  content_length: int | None = None):
    """
    `content_length`, when known, is signed into the link: R2 then refuses
    an upload of any other size, so a link can't be used to store more.

    Generate a presigned URL to upload a file directly to R2. Returns None on
    any failure — including missing/misconfigured credentials (get_s3_client
    raises before this even reaches R2), which used to propagate uncaught
    out of get_s3_client() and turn into a bare, undiagnosable 500 on every
    single upload/submission route. The caller decides what to tell the
    client; this function just never lets a config problem crash the process.
    """
    try:
        s3_client = get_s3_client()
        params = {'Bucket': R2_BUCKET_NAME, 'Key': object_name, 'ContentType': content_type}
        if content_length is not None:
            params['ContentLength'] = content_length
        response = s3_client.generate_presigned_url(
            'put_object',
            Params=params,
            ExpiresIn=expiration
        )
        return response
    except Exception as e:
        print(f"Error generating presigned upload URL: {e}")
        return None

def generate_presigned_download_url(object_name: str, expiration=3600):
    """
    Generate a presigned URL to securely download a file from R2. Same
    all-failures-return-None contract as generate_presigned_upload_url.
    """
    try:
        s3_client = get_s3_client()
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


class StorageUnavailable(Exception):
    """R2 couldn't be asked (down, or misconfigured): not an answer about
    the file, so the caller should try again rather than decide anything."""


def object_size(key: str) -> int | None:
    """The size of a file in R2, or None when there's no such file. Raises
    StorageUnavailable when R2 couldn't be asked."""
    try:
        head = get_s3_client().head_object(Bucket=R2_BUCKET_NAME, Key=key)
    except Exception as e:
        code = str(getattr(e, "response", {}).get("Error", {}).get("Code", ""))
        if code in ("404", "NoSuchKey", "NotFound"):
            return None
        raise StorageUnavailable(str(e)) from e
    return int(head.get("ContentLength") or 0)


def delete_objects(keys: list[str]) -> None:
    """Deletes these photos from R2. Best effort: the database rows are
    already gone, so a failure here only leaves an unreachable file behind,
    and is logged rather than failing the parent's request."""
    if not keys or not storage_configured():
        return
    try:
        get_s3_client().delete_objects(
            Bucket=R2_BUCKET_NAME,
            Delete={"Objects": [{"Key": k} for k in keys], "Quiet": True},
        )
    except Exception as e:
        print(f"R2: couldn't delete {len(keys)} photo(s): {e}")
