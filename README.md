# X-ray object detection — MLflow → Model Registry → KServe

OpenShift AI demo of an end-to-end **model lifecycle** for X-ray baggage / prohibited-item detection:

**Experiment → Track → Evaluate → Select → Register → Promote → Deploy → Validate → Roll back or promote further**

| Layer | Role in this demo |
|-------|-------------------|
| **MLflow** | Data-scientist experiments only (params, metrics, dataset lineage, artifacts) |
| **OpenShift AI Model Registry** | Production boundary — curated versions; `stage=prod` is the production designation |
| **Data Science Pipelines** | Resolve `stage=prod` and update KServe (canary → 100% or rollback) |
| **KServe (Serverless)** | Serve ONNX; canary traffic split |

MLflow Model Registry aliases (e.g. `@prod`) are **not** used. Production moves by changing `stage=prod` on an OpenShift AI Model Registry version.

```text
Jupyter workbench
  → MLflow experiments (many runs)
  → compare / select (few candidates)
  → ONNX → S3
  → OpenShift AI Model Registry (stage=candidate → stage=prod)
  → DSP pipeline
  → KServe InferenceService (canary → promote / rollback)
```

## Dataset

- **Source**: [Roboflow — X-ray baggage detection](https://universe.roboflow.com/malek-mhnrl/x-ray-baggage-detection/dataset/1) (YOLO format, CC BY 4.0)
- Layout under `images/` with `data.yaml` (`nc: 5`)

## Prerequisites (cluster)

- OpenShift AI with **MLflow**, **Model Registry**, **Data Science Pipelines**, and **single-model serving**
- KServe in **Advanced / Serverless** mode (required for `canaryTrafficPercent`)
- S3-compatible object storage + project Connection
- Workbench image: **Jupyter | Minimal | CUDA | Python 3.12** (attach a GPU when training live; CPU + short `DEMO_EPOCHS` or warm-start also works)

Environment variables: [`docs/env.md`](docs/env.md).

## Setup

### Cluster bootstrap (with `oc` login)

Platform components (MLflow, Model Registry, DSP, KServe Serverless) must already exist.
This creates project **`object-detection-xray`**, pipeline SA/RBAC, optional S3 Connection, and optionally the InferenceService:

```bash
oc login ...
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
export AWS_S3_ENDPOINT=... AWS_DEFAULT_REGION=us-east-1 AWS_S3_BUCKET=models
# Optional until a model is in S3:
# export STORAGE_URI=s3://$AWS_S3_BUCKET/object-detection/xray-detector/<run_id>
./deploy.sh
source .deploy/env.cluster.sh
```

### Workbench image

**Recommended:** build a custom image that starts from **Jupyter | Minimal | CUDA | Python 3.12** (`minimal-gpu:3.5`) and runs [`install-dependencies.sh`](install-dependencies.sh):

```bash
./deploy.sh --build-workbench
# or manually — see openshift/workbench/README.md
```

Then create a workbench in project `object-detection-xray` using **X-ray detector | Minimal CUDA | Python 3.12** (`xray-workbench:latest`) and attach a GPU if training.

**Alternative:** use the stock **Jupyter | Minimal | CUDA | Python 3.12** image and run `bash install-dependencies.sh` once in the workbench terminal.

Clone or mount this repo at the workbench root so paths like `images/data.yaml` resolve.

## Demo flow (presenter script)

Aim for ~20–30 minutes with short training runs (`DEMO_EPOCHS=3`).

1. **Train & track** — [`notebooks/01_train_track.ipynb`](notebooks/01_train_track.ipynb)  
   Run 2–3 hyperparameter variants; each run logs to MLflow. Emphasize experiment history, not registration.

2. **Evaluate & select** — [`notebooks/02_evaluate_select.ipynb`](notebooks/02_evaluate_select.ipynb)  
   Compare runs; pick one. Explicitly show that other runs are **not** registered.

3. **Export & register** — [`notebooks/03_export_register.ipynb`](notebooks/03_export_register.ipynb)  
   ONNX export → versioned S3 key `object-detection/xray-detector/<run_id>/model.onnx` → register in OpenShift AI Model Registry as `stage=candidate` with `mlflow_run_id` lineage.

4. **Promote prod** — [`notebooks/04_promote_prod.ipynb`](notebooks/04_promote_prod.ipynb)  
   Set `stage=prod` on the chosen version (clears previous prod). Show the pipeline contract (`uri` / `storage_path`).

5. **Deploy canary** — [`pipelines/promote_deploy_canary.py`](pipelines/promote_deploy_canary.py)  
   ```bash
   python pipelines/promote_deploy_canary.py --action leave-canary
   ```  
   Or compile/import into Data Science Pipelines (`--compile`). Patches [`openshift/inferenceservice-xray-detector.yaml`](openshift/inferenceservice-xray-detector.yaml) with 10% canary.

6. **Validate** — [`notebooks/05_infer_served.ipynb`](notebooks/05_infer_served.ipynb)  
   Hit the InferenceService; optionally `latest-` / `prev-` tag routes.

7. **Promote or roll back**  
   ```bash
   python pipelines/promote_deploy_canary.py --action promote   # 100%
   # or
   python pipelines/promote_deploy_canary.py --action rollback  # canaryTrafficPercent: 0
   ```

Warm-start option: skip live training and export from checked-in `runs-openshift/exp1/weights/best.pt` by setting tags/paths manually — useful if GPU time is limited.

## Repository layout

| Path | Purpose |
|------|---------|
| `notebooks/01_…05_…` | Lifecycle notebooks |
| `src/` | Dataset fingerprint, MLflow helpers, Model Registry client, S3 + KServe utils |
| `openshift/` | InferenceService + canary/promote/rollback examples + pipeline RBAC |
| `pipelines/` | Promote/deploy/canary pipeline (CLI + KFP compile) |
| `docs/env.md` | Environment variables |
| `train.ipynb` / `test.ipynb` / `export.ipynb` | Legacy single-cell notebooks (still usable; paths aligned to `runs-openshift/`) |
| `upload-best-onnx-to-s3.sh` | Optional AWS CLI upload helper |

## Why OpenShift AI Model Registry here?

MLflow remains the familiar DS experiment system. The OpenShift AI Model Registry is the **operational** handoff: only curated models, dashboard visibility, RBAC/project sharing, and a stable contract for pipelines and KServe. That keeps “every experiment artifact” out of production serving.

## Serving notes

- Format: **ONNX** on S3-compatible storage
- Canary requires Knative Serverless mode
- YOLO ONNX may need client-side letterbox/NMS for polished boxes; notebook 05 proves endpoint reachability and lifecycle wiring

## Automation path

The demo runs the pipeline **after** `stage=prod` is set. The same pipeline is the automation seam for production: webhook / EventListener / GitOps reconcile on production designation change → resolve registry → canary → promote.

## License

Dataset terms: Roboflow export files under `images/` (CC BY 4.0 for the linked version). Add a top-level license for your own code if you redistribute beyond this demo.
