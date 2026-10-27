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
   - Restart kernel if registry client was just updated
4. **Apply/update ISVC** if not yet pointing at this run’s prefix:
   `STORAGE_PATH=object-detection/xray-detector/<run_id> ./openshift/apply-inferenceservice.sh`
5. **04_promote_prod** — `stage=prod` → `.demo_state.json` (`SELECTED_VERSION_ID`)
6. **Canary** — `./pipelines/run-promote-deploy-canary.sh --action leave-canary`
7. **05_infer_served** — hit `INFERENCE_ENDPOINT` / ISVC status URL
8. **Promote or rollback** — same script `--action promote` or `rollback`

## Env

Prefer workbench Connection injection for `AWS_*`. Also set/source:

- `MODEL_REGISTRY_URL` (HTTPS registry route)
- `MODEL_REGISTRY_VERIFY_SSL=false` on lab clusters if needed
- `MLFLOW_*` via Notebook annotation (not hand-set URI alone)

See `docs/env.md` and `.env` (gitignored).

## If blocked

Use skill `deploy-xray-demo` → [troubleshooting.md](../deploy-xray-demo/troubleshooting.md).
