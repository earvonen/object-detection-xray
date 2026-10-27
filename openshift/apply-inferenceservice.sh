#!/usr/bin/env bash
# Render and oc-apply openshift/inferenceservice-xray-detector.yaml
#
# Fill these (or export beforehand). STORAGE_PATH is the Connection-relative
# prefix from notebook 03, e.g. object-detection/xray-detector/<mlflow_run_id>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/inferenceservice-xray-detector.yaml"

export NAMESPACE="${NAMESPACE:-object-detection-xray}"
export STORAGE_KEY="${STORAGE_KEY:-aws-connection-xray-models}"
export STORAGE_PATH="${STORAGE_PATH:-object-detection/xray-detector/REPLACE_ME_RUN_ID}"

if [[ "${STORAGE_PATH}" == *REPLACE_ME* ]]; then
  echo "error: set STORAGE_PATH to the ONNX prefix from notebook 03" >&2
  echo "  e.g. STORAGE_PATH=object-detection/xray-detector/<run_id> $0" >&2
  exit 1
fi

if ! command -v oc >/dev/null 2>&1; then
  echo "error: oc not found" >&2
  exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT

sed \
  -e "s|__NAMESPACE__|${NAMESPACE}|g" \
  -e "s|__STORAGE_KEY__|${STORAGE_KEY}|g" \
  -e "s|__STORAGE_PATH__|${STORAGE_PATH}|g" \
  "${MANIFEST}" >"${TMP}"

# ServingRuntime (OVMS) must exist in the project for ONNX.
if [[ -f "${SCRIPT_DIR}/servingruntime-ovms.yaml" ]]; then
  echo "Applying ServingRuntime kserve-ovms"
  sed "s|namespace: object-detection-xray|namespace: ${NAMESPACE}|g" \
    "${SCRIPT_DIR}/servingruntime-ovms.yaml" | oc apply -f -
fi

if ! oc get knativeserving knative-serving -n knative-serving >/dev/null 2>&1; then
  echo "warning: KnativeServing not found — Serverless ISVCs will fail." >&2
  echo "  Apply openshift/knative-serving.yaml (cluster-admin) first." >&2
fi

echo "Applying InferenceService xray-detector in ${NAMESPACE}"
echo "  storage.key=${STORAGE_KEY}"
echo "  storage.path=${STORAGE_PATH}"
oc apply -f "${TMP}"
oc get inferenceservice xray-detector -n "${NAMESPACE}"
