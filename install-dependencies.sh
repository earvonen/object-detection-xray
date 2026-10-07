#!/usr/bin/env bash
# Install demo dependencies for train / track / register / serve workflows.
set -euo pipefail

pip install \
  "numpy>=2.0.0,<3" \
  "torch>=2.4" \
  ultralytics \
  "openvino>=2024.5" \
  onnx \
  onnxruntime \
  awscli \
  boto3 \
  mlflow \
  requests \
  pyyaml \
  pandas \
  "kfp>=2.0.0,<3" \
  kubernetes
