# X-ray object detection — MLflow → Model Registry → KServe

OpenShift AI demo of an end-to-end **model lifecycle** for X-ray baggage / prohibited-item detection:

**Experiment → Track → Evaluate → Select → Register → Promote → Canary → Validate → Promote or roll back**

| Layer | Role in this demo |
|-------|-------------------|
| **MLflow** | Data-scientist experiments only (params, metrics, dataset lineage, artifacts) |
| **OpenShift AI Model Registry** | Production boundary — curated versions; `stage=prod` is the production designation |
| **KServe (Serverless)** | Serve ONNX; canary traffic split (`latest-` / `prev-` tag routes) |
| **Notebooks 00–05** | Presenter path — train through canary, infer, and promote/rollback **from cells** |
| **Data Science Pipelines** *(optional)* | Same canary/promote logic compiled for automation (webhook / DSP), not required live |

MLflow Model Registry aliases (e.g. `@prod`) are **not** used. Production moves by changing `stage=prod` on an OpenShift AI Model Registry version.

```text
Jupyter workbench
  → MLflow experiments (many runs)
  → compare / select (few candidates)
  → ONNX → S3
  → OpenShift AI Model Registry (stage=candidate → stage=prod)
  → KServe InferenceService (canary → promote / rollback)
       ↑ driven by notebook cells (src.canary_deploy)
```

## Dataset

