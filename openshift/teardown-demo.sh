#!/usr/bin/env bash
# Remove the demo project and workbench→Model Registry RoleBinding.
# Does NOT delete MLflow experiments, Model Registry models, S3 objects, or KnativeServing.
set -euo pipefail

NAMESPACE="${KSERVE_NAMESPACE:-object-detection-xray}"
MR_NAMESPACE="${MODEL_REGISTRY_NAMESPACE:-rhoai-model-registries}"
MR_ROLEBINDING="${MR_ROLEBINDING:-xray-workbench-model-registry}"

if ! command -v oc >/dev/null 2>&1; then
  echo "error: oc not found" >&2
  exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
  echo "error: not logged in to OpenShift (oc whoami failed)" >&2
  exit 1
fi

echo "Will delete:"
echo "  Namespace/${NAMESPACE}"
echo "  RoleBinding/${MR_ROLEBINDING} (ns ${MR_NAMESPACE})"
echo
read -r -p "Continue? [y/N] " reply
case "${reply}" in
  y|Y|yes|YES) ;;
  *) echo "Aborted."; exit 1 ;;
esac

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

echo "Done. MLflow runs, Model Registry entries, and S3 objects were left intact."
