#!/usr/bin/env bash
# Render and apply the demo workbench PVC + Notebook.
# Discovers MODEL_REGISTRY_URL / INFERENCE_* (etc.) into ConfigMap xray-demo-env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

NAMESPACE="${NAMESPACE:-object-detection-xray}"
CONNECTION_NAME="${STORAGE_KEY:-${CONNECTION_NAME:-aws-connection-xray-models}}"
PVC_SIZE="${WORKBENCH_PVC_SIZE:-20Gi}"
WORKBENCH_IMAGE="${WORKBENCH_IMAGE:-image-registry.openshift-image-registry.svc:5000/${NAMESPACE}/xray-workbench:latest}"
HARDWARE_PROFILE_NAMESPACE="${HARDWARE_PROFILE_NAMESPACE:-redhat-ods-applications}"
HARDWARE_PROFILE_NAME="${HARDWARE_PROFILE_NAME:-}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck disable=SC1091
  set -a && source "${REPO_ROOT}/.env" && set +a
  NAMESPACE="${NAMESPACE:-object-detection-xray}"
  CONNECTION_NAME="${STORAGE_KEY:-${CONNECTION_NAME:-aws-connection-xray-models}}"
  WORKBENCH_IMAGE="${WORKBENCH_IMAGE:-image-registry.openshift-image-registry.svc:5000/${NAMESPACE}/xray-workbench:latest}"
  HARDWARE_PROFILE_NAMESPACE="${HARDWARE_PROFILE_NAMESPACE:-redhat-ods-applications}"
  HARDWARE_PROFILE_NAME="${HARDWARE_PROFILE_NAME:-}"
fi

if ! command -v oc >/dev/null 2>&1; then
  echo "error: oc not found" >&2
  exit 1
fi

# Prefer an existing HardwareProfile whose nodeSelector has free nvidia.com/gpu.
# Override with HARDWARE_PROFILE_NAME when set.
resolve_hardware_profile() {
  local ns="$1" name
  if [[ -n "${HARDWARE_PROFILE_NAME}" ]]; then
    if oc get hardwareprofile "${HARDWARE_PROFILE_NAME}" -n "${ns}" >/dev/null 2>&1; then
      echo "${HARDWARE_PROFILE_NAME}"
      return 0
    fi
    echo "error: HARDWARE_PROFILE_NAME=${HARDWARE_PROFILE_NAME} not found in ${ns}" >&2
    return 1
  fi
  name="$(
    oc get hardwareprofile -n "${ns}" -o json 2>/dev/null >"${TMPDIR_RENDER:-/tmp}/hp.json" || true
    oc get nodes -o json 2>/dev/null >"${TMPDIR_RENDER:-/tmp}/nodes.json" || true
    oc get pods -A -o json 2>/dev/null >"${TMPDIR_RENDER:-/tmp}/pods.json" || true
    PREFER='gpu-profile nvidia-l4-medium nvidia-l4-small nvidia-a100-small nvidia-a100-medium nvidia-gpu' \
    HP_JSON="${TMPDIR_RENDER:-/tmp}/hp.json" NODES_JSON="${TMPDIR_RENDER:-/tmp}/nodes.json" PODS_JSON="${TMPDIR_RENDER:-/tmp}/pods.json" \
    python3 - <<'PY'
import json, os
prefer = os.environ.get("PREFER", "").split()
try:
    profiles = {d["metadata"]["name"]: d for d in json.load(open(os.environ["HP_JSON"])).get("items") or []}
    nodes = json.load(open(os.environ["NODES_JSON"])).get("items") or []
    pods = json.load(open(os.environ["PODS_JSON"])).get("items") or []
except Exception:
    profiles, nodes, pods = {}, [], []

used = {}
for p in pods:
    node = (p.get("spec") or {}).get("nodeName") or ""
    if not node:
        continue
    for c in (p.get("spec") or {}).get("containers") or []:
        g = ((c.get("resources") or {}).get("requests") or {}).get("nvidia.com/gpu")
        if g:
            used[node] = used.get(node, 0) + int(float(g))

def free_for(selector):
    selector = selector or {}
    total = 0
    for n in nodes:
        labels = (n.get("metadata") or {}).get("labels") or {}
        if any(labels.get(k) != v for k, v in selector.items()):
            continue
        alloc = int(float(((n.get("status") or {}).get("allocatable") or {}).get("nvidia.com/gpu") or 0))
        total += max(0, alloc - used.get(n["metadata"]["name"], 0))
    return total

def is_gpu(doc):
    if ((doc.get("metadata") or {}).get("annotations") or {}).get("opendatahub.io/disabled") == "true":
        return False
    return any(i.get("identifier") == "nvidia.com/gpu" for i in ((doc.get("spec") or {}).get("identifiers") or []))

ordered = [n for n in prefer if n in profiles] + [n for n in profiles if n not in prefer]
best = None
best_free = -1
for name in ordered:
    doc = profiles[name]
    if not is_gpu(doc):
        continue
    sched = ((doc.get("spec") or {}).get("scheduling") or {}).get("node") or {}
    free = free_for(sched.get("nodeSelector") or {})
    # Profiles with no selector can land on any GPU node.
    if free > best_free:
        best, best_free = name, free
    if free > 0 and name in prefer:
        print(name)
        raise SystemExit
if best and best_free > 0:
    print(best)
elif best:
    print(best)
PY
  )"
  if [[ -n "${name}" ]]; then
    echo "${name}"
    return 0
  fi
  echo "error: no GPU HardwareProfile found in ${ns}; set HARDWARE_PROFILE_NAME" >&2
  return 1
}

