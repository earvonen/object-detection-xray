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
- [ ] Workbench Running; MLflow annotation + ConfigMap xray-demo-env (MODEL_REGISTRY_URL, …)
- [ ] notebooks/00_seed_baseline.ipynb  # weak model → …/baseline + ISVC Ready (before audience)
- [ ] ./openshift/discover-demo-env.sh --restart   # if 00 did not already; fills INFERENCE_ENDPOINT
- [ ] Notebooks 01→04 (train → select → export/register → stage=prod); do not retarget ISVC to candidate
- [ ] ./pipelines/run-promote-deploy-canary.sh --action leave-canary  # expect two revisions/pods
- [ ] ./openshift/discover-demo-env.sh --restart   # refresh latest-/prev- tag URLs for notebook 05
- [ ] notebooks/05_infer_served.ipynb (uses injected INFERENCE_ENDPOINT)
```

## Agent: discover env into the workbench

When deploying (or after ISVC/canary changes), use the active `oc` session — **do not ask the user to paste URLs**.

```bash
./openshift/discover-demo-env.sh --restart
```

That writes `.deploy/env.cluster.sh` and applies ConfigMap `xray-demo-env` in the demo namespace. The Notebook mounts it via `envFrom` (`openshift/workbench/notebook.yaml`).

| Var | Source |
|-----|--------|
| `MODEL_REGISTRY_URL` | Route `xray-model-registry-https` in `rhoai-model-registries` |
| `MODEL_REGISTRY_VERIFY_SSL` | default `false` (lab) |
| `INFERENCE_ENDPOINT` | ISVC `status.components.predictor.url` (when Ready) |
| `INFERENCE_ENDPOINT_LATEST` / `_PREV` | ISVC traffic tag URLs (canary) |
| `KSERVE_NAMESPACE`, `INFERENCE_SERVICE_NAME`, `REGISTERED_MODEL_NAME`, `STORAGE_KEY`, `S3_KEY_PREFIX`, `MLFLOW_EXPERIMENT_NAME` | defaults / deploy |

**MLflow:** leave to Notebook annotation `opendatahub.io/mlflow-instance=mlflow` (URI + `kubernetes-namespaced` auth). Do not inject a bare `MLFLOW_TRACKING_URI` into the ConfigMap.

**S3 / AWS_*:** Connection Secret only — never invent MinIO (workspace rule `s3-ask-user`).

After ConfigMap updates, `--restart` deletes the workbench pod so kernels see new env (restart kernel or reconnect).

## Commands (repo root)

```bash
set -a && source .env && set +a   # if using .env

# Platform one-time (cluster-admin)
oc apply -f openshift/knative-serving.yaml
# wait: oc get knativeserving knative-serving -n knative-serving

./deploy.sh --build-workbench --skip-isvc
# deploy.sh / apply-notebook.sh call discover-demo-env.sh

# Prefer notebook 00 before the live demo. Fallback after 03 only:
# ./openshift/ensure-baseline-isvc.sh   # also refreshes INFERENCE_* via discover

# After notebook 04 stage=prod:
./pipelines/run-promote-deploy-canary.sh --action leave-canary
./openshift/discover-demo-env.sh --restart   # tag routes for notebook 05
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

**Smoke test:** use the **predictor** URL (`INFERENCE_ENDPOINT` / `status.components.predictor.url`), not `status.url` (often 503). See [troubleshooting.md](troubleshooting.md).
## Failure reference

For event messages and fixes, read [troubleshooting.md](troubleshooting.md).
