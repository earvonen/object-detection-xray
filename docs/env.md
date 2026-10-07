# Environment variables

Copy these into your OpenShift AI workbench, pipeline run, or local shell.
Names match OpenShift AI data-connection conventions where possible.

## Recommended workbench

**Jupyter | Minimal | CUDA | Python 3.12** in project `object-detection-xray`.
Attach a GPU when training; not required for register / promote / infer-only steps.

## MLflow (experiments only)

| Variable | Example | Purpose |
|----------|---------|---------|
| `MLFLOW_TRACKING_URI` | `https://mlflow-…` | Operator-managed MLflow tracking server |
| `MLFLOW_EXPERIMENT_NAME` | `xray-detector` | Experiment used by the notebooks (default: `xray-detector`) |
| `MLFLOW_TRACKING_TOKEN` | *(optional)* | Bearer token if the tracking server requires auth |

## S3-compatible object storage

| Variable | Example | Purpose |
|----------|---------|---------|
| `AWS_ACCESS_KEY_ID` | `…` | Access key |
| `AWS_SECRET_ACCESS_KEY` | `…` | Secret key |
| `AWS_S3_ENDPOINT` | `https://minio.example.com` | API endpoint (AWS or MinIO) |
| `AWS_DEFAULT_REGION` | `us-east-1` | Region |
| `AWS_S3_BUCKET` | `models` | Bucket for ONNX artifacts |

Optional:

| Variable | Default | Purpose |
|----------|---------|---------|
| `S3_KEY_PREFIX` | `object-detection/xray-detector` | Prefix for versioned ONNX keys |
| `LOCAL_ONNX` | *(run-specific)* | Local ONNX path for upload scripts |

Versioned object key pattern used by the demo:

```text
s3://$AWS_S3_BUCKET/$S3_KEY_PREFIX/<mlflow_run_id>/model.onnx
```

## OpenShift AI Model Registry (production boundary)

| Variable | Example | Purpose |
|----------|---------|---------|
| `MODEL_REGISTRY_URL` | `http://rhoai-registry-…:8080` | Registry REST base (in-cluster or route) |
| `MODEL_REGISTRY_TOKEN` | *(optional)* | Bearer token for authenticated routes |
| `REGISTERED_MODEL_NAME` | `xray-detector` | Logical model name in the registry |
| `MODEL_REGISTRY_VERIFY_SSL` | `true` | Set `false` only for lab/self-signed TLS |

Production designation is the custom property `stage=prod` on a model version
(not an MLflow Model Registry alias).

## Cluster bootstrap (`./deploy.sh`)

With an active `oc` login, bootstrap the demo project (default namespace
`object-detection-xray`). Platform components (MLflow, Model Registry, DSP,
KServe) must already be installed.

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_S3_ENDPOINT=...
export AWS_DEFAULT_REGION=us-east-1
export AWS_S3_BUCKET=models
# Optional — create InferenceService now (otherwise create after ONNX upload):
# export STORAGE_URI=s3://models/object-detection/xray-detector/<run_id>
# or: export STORAGE_KEY=aws-connection-xray-models STORAGE_PATH=object-detection/xray-detector/<run_id>
./deploy.sh
```

Writes rendered manifests and `env.cluster.sh` under `.deploy/` (gitignored).

## KServe / pipeline

| Variable | Example | Purpose |
|----------|---------|---------|
| `KSERVE_NAMESPACE` | `object-detection-xray` | Namespace of the InferenceService (default from `deploy.sh`) |
| `INFERENCE_SERVICE_NAME` | `xray-detector` | InferenceService name |
| `CANARY_TRAFFIC_PERCENT` | `10` | Canary traffic share for pipeline deploy |
| `STORAGE_KEY` | `aws-connection-…` | Optional OpenShift AI Connection name for S3 |
| `INFERENCE_ENDPOINT` | `https://xray-detector-…` | Endpoint used by the served-inference notebook |
| `INFERENCE_HOST_HEADER` | *(optional)* | `Host` header when calling via cluster ingress |

## Demo knobs (notebooks)

| Variable | Default | Purpose |
|----------|---------|---------|
| `DEMO_EPOCHS` | `3` | Short training runs for live demos |
| `DEMO_IMGSZ` | `640` | Training image size |
| `DEMO_MODEL` | `yolov8n.pt` | Base checkpoint |
| `SELECTED_RUN_ID` | *(set after selection)* | MLflow run chosen for export/register |
| `SELECTED_VERSION_ID` | *(set after register)* | Model Registry version id to promote |
