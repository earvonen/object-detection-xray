#!/usr/bin/env python3
"""Promote / canary / rollback pipeline for the X-ray detector demo.

Core logic lives in ``src.canary_deploy`` (used by notebooks). This module
keeps the CLI entrypoint and optional KFP compile for Data Science Pipelines.

Demo path: run canary / promote / rollback cells in notebooks 04 and 05.
Optional CLI (same behavior)::

    python pipelines/promote_deploy_canary.py --action leave-canary
    python pipelines/promote_deploy_canary.py --action promote
    python pipelines/promote_deploy_canary.py --compile /tmp/promote_deploy_canary.yaml
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from src.canary_deploy import (  # noqa: E402
    ResolveResult,
    deploy_canary,
    promote_or_rollback,
    resolve_prod,
    run_flow,
    validate_endpoint,
)
from src.kserve_utils import default_namespace, default_service_name  # noqa: E402

# Re-export for callers that imported these names from this module.
__all__ = [
    "ResolveResult",
    "compile_pipeline",
    "deploy_canary",
    "main",
    "promote_or_rollback",
    "resolve_prod",
    "run_flow",
    "validate_endpoint",
]


def compile_pipeline(output_path: str) -> None:
    """Compile a KFP v2 pipeline YAML for OpenShift AI Data Science Pipelines."""
    from kfp import compiler, dsl

    # Lightweight image with oc + python; override at submit time for your cluster.
    BASE_IMAGE = os.environ.get(
        "PIPELINE_RUNTIME_IMAGE",
        "quay.io/opendatahub/workbench-images:jupyter-minimal-ubi9-python-3.11",
    )

    @dsl.component(base_image=BASE_IMAGE, packages_to_install=["requests"])
    def resolve_prod_op(
        model_registry_url: str,
        model_name: str,
        model_registry_token: str = "",
    ) -> str:
        import json
        import os

        import requests

        os.environ["MODEL_REGISTRY_URL"] = model_registry_url
        if model_registry_token:
            os.environ["MODEL_REGISTRY_TOKEN"] = model_registry_token

        api = model_registry_url.rstrip("/") + "/api/model_registry/v1alpha3"
        headers = {"Accept": "application/json"}
        if model_registry_token:
            headers["Authorization"] = f"Bearer {model_registry_token}"

        models = requests.get(f"{api}/registered_models", headers=headers, timeout=60, verify=False).json()
        items = models if isinstance(models, list) else models.get("items") or models.get("registeredModels") or []
        registered = next((m for m in items if m.get("name") == model_name), None)
        if not registered:
            raise RuntimeError(f"model not found: {model_name}")

        versions = requests.get(
            f"{api}/registered_models/{registered['id']}/versions",
            headers=headers,
            timeout=60,
            verify=False,
        ).json()
        vitems = versions if isinstance(versions, list) else versions.get("items") or versions.get("modelVersions") or []

        def stage_of(v):
            props = v.get("customProperties") or {}
            stage = props.get("stage") or {}
            if isinstance(stage, dict):
                return stage.get("string_value")
            return stage

        prod = next((v for v in vitems if stage_of(v) == "prod"), None)
        if not prod:
            raise RuntimeError("no stage=prod version")

        arts = requests.get(
            f"{api}/model_versions/{prod['id']}/artifacts",
            headers=headers,
            timeout=60,
            verify=False,
        ).json()
        aitems = arts if isinstance(arts, list) else arts.get("items") or arts.get("artifacts") or arts.get("modelArtifacts") or []
        if not aitems:
            raise RuntimeError("no artifacts on prod version")
        art = aitems[0]
        uri = art.get("uri") or ""
        storage_path = art.get("storagePath") or ""
        if not storage_path and uri.startswith("s3://"):
            storage_path = uri.split("/", 3)[-1]
        payload = {
            "version_id": str(prod["id"]),
            "version_name": prod.get("name"),
            "uri": uri,
            "storage_key": art.get("storageKey") or "",
            "storage_path": storage_path,
        }
        return json.dumps(payload)

    @dsl.component(base_image=BASE_IMAGE)
    def deploy_canary_op(
        resolved_json: str,
        namespace: str,
        service_name: str,
        canary_percent: int,
    ) -> str:
        import json
        import subprocess

        resolved = json.loads(resolved_json)
        predictor = {"canaryTrafficPercent": int(canary_percent), "model": {}}
        if resolved.get("storage_key") and resolved.get("storage_path"):
            predictor["model"]["storage"] = {
                "key": resolved["storage_key"],
                "path": resolved["storage_path"],
            }
        else:
            predictor["model"]["storageUri"] = resolved["uri"]
        body = {
            "metadata": {"annotations": {"serving.kserve.io/enable-tag-routing": "true"}},
            "spec": {"predictor": predictor},
        }
        subprocess.run(
            [
                "oc",
                "patch",
                "inferenceservice",
                service_name,
                "-n",
                namespace,
                "--type=merge",
                "-p",
                json.dumps(body),
            ],
            check=True,
        )
        return "canary-patched"

    @dsl.component(base_image=BASE_IMAGE)
    def validate_op(endpoint: str, skip_validate: bool = True) -> str:
        import urllib.error
        import urllib.request

        if skip_validate or not endpoint:
            return "skipped"
        req = urllib.request.Request(endpoint, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310
                return f"ok status={resp.status}"
        except urllib.error.HTTPError as exc:
            return f"reachable status={exc.code}"
        except Exception as exc:  # noqa: BLE001
            return f"failed: {exc}"

    @dsl.component(base_image=BASE_IMAGE)
    def finalize_op(
        resolved_json: str,
        namespace: str,
        service_name: str,
        action: str,
    ) -> str:
        import json
        import subprocess

        if action == "leave-canary":
            return "left in canary state"
        resolved = json.loads(resolved_json)
        if action == "rollback":
            predictor = {"canaryTrafficPercent": 0, "model": {}}
            if resolved.get("storage_key") and resolved.get("storage_path"):
                predictor["model"]["storage"] = {
                    "key": resolved["storage_key"],
                    "path": resolved["storage_path"],
                }
            else:
                predictor["model"]["storageUri"] = resolved["uri"]
            body = {"spec": {"predictor": predictor}}
            subprocess.run(
                [
                    "oc",
                    "patch",
                    "inferenceservice",
                    service_name,
                    "-n",
                    namespace,
                    "--type=merge",
                    "-p",
                    json.dumps(body),
                ],
                check=True,
            )
            return "rolled-back"
        if action == "promote":
            # Ensure storage points at prod artifact, then remove canary field.
            predictor = {"model": {}}
            if resolved.get("storage_key") and resolved.get("storage_path"):
                predictor["model"]["storage"] = {
                    "key": resolved["storage_key"],
                    "path": resolved["storage_path"],
                }
            else:
                predictor["model"]["storageUri"] = resolved["uri"]
            subprocess.run(
                [
                    "oc",
                    "patch",
                    "inferenceservice",
                    service_name,
                    "-n",
                    namespace,
                    "--type=merge",
                    "-p",
                    json.dumps({"spec": {"predictor": predictor}}),
                ],
                check=True,
            )
            subprocess.run(
                [
                    "oc",
                    "patch",
                    "inferenceservice",
                    service_name,
                    "-n",
                    namespace,
                    "--type=json",
                    "-p",
                    json.dumps([{"op": "remove", "path": "/spec/predictor/canaryTrafficPercent"}]),
                ],
                check=True,
            )
            return "promoted-100"
        raise RuntimeError(f"unknown action {action}")

    @dsl.pipeline(
        name="xray-promote-deploy-canary",
        description="Resolve OSAI Model Registry stage=prod and canary-deploy to KServe",
    )
    def promote_deploy_canary_pipeline(
        model_registry_url: str,
        model_name: str = "xray-detector",
        namespace: str = "default",
        service_name: str = "xray-detector",
        canary_percent: int = 10,
        action: str = "leave-canary",
        validate_url: str = "",
        skip_validate: bool = True,
        model_registry_token: str = "",
    ):
        resolved = resolve_prod_op(
            model_registry_url=model_registry_url,
            model_name=model_name,
            model_registry_token=model_registry_token,
        )
        deployed = deploy_canary_op(
            resolved_json=resolved.output,
            namespace=namespace,
            service_name=service_name,
            canary_percent=canary_percent,
        )
        validated = validate_op(endpoint=validate_url, skip_validate=skip_validate)
        validated.after(deployed)
        final = finalize_op(
            resolved_json=resolved.output,
            namespace=namespace,
            service_name=service_name,
            action=action,
        )
        final.after(validated)

    compiler.Compiler().compile(promote_deploy_canary_pipeline, output_path)
    print(f"Compiled pipeline -> {output_path}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--action",
        choices=("leave-canary", "promote", "rollback"),
        default=os.environ.get("PIPELINE_ACTION", "leave-canary"),
    )
    parser.add_argument("--model-name", default=os.environ.get("REGISTERED_MODEL_NAME", "xray-detector"))
    parser.add_argument("--namespace", default=default_namespace())
    parser.add_argument("--service-name", default=default_service_name())
    parser.add_argument(
        "--canary-percent",
        type=int,
        default=int(os.environ.get("CANARY_TRAFFIC_PERCENT", "10")),
    )
    parser.add_argument("--validate-url", default=os.environ.get("INFERENCE_ENDPOINT", ""))
    parser.add_argument("--skip-validate", action="store_true", default=True)
    parser.add_argument("--no-skip-validate", action="store_false", dest="skip_validate")
    parser.add_argument("--compile", metavar="YAML", help="Compile KFP pipeline YAML and exit")
    args = parser.parse_args(argv)

    if args.compile:
        compile_pipeline(args.compile)
        return 0

    run_flow(
        model_name=args.model_name,
        namespace=args.namespace,
        service_name=args.service_name,
        canary_percent=args.canary_percent,
        action=args.action,
        validate_url=args.validate_url,
        skip_validate=args.skip_validate,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
