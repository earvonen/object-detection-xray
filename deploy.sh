#!/usr/bin/env bash
# Bootstrap the object-detection-xray demo onto an OpenShift cluster.
#
# Assumes platform components already exist (MLflow, Model Registry, Data Science
# Pipelines, KServe single-model / Serverless). This script only creates the
# demo project namespace and serving / RBAC plumbing.
#
# Prerequisites:
#   - oc logged in with permission to create the target namespace
#   - Optional: AWS_* env vars to create an S3 data-connection Secret
#   - Optional: STORAGE_URI or STORAGE_KEY+STORAGE_PATH to create the InferenceService
#
# S3 policy: do NOT deploy MinIO or another object store from this script or ad-hoc
# cluster work. If AWS_* are unset, skip the Connection and ask the user how they
# want object storage handled.
#
# Usage:
#   oc login ...
#   export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_S3_ENDPOINT=...
#   export AWS_DEFAULT_REGION=us-east-1 AWS_S3_BUCKET=models
#   # After a model is in S3 (or use a warm-start URI):
#   export STORAGE_URI=s3://models/object-detection/xray-detector/<run_id>
#   ./deploy.sh
#
# Flags:
#   --skip-isvc       Do not create/update the InferenceService
#   --skip-pipeline   Do not compile the KFP pipeline YAML
#   --skip-notebook   Do not apply workbench Notebook/PVC manifests
#   --build-workbench Apply workbench ImageStream/BuildConfig and start a build
#                     (layers install-dependencies.sh on Minimal CUDA Python 3.12)
#   --dry-run         Print actions without applying
#
# Optional: source .env (gitignored) for AWS_* / CONNECTION defaults.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  set -a && source "${SCRIPT_DIR}/.env" && set +a
fi

NAMESPACE="${KSERVE_NAMESPACE:-object-detection-xray}"
ISVC_NAME="${INFERENCE_SERVICE_NAME:-xray-detector}"
PIPELINE_SA="${PIPELINE_SA:-xray-pipeline}"
CONNECTION_NAME="${STORAGE_KEY:-aws-connection-xray-models}"
S3_KEY_PREFIX="${S3_KEY_PREFIX:-object-detection/xray-detector}"
WORKBENCH_IMAGE="${WORKBENCH_IMAGE:-image-registry.openshift-image-registry.svc:5000/${NAMESPACE}/xray-workbench:latest}"
OUT_DIR="${SCRIPT_DIR}/.deploy"
SKIP_ISVC=0
SKIP_PIPELINE=0
SKIP_NOTEBOOK=0
BUILD_WORKBENCH=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-isvc) SKIP_ISVC=1 ;;
    --skip-pipeline) SKIP_PIPELINE=1 ;;
    --skip-notebook) SKIP_NOTEBOOK=1 ;;
    --build-workbench) BUILD_WORKBENCH=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
      exit 0
      ;;
    *)
      echo "Unknown flag: $1" >&2
      exit 1
      ;;
  esac
  shift
done

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

apply_yaml() {
  local file="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: would apply ${file}"
    cat "$file"
    echo "---"
  else
    oc apply -f "$file"
  fi
}

if ! command -v oc >/dev/null 2>&1; then
  echo "error: oc not found in PATH" >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 0 ]] && ! oc whoami >/dev/null 2>&1; then
  echo "error: not logged in to a cluster (oc whoami failed)" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry-run mode (no cluster changes)"
else
  log "cluster: $(oc whoami --show-server 2>/dev/null || echo unknown) as $(oc whoami)"
fi
log "namespace: ${NAMESPACE}"

# --- Namespace (OpenShift AI data science project label) ---
cat >"${OUT_DIR}/namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    opendatahub.io/dashboard: "true"
    kubernetes.openshift.io/cluster-monitoring: "true"
  annotations:
    openshift.io/display-name: "Object Detection X-ray (lifecycle demo)"
    openshift.io/description: "MLflow experiments → OpenShift AI Model Registry → KServe canary"
EOF
apply_yaml "${OUT_DIR}/namespace.yaml"

# --- Pipeline ServiceAccount + RBAC ---
cat >"${OUT_DIR}/sa-rbac.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${PIPELINE_SA}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: xray-lifecycle-demo
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: xray-isvc-patcher
  namespace: ${NAMESPACE}
