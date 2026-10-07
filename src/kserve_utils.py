"""Helpers to patch KServe InferenceService for canary / promote / rollback."""

from __future__ import annotations

import json
import os
import subprocess
from typing import Any, Optional


def _oc(*args: str) -> str:
    cmd = ["oc", *args]
    proc = subprocess.run(cmd, check=True, capture_output=True, text=True)
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
