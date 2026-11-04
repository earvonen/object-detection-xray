#!/usr/bin/env bash
# Ensure cluster platform pieces the demo needs (cluster-admin).
# Idempotent. Does NOT touch S3 / MinIO.
#
# - KnativeServing (KServe Serverless / canary)
# - Restart kserve / odh-model controllers after Knative is Ready (avoids
#   ServerlessModeRejected from stale "Knative not available" cache)
# - DSC mlflowoperator → Managed
# - ModelRegistry xray-model-registry (+ DB secret)
# - MLflow CR mlflow (lab sqlite + PVC; see openshift/mlflow.yaml)
#
# Usage:
#   ./openshift/ensure-platform.sh
#   ./openshift/ensure-platform.sh --wait
#   ./openshift/ensure-platform.sh --dry-run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAIT=0
DRY_RUN=0
SKIP_CONTROLLER_RESTART=0
for arg in "$@"; do
  case "$arg" in
    --wait) WAIT=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --skip-controller-restart) SKIP_CONTROLLER_RESTART=1 ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg" >&2
      exit 1
      ;;
  esac
done

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

if ! command -v oc >/dev/null 2>&1; then
  echo "error: oc not found" >&2
  exit 1
fi
if [[ "$DRY_RUN" -eq 0 ]] && ! oc whoami >/dev/null 2>&1; then
  echo "error: not logged in (oc whoami failed)" >&2
  exit 1
fi

apply() {
  local file="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: would apply ${file}"
    return 0
  fi
  oc apply -f "$file"
}

# --- KnativeServing ---
KNATIVE_APPLIED=0
if oc get knativeserving knative-serving -n knative-serving >/dev/null 2>&1; then
  log "KnativeServing already present"
else
  log "applying KnativeServing"
  apply "${SCRIPT_DIR}/knative-serving.yaml"
  KNATIVE_APPLIED=1
fi

restart_serving_controllers() {
  # KServe / odh-model often start before KnativeServing exists and cache
  # "Knative Services are not available" until their pods restart.
  local ns="redhat-ods-applications"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: would restart kserve-controller-manager + odh-model-controller"
    return 0
  fi
  if ! oc get ns "$ns" >/dev/null 2>&1; then
    warn "namespace ${ns} missing — skip serving controller restart"
    return 0
  fi
  log "restarting kserve-controller-manager + odh-model-controller (clear Knative cache)"
  oc delete pod -n "$ns" -l control-plane=kserve-controller-manager --wait=false 2>/dev/null || true
  oc delete pod -n "$ns" -l control-plane=odh-model-controller --wait=false 2>/dev/null || true
  # Fallback name match if labels differ across RHOAI builds
  oc get pods -n "$ns" -o name 2>/dev/null \
    | grep -E 'kserve-controller-manager|odh-model-controller' \
    | while read -r p; do oc delete -n "$ns" "$p" --wait=false 2>/dev/null || true; done
  sleep 3
  local i pod
  for i in $(seq 1 36); do
    pod="$(oc get pods -n "$ns" -o name 2>/dev/null | grep 'kserve-controller-manager' | head -1 || true)"
    if [[ -n "$pod" ]] && oc wait --for=condition=Ready -n "$ns" "$pod" --timeout=15s >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
  pod="$(oc get pods -n "$ns" -o name 2>/dev/null | grep 'odh-model-controller' | head -1 || true)"
  if [[ -n "$pod" ]]; then
    oc wait --for=condition=Ready -n "$ns" "$pod" --timeout=120s >/dev/null 2>&1 \
      || warn "odh-model-controller not Ready yet — continue"
  fi
}

# --- MLflow operator on DSC ---
DSC="$(oc get datasciencecluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$DSC" ]]; then
  warn "no DataScienceCluster found — skip mlflowoperator patch"
else
  STATE="$(oc get datasciencecluster "$DSC" -o jsonpath='{.spec.components.mlflowoperator.managementState}' 2>/dev/null || true)"
  if [[ "$STATE" == "Managed" ]]; then
    log "DSC/${DSC} mlflowoperator already Managed"
  else
    log "patching DSC/${DSC} mlflowoperator=Managed (was '${STATE:-unset}')"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "dry-run: would patch mlflowoperator"
    else
      oc patch datasciencecluster "$DSC" --type=merge \
        -p '{"spec":{"components":{"mlflowoperator":{"managementState":"Managed"}}}}'
    fi
  fi
