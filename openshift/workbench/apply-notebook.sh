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

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck disable=SC1091
  set -a && source "${REPO_ROOT}/.env" && set +a
  NAMESPACE="${NAMESPACE:-object-detection-xray}"
  CONNECTION_NAME="${STORAGE_KEY:-${CONNECTION_NAME:-aws-connection-xray-models}}"
  WORKBENCH_IMAGE="${WORKBENCH_IMAGE:-image-registry.openshift-image-registry.svc:5000/${NAMESPACE}/xray-workbench:latest}"
fi

if ! command -v oc >/dev/null 2>&1; then
  echo "error: oc not found" >&2
  exit 1
fi

render() {
  local src="$1" dst="$2"
  sed \
    -e "s|__NAMESPACE__|${NAMESPACE}|g" \
    -e "s|__PVC_SIZE__|${PVC_SIZE}|g" \
    -e "s|__WORKBENCH_IMAGE__|${WORKBENCH_IMAGE}|g" \
    -e "s|__CONNECTION_NAME__|${CONNECTION_NAME}|g" \
    "${src}" >"${dst}"
}

TMPDIR_RENDER="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_RENDER}"' EXIT

render "${SCRIPT_DIR}/notebook-pvc.yaml" "${TMPDIR_RENDER}/pvc.yaml"
render "${SCRIPT_DIR}/notebook.yaml" "${TMPDIR_RENDER}/notebook.yaml"

# ConfigMap before Notebook so envFrom resolves on first start.
echo "Discovering cluster demo env → ConfigMap/xray-demo-env"
KSERVE_NAMESPACE="${NAMESPACE}" STORAGE_KEY="${CONNECTION_NAME}" \
  "${REPO_ROOT}/openshift/discover-demo-env.sh"

echo "Applying workbench PVC + Notebook in ${NAMESPACE}"
echo "  image=${WORKBENCH_IMAGE}"
echo "  connection=${CONNECTION_NAME}"
oc apply -f "${TMPDIR_RENDER}/pvc.yaml"
oc apply -f "${TMPDIR_RENDER}/notebook.yaml"
oc get pvc object-detection-workbench-storage -n "${NAMESPACE}"
oc get notebook object-detection-workbench -n "${NAMESPACE}"
