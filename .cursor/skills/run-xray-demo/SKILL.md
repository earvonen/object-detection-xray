---
name: run-xray-demo
description: >-
  Run the object-detection-xray presenter flow on an already-deployed cluster
  (notebooks 01–05, canary promote/rollback). Use when walking through the
  demo, fixing notebook/MLflow/registry cells, or promoting the canary.
---

# Run X-ray demo (presenter)

Assumes `deploy-xray-demo` bootstrap is done. Work in project `object-detection-xray`.

## Flow

0. **00_seed_baseline** (before the audience) — deliberately weak train → upload `…/baseline/1/model.onnx` → `ensure-baseline-isvc.sh --force`  
   - ISVC must be Ready on baseline before notebook 01  
   - Knobs: `BASELINE_EPOCHS=1`, `BASELINE_FRACTION=0.02`, `BASELINE_IMGSZ=320`
1. **01_train_track** — matrix of short YOLO runs → MLflow experiment `xray-detector`  
   - Need GPU; `DEMO_BATCH`/`DEMO_WORKERS` if 16Gi OOM  
   - Ultralytics MLflow must stay off (`settings.update({"mlflow": False})`)
2. **02_evaluate_select** — pick best run → `.demo_state.json` (`SELECTED_RUN_ID`)
3. **03_export_register** — ONNX → S3 → Model Registry `stage=candidate`  
   - Needs `MODEL_REGISTRY_URL` + SA/RBAC auth; Connection/`AWS_*` for upload  
   - Uploads `…/<run_id>/1/model.onnx` (OVMS version dir); restart kernel if client/`s3_utils` just updated  
   - **Do not** re-point the ISVC at this run_id (baseline from 00 stays `prev`)
4. **04_promote_prod** — `stage=prod`, then **deploy canary** cell (`src.canary_deploy.run_flow(leave-canary)`)  
   - Needs ISVC patch RBAC (`openshift/rbac-workbench-isvc-patcher.yaml`)  
   - Expect two revisions/pods (`prev`=baseline, `latest`=prod path)  
   - Fails if storage.path already equals prod (canary would be a no-op)
5. **05_infer_served** — smoke predictor → tag-route both revisions → **promote** or **rollback** cell  
   - Reads `INFERENCE_*` from live ISVC via `sync_inference_env()` (no shell script)

Presenter path is **notebooks only** (00→05). Optional CLI remains at `pipelines/run-promote-deploy-canary.sh` for automation / DSP.

## Env

Prefer ConfigMap from deploy (`./openshift/discover-demo-env.sh`). Notebooks also refresh `INFERENCE_*` from the ISVC in-process.

Workbench: `MODEL_REGISTRY_URL` / names from ConfigMap `xray-demo-env`; `AWS_*` from Connection Secret; MLflow URI+auth from `opendatahub.io/mlflow-instance=mlflow`.

See `docs/env.md` and `.env` (gitignored) for S3 only.
## If blocked

Use skill `deploy-xray-demo` → [troubleshooting.md](../deploy-xray-demo/troubleshooting.md).
