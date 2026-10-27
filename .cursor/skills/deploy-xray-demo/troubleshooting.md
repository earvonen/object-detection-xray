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
| Connection empty / no `AWS_*` in pod | `opendatahub.io/connections` not set or workbench not restarted | Set annotation to Connection Secret name; stop/start Notebook |
| Create workbench grayed out | ImageStream missing GPU recommend annotations | `bash openshift/workbench/annotate-imagestream.sh` |

## Useful probes

```bash
oc get knativeserving -n knative-serving
oc get mlflow -A
oc get modelregistry -A
oc get servingruntime,inferenceservice,ksvc -n object-detection-xray
oc get pods -A -o json | # filter nvidia.com/gpu requests
oc get rolebinding -n rhoai-model-registries | rg xray
```

## URLs (cluster-specific)

Discover, do not hardcode forever:

```bash
oc get mlflow -A -o jsonpath='{range .items[*]}{.status.url}{"\n"}{end}'
oc get route -n rhoai-model-registries -o name   # *-https REST
oc get inferenceservice -n object-detection-xray -o jsonpath='{.items[0].status.url}{"\n"}'
```
