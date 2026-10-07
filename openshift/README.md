# KServe manifests

Serverless (Knative) InferenceService examples for the X-ray detector lifecycle demo.

## Prerequisites

- OpenShift AI **single-model serving** enabled
- Deployment mode **Advanced / Serverless** (required for `canaryTrafficPercent`)
- S3-compatible Connection in the data science project (or `storageUri` with cluster credentials)
- Platform ONNX / OpenVINO runtime available for `modelFormat.name: onnx`

## Apply baseline

1. Copy `inferenceservice-xray-detector.yaml` and replace:
   - `REPLACE_ME_NAMESPACE`
   - `REPLACE_ME_STORAGE_URI` (directory or object prefix containing the ONNX model)
2. Optionally switch to Connection-based `storage.key` / `storage.path` (commented in the file).
3. Apply:

```bash
oc apply -f openshift/inferenceservice-xray-detector.yaml
oc get inferenceservice xray-detector -n <namespace>
```

## Canary / promote / rollback

| File | Effect |
|------|--------|
| `inferenceservice-canary-patch.yaml` | New URI + 10% canary |
| `inferenceservice-promote-100.yaml` | 100% to new revision (no canary field) |
| `inferenceservice-rollback.yaml` | `canaryTrafficPercent: 0` |

Prefer the Data Science Pipeline (`pipelines/promote_deploy_canary.py`), which patches the live InferenceService after resolving `stage=prod` from the OpenShift AI Model Registry.

Tag routing annotation `serving.kserve.io/enable-tag-routing: "true"` exposes `latest-` / `prev-` routes for explicit canary validation.
