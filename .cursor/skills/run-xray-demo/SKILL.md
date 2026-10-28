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

1. **01_train_track** — matrix of short YOLO runs → MLflow experiment `xray-detector`  
   - Need GPU; `DEMO_BATCH`/`DEMO_WORKERS` if 16Gi OOM  
   - Ultralytics MLflow must stay off (`settings.update({"mlflow": False})`)
2. **02_evaluate_select** — pick best run → `.demo_state.json` (`SELECTED_RUN_ID`)
3. **03_export_register** — ONNX → S3 → Model Registry `stage=candidate`  
   - Needs `MODEL_REGISTRY_URL` + SA/RBAC auth; Connection/`AWS_*` for upload  
   - Uploads `…/<run_id>/1/model.onnx` (OVMS version dir); restart kernel if client/`s3_utils` just updated
4. **Baseline ISVC** — **never** apply the ISVC to the candidate run you will canary:
   ```bash
   ./openshift/ensure-baseline-isvc.sh
   ```
   - Seeds `object-detection/xray-detector/baseline` if missing; creates ISVC on that path  
   - If ISVC already exists, leaves it (that revision becomes Knative `prev`)  
   - Confirm OVMS loaded (`/mnt/models/1/model.onnx`); Ready alone is not enough
5. **04_promote_prod** — `stage=prod` → `.demo_state.json` (`SELECTED_VERSION_ID`)
6. **Canary** — `./pipelines/run-promote-deploy-canary.sh --action leave-canary`  
   - Needs ISVC patch RBAC (`openshift/rbac-workbench-isvc-patcher.yaml`)  
   - Must change `storage.path` vs live ISVC → expect revisions `…-0000N` + `…-0000N+1` and **two** pods  
   - Script exits if paths are identical (canary would be a no-op)
7. **05_infer_served** — set `INFERENCE_ENDPOINT` to **predictor** URL (`status.components.predictor.url`), not `status.url` (often 503)
8. **Promote or rollback** — `--action promote` (100% + refresh S3 baseline) or `rollback`

## Env

Prefer workbench Connection injection for `AWS_*`. Also set/source:

- `MODEL_REGISTRY_URL` (HTTPS registry route)
- `MODEL_REGISTRY_VERIFY_SSL=false` on lab clusters if needed
- `MLFLOW_*` via Notebook annotation (not hand-set URI alone)

See `docs/env.md` and `.env` (gitignored).

## If blocked

Use skill `deploy-xray-demo` → [troubleshooting.md](../deploy-xray-demo/troubleshooting.md).
