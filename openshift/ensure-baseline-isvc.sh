#!/usr/bin/env bash
# Ensure a *baseline* InferenceService exists so canary can roll a *new* revision.
#
# Canary only creates a second Knative revision when storage.path changes.
# Pointing the ISVC at the same run you are about to promote makes canary a no-op.
#
# This script:
#   1. Ensures …/object-detection/xray-detector/baseline/1/model.onnx exists
#      (seeds by copying from SOURCE_PATH / SELECTED_RUN_ID / newest run if missing)
#   2. Creates the ISVC on the baseline path if it does not exist
#   3. Leaves an existing ISVC alone (prior revision stays "prev" for canary)
#
# Usage (after notebook 03 has uploaded ONNX at least once):
#   ./openshift/ensure-baseline-isvc.sh
#   SOURCE_PATH=object-detection/xray-detector/<run_id> ./openshift/ensure-baseline-isvc.sh
#   ./openshift/ensure-baseline-isvc.sh --force   # re-point ISVC at baseline
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# Keep system tools (oc) reachable from Jupyter terminals, but do not put
# /usr/bin ahead of the workbench venv — that made `python3` resolve to a
# system interpreter without boto3 (install-dependencies installs into
# /opt/app-root). Prefer PYTHON from the caller (notebook sets sys.executable).
export PATH="${PATH:-}:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
if [[ -n "${PYTHON:-}" && -x "${PYTHON}" ]]; then
  :
elif [[ -x /opt/app-root/bin/python3 ]]; then
  PYTHON=/opt/app-root/bin/python3
else
  PYTHON="$(command -v python3)"
fi
if [[ -z "${PYTHON}" ]]; then
  echo "error: python3 not found" >&2
  exit 1
fi

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
  esac
done

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

NAMESPACE="${NAMESPACE:-object-detection-xray}"
STORAGE_KEY="${STORAGE_KEY:-aws-connection-xray-models}"
S3_KEY_PREFIX="${S3_KEY_PREFIX:-object-detection/xray-detector}"
BASELINE_PATH="${BASELINE_PATH:-${S3_KEY_PREFIX}/baseline}"
ISVC_NAME="${INFERENCE_SERVICE_NAME:-xray-detector}"

if ! command -v oc >/dev/null 2>&1; then
  echo "error: oc not found" >&2
  exit 1
fi
if ! oc whoami >/dev/null 2>&1; then
  echo "error: oc must be logged in" >&2
  exit 1
fi

SOURCE_PATH="${SOURCE_PATH:-}"
if [[ -z "${SOURCE_PATH}" && -n "${SELECTED_RUN_ID:-}" ]]; then
  SOURCE_PATH="${S3_KEY_PREFIX}/${SELECTED_RUN_ID}"
fi
if [[ -z "${SOURCE_PATH}" && -f "${REPO_ROOT}/.demo_state.json" ]]; then
  RID="$(python3 -c 'import json; print(json.load(open(".demo_state.json")).get("SELECTED_RUN_ID",""))')"
  if [[ -n "${RID}" ]]; then
    SOURCE_PATH="${S3_KEY_PREFIX}/${RID}"
  fi
fi

export SOURCE_PATH BASELINE_PATH
echo "Baseline path: ${BASELINE_PATH}"
echo "Source path:   ${SOURCE_PATH:-"(auto if baseline missing)"}"
echo "Python:        ${PYTHON}"

"${PYTHON}" - <<'PY'
import os, sys
sys.path.insert(0, ".")
from src.s3_utils import ensure_baseline_model

uri = ensure_baseline_model(
    baseline_path=os.environ["BASELINE_PATH"],
    source_path=os.environ.get("SOURCE_PATH") or None,
)
print("baseline model:", uri)
PY

if oc get inferenceservice "${ISVC_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  CURRENT_PATH="$(oc get inferenceservice "${ISVC_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.predictor.model.storage.path}' 2>/dev/null || true)"
  if [[ "${FORCE}" -eq 0 ]]; then
    echo "InferenceService/${ISVC_NAME} already exists (storage.path=${CURRENT_PATH:-unknown})."
    echo "Leaving it so canary can introduce a different path as the latest revision."
    echo "Use --force to re-point at ${BASELINE_PATH}."
    oc get inferenceservice "${ISVC_NAME}" -n "${NAMESPACE}"
    exit 0
  fi
fi

echo "Applying InferenceService on baseline path ${BASELINE_PATH}"
STORAGE_PATH="${BASELINE_PATH}" STORAGE_KEY="${STORAGE_KEY}" NAMESPACE="${NAMESPACE}" \
  "${SCRIPT_DIR}/apply-inferenceservice.sh"