fi

# --- Model Registry instance ---
MR_NS="rhoai-model-registries"
if ! oc get ns "$MR_NS" >/dev/null 2>&1; then
  warn "namespace ${MR_NS} missing — enable modelregistry on DSC first"
else
  if [[ "$DRY_RUN" -eq 0 ]] && ! oc get secret xray-model-registry-db -n "$MR_NS" >/dev/null 2>&1; then
    log "creating Secret/${MR_NS}/xray-model-registry-db"
    PASS="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
    oc create secret generic xray-model-registry-db \
      -n "$MR_NS" \
      --from-literal=database-password="$PASS"
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: would ensure Secret xray-model-registry-db"
  else
    log "Secret xray-model-registry-db already present"
  fi
  log "applying ModelRegistry xray-model-registry"
  apply "${SCRIPT_DIR}/model-registry-xray.yaml"
fi

# --- MLflow CR (needs CRD from operator) ---
wait_mlflow_crd() {
  local i
  for i in $(seq 1 60); do
    if oc get crd mlflows.mlflow.opendatahub.io >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry-run: would apply openshift/mlflow.yaml when CRD exists"
else
  if oc get mlflow mlflow >/dev/null 2>&1; then
    log "MLflow/mlflow already present"
  else
    log "waiting for mlflows CRD (mlflow operator)…"
    if wait_mlflow_crd; then
      log "applying openshift/mlflow.yaml"
      oc apply -f "${SCRIPT_DIR}/mlflow.yaml"
    else
      warn "mlflows CRD not ready — apply openshift/mlflow.yaml after operator installs"
    fi
  fi
fi

if [[ "$WAIT" -eq 1 && "$DRY_RUN" -eq 0 ]]; then
  log "waiting for KnativeServing Ready…"
  oc wait knativeserving/knative-serving -n knative-serving --for=condition=Ready --timeout=300s 2>/dev/null \
    || warn "KnativeServing wait timed out / condition missing"

  # Always bounce serving controllers after Knative Ready on --wait. Cheap insurance
  # against ServerlessModeRejected when ISVC is created later (notebook 00 / canary).
  if [[ "$SKIP_CONTROLLER_RESTART" -eq 0 ]]; then
    restart_serving_controllers
  else
    log "skipping serving controller restart (--skip-controller-restart)"
  fi

  log "waiting for ModelRegistry Available…"
  for i in $(seq 1 60); do
    avail="$(oc get mr xray-model-registry -n "$MR_NS" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
    # Some versions expose .status as columns only — also check pods
    if [[ "$avail" == "True" ]] \
      || oc get route xray-model-registry-https -n "$MR_NS" >/dev/null 2>&1; then
      if oc get role registry-user-xray-model-registry -n "$MR_NS" >/dev/null 2>&1; then
        log "Model Registry route + Role present"
        break
      fi
    fi
    sleep 5
  done

  log "waiting for MLflow Available / URL…"
  for i in $(seq 1 72); do
    url="$(oc get mlflow mlflow -o jsonpath='{.status.url}' 2>/dev/null || true)"
    avail="$(oc get mlflow mlflow -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
    if [[ -n "$url" && "$avail" == "True" ]]; then
      log "MLflow Available url=${url}"
      break
    fi
    if [[ -n "$url" && $i -ge 24 ]]; then
      # URL often appears before Available flips; good enough to proceed
      log "MLflow url=${url} (Available=${avail:-unset}) — continuing"
      break
    fi
    sleep 5
  done
elif [[ "$KNATIVE_APPLIED" -eq 1 && "$SKIP_CONTROLLER_RESTART" -eq 0 ]]; then
  # Without --wait we still kick controllers once Knative CR was newly applied.
  warn "KnativeServing was just applied — restart serving controllers after it is Ready:"
  warn "  oc wait knativeserving/knative-serving -n knative-serving --for=condition=Ready --timeout=300s"
  warn "  ./openshift/ensure-platform.sh --wait"
fi

log "platform ensure done"
echo "  knativeserving: $(oc get knativeserving -n knative-serving --no-headers 2>/dev/null | head -1 || echo missing)"
echo "  mr: $(oc get mr xray-model-registry -n rhoai-model-registries --no-headers 2>/dev/null || echo missing)"
echo "  mlflow: $(oc get mlflow mlflow -o jsonpath='{.status.url}' 2>/dev/null || echo missing)"
