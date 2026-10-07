#!/usr/bin/env bash
# Install demo dependencies for train / track / register / serve workflows.
#
# Prefer the OpenShift AI workbench image:
#   Jupyter | Minimal | CUDA | Python 3.12
# OpenVINO has no wheels for bleeding-edge Pythons (e.g. 3.14); it is optional
# for the ONNX → KServe path.
set -euo pipefail

PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "error: $PYTHON not found" >&2
  exit 1
fi

PY_VER="$("$PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
echo "Using $($PYTHON -c 'import sys; print(sys.executable)') (Python ${PY_VER})"

# Core packages required for the MLflow → Model Registry → ONNX/KServe demo.
"$PYTHON" -m pip install \
  "numpy>=2.0.0,<3" \
  "torch>=2.4" \
  ultralytics \
  onnx \
  onnxruntime \
  awscli \
  boto3 \
  mlflow \
  requests \
  pyyaml \
  pandas \
  "kfp>=2.0.0,<3"

# OpenVINO is only needed for optional IR export in export.ipynb / legacy paths.
# Skip cleanly when no matching wheel exists (common on Python 3.13+).
if "$PYTHON" -c 'import sys; raise SystemExit(0 if sys.version_info < (3, 13) else 1)'; then
  if "$PYTHON" -m pip install "openvino>=2024.5"; then
    echo "OpenVINO installed."
  else
    echo "warning: OpenVINO install failed; ONNX/KServe demo still works. IR export in export.ipynb will not." >&2
  fi
else
  echo "warning: Python ${PY_VER} has no OpenVINO wheels on PyPI — skipping openvino." >&2
  echo "         Use an OpenShift AI workbench with Python 3.11/3.12, or set PYTHON=/path/to/python3.12" >&2
  echo "         The ONNX lifecycle demo does not require OpenVINO." >&2
fi

echo "Done."
