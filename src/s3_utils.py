"""S3 helpers for versioned ONNX uploads."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Optional


def _client():
    import boto3

    endpoint = os.environ.get("AWS_S3_ENDPOINT")
    region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        region_name=region,
        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID"),
        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY"),
    )


def versioned_key(run_id: str, prefix: Optional[str] = None, filename: str = "model.onnx") -> str:
    base = prefix or os.environ.get("S3_KEY_PREFIX", "object-detection/xray-detector")
    return f"{base.rstrip('/')}/{run_id}/{filename}"


def upload_file(local_path: str | Path, key: str, bucket: Optional[str] = None) -> str:
    bucket = bucket or os.environ["AWS_S3_BUCKET"]
    path = Path(local_path)
    if not path.is_file():
        raise FileNotFoundError(path)
    client = _client()
    extra = {"ContentType": "application/octet-stream"}
    client.upload_file(str(path), bucket, key, ExtraArgs=extra)
    return f"s3://{bucket}/{key}"


def storage_path_from_uri(s3_uri: str) -> str:
    """Return object key/path without the s3://bucket/ prefix."""
    if not s3_uri.startswith("s3://"):
        return s3_uri
    without = s3_uri[len("s3://") :]
    _, _, path = without.partition("/")
    return path
