#!/usr/bin/env bash
# Remove demo MLflow runs/experiments (and reset Model Registry stage), then
# delete the demo project and workbench→Model Registry RoleBinding.
# Does NOT delete S3 objects or KnativeServing.
#
# Usage:
#   ./openshift/teardown-demo.sh           # interactive confirm
#   ./openshift/teardown-demo.sh --yes     # no prompt (agents / CI)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${KSERVE_NAMESPACE:-object-detection-xray}"
MR_NAMESPACE="${MODEL_REGISTRY_NAMESPACE:-rhoai-model-registries}"
MR_ROLEBINDING="${MR_ROLEBINDING:-xray-workbench-model-registry}"
YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=1 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
  esac
done

if ! command -v oc >/dev/null 2>&1; then
  echo "error: oc not found" >&2
  exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
  echo "error: not logged in to OpenShift (oc whoami failed)" >&2
  exit 1
fi

echo "Will:"
echo "  1. Delete MLflow runs; rename+soft-delete experiments (workspace ${NAMESPACE})"
echo "  2. Reset Model Registry model '${REGISTERED_MODEL_NAME:-xray-detector}' (keep LIVE; clear stage=prod)"
echo "  3. Delete RoleBinding/${MR_ROLEBINDING} (ns ${MR_NAMESPACE})"
echo "  4. Delete Namespace/${NAMESPACE}"
echo "S3 and KnativeServing are left alone."
echo

if [[ "$YES" -ne 1 ]]; then
  read -r -p "Continue? [y/N] " reply
  case "${reply}" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# Always wipe MLflow runs before removing the project — otherwise the next
# deploy reuses workspace ${NAMESPACE} and old runs reappear in the UI.
bash "${SCRIPT_DIR}/reset-mlflow-registry.sh"

if oc get rolebinding "${MR_ROLEBINDING}" -n "${MR_NAMESPACE}" >/dev/null 2>&1; then
  echo "Deleting RoleBinding/${MR_ROLEBINDING} in ${MR_NAMESPACE}"
  oc delete rolebinding "${MR_ROLEBINDING}" -n "${MR_NAMESPACE}"
else
  echo "RoleBinding/${MR_ROLEBINDING} not found in ${MR_NAMESPACE} (skip)"
fi

if oc get ns "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Deleting Namespace/${NAMESPACE} (may take a minute for PVCs/ISVC finalizers)"
  oc delete ns "${NAMESPACE}"
else
  echo "Namespace/${NAMESPACE} not found (skip)"
fi

ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
rm -f "${ROOT}/.demo_state.json"

echo "Done. S3 objects and KnativeServing were left intact."