render() {
  local src="$1" dst="$2"
  sed \
    -e "s|__NAMESPACE__|${NAMESPACE}|g" \
    -e "s|__PVC_SIZE__|${PVC_SIZE}|g" \
    -e "s|__WORKBENCH_IMAGE__|${WORKBENCH_IMAGE}|g" \
    -e "s|__CONNECTION_NAME__|${CONNECTION_NAME}|g" \
    -e "s|__HARDWARE_PROFILE_NAME__|${HARDWARE_PROFILE_NAME}|g" \
    -e "s|__HARDWARE_PROFILE_NAMESPACE__|${HARDWARE_PROFILE_NAMESPACE}|g" \
    "${src}" >"${dst}"
}

TMPDIR_RENDER="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_RENDER}"' EXIT

HARDWARE_PROFILE_NAME="$(resolve_hardware_profile "${HARDWARE_PROFILE_NAMESPACE}")"

render "${SCRIPT_DIR}/notebook-pvc.yaml" "${TMPDIR_RENDER}/pvc.yaml"
render "${SCRIPT_DIR}/notebook.yaml" "${TMPDIR_RENDER}/notebook.yaml"

# ConfigMap before Notebook so envFrom resolves on first start.
echo "Discovering cluster demo env → ConfigMap/xray-demo-env"
KSERVE_NAMESPACE="${NAMESPACE}" STORAGE_KEY="${CONNECTION_NAME}" \
  "${REPO_ROOT}/openshift/discover-demo-env.sh"

echo "Applying workbench PVC + Notebook in ${NAMESPACE}"
echo "  image=${WORKBENCH_IMAGE}"
echo "  connection=${CONNECTION_NAME}"
echo "  hardwareProfile=${HARDWARE_PROFILE_NAMESPACE}/${HARDWARE_PROFILE_NAME}"
oc apply -f "${TMPDIR_RENDER}/pvc.yaml"
oc apply -f "${TMPDIR_RENDER}/notebook.yaml"
# Clear stop annotation left by dashboard Stop so the new image/env come up.
oc annotate notebook object-detection-workbench -n "${NAMESPACE}" \
  kubeflow-resource-stopped- --overwrite 2>/dev/null || true
oc get pvc object-detection-workbench-storage -n "${NAMESPACE}"
oc get notebook object-detection-workbench -n "${NAMESPACE}"
