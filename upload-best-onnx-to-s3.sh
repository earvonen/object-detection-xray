#!/usr/bin/env bash
# Upload a YOLO ONNX export to S3-compatible object storage (AWS CLI).
# Connection settings use OpenShift AI data-connection style AWS_* variables.
#
# Required:
#   AWS_ACCESS_KEY_ID
#   AWS_SECRET_ACCESS_KEY
#   AWS_S3_ENDPOINT       — e.g. https://play.min.io or https://s3.<region>.amazonaws.com
#   AWS_DEFAULT_REGION
#   AWS_S3_BUCKET
#
# Optional:
#   LOCAL_ONNX           — default: runs-openshift/exp1/weights/best.onnx
#   S3_KEY               — default: object-detection/xray-detector/model.onnx
#   MLFLOW_RUN_ID        — if set and S3_KEY unset, key becomes
#                          object-detection/xray-detector/<run_id>/model.onnx
#
# Usage:
#   export AWS_ACCESS_KEY_ID=...
#   export AWS_SECRET_ACCESS_KEY=...
#   export AWS_S3_ENDPOINT=https://s3.us-east-1.amazonaws.com
#   export AWS_DEFAULT_REGION=us-east-1
#   export AWS_S3_BUCKET=my-bucket
#   ./upload-best-onnx-to-s3.sh

set -euo pipefail

: "${AWS_ACCESS_KEY_ID:?Set AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Set AWS_SECRET_ACCESS_KEY}"
: "${AWS_S3_ENDPOINT:?Set AWS_S3_ENDPOINT}"
: "${AWS_DEFAULT_REGION:?Set AWS_DEFAULT_REGION}"
: "${AWS_S3_BUCKET:?Set AWS_S3_BUCKET}"

LOCAL_ONNX="${LOCAL_ONNX:-runs-openshift/exp1/weights/best.onnx}"
PREFIX="${S3_KEY_PREFIX:-object-detection/xray-detector}"

if [[ -n "${S3_KEY:-}" ]]; then
  :
elif [[ -n "${MLFLOW_RUN_ID:-}" ]]; then
  S3_KEY="${PREFIX}/${MLFLOW_RUN_ID}/model.onnx"
else
  S3_KEY="${PREFIX}/model.onnx"
fi

S3_URI="s3://${AWS_S3_BUCKET}/${S3_KEY}"

if ! command -v aws >/dev/null 2>&1; then
  echo "error: aws CLI not found. Install via ./install-dependencies.sh" >&2
  exit 1
fi

if [[ ! -f "$LOCAL_ONNX" ]]; then
  echo "error: file not found: $LOCAL_ONNX" >&2
  exit 1
fi

echo "Uploading: $LOCAL_ONNX -> $S3_URI (endpoint: $AWS_S3_ENDPOINT)"
aws s3 cp "$LOCAL_ONNX" "$S3_URI" \
  --endpoint-url "$AWS_S3_ENDPOINT" \
  --region "$AWS_DEFAULT_REGION" \
  --content-type application/octet-stream
echo "Done."
echo "S3_URI=$S3_URI"
echo "S3_KEY=$S3_KEY"
