"""Resolve Model Registry ``stage=prod`` and canary / promote / rollback the ISVC.

Used by notebooks (demo path) and ``pipelines/promote_deploy_canary.py`` (CLI / KFP).
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from typing import Any, NamedTuple, Optional

from src.kserve_utils import (
    default_namespace,
    default_service_name,
    get_inference_service_storage_path,
    patch_inference_service,
)
from src.registry_client import ModelRegistryClient
from src.s3_utils import refresh_baseline_from, storage_path_from_uri


class ResolveResult(NamedTuple):
    version_id: str
    version_name: str
    uri: str
    storage_key: str
    storage_path: str
    mlflow_run_id: str


def resolve_prod(model_name: str) -> ResolveResult:
    client = ModelRegistryClient()
    resolved = client.resolve_prod(model_name)
    return ResolveResult(
        version_id=str(resolved["version_id"]),
        version_name=str(resolved.get("version_name") or ""),
        uri=str(resolved.get("uri") or ""),
        storage_key=str(resolved.get("storage_key") or os.environ.get("STORAGE_KEY") or ""),
        storage_path=str(resolved.get("storage_path") or ""),
        mlflow_run_id=str(resolved.get("mlflow_run_id") or ""),
    )


def deploy_canary(
    resolved: ResolveResult,
    namespace: str,
    service_name: str,
    canary_percent: int,
    *,
    require_new_path: bool = True,
) -> str:
    new_path = storage_path_from_uri(resolved.storage_path or resolved.uri or "")
    current = get_inference_service_storage_path(service_name, namespace)
    if current and new_path and current.rstrip("/") == new_path.rstrip("/"):
        if require_new_path:
            raise SystemExit(
                f"Canary storage.path matches the live InferenceService ({current}).\n"
                "Knative will not create a second revision/pod.\n"
                "Serve a different baseline first (notebook 00 / ensure-baseline-isvc), "
                "then re-run canary so stage=prod points at the new run's path."
            )
        return f"skipped canary redeploy (already on {current})"
    return patch_inference_service(
        name=service_name,
        namespace=namespace,
        storage_uri=resolved.uri if not resolved.storage_key else None,
        storage_key=resolved.storage_key or None,
        storage_path=new_path or resolved.storage_path or None,
        canary_traffic_percent=canary_percent,
        remove_canary=False,
        enable_tag_routing=True,
    )


def validate_endpoint(endpoint: str, skip: bool = False) -> str:
    if skip or not endpoint:
        return "skipped"
    req = urllib.request.Request(endpoint, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310
            return f"ok status={resp.status}"
    except urllib.error.HTTPError as exc:
        return f"reachable status={exc.code}"
    except Exception as exc:  # noqa: BLE001
        return f"failed: {exc}"


def promote_or_rollback(
    action: str,
    resolved: ResolveResult,
    namespace: str,
    service_name: str,
) -> str:
    if action == "leave-canary":
        return "left in canary state"
    if action == "promote":
        out = patch_inference_service(
            name=service_name,
            namespace=namespace,
            storage_uri=resolved.uri if not resolved.storage_key else None,
            storage_key=resolved.storage_key or None,
            storage_path=storage_path_from_uri(resolved.storage_path or resolved.uri or "")
            or resolved.storage_path
            or None,
            remove_canary=True,
            enable_tag_routing=True,
        )
        try:
            src = storage_path_from_uri(resolved.storage_path or resolved.uri or "")
            if src:
                baseline_uri = refresh_baseline_from(src)
                print(f"refreshed S3 baseline from prod → {baseline_uri}")
        except Exception as exc:  # noqa: BLE001
            print(f"warning: could not refresh S3 baseline: {exc}")
        return out
    if action == "rollback":
        return patch_inference_service(
            name=service_name,
            namespace=namespace,
            storage_uri=resolved.uri if not resolved.storage_key else None,
            storage_key=resolved.storage_key or None,
            storage_path=resolved.storage_path or None,
            canary_traffic_percent=0,
            remove_canary=False,
            enable_tag_routing=True,
        )
    raise ValueError(f"Unknown action: {action}")


def run_flow(
    model_name: Optional[str] = None,
    namespace: Optional[str] = None,
    service_name: Optional[str] = None,
    canary_percent: Optional[int] = None,
    action: str = "leave-canary",
    validate_url: Optional[str] = None,
    skip_validate: bool = True,
) -> dict[str, Any]:
    """Notebook- and CLI-friendly canary / promote / rollback.

    ``action``: ``leave-canary`` | ``promote`` | ``rollback``.
    """
    model_name = model_name or os.environ.get("REGISTERED_MODEL_NAME", "xray-detector")
    namespace = namespace or default_namespace()
    service_name = service_name or default_service_name()
    canary_percent = (
        int(canary_percent)
        if canary_percent is not None
        else int(os.environ.get("CANARY_TRAFFIC_PERCENT", "10"))
    )
    validate_url = validate_url if validate_url is not None else os.environ.get("INFERENCE_ENDPOINT", "")

    print(f"[1/4] Resolving stage=prod for {model_name}")
    resolved = resolve_prod(model_name)
    print(json.dumps(resolved._asdict(), indent=2))

    print(f"[2/4] Deploying canary ({canary_percent}%) to InferenceService {namespace}/{service_name}")
    deploy_out = deploy_canary(
        resolved,
        namespace,
        service_name,
        canary_percent,
        require_new_path=(action == "leave-canary"),
    )
    print(deploy_out)

    print("[3/4] Validating endpoint")
    validate_out = validate_endpoint(validate_url or "", skip=skip_validate)
    print(validate_out)

    print(f"[4/4] action={action}")
    final_out = promote_or_rollback(action, resolved, namespace, service_name)
    print(final_out)

    return {
        "resolved": resolved._asdict(),
        "deploy": deploy_out,
        "validate": validate_out,
        "final": final_out,
    }
