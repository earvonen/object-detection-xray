#!/usr/bin/env bash
# Upload trained YOLO ONNX export to S3 (AWS CLI; install via install-dependencies.sh).
# All connection settings come from environment variables.
#
# Required:
#   S3_ACCESS_KEY   — access key id
#   S3_SECRET_KEY   — secret access key
#   S3_ENDPOINT     — API endpoint (e.g. https://play.min.io for MinIO, or
#                     https://s3.<region>.amazonaws.com for AWS)
#   S3_REGION       — region name (e.g. us-east-1)
#   S3_BUCKET       — bucket name
#
# Optional:
#   S3_KEY          — object key (default: models/best.onnx)
#   LOCAL_ONNX      — local file path (default: runs-openshift/exp1/weights/best.onnx)
#
# Usage:
#   export S3_ACCESS_KEY=...
#   export S3_SECRET_KEY=...
#   export S3_ENDPOINT=https://s3.us-east-1.amazonaws.com
#   export S3_REGION=us-east-1
#   export S3_BUCKET=my-bucket
#   ./upload-best-onnx-to-s3.sh

set -euo pipefail

S3_ACCESS_KEY="${S3_ACCESS_KEY:?Set S3_ACCESS_KEY}"
S3_SECRET_KEY="${S3_SECRET_KEY:?Set S3_SECRET_KEY}"
S3_ENDPOINT="${S3_ENDPOINT:?Set S3_ENDPOINT (e.g. https://s3.us-east-1.amazonaws.com or your MinIO URL)}"
S3_REGION="${S3_REGION:?Set S3_REGION}"
S3_BUCKET="${S3_BUCKET:?Set S3_BUCKET}"

LOCAL_ONNX="${LOCAL_ONNX:-runs-openshift/exp1/weights/best.onnx}"
S3_KEY="${S3_KEY:-models/best.onnx}"
S3_URI="s3://${S3_BUCKET}/${S3_KEY}"

export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
export AWS_DEFAULT_REGION="$S3_REGION"

if ! command -v aws >/dev/null 2>&1; then
  echo "error: aws CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2
  exit 1
fi

if [[ ! -f "$LOCAL_ONNX" ]]; then
  echo "error: file not found: $LOCAL_ONNX" >&2
  exit 1
fi

echo "Uploading: $LOCAL_ONNX -> $S3_URI (endpoint: $S3_ENDPOINT)"
aws s3 cp "$LOCAL_ONNX" "$S3_URI" \
  --endpoint-url "$S3_ENDPOINT" \
  --region "$S3_REGION" \
  --content-type application/octet-stream
echo "Done."
