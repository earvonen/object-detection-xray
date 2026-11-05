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


def _bucket() -> str:
    return os.environ["AWS_S3_BUCKET"]


def model_repo_prefix(prefix: Optional[str] = None) -> str:
    return (prefix or os.environ.get("S3_KEY_PREFIX", "object-detection/xray-detector")).rstrip("/")


def baseline_storage_path(prefix: Optional[str] = None) -> str:
    """Stable KServe storage.path used as the pre-canary (prev) revision."""
    return os.environ.get("BASELINE_PATH") or f"{model_repo_prefix(prefix)}/baseline"


def versioned_key(run_id: str, prefix: Optional[str] = None, filename: str = "model.onnx") -> str:
    """OVMS expects ``{prefix}/{run_id}/1/model.onnx`` (numeric version dir)."""
    return f"{model_repo_prefix(prefix)}/{run_id}/1/{filename}"


def upload_file(local_path: str | Path, key: str, bucket: Optional[str] = None) -> str:
    bucket = bucket or _bucket()
    path = Path(local_path)
    if not path.is_file():
        raise FileNotFoundError(path)
    client = _client()
    extra = {"ContentType": "application/octet-stream"}
    client.upload_file(str(path), bucket, key, ExtraArgs=extra)
    return f"s3://{bucket}/{key}"


def storage_path_from_uri(s3_uri: str) -> str:
    """Return KServe/OVMS model-repo prefix (no s3://bucket, no ``1/model.onnx``)."""
    if not s3_uri.startswith("s3://"):
        path = s3_uri
    else:
        without = s3_uri[len("s3://") :]
        _, _, path = without.partition("/")
    for suffix in ("/1/model.onnx", "/model.onnx"):
        if path.endswith(suffix):
            return path[: -len(suffix)]
    return path


def _object_exists(client, bucket: str, key: str) -> bool:
    try:
        client.head_object(Bucket=bucket, Key=key)
        return True
    except Exception:  # noqa: BLE001 — boto3 ClientError / missing
        return False


def _find_onnx_key(client, bucket: str, repo_path: str) -> Optional[str]:
    """Return an object key for OVMS under repo_path (prefer ``1/model.onnx``)."""
    repo = storage_path_from_uri(repo_path)
    preferred = f"{repo}/1/model.onnx"
    if _object_exists(client, bucket, preferred):
        return preferred
    flat = f"{repo}/model.onnx"
    if _object_exists(client, bucket, flat):
        return flat
    # Any .onnx under the prefix
    token = None
    while True:
        kw: dict = {"Bucket": bucket, "Prefix": repo.rstrip("/") + "/"}
        if token:
            kw["ContinuationToken"] = token
        resp = client.list_objects_v2(**kw)
        for obj in resp.get("Contents") or []:
            key = obj["Key"]
            if key.endswith(".onnx"):
                return key
        if not resp.get("IsTruncated"):
            break
        token = resp["NextContinuationToken"]
    return None


def copy_model_repo(source_path: str, dest_path: str, bucket: Optional[str] = None) -> str:
    """Copy ONNX from source model-repo prefix to dest as ``dest/1/model.onnx``."""
    bucket = bucket or _bucket()
    client = _client()
    src_key = _find_onnx_key(client, bucket, source_path)
    if not src_key:
        raise FileNotFoundError(f"No ONNX under s3://{bucket}/{storage_path_from_uri(source_path)}/")
    dest_repo = storage_path_from_uri(dest_path)
    dest_key = f"{dest_repo}/1/model.onnx"
    client.copy_object(Bucket=bucket, CopySource={"Bucket": bucket, "Key": src_key}, Key=dest_key)
    # Optional flat copy for older tooling
    client.copy_object(
        Bucket=bucket,
        CopySource={"Bucket": bucket, "Key": src_key},
        Key=f"{dest_repo}/model.onnx",
    )
    return f"s3://{bucket}/{dest_key}"


def ensure_baseline_model(
    baseline_path: Optional[str] = None,
    source_path: Optional[str] = None,
    bucket: Optional[str] = None,
) -> str:
    """Ensure baseline ``1/model.onnx`` exists; seed from source_path if missing.

    Returns the s3 URI of the baseline versioned object.
    """
    bucket = bucket or _bucket()
    client = _client()
    baseline = storage_path_from_uri(baseline_path or baseline_storage_path())
    dest_key = f"{baseline}/1/model.onnx"
    if _object_exists(client, bucket, dest_key):
        return f"s3://{bucket}/{dest_key}"

    src = source_path
    if not src:
        # Newest run dir under the model prefix that is not baseline
        prefix = model_repo_prefix() + "/"
        token = None
        candidates: list[str] = []
        while True:
            kw: dict = {"Bucket": bucket, "Prefix": prefix}
            if token:
                kw["ContinuationToken"] = token
            resp = client.list_objects_v2(**kw)
            for obj in resp.get("Contents") or []:
                key = obj["Key"]
                if key.endswith("/1/model.onnx") or key.endswith("/model.onnx"):
                    repo = storage_path_from_uri(key)
                    if repo.rstrip("/").endswith("/baseline") or repo.endswith("baseline"):
                        continue
                    candidates.append(repo)
            if not resp.get("IsTruncated"):
                break
            token = resp["NextContinuationToken"]
        # Prefer unique repos; last lexicographic is fine for demo seed
        candidates = sorted(set(candidates))
        if not candidates:
            raise FileNotFoundError(
                f"No baseline at {dest_key} and no source ONNX under {prefix}. "
                "Run notebook 03 first, then re-run ensure-baseline-isvc.sh."
            )
        src = candidates[-1]

    return copy_model_repo(src, baseline, bucket=bucket)


def refresh_baseline_from(source_path: str, baseline_path: Optional[str] = None) -> str:
    """Overwrite baseline with the given model-repo (e.g. after promote to 100%)."""
    return copy_model_repo(source_path, baseline_path or baseline_storage_path())
