#!/usr/bin/env bash
# Full demo reset: MLflow + Model Registry data, then namespace + MR RoleBinding.
# Does NOT delete KnativeServing or S3 objects (user handles S3).
#
# Usage:
#   ./openshift/reset-demo.sh           # interactive confirm
#   ./openshift/reset-demo.sh --yes     # no prompt (agents / CI)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${KSERVE_NAMESPACE:-object-detection-xray}"
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

echo "This will:"
echo "  1. Delete MLflow runs; rename+soft-delete experiments (workspace ${NAMESPACE})"
echo "  2. Reset Model Registry model '${REGISTERED_MODEL_NAME:-xray-detector}' (keep LIVE; clear stage=prod — API has no hard delete)"
echo "  3. Delete RoleBinding xray-workbench-model-registry in rhoai-model-registries"
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

bash "${SCRIPT_DIR}/reset-mlflow-registry.sh"

# Teardown without a second prompt
export KSERVE_NAMESPACE="${NAMESPACE}"
MR_NAMESPACE="${MODEL_REGISTRY_NAMESPACE:-rhoai-model-registries}"
MR_ROLEBINDING="${MR_ROLEBINDING:-xray-workbench-model-registry}"

if oc get rolebinding "${MR_ROLEBINDING}" -n "${MR_NAMESPACE}" >/dev/null 2>&1; then
  echo "Deleting RoleBinding/${MR_ROLEBINDING} in ${MR_NAMESPACE}"
  oc delete rolebinding "${MR_ROLEBINDING}" -n "${MR_NAMESPACE}"
else
  echo "RoleBinding/${MR_ROLEBINDING} not found (skip)"
fi

if oc get ns "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Deleting Namespace/${NAMESPACE}"
  oc delete ns "${NAMESPACE}"
else
  echo "Namespace/${NAMESPACE} not found (skip)"
fi

# Local demo handoff file if present
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
rm -f "${ROOT}/.demo_state.json"

echo "Reset complete. Re-bootstrap with: set -a && source .env && set +a && ./deploy.sh --build-workbench --skip-isvc"
