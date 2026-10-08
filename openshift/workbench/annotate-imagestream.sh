#!/usr/bin/env bash
# Fix OpenShift AI dashboard validation for xray-workbench:latest.
# Builds only create a status tag; the dashboard needs a *spec* tag with
# notebook-software / notebook-python-dependencies annotations.
set -euo pipefail

NS="${KSERVE_NAMESPACE:-object-detection-xray}"
IS=xray-workbench
TAG=latest

oc label is/"${IS}" -n "${NS}" --overwrite opendatahub.io/notebook-image=true >/dev/null

oc annotate is/"${IS}" -n "${NS}" --overwrite \
  opendatahub.io/notebook-image-name="X-ray detector | Minimal CUDA | Python 3.12" \
  opendatahub.io/notebook-image-desc="Jupyter Minimal CUDA Python 3.12 with Ultralytics, MLflow, ONNX for the xray detector demo" \
  opendatahub.io/notebook-image-order="100" \
  opendatahub.io/notebook-image-url="https://github.com/red-hat-data-services/notebooks/tree/main/jupyter/minimal" \
  opendatahub.io/recommended-accelerators='["nvidia.com/gpu"]'

DIGEST="$(oc get is/"${IS}" -n "${NS}" -o jsonpath="{.status.tags[?(@.tag==\"${TAG}\")].items[0].image}")"
if [[ -z "${DIGEST}" ]]; then
  echo "error: no image found for ${IS}:${TAG} in ${NS} — build first" >&2
  exit 1
fi

oc patch is/"${IS}" -n "${NS}" --type=merge -p "$(DIGEST="${DIGEST}" NS="${NS}" IS="${IS}" TAG="${TAG}" python3 - <<'PY'
import json, os
digest = os.environ["DIGEST"]
ns = os.environ["NS"]
is_name = os.environ["IS"]
tag = os.environ["TAG"]
print(json.dumps({
  "spec": {
    "lookupPolicy": {"local": True},
    "tags": [{
      "name": tag,
      "annotations": {
        "opendatahub.io/workbench-image-recommended": "true",
        "opendatahub.io/notebook-software": json.dumps([
          {"name": "CUDA", "version": "13.0"},
          {"name": "Python", "version": "v3.12"},
        ], indent=2),
        "opendatahub.io/notebook-python-dependencies": json.dumps([
          {"name": "JupyterLab", "version": "4.6"},
          {"name": "Ultralytics", "version": "8"},
          {"name": "MLflow", "version": "3"},
          {"name": "ONNX", "version": "1"},
          {"name": "PyTorch", "version": "2"},
        ], indent=2),
      },
      "from": {
        "kind": "ImageStreamImage",
        "name": f"{is_name}@{digest}",
        "namespace": ns,
      },
      "referencePolicy": {"type": "Source"},
    }]
  }
}))
PY
)"

echo "Annotated ${NS}/${IS}:${TAG} (digest ${DIGEST})"
echo "Hard-refresh Create workbench, select this image, and set Accelerator = NVIDIA GPU."
