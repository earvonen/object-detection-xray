#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Resolve Model Registry URL: env wins; otherwise discover the cluster route.
# Do not keep apps.example.com as a silent default — it only fails DNS in the workbench.
if [[ -z "${MODEL_REGISTRY_URL:-}" || "${MODEL_REGISTRY_URL}" == *apps.example.com* ]]; then
  if oc get route xray-model-registry-https -n rhoai-model-registries >/dev/null 2>&1; then
    MODEL_REGISTRY_URL="https://$(oc get route xray-model-registry-https -n rhoai-model-registries -o jsonpath='{.spec.host}')"
  else
    echo "error: set MODEL_REGISTRY_URL (could not find route xray-model-registry-https)" >&2
    exit 1
  fi
fi
export MODEL_REGISTRY_URL
export MODEL_REGISTRY_TOKEN="${MODEL_REGISTRY_TOKEN:-}"          # optional; workbench SA token used if empty
export MODEL_REGISTRY_VERIFY_SSL="${MODEL_REGISTRY_VERIFY_SSL:-false}"
export KSERVE_NAMESPACE="${KSERVE_NAMESPACE:-object-detection-xray}"
export INFERENCE_SERVICE_NAME="${INFERENCE_SERVICE_NAME:-xray-detector}"
export REGISTERED_MODEL_NAME="${REGISTERED_MODEL_NAME:-xray-detector}"
export CANARY_TRAFFIC_PERCENT="${CANARY_TRAFFIC_PERCENT:-10}"
export STORAGE_KEY="${STORAGE_KEY:-aws-connection-xray-models}"
# export INFERENCE_ENDPOINT="${INFERENCE_ENDPOINT:-}"           # optional validate URL
# export PIPELINE_ACTION="${PIPELINE_ACTION:-leave-canary}"

echo "MODEL_REGISTRY_URL=${MODEL_REGISTRY_URL}"
python3 pipelines/promote_deploy_canary.py "$@"
status=$?
# Refresh INFERENCE_ENDPOINT / latest-/prev- tag URLs into the workbench ConfigMap.
if [[ "$status" -eq 0 && -x ./openshift/discover-demo-env.sh ]]; then
  ./openshift/discover-demo-env.sh --restart || true
fi
exit "$status"
