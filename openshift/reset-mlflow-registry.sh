#!/usr/bin/env bash
# Clear demo MLflow experiments/runs and reset Model Registry prod stage.
# Model Registry hard DELETE is not supported (405; Allow: GET, PATCH only).
# Do NOT archive the registered model — ARCHIVED hides it in the UI while
# notebook 03 still attaches new versions under that same model id.
# Instead: keep/restore LIVE, clear stage=prod on versions.
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


def search_experiments(view_type: str):
    """Paginate experiment search (view may exceed a single page)."""
    out = []
    page_token = None
    while True:
        body = {"max_results": 100, "view_type": view_type}
        if page_token:
            body["page_token"] = page_token
        code, data = mlflow("POST", "/api/2.0/mlflow/experiments/search", body)
        if code >= 400:
            print(f"search {view_type} failed: {code} {data}")
            return out
        out.extend(data.get("experiments") or [])
        page_token = (data or {}).get("next_page_token")
        if not page_token:
            return out


def delete_all_runs(eid: str) -> int:
    """Soft-delete every run in the experiment (active + already-listed deleted).

    Paginate with view_type=ALL — a bare search can miss pages and leave demo
    runs visible after teardown.
    """
    deleted = 0
    page_token = None
    while True:
        body = {"experiment_ids": [eid], "max_results": 100, "view_type": "ALL"}
        if page_token:
            body["page_token"] = page_token
        code, runs_data = mlflow("POST", "/api/2.0/mlflow/runs/search", body)
        if code >= 400:
            print(f"  runs/search failed for {eid}: {code} {runs_data}")
            return deleted
        runs = (runs_data or {}).get("runs") or []
        for r in runs:
            info = r.get("info") or {}
            rid = info.get("run_id")
            if not rid:
                continue
            if info.get("lifecycle_stage") == "deleted":
                continue
            c, _ = mlflow("POST", "/api/2.0/mlflow/runs/delete", {"run_id": rid})
            print(f"  delete run {rid[:8]}: {c}")
            deleted += 1
        page_token = (runs_data or {}).get("next_page_token")
        if not page_token:
            return deleted


# Include deleted so we can still purge/rename leftovers
for view in ("ACTIVE_ONLY", "DELETED_ONLY"):
    exps = search_experiments(view)
    print(f"{view}: {[(e.get('experiment_id'), e.get('name'), e.get('lifecycle_stage')) for e in exps]}")
    for e in exps:
        eid = e["experiment_id"]
        name = e["name"]
        if e.get("lifecycle_stage") == "deleted":
            code, _ = mlflow("POST", "/api/2.0/mlflow/experiments/restore", {"experiment_id": eid})
            print(f"  restore {eid} ({name}): {code}")
        n = delete_all_runs(eid)
        print(f"  deleted {n} active run(s) in experiment {eid}")
        # Unique suffix so rename does not collide with a prior *-archived-reset.
        if "-archived-reset" in name:
            new_name = name
        else:
            new_name = f"{name}-archived-reset-{eid}"
        if new_name != name:
            c, _ = mlflow("POST", "/api/2.0/mlflow/experiments/update", {"experiment_id": eid, "new_name": new_name})
            print(f"  rename {name} -> {new_name}: {c}")
        c, _ = mlflow("POST", "/api/2.0/mlflow/experiments/delete", {"experiment_id": eid})
        print(f"  soft-delete {eid}: {c}")

print("=== Model Registry ===")
print("(API has no hard DELETE — keep model LIVE so notebook versions stay visible)")
code, data = req(f"{MR}/api/model_registry/v1alpha3/registered_models")
if code >= 400:
    print(f"list models failed: {code} {data}")
else:
    items = data.get("items") or data if isinstance(data, list) else []
    found = False
    for m in items:
        mid, name, state = m.get("id"), m.get("name"), m.get("state")
        if name != MODEL:
            continue
        found = True
        print(f"model id={mid} name={name} state={state}")
        if state != "LIVE":
            c, out = req(
                f"{MR}/api/model_registry/v1alpha3/registered_models/{mid}",
                method="PATCH",
                body={"state": "LIVE"},
            )
            print(f"  restore model LIVE: {c} state={out.get('state')}")
        code, vers = req(f"{MR}/api/model_registry/v1alpha3/registered_models/{mid}/versions")
        versions = (vers or {}).get("items") or []
        for v in versions:
            vid = v.get("id")
            vstate = v.get("state")
            props = dict(v.get("customProperties") or {})
            stage = (props.get("stage") or {}).get("string_value")
            patch = {}
            if vstate != "LIVE":
                patch["state"] = "LIVE"
            if stage == "prod":
                props["stage"] = {"metadataType": "MetadataStringValue", "string_value": "reset"}
                patch["customProperties"] = props
            if not patch:
                print(f"  version {vid}: already LIVE, stage={stage!r} (no change)")
                continue
            c, out = req(
                f"{MR}/api/model_registry/v1alpha3/model_versions/{vid}",
                method="PATCH",
                body=patch,
            )
            new_stage = ((out.get("customProperties") or {}).get("stage") or {}).get("string_value")
            print(f"  version {vid}: {c} state={out.get('state')} stage={new_stage!r}")
    if not found:
        print(f"no registered model named {MODEL!r} (nothing to reset)")

print("Done (MLflow + Model Registry).")
PY
