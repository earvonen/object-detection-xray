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

## Use in OpenShift AI

1. Open project **object-detection-xray**
2. Create a workbench
3. Select image **X-ray detector | Minimal CUDA | Python 3.12** (`xray-workbench:latest`)
4. Set **Accelerator** to an NVIDIA GPU (required while the image recommends GPU — otherwise Create stays disabled)
5. Fill name / storage as usual → Create

If Create stays gray after selecting this image, re-apply tag metadata (builds can drop it):

```bash
bash openshift/workbench/annotate-imagestream.sh
# then hard-refresh the dashboard
```

You can skip `bash install-dependencies.sh` in the workbench for packages already in the image (still clone/mount this repo for notebooks and data).

## Base image pin

`BuildConfig.spec.strategy.dockerStrategy.from` uses `minimal-gpu:3.5`. To follow a newer RHOAI tag (still Py3.12 CUDA), change that ImageStreamTag and rebuild.
