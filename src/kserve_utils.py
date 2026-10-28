"""Helpers to patch KServe InferenceService for canary / promote / rollback."""

from __future__ import annotations

import json
import os
import subprocess
from typing import Any, Optional


def _oc(*args: str) -> str:
    cmd = ["oc", *args]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(f"oc {' '.join(args[:6])}… failed ({proc.returncode}): {detail}")
    return proc.stdout


def patch_inference_service(
    name: str,
    namespace: str,
    storage_uri: Optional[str] = None,
    storage_key: Optional[str] = None,
    storage_path: Optional[str] = None,
    canary_traffic_percent: Optional[int] = None,
    remove_canary: bool = False,
    enable_tag_routing: bool = True,
) -> str:
    """Patch an InferenceService using strategic merge / JSON patch via oc.

    - Set ``canary_traffic_percent`` for canary rollout (Serverless mode).
    - Set ``remove_canary=True`` to promote canary to 100% traffic.
    - Prefer storage key+path (OpenShift AI Connection) when provided; else storageUri.
    """
    predictor: dict[str, Any] = {}
    model: dict[str, Any] = {}

    if storage_key and storage_path:
        model["storage"] = {"key": storage_key, "path": storage_path}
    elif storage_uri:
        model["storageUri"] = storage_uri

    if model:
        predictor["model"] = model

    if remove_canary:
        # JSON patch to remove the field entirely.
        patches = [
            {"op": "remove", "path": "/spec/predictor/canaryTrafficPercent"},
        ]
        if storage_uri or (storage_key and storage_path):
            # First merge storage update, then remove canary.
            merge_body = {
                "metadata": {
                    "annotations": {
                        "serving.kserve.io/enable-tag-routing": "true" if enable_tag_routing else "false"
                    }
                },
                "spec": {"predictor": predictor},
            }
            _oc(
                "patch",
                "inferenceservice",
                name,
                "-n",
                namespace,
                "--type=merge",
                "-p",
                json.dumps(merge_body),
            )
        return _oc(
            "patch",
            "inferenceservice",
            name,
            "-n",
            namespace,
            "--type=json",
            "-p",
            json.dumps(patches),
        )

    if canary_traffic_percent is not None:
        predictor["canaryTrafficPercent"] = int(canary_traffic_percent)

    body: dict[str, Any] = {
        "metadata": {
            "annotations": {
                "serving.kserve.io/enable-tag-routing": "true" if enable_tag_routing else "false"
            }
        },
        "spec": {"predictor": predictor},
    }
    return _oc(
        "patch",
        "inferenceservice",
        name,
        "-n",
        namespace,
        "--type=merge",
        "-p",
        json.dumps(body),
    )


def default_namespace() -> str:
    return os.environ.get("KSERVE_NAMESPACE") or os.environ.get("NAMESPACE") or "default"


def default_service_name() -> str:
    return os.environ.get("INFERENCE_SERVICE_NAME", "xray-detector")


def get_inference_service_storage_path(name: str, namespace: str) -> Optional[str]:
    """Return current ``spec.predictor.model.storage.path`` or None."""
    try:
        out = _oc(
            "get",
            "inferenceservice",
            name,
            "-n",
            namespace,
            "-o",
            "jsonpath={.spec.predictor.model.storage.path}",
        )
    except RuntimeError:
        return None
    path = (out or "").strip()
    return path or None


def get_predictor_endpoints(
    name: Optional[str] = None,
    namespace: Optional[str] = None,
) -> dict[str, Any]:
    """Read predictor + canary tag URLs from the live InferenceService.

    Returns keys: ``endpoint``, ``latest``, ``prev``, ``canary_percent``,
    ``storage_path``, ``ready``, ``raw_traffic``. Suitable for notebook 05
    without restarting the workbench / ConfigMap.
    """
    name = name or default_service_name()
    namespace = namespace or default_namespace()
    raw = _oc("get", "inferenceservice", name, "-n", namespace, "-o", "json")
    doc = json.loads(raw)
    status = doc.get("status") or {}
    spec = doc.get("spec") or {}
    predictor_status = (status.get("components") or {}).get("predictor") or {}
    traffic = predictor_status.get("traffic") or []
    latest = prev = ""
    for t in traffic:
        tag = (t.get("tag") or "").lower()
        url = (t.get("url") or "").rstrip("/")
        if not url:
            continue
        if tag == "latest":
            latest = url
        elif tag == "prev":
            prev = url
    endpoint = (predictor_status.get("url") or status.get("url") or "").rstrip("/")
    canary = (spec.get("predictor") or {}).get("canaryTrafficPercent")
    storage = ((spec.get("predictor") or {}).get("model") or {}).get("storage") or {}
    ready = next(
        (c.get("status") for c in (status.get("conditions") or []) if c.get("type") == "Ready"),
        None,
    )
    return {
        "endpoint": endpoint,
        "latest": latest,
        "prev": prev,
        "canary_percent": canary,
        "storage_path": storage.get("path") or "",
        "ready": ready,
        "raw_traffic": traffic,
    }


def sync_inference_env(
    name: Optional[str] = None,
    namespace: Optional[str] = None,
) -> dict[str, Any]:
    """Update ``os.environ`` INFERENCE_* from the live ISVC (current kernel only)."""
    info = get_predictor_endpoints(name=name, namespace=namespace)
    if info.get("endpoint"):
        os.environ["INFERENCE_ENDPOINT"] = info["endpoint"]
    if info.get("latest"):
        os.environ["INFERENCE_ENDPOINT_LATEST"] = info["latest"]
    else:
        os.environ.pop("INFERENCE_ENDPOINT_LATEST", None)
    if info.get("prev"):
        os.environ["INFERENCE_ENDPOINT_PREV"] = info["prev"]
    else:
        os.environ.pop("INFERENCE_ENDPOINT_PREV", None)
    return info
