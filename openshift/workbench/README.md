# Custom workbench image

Builds **Jupyter | Minimal | CUDA | Python 3.12** (`redhat-ods-applications/minimal-gpu:3.5`) with [`install-dependencies.sh`](../../install-dependencies.sh) baked in.

## Apply and build

```bash
# Ensure project exists
./deploy.sh --skip-isvc --skip-pipeline   # or create ns object-detection-xray

oc apply -f openshift/workbench/imagestream.yaml
oc apply -f openshift/workbench/buildconfig.yaml

# From the repository root — uploads context for the Containerfile COPY
oc start-build xray-workbench -n object-detection-xray --from-dir=. --follow
```

## Workbench Notebook (GitOps)

PVC + Notebook CR live in this directory and are applied by `./deploy.sh` (unless `--skip-notebook`):

- [`notebook-pvc.yaml`](notebook-pvc.yaml)
- [`notebook.yaml`](notebook.yaml) — includes `opendatahub.io/mlflow-instance=mlflow` and the S3 Connection name

```bash
# Standalone (after image build / Connection exist):
./openshift/workbench/apply-notebook.sh

# Or via deploy (sources .env when present):
./deploy.sh --build-workbench --skip-isvc
```

Dashboard alternative: create the workbench manually and select **X-ray detector | Minimal CUDA | Python 3.12**. If Create stays gray, re-apply tag metadata:

```bash
bash openshift/workbench/annotate-imagestream.sh
```

Skip `bash install-dependencies.sh` when using the custom image (still clone/mount this repo for notebooks and data).

## Base image pin

`BuildConfig.spec.strategy.dockerStrategy.from` uses `minimal-gpu:3.5`. To follow a newer RHOAI tag (still Py3.12 CUDA), change that ImageStreamTag and rebuild.