rules:
  - apiGroups: ["serving.kserve.io"]
    resources: ["inferenceservices"]
    verbs: ["get", "list", "watch", "patch", "update", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: xray-isvc-patcher
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: xray-isvc-patcher
subjects:
  - kind: ServiceAccount
    name: ${PIPELINE_SA}
    namespace: ${NAMESPACE}
  # Workbench terminal runs promote script with this SA.
  - kind: ServiceAccount
    name: object-detection-workbench
    namespace: ${NAMESPACE}
EOF
apply_yaml "${OUT_DIR}/sa-rbac.yaml"

# Workbench / pipeline SA → Model Registry kube-rbac-proxy (get services/<registry>).
# Only apply when the registry Role exists in rhoai-model-registries.
if oc get role registry-user-xray-model-registry -n rhoai-model-registries >/dev/null 2>&1; then
  log "binding workbench/pipeline SAs to Model Registry Role registry-user-xray-model-registry"
  apply_yaml "${SCRIPT_DIR}/openshift/rbac-workbench-model-registry.yaml"
else
  warn "Role registry-user-xray-model-registry not found in rhoai-model-registries — skip workbench MR RBAC"
fi

# Bind the same Role to common DSP runner SAs if they already exist in the project.
for sa in pipeline ds-pipeline-pipelines-definition pipeline-runner; do
  if oc get sa "$sa" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "binding xray-isvc-patcher to existing ServiceAccount/${sa}"
    cat >"${OUT_DIR}/rb-${sa}.yaml" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: xray-isvc-patcher-${sa}
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: xray-isvc-patcher
subjects:
  - kind: ServiceAccount
    name: ${sa}
    namespace: ${NAMESPACE}
EOF
    apply_yaml "${OUT_DIR}/rb-${sa}.yaml"
  fi
done

# --- Optional S3 data connection Secret (OpenShift AI dashboard-compatible) ---
if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" && -n "${AWS_S3_ENDPOINT:-}" && -n "${AWS_S3_BUCKET:-}" ]]; then
  REGION="${AWS_DEFAULT_REGION:-us-east-1}"
  log "applying data connection Secret/${CONNECTION_NAME}"
  cat >"${OUT_DIR}/data-connection.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${CONNECTION_NAME}
  namespace: ${NAMESPACE}
  labels:
    opendatahub.io/dashboard: "true"
    opendatahub.io/managed: "true"
    app.kubernetes.io/part-of: xray-lifecycle-demo
  annotations:
    opendatahub.io/connection-type: s3
    openshift.io/display-name: "X-ray model storage"
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "${AWS_ACCESS_KEY_ID}"
  AWS_SECRET_ACCESS_KEY: "${AWS_SECRET_ACCESS_KEY}"
  AWS_S3_ENDPOINT: "${AWS_S3_ENDPOINT}"
  AWS_DEFAULT_REGION: "${REGION}"
  AWS_S3_BUCKET: "${AWS_S3_BUCKET}"
EOF
  apply_yaml "${OUT_DIR}/data-connection.yaml"
else
  warn "AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_S3_ENDPOINT / AWS_S3_BUCKET not all set — skipping data connection Secret"
fi

# --- InferenceService ---
STORAGE_PATH="${STORAGE_PATH:-}"
STORAGE_URI="${STORAGE_URI:-}"

if [[ "$SKIP_ISVC" -eq 1 ]]; then
  log "skipping InferenceService (--skip-isvc)"
elif [[ -n "${STORAGE_KEY:-}" && -n "${STORAGE_PATH}" ]]; then
  log "applying InferenceService/${ISVC_NAME} (Connection storage.key=${STORAGE_KEY} path=${STORAGE_PATH})"
  cat >"${OUT_DIR}/inferenceservice.yaml" <<EOF
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: ${ISVC_NAME}
  namespace: ${NAMESPACE}
  annotations:
    serving.kserve.io/deploymentMode: Serverless
    serving.kserve.io/enable-tag-routing: "true"
  labels:
    app.kubernetes.io/name: ${ISVC_NAME}
    app.kubernetes.io/part-of: xray-lifecycle-demo
spec:
  predictor:
    model:
      modelFormat:
        name: onnx
      protocolVersion: v2
      storage:
        key: ${STORAGE_KEY}
        path: ${STORAGE_PATH}
      resources:
        requests:
          cpu: "500m"
          memory: 1Gi
        limits:
          cpu: "2"
          memory: 4Gi
EOF
  apply_yaml "${OUT_DIR}/inferenceservice.yaml"
elif [[ -n "${STORAGE_URI}" ]]; then
  log "applying InferenceService/${ISVC_NAME} (storageUri=${STORAGE_URI})"
  cat >"${OUT_DIR}/inferenceservice.yaml" <<EOF
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: ${ISVC_NAME}
  namespace: ${NAMESPACE}
  annotations:
    serving.kserve.io/deploymentMode: Serverless
    serving.kserve.io/enable-tag-routing: "true"
  labels:
    app.kubernetes.io/name: ${ISVC_NAME}
    app.kubernetes.io/part-of: xray-lifecycle-demo
spec:
  predictor:
    model:
      modelFormat:
        name: onnx
      protocolVersion: v2
      storageUri: ${STORAGE_URI}
      resources:
        requests:
          cpu: "500m"
          memory: 1Gi
        limits:
          cpu: "2"
          memory: 4Gi
EOF
  apply_yaml "${OUT_DIR}/inferenceservice.yaml"
else
  warn "STORAGE_URI or STORAGE_KEY+STORAGE_PATH not set — InferenceService not created"
  warn "After notebook 03 uploads ONNX, re-run with e.g.:"
  warn "  STORAGE_URI=s3://\$AWS_S3_BUCKET/${S3_KEY_PREFIX}/<run_id> ./deploy.sh"
  warn "or let pipelines/promote_deploy_canary.py patch a pre-created ISVC after stage=prod"
fi

# --- Optional custom workbench image (Minimal CUDA Py3.12 + install-dependencies.sh) ---
if [[ "$BUILD_WORKBENCH" -eq 1 ]]; then
  log "applying workbench ImageStream + BuildConfig"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: would apply openshift/workbench Imagestream/BuildConfig and start-build"
  else
    # Allow builder SA to pull the RHOAI base ImageStream if needed.
    if oc get ns redhat-ods-applications >/dev/null 2>&1; then
      oc policy add-role-to-user system:image-puller \
        "system:serviceaccount:${NAMESPACE}:builder" \
        -n redhat-ods-applications >/dev/null 2>&1 || true
    fi
    oc apply -f "${SCRIPT_DIR}/openshift/workbench/imagestream.yaml"
    oc apply -f "${SCRIPT_DIR}/openshift/workbench/buildconfig.yaml"
    log "starting binary build xray-workbench (this can take several minutes)"
    oc start-build xray-workbench -n "${NAMESPACE}" --from-dir="${SCRIPT_DIR}" --follow
    WORKBENCH_IMAGE="image-registry.openshift-image-registry.svc:5000/${NAMESPACE}/xray-workbench:latest"
    log "workbench image: ${WORKBENCH_IMAGE}"
  fi
fi

# --- Workbench Notebook (PVC + Notebook CR) ---
if [[ "$SKIP_NOTEBOOK" -eq 1 ]]; then
  log "skipping workbench Notebook (--skip-notebook)"
elif [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry-run: would apply openshift/workbench/notebook-pvc.yaml + notebook.yaml"
else
  log "applying workbench Notebook object-detection-workbench"
  NAMESPACE="${NAMESPACE}" \
    STORAGE_KEY="${CONNECTION_NAME}" \
    WORKBENCH_IMAGE="${WORKBENCH_IMAGE}" \
    "${SCRIPT_DIR}/openshift/workbench/apply-notebook.sh"
fi

# --- Compile pipeline YAML for DSP import ---
PIPELINE_OUT="${OUT_DIR}/promote_deploy_canary.yaml"
if [[ "$SKIP_PIPELINE" -eq 1 ]]; then
  log "skipping pipeline compile (--skip-pipeline)"
elif command -v python3 >/dev/null 2>&1; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: would compile pipeline to ${PIPELINE_OUT}"
  else
    if python3 "${SCRIPT_DIR}/pipelines/promote_deploy_canary.py" --compile "${PIPELINE_OUT}" 2>/dev/null; then
      log "compiled pipeline: ${PIPELINE_OUT}"
    else
      warn "pipeline compile failed (install kfp via ./install-dependencies.sh). Continuing."
    fi
  fi
else
  warn "python3 not found — skipping pipeline compile"
fi

# --- Env helper for workbench / local shell ---
ENV_OUT="${OUT_DIR}/env.cluster.sh"
cat >"${ENV_OUT}" <<EOF
# Generated by deploy.sh — source this in your workbench or shell
export KSERVE_NAMESPACE="${NAMESPACE}"
export INFERENCE_SERVICE_NAME="${ISVC_NAME}"
export REGISTERED_MODEL_NAME="xray-detector"
export S3_KEY_PREFIX="${S3_KEY_PREFIX}"
export STORAGE_KEY="${STORAGE_KEY:-${CONNECTION_NAME}}"
export PIPELINE_SA="${PIPELINE_SA}"
# Set these from your cluster / secrets as needed:
# export MLFLOW_TRACKING_URI=...
# export MODEL_REGISTRY_URL=...
# export AWS_ACCESS_KEY_ID=...
# export AWS_SECRET_ACCESS_KEY=...
# export AWS_S3_ENDPOINT=...
# export AWS_DEFAULT_REGION=...
# export AWS_S3_BUCKET=...
EOF
if [[ "$DRY_RUN" -eq 0 ]]; then
  log "wrote ${ENV_OUT}"
fi

log "done"
echo
echo "Next steps:"
if [[ "$SKIP_NOTEBOOK" -eq 0 ]]; then
  echo "  1. Open workbench object-detection-workbench in project ${NAMESPACE} (from openshift/workbench/notebook.yaml)"
else
  echo "  1. Create/open a workbench in project ${NAMESPACE} (or re-run without --skip-notebook)"
fi
echo "  2. source ${ENV_OUT}  # plus MODEL_REGISTRY_URL if needed; MLflow auth comes from notebook annotation"
if [[ "$BUILD_WORKBENCH" -eq 0 ]]; then
  echo "  3. Prefer ./deploy.sh --build-workbench so the Notebook image exists; else bash install-dependencies.sh"
  echo "  4. Run notebooks/01 → 04, then:"
else
  echo "  3. Run notebooks/01 → 04, then:"
fi
echo "       ./pipelines/run-promote-deploy-canary.sh --action leave-canary"
echo "  Optional: import ${PIPELINE_OUT} into Data Science Pipelines"
echo
if [[ "$DRY_RUN" -eq 0 ]]; then
  oc get ns "${NAMESPACE}" -o name
  oc get sa,role,rolebinding,secret,inferenceservice -n "${NAMESPACE}" 2>/dev/null || true
fi
