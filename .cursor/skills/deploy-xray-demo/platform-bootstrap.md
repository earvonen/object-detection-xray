# Platform bootstrap (RHOAI 3.5 / OpenTLC)

Prefer the repo script and manifests — do **not** hand-type CRs from memory or outdated docs snippets.

```bash
./openshift/ensure-platform.sh --wait
# or: ./deploy.sh --ensure-platform --build-workbench --skip-isvc
```

| Step | Manifest / action |
|------|-------------------|
| KnativeServing | `openshift/knative-serving.yaml` |
| MLflow operator | DSC patch `mlflowoperator.managementState=Managed` (script) |
| Model Registry instance | Secret `xray-model-registry-db` + `openshift/model-registry-xray.yaml` |
| MLflow CR | `openshift/mlflow.yaml` (after `mlflows` CRD exists) |

`default-modelregistry` (platform component) ≠ demo registry. Demo needs **`mr/xray-model-registry`**, Role `registry-user-xray-model-registry`, route `xray-model-registry-https`.

## Why `openshift/mlflow.yaml` looks the way it does

RHOAI 3.5 CRD rejects the older “minimal” snippet that omits `serveArtifacts` while using `file://` artifacts (`defaultArtifactRoot must be set when serveArtifacts is not true` / `serveArtifacts must be enabled when artifactsDestination uses file-based storage`). The checked-in CR sets `serveArtifacts: true` + PVC + sqlite.

## Readiness (do not over-wait)

- KnativeServing: `Ready=True`
- **Then** serving controllers restarted (`ensure-platform.sh --wait` does this) — prevents `ServerlessModeRejected` when notebook 00 creates the ISVC
- MR: route + Role present (AVAILABLE column / conditions)
- MLflow: `.status.url` set and `Available=True` (there may be **no** condition type named `Ready`)

Order matters: Knative Ready → restart kserve/odh-model → **then** ISVC (notebook 00). Creating the ISVC while controllers still think Knative is missing leaves it stuck with no `ksvc` until controllers are bounced.

## Stale `.env` hosts

OpenTLC sandboxes change DNS every lab. `discover-demo-env.sh` now prefers live routes when env `MODEL_REGISTRY_URL` / `MLFLOW_TRACKING_URI` disagree with the current cluster. Still rewrite `.env` hosts when switching clusters so local shells stay correct.

## Parallel batch

When probe shows multiple gaps, run `ensure-platform.sh` once (it applies Knative + DSC + MR together, then MLflow when the CRD appears). Start `deploy.sh --build-workbench` after the MR Role exists so the image build overlaps MLflow becoming Available — or use `deploy.sh --ensure-platform --build-workbench --skip-isvc` for a single entrypoint.
