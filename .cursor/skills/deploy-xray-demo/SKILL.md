---
name: deploy-xray-demo
description: >-
  Deploy the object-detection-xray OpenShift AI lifecycle demo onto a cluster
  (MLflow → Model Registry → KServe canary). Use when installing on a new
  cluster, running deploy.sh, bootstrapping workbench/InferenceService, or
  when the user mentions OpenTLC, RHOAI demo deploy, or “set up the xray demo”.
---

# Deploy X-ray detection demo

Follow this order. Do **not** invent S3 (see workspace rule `s3-ask-user`).

## Preconditions (ask / verify with `oc`)

| Need | How to check / fix |
|------|--------------------|
| `oc` login to target cluster | `oc whoami --show-server` |
| OpenShift AI (RHOAI) with KServe Managed | `oc get dsc` → `kserve.managementState: Managed` |
| MLflow operator Managed + MLflow CR | `oc get mlflow -A` (expect URL) |
| Model Registry instance | e.g. `xray-model-registry` in `rhoai-model-registries` |
| **KnativeServing** instance | `oc get knativeserving -n knative-serving` — if missing: `oc apply -f openshift/knative-serving.yaml` (Serverless operator alone is not enough) |
| GPU node (for training workbench) | `oc get nodes -o custom-columns=...nvidia.com/gpu` — free GPU consumers if only 1 GPU |
| S3 decision from user | Existing Connection **or** `AWS_*` for Filebase/AWS — never stand up MinIO |

## Bootstrap checklist

Copy and tick:

```
- [ ] .env present (gitignored) or AWS_* exported — see docs/env.md
- [ ] KnativeServing Ready
- [ ] ./deploy.sh --build-workbench --skip-isvc   # ns, Connection, MR RBAC, image, Notebook
- [ ] Workbench Running; MLflow annotation opendatahub.io/mlflow-instance=mlflow
- [ ] notebooks/00_seed_baseline.ipynb  # weak model → …/baseline + ISVC Ready (before audience)
- [ ] Notebooks 01→04 (train → select → export/register → stage=prod); do not retarget ISVC to candidate
- [ ] ./pipelines/run-promote-deploy-canary.sh --action leave-canary  # expect two revisions/pods
- [ ] notebooks/05_infer_served.ipynb (predictor URL)
```

## Commands (repo root)

```bash
set -a && source .env && set +a   # if using .env

# Platform one-time (cluster-admin)
oc apply -f openshift/knative-serving.yaml
# wait: oc get knativeserving knative-serving -n knative-serving

./deploy.sh --build-workbench --skip-isvc

# Prefer notebook 00 before the live demo. Fallback after 03 only:
# ./openshift/ensure-baseline-isvc.sh

# After notebook 04 stage=prod:
./pipelines/run-promote-deploy-canary.sh --action leave-canary
```

`deploy.sh` sources `.env` when present; creates Connection Secret via `oc apply` YAML; applies Notebook/PVC unless `--skip-notebook`.

## Auth gotchas (do not re-debug from scratch)

**MLflow:** Public URI needs Kubernetes auth. Prefer Notebook annotation `opendatahub.io/mlflow-instance=mlflow` (injects `MLFLOW_TRACKING_URI` + `MLFLOW_TRACKING_AUTH=kubernetes-namespaced`). Bare URI without token → `UNAUTHENTICATED`. Disable Ultralytics auto-MLflow (`settings.update({"mlflow": False})`) so runs stay in experiment `xray-detector`.

**Model Registry:** Route is kube-rbac-proxy. Apply `openshift/rbac-workbench-model-registry.yaml` (own RoleBinding — do not patch operator-managed `*-users`). Client uses mounted SA token if `MODEL_REGISTRY_TOKEN` unset. Restart kernel after pulling `src/registry_client.py`.

**Selection handoff:** Kernels do not share `os.environ`. Notebooks 02–04 use `.demo_state.json` (`src/demo_state.py`).

**Workbench RAM:** Defaults `DEMO_BATCH=8`, `DEMO_WORKERS=2` for 16Gi; lower further if OOM.

## InferenceService timing

Prefer **notebook 00** to seed `…/baseline` and apply the ISVC before the live demo. Canary after notebook 04 must change `storage.path` so Knative creates a second revision/pod. Pipeline only patches an existing ISVC.

**OVMS layout:** S3 prefix must contain `1/model.onnx`. Candidate: `…/<run_id>/1/model.onnx`. Baseline: `…/baseline/1/model.onnx`.

**Smoke test:** use the **predictor** HTTPS URL (`status.components.predictor.url`), not `status.url` (often 503). See [troubleshooting.md](troubleshooting.md).

## Failure reference

For event messages and fixes, read [troubleshooting.md](troubleshooting.md).
