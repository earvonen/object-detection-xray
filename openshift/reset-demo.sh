#!/usr/bin/env bash
# Full demo reset: MLflow + Model Registry data, then namespace + MR RoleBinding.
# Does NOT delete KnativeServing or S3 objects (user handles S3).
#
# Usage:
#   ./openshift/reset-demo.sh           # interactive confirm
#   ./openshift/reset-demo.sh --yes     # no prompt (agents / CI)
#
# Implementation: delegates to teardown-demo.sh (which now wipes MLflow runs).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/teardown-demo.sh" "$@"
