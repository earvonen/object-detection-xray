# Deploy troubleshooting

| Symptom | Cause | Fix |
|---------|--------|-----|
| `ServerlessModeRejected` / Knative Services not available | Serverless operator installed but no `KnativeServing` CR | `oc apply -f openshift/knative-serving.yaml`; wait Ready; recreate ISVC; restart `kserve-controller-manager` / `odh-model-controller` if still cached |
| `no runtime found … model type: {onnx}` | No ServingRuntime / onnx not autoSelect | `oc apply -f openshift/servingruntime-ovms.yaml`; set `spec.predictor.model.runtime: kserve-ovms` |
| ISVC Pending / workbench `Insufficient nvidia.com/gpu` | Single GPU held by another pod | Find GPU consumers cluster-wide; undeploy e.g. leftover Llama ISVC |
| MLflow `Missing Authorization header` | No K8s auth | Annotate Notebook `opendatahub.io/mlflow-instance=mlflow`, stop/start workbench |
| MLflow only one run / split experiments | Ultralytics `mlflow: true` using `project=` as experiment | `settings.update({"mlflow": False})` in notebook 01 |
| Notebook 03 `Set SELECTED_RUN_ID` | Env not shared across kernels | Re-run 02 selection (writes `.demo_state.json`); pull `src/demo_state.py` |
| Model Registry `401 Unauthorized` | No Bearer / stale client | Ensure MR RoleBinding for workbench SA; restart kernel; pull updated `registry_client.py` |
| Model Registry `403 Forbidden` | SA lacks `get services/<registry>` | Apply `openshift/rbac-workbench-model-registry.yaml` (separate RB, not operator binding) |
| Connection empty / no `AWS_*` in pod | `opendatahub.io/connections` not set or workbench not restarted | Set annotation to `namespace/secret-name` (webhook rejects bare secret name); stop/start Notebook |
| Notebook admission: invalid secret reference format | Connection annotation missing namespace | Use `object-detection-xray/aws-connection-xray-models` |
| Create workbench grayed out | ImageStream missing GPU recommend annotations | `bash openshift/workbench/annotate-imagestream.sh` |
| ISVC `Ready=True` but `/v2/models/xray-detector` → version/name not found | OVMS needs numeric version dir; flat `model.onnx` at repo root → “No version found for model in path: /mnt/models” | S3 layout must be `{STORAGE_PATH}/1/model.onnx`. `src/s3_utils.versioned_key` uploads that. For older flat uploads: copy object to `…/<run_id>/1/model.onnx`, delete predictor pod so storage-initializer re-pulls. Confirm: `oc exec … -c kserve-container -- ls -laR /mnt/models` shows `/mnt/models/1/model.onnx` and logs say version AVAILABLE |
| External `status.url` (often `http://…`) returns OpenShift HTML **503** | Route / gateway mismatch; ISVC status URL is not always the working public path | Use **predictor** URL (HTTPS): `oc get isvc xray-detector -n object-detection-xray -o jsonpath='{.status.components.predictor.url}'` then `…/v2/models/xray-detector/infer`. Ready=True ≠ model loaded — check OVMS logs first |
| `run-promote-deploy-canary.sh` fails on `oc patch inferenceservice` (exit 1 / Forbidden) | Workbench SA lacked ISVC patch RBAC (only pipeline SA was bound) | `oc apply -f openshift/rbac-workbench-isvc-patcher.yaml` (cluster-admin). Pull updated `src/` so `storage_path` strips `/model.onnx` before patch |
| Canary patches `storage.path` ending in `model.onnx` | MR artifact stored object key, not OVMS repo root | `resolve_prod` now normalizes via `_ovms_storage_path`; re-run promote after pulling `registry_client.py` |
| Canary 90/10 but `latest` and `prev` are the **same** revision / only one pod | ISVC already served the prod `storage.path` (applied candidate before canary) | `./openshift/ensure-baseline-isvc.sh --force` then canary again with a **different** prod path; script now fails fast if paths match |
| `ensure-baseline-isvc.sh` cannot seed | No ONNX in bucket yet | Run notebook 03 first (uploads `…/<run_id>/1/model.onnx`), then re-run ensure |

## Useful probes

```bash
oc get knativeserving -n knative-serving
oc get mlflow -A
oc get modelregistry -A
oc get servingruntime,inferenceservice,ksvc -n object-detection-xray
oc get pods -A -o json | # filter nvidia.com/gpu requests
oc get rolebinding -n rhoai-model-registries | rg xray
# OVMS actually loaded?
oc logs -n object-detection-xray -l serving.kserve.io/inferenceservice=xray-detector -c kserve-container --tail=40
oc exec -n object-detection-xray deploy/$(oc get deploy -n object-detection-xray -o name | rg predictor | head -1) \
  -c kserve-container -- ls -laR /mnt/models
```

## Smoke-test infer (after ISVC Ready + model AVAILABLE)

```bash
PRED=$(oc get inferenceservice xray-detector -n object-detection-xray \
  -o jsonpath='{.status.components.predictor.url}')
# Prefer $PRED (HTTPS predictor), not status.url, for /v2/.../infer
# Payload: FP32 NCHW [1,3,640,640] input name "images" (see notebooks/05_infer_served.ipynb)
# Expect HTTP 200 and output0 shape [1,9,8400] for this YOLO ONNX
```

## URLs (cluster-specific)

Discover, do not hardcode forever:

```bash
oc get mlflow -A -o jsonpath='{range .items[*]}{.status.url}{"\n"}{end}'
oc get route -n rhoai-model-registries -o name   # *-https REST
oc get inferenceservice xray-detector -n object-detection-xray \
  -o jsonpath='status={.status.url}{"\n"}predictor={.status.components.predictor.url}{"\n"}'
```
