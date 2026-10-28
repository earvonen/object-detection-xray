# Environment variables

Copy these into your OpenShift AI workbench, pipeline run, or local shell.
Names match OpenShift AI data-connection conventions where possible.

## Recommended workbench

**Jupyter | Minimal | CUDA | Python 3.12** in project `object-detection-xray`.
Attach a GPU when training; not required for register / promote / infer-only steps.

## MLflow (experiments only)

OpenShift AI MLflow uses Kubernetes auth (`--app-name=kubernetes-auth`). Do **not** point
the workbench at the public URI with a bare `MLFLOW_TRACKING_URI` and no auth — the server
returns `UNAUTHENTICATED: Missing Authorization header or X-Forwarded-Access-Token`.

**Preferred (workbench):** annotate the Notebook so the platform injects URI + auth + RBAC:

```bash
oc annotate notebook <workbench-name> -n <project> \
  opendatahub.io/mlflow-instance=mlflow --overwrite
# Then stop/start the workbench so env is injected.
```

That sets `MLFLOW_TRACKING_URI`, `MLFLOW_TRACKING_AUTH=kubernetes-namespaced`, and
`MLFLOW_K8S_INTEGRATION=true`, and creates RoleBinding `*-mlflow` for the workbench SA.
(Dashboard-managed workbenches usually get this annotation automatically.)

| Variable | Example | Purpose |
|----------|---------|---------|
| `MLFLOW_TRACKING_URI` | `https://rh-ai…/mlflow` | Tracking server (injected by annotation, or set manually) |
| `MLFLOW_TRACKING_AUTH` | `kubernetes-namespaced` | SA token + `X-MLFLOW-WORKSPACE` (injected) |
| `MLFLOW_K8S_INTEGRATION` | `true` | Enable K8s credential provider (injected) |
| `MLFLOW_EXPERIMENT_NAME` | `xray-detector` | Experiment used by the notebooks (default: `xray-detector`) |
| `MLFLOW_TRACKING_TOKEN` / `MLFLOW_WORKSPACE` | *(manual only)* | Alternative to K8s auth: `oc whoami -t` + project name |

## S3-compatible object storage

Do not invent or deploy an object store for this demo. Ask the human operator for an existing
S3-compatible endpoint (or OpenShift AI Connection) and use the variables below once provided.

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

The HTTPS route sits behind **kube-rbac-proxy**. Calls without a Bearer token get
`401 Unauthorized`. In a workbench, `ModelRegistryClient` uses the mounted
ServiceAccount token automatically; `./deploy.sh` (or
`openshift/rbac-workbench-model-registry.yaml`) must bind that SA to
`registry-user-xray-model-registry` in `rhoai-model-registries`.

| Variable | Example | Purpose |
|----------|---------|---------|
| `MODEL_REGISTRY_URL` | `https://xray-model-registry-rest.…` | Registry REST base (route or in-cluster svc) |
| `MODEL_REGISTRY_TOKEN` | *(optional)* | Override Bearer token (`oc whoami -t`); else SA token |
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
# After notebook 03, prefer baseline ISVC (not the candidate run_id) so canary works:
#   ./openshift/ensure-baseline-isvc.sh
# Optional override:
# export STORAGE_KEY=aws-connection-xray-models
# export BASELINE_PATH=object-detection/xray-detector/baseline
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
| `DEMO_BATCH` | `8` | Train batch size (lower if the 16Gi workbench OOMs; try `4`) |
| `DEMO_WORKERS` | `2` | DataLoader workers (Ultralytics default `8` often blows host RAM) |
| `BASELINE_EPOCHS` | `1` | Notebook 00 weak seed |
| `BASELINE_FRACTION` | `0.02` | Notebook 00: fraction of train images |
| `BASELINE_IMGSZ` | `320` | Notebook 00 small input size |
| `BASELINE_PATH` | `object-detection/xray-detector/baseline` | S3/OVMS prefix for the pre-demo ISVC |
| `SELECTED_RUN_ID` | *(from notebook 02)* | MLflow run chosen for export/register |
| `SELECTED_VERSION_ID` | *(from notebook 03)* | Model Registry version id to promote |

Notebook kernels do **not** share `os.environ`. Notebooks 02–04 persist those
`SELECTED_*` values in gitignored `.demo_state.json` (env still overrides when set).
