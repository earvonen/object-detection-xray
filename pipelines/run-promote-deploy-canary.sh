#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Required / commonly used — fill in before running
export MODEL_REGISTRY_URL="${MODEL_REGISTRY_URL:-https://xray-model-registry-rest.apps.example.com}"
export MODEL_REGISTRY_TOKEN="${MODEL_REGISTRY_TOKEN:-}"          # optional; workbench SA token used if empty
export MODEL_REGISTRY_VERIFY_SSL="${MODEL_REGISTRY_VERIFY_SSL:-false}"
export KSERVE_NAMESPACE="${KSERVE_NAMESPACE:-object-detection-xray}"
export INFERENCE_SERVICE_NAME="${INFERENCE_SERVICE_NAME:-xray-detector}"
export REGISTERED_MODEL_NAME="${REGISTERED_MODEL_NAME:-xray-detector}"
export CANARY_TRAFFIC_PERCENT="${CANARY_TRAFFIC_PERCENT:-10}"
export STORAGE_KEY="${STORAGE_KEY:-aws-connection-xray-models}"
# export INFERENCE_ENDPOINT="${INFERENCE_ENDPOINT:-}"           # optional validate URL
# export PIPELINE_ACTION="${PIPELINE_ACTION:-leave-canary}"

exec python3 pipelines/promote_deploy_canary.py "$@"