- **Source**: [Roboflow — X-ray baggage detection](https://universe.roboflow.com/malek-mhnrl/x-ray-baggage-detection/dataset/1) (YOLO format, CC BY 4.0)
- Layout under `images/` with `data.yaml` (`nc: 5`)

## Prerequisites (cluster)

- OpenShift AI with **MLflow**, **Model Registry**, and **single-model serving** (DSP optional)
- KServe in **Advanced / Serverless** mode + a **KnativeServing** instance (required for `canaryTrafficPercent`)
- S3-compatible object storage + project Connection (you supply credentials — see below)
- GPU node recommended for live training; CPU + short knobs or warm-start also works

Environment variables: [`docs/env.md`](docs/env.md).

## Setup

### Cluster bootstrap (with `oc` login)

Platform components (MLflow, Model Registry, KServe Serverless / KnativeServing) must already exist.
`deploy.sh` creates project **`object-detection-xray`**, Connection Secret (if `AWS_*` set), Model Registry + ISVC patch RBAC, workbench image/Notebook, and discovers cluster URLs into ConfigMap **`xray-demo-env`**.

```bash
oc login ...
# Prefer a gitignored .env with AWS_* (see docs/env.md)
set -a && source .env && set +a

# Skip ISVC until notebook 00 seeds …/baseline (canary needs a different path later)
./deploy.sh --build-workbench --skip-isvc

# Optional: re-discover URLs after the ISVC exists
./openshift/discover-demo-env.sh --restart
```

Workbench env (no hand-exports needed in notebooks):

| Source | Variables |
|--------|-----------|
| Notebook annotation `opendatahub.io/mlflow-instance=mlflow` | `MLFLOW_TRACKING_URI` + Kubernetes auth |
| ConfigMap `xray-demo-env` (from `discover-demo-env.sh`) | `MODEL_REGISTRY_URL`, `INFERENCE_ENDPOINT`, tag URLs, names/prefixes |
| Connection Secret (via `envFrom`) | `AWS_*` |

**S3 / object storage:** do **not** stand up MinIO or any other object store for this demo. Use an existing bucket/Connection and supply `AWS_*`, or defer serving. See [`.cursor/rules/s3-ask-user.mdc`](.cursor/rules/s3-ask-user.mdc).

### Workbench image

**Recommended:** `./deploy.sh --build-workbench` layers [`install-dependencies.sh`](install-dependencies.sh) on **Jupyter | Minimal | CUDA | Python 3.12** and applies Notebook `object-detection-workbench`.

**Alternative:** stock Minimal CUDA image + `bash install-dependencies.sh` in the terminal.

Clone or sync this repo into the workbench so `images/data.yaml` and `notebooks/` resolve.

### Reset / teardown

| Goal | Command |
|------|---------|
| Wipe MLflow runs + clear `stage=prod` (keep LIVE model) | `./openshift/reset-mlflow-registry.sh` |
| Wipe MLflow/MR data, then delete demo namespace + MR RoleBinding | `./openshift/teardown-demo.sh` |
| Full reset (same as teardown; also used by agents with `--yes`) | `./openshift/reset-demo.sh` |

## Demo flow (presenter — notebooks only)

Aim for ~20–30 minutes with short training (`DEMO_EPOCHS=3`). Each code cell has a plain-language markdown blurb above it.

0. **Seed baseline (before the audience)** — [`notebooks/00_seed_baseline.ipynb`](notebooks/00_seed_baseline.ipynb)  
   Deliberately weak train → `…/baseline/1/model.onnx` → InferenceService on that path so a **prev** revision exists before the live story.

1. **Train & track** — [`notebooks/01_train_track.ipynb`](notebooks/01_train_track.ipynb)  
   Short YOLO matrix → MLflow experiment `xray-detector`. Emphasize experiment history, not registration.

2. **Evaluate & select** — [`notebooks/02_evaluate_select.ipynb`](notebooks/02_evaluate_select.ipynb)  
   Compare runs; pick one into `.demo_state.json`. Other runs stay experiments only.

3. **Export & register** — [`notebooks/03_export_register.ipynb`](notebooks/03_export_register.ipynb)  
   ONNX → `object-detection/xray-detector/<run_id>/1/model.onnx` → Model Registry `stage=candidate`.  
   **Do not** retarget the ISVC to this run (baseline from 00 stays `prev`).

4. **Promote prod + canary** — [`notebooks/04_promote_prod.ipynb`](notebooks/04_promote_prod.ipynb)  
   `stage=prod`, then a cell patches the ISVC with `canaryTrafficPercent: 10` (via `src.canary_deploy`). Expect two revisions/pods.

5. **Infer + promote/rollback** — [`notebooks/05_infer_served.ipynb`](notebooks/05_infer_served.ipynb)  
   Smoke the predictor URL, hit `latest-` / `prev-` tag routes, then promote to 100% or roll back — all in cells.

If you skipped notebook 00, run `./openshift/ensure-baseline-isvc.sh` after notebook 03 before canary.

Warm-start option: skip live training and export from checked-in `runs-openshift/exp1/weights/best.pt` — useful if GPU time is limited.

## Repository layout

| Path | Purpose |
|------|---------|
| `notebooks/00_…05_…` | Seed + full lifecycle (presenter path) |
| `src/` | MLflow helpers, Model Registry client, S3/OVMS paths, KServe patch + `canary_deploy` |
| `openshift/` | ISVC manifests, workbench build, RBAC, `discover-demo-env.sh`, reset/teardown |
| `pipelines/` | Optional CLI / KFP compile of the same canary flow |
| `docs/env.md` | Environment variables |
| `deploy.sh` | Bootstrap project, Connection, workbench, discovery |
| `train.ipynb` / `test.ipynb` / `export.ipynb` | Legacy notebooks (paths aligned to `runs-openshift/`) |

## Why OpenShift AI Model Registry here?

MLflow remains the familiar DS experiment system. The OpenShift AI Model Registry is the **operational** handoff: only curated models, dashboard visibility, RBAC/project sharing, and a stable contract for serving. That keeps “every experiment artifact” out of production.

## Serving notes

- Format: **ONNX** on S3; OVMS expects `{prefix}/1/model.onnx` (baseline: `…/baseline/1/model.onnx`)
- Canary needs Knative Serverless + a path change vs the live ISVC
- Smoke tests: use the **predictor** URL (`status.components.predictor.url` / `INFERENCE_ENDPOINT`), not `status.url` (often 503)
- Tag routing (`serving.kserve.io/enable-tag-routing=true`) exposes `latest-` / `prev-` hosts for explicit canary checks
- YOLO ONNX may need client-side letterbox/NMS for pretty boxes; notebook 05 proves the serving path

## Automation path

The live demo uses notebook cells. The same logic (`src.canary_deploy` / `pipelines/promote_deploy_canary.py`) is the seam for production automation: webhook / EventListener / GitOps on `stage=prod` → canary → promote.

```bash
# Optional — same behavior as notebook 04/05 cells
./pipelines/run-promote-deploy-canary.sh --action leave-canary
./pipelines/run-promote-deploy-canary.sh --action promote   # or rollback
```

## License

Dataset terms: Roboflow export files under `images/` (CC BY 4.0 for the linked version). Add a top-level license for your own code if you redistribute beyond this demo.
