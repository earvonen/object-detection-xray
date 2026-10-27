#!/usr/bin/env bash
# Clear demo MLflow experiments/runs and archive Model Registry entries.
# Hard DELETE is not supported on this Model Registry API; models are ARCHIVED.
# MLflow permanent-delete is unavailable — runs are deleted, experiments renamed
# then soft-deleted so names like xray-detector are free again.
#
# Requires: oc login, curl, python3
# Does NOT touch S3 or KnativeServing.
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/local/bin:${PATH:-}"

NAMESPACE="${KSERVE_NAMESPACE:-object-detection-xray}"
REGISTERED_MODEL_NAME="${REGISTERED_MODEL_NAME:-xray-detector}"
MLFLOW_URL="${MLFLOW_TRACKING_URI:-}"
MR_URL="${MODEL_REGISTRY_URL:-}"

if ! command -v oc >/dev/null 2>&1 || ! oc whoami >/dev/null 2>&1; then
  echo "error: oc must be logged in" >&2
  exit 1
fi

TOKEN="$(oc whoami -t)"

if [[ -z "${MLFLOW_URL}" ]]; then
  MLFLOW_URL="$(oc get mlflow -A -o jsonpath='{.items[0].status.url}' 2>/dev/null || true)"
fi
if [[ -z "${MR_URL}" ]]; then
  MR_URL="$(oc get route -n rhoai-model-registries -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.host}{"\n"}{end}' 2>/dev/null \
    | awk '/https/ {print "https://"$2; exit}')"
  if [[ -z "${MR_URL}" ]]; then
    MR_URL="$(oc get route -n rhoai-model-registries -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null | head -1)"
    [[ -n "${MR_URL}" && "${MR_URL}" != https://* ]] && MR_URL="https://${MR_URL}"
  fi
  # Prefer the REST route name if present
  if oc get route xray-model-registry-https -n rhoai-model-registries >/dev/null 2>&1; then
    MR_URL="https://$(oc get route xray-model-registry-https -n rhoai-model-registries -o jsonpath='{.spec.host}')"
  fi
fi

MLFLOW_URL="${MLFLOW_URL%/}"
MR_URL="${MR_URL%/}"

echo "MLflow: ${MLFLOW_URL:-"(unset)"}"
echo "Model Registry: ${MR_URL:-"(unset)"}"
echo "Workspace / project: ${NAMESPACE}"
echo "Registered model: ${REGISTERED_MODEL_NAME}"

if [[ -z "${MLFLOW_URL}" || -z "${MR_URL}" ]]; then
  echo "error: could not resolve MLFLOW_TRACKING_URI / MODEL_REGISTRY_URL" >&2
  exit 1
fi

export MLFLOW_URL MR_URL NAMESPACE TOKEN REGISTERED_MODEL_NAME

python3 <<'PY'
import json, os, ssl, urllib.error, urllib.request

TOKEN = os.environ["TOKEN"]
MLFLOW = os.environ["MLFLOW_URL"].rstrip("/")
MR = os.environ["MR_URL"].rstrip("/")
WS = os.environ["NAMESPACE"]
MODEL = os.environ["REGISTERED_MODEL_NAME"]
ctx = ssl._create_unverified_context()


def req(url: str, method: str = "GET", body=None, headers=None):
    data = None if body is None else json.dumps(body).encode()
    h = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json", "Accept": "application/json"}
    if headers:
        h.update(headers)
    request = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(request, context=ctx, timeout=60) as resp:
            raw = resp.read().decode() or "{}"
            return resp.status, json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as e:
        raw = e.read().decode() if e.fp else ""
        try:
            parsed = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            parsed = {"raw": raw[:300]}
        return e.code, parsed


def mlflow(method, path, body=None):
    return req(
        MLFLOW + path,
        method=method,
        body=body,
        headers={"X-MLFLOW-WORKSPACE": WS},
    )


print("=== MLflow ===")
# Include deleted so we can still purge/rename leftovers
for view in ("ACTIVE_ONLY", "DELETED_ONLY"):
    code, data = mlflow("POST", "/api/2.0/mlflow/experiments/search", {"max_results": 100, "view_type": view})
    if code >= 400:
        print(f"search {view} failed: {code} {data}")
        continue
    exps = data.get("experiments") or []
    print(f"{view}: {[(e.get('experiment_id'), e.get('name'), e.get('lifecycle_stage')) for e in exps]}")
    for e in exps:
        eid = e["experiment_id"]
        name = e["name"]
        if e.get("lifecycle_stage") == "deleted":
            code, _ = mlflow("POST", "/api/2.0/mlflow/experiments/restore", {"experiment_id": eid})
            print(f"  restore {eid} ({name}): {code}")
        code, runs_data = mlflow(
            "POST",
            "/api/2.0/mlflow/runs/search",
            {"experiment_ids": [eid], "max_results": 100},
        )
        runs = (runs_data or {}).get("runs") or []
        for r in runs:
            rid = r["info"]["run_id"]
            c, _ = mlflow("POST", "/api/2.0/mlflow/runs/delete", {"run_id": rid})
            print(f"  delete run {rid[:8]}: {c}")
        new_name = name if name.endswith("-archived-reset") else f"{name}-archived-reset"
        if new_name != name:
            c, _ = mlflow("POST", "/api/2.0/mlflow/experiments/update", {"experiment_id": eid, "new_name": new_name})
            print(f"  rename {name} -> {new_name}: {c}")
        c, _ = mlflow("POST", "/api/2.0/mlflow/experiments/delete", {"experiment_id": eid})
        print(f"  soft-delete {eid}: {c}")

print("=== Model Registry ===")
code, data = req(f"{MR}/api/model_registry/v1alpha3/registered_models")
if code >= 400:
    print(f"list models failed: {code} {data}")
else:
    items = data.get("items") or data if isinstance(data, list) else []
    for m in items:
        mid, name, state = m.get("id"), m.get("name"), m.get("state")
        if name != MODEL:
            continue
        print(f"model id={mid} name={name} state={state}")
        code, vers = req(f"{MR}/api/model_registry/v1alpha3/registered_models/{mid}/versions")
        versions = (vers or {}).get("items") or []
        for v in versions:
            vid = v.get("id")
            c, out = req(
                f"{MR}/api/model_registry/v1alpha3/model_versions/{vid}",
                method="PATCH",
                body={"state": "ARCHIVED"},
            )
            print(f"  archive version {vid}: {c}")
        c, out = req(
            f"{MR}/api/model_registry/v1alpha3/registered_models/{mid}",
            method="PATCH",
            body={"state": "ARCHIVED"},
        )
        print(f"  archive model {mid}: {c} state={out.get('state')}")
        # Hard delete often 405 — try anyway
        c, _ = req(f"{MR}/api/model_registry/v1alpha3/registered_models/{mid}", method="DELETE")
        print(f"  delete model {mid}: {c} (405 means API does not support hard delete)")

print("Done (MLflow + Model Registry).")
PY
