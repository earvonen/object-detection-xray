# OpenShift manifests

Serverless (Knative) InferenceService examples and platform bootstrap for the
X-ray detector lifecycle demo.

## Platform (fresh cluster)

```bash
./openshift/ensure-platform.sh --wait
# Applies: knative-serving.yaml, DSC mlflowoperator=Managed, model-registry-xray.yaml,
#          mlflow.yaml (after CRD appears)
```

| File | Purpose |
|------|---------|
| `knative-serving.yaml` | KnativeServing instance (Serverless operator alone is not enough) |
| `mlflow.yaml` | Lab MLflow CR (`serveArtifacts: true` + sqlite/PVC — required on RHOAI 3.5+) |
| `model-registry-xray.yaml` | Demo MR instance `xray-model-registry` (needs DB secret from ensure-platform) |
| `ensure-platform.sh` | Idempotent apply + optional `--wait` |

## Serving prerequisites

- OpenShift AI **single-model serving** enabled
- Deployment mode **Advanced / Serverless** (required for `canaryTrafficPercent`)
- S3-compatible Connection in the data science project (or `storageUri` with cluster credentials)
- Platform ONNX / OpenVINO runtime available for `modelFormat.name: onnx`

## Apply baseline

For the lifecycle demo, prefer:

```bash
# After notebook 03 uploaded ONNX — seeds …/baseline and creates the ISVC on that path.
# Do not point the ISVC at the candidate run_id you will canary.
./openshift/ensure-baseline-isvc.sh
```

Or manually:

```bash
STORAGE_PATH=object-detection/xray-detector/baseline ./openshift/apply-inferenceservice.sh
```

## Canary / promote / rollback

| File | Effect |
|------|--------|
| `inferenceservice-canary-patch.yaml` | New URI + 10% canary |
| `inferenceservice-promote-100.yaml` | 100% to new revision (no canary field) |
| `inferenceservice-rollback.yaml` | `canaryTrafficPercent: 0` |

Demo path: notebook 04/05 cells call `src.canary_deploy` (same logic as `pipelines/promote_deploy_canary.py` CLI / optional DSP compile).

Tag routing annotation `serving.kserve.io/enable-tag-routing: "true"` exposes `latest-` / `prev-` routes for explicit canary validation.

## Custom workbench image

See [`workbench/`](workbench/) for a BuildConfig that layers `install-dependencies.sh` onto **Jupyter | Minimal | CUDA | Python 3.12** (`minimal-gpu:3.5`).
