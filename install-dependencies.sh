#!/usr/bin/env bash
# Install demo dependencies for train / track / register / serve workflows.
#
# Prefer the OpenShift AI workbench image:
#   Jupyter | Minimal | CUDA | Python 3.12
# OpenVINO / awscli are optional; failures there do not block the ONNX lifecycle demo.
set -euo pipefail

PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "error: $PYTHON not found" >&2
  exit 1
fi

PY_VER="$("$PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
echo "Using $($PYTHON -c 'import sys; print(sys.executable)') (Python ${PY_VER})"

# Core packages required for the MLflow → Model Registry → ONNX/KServe demo.
# S3 uploads in notebooks use boto3 (not the AWS CLI).
"$PYTHON" -m pip install \
  "numpy>=2.0.0,<3" \
  "torch>=2.4" \
  ultralytics \
  onnx \
  onnxruntime \
  boto3 \
  mlflow \
  requests \
  pyyaml \
  pandas \
  "kfp>=2.0.0,<3"

# Optional: AWS CLI for upload-best-onnx-to-s3.sh. Often unavailable in locked-down
# workbench pip indexes; notebooks/03 use boto3 instead.
if "$PYTHON" -m pip install awscli; then
  echo "awscli installed."
else
  echo "warning: awscli not installed (use notebooks/03 boto3 upload, or install awscli another way)." >&2
fi

# OpenVINO is only needed for optional IR export in export.ipynb / legacy paths.
if "$PYTHON" -c 'import sys; raise SystemExit(0 if sys.version_info < (3, 13) else 1)'; then
  if "$PYTHON" -m pip install "openvino>=2024.5"; then
    echo "OpenVINO installed."
  else
    echo "warning: OpenVINO install failed; ONNX/KServe demo still works. IR export in export.ipynb will not." >&2
  fi
else
  echo "warning: Python ${PY_VER} has no OpenVINO wheels on PyPI — skipping openvino." >&2
  echo "         Use Jupyter | Minimal | CUDA | Python 3.12 on OpenShift AI for full deps." >&2
fi

echo "Done."
