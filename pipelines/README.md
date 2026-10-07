# Promote / deploy / canary pipeline

Resolves **OpenShift AI Model Registry** `stage=prod` for `xray-detector` and updates the KServe `InferenceService`.

## Steps

1. **ResolveProd** — find version with custom property `stage=prod`
2. **DeployCanary** — patch InferenceService storage + `canaryTrafficPercent` (default 10)
3. **Validate** — optional HTTP smoke check
4. **PromoteOrRollback** — `leave-canary` | `promote` (100%) | `rollback` (`canaryTrafficPercent: 0`)

## Run from a workbench (CLI)

```bash
export MODEL_REGISTRY_URL=http://...:8080
export KSERVE_NAMESPACE=<project>
export INFERENCE_SERVICE_NAME=xray-detector
# oc login already done in the workbench / with a token

python pipelines/promote_deploy_canary.py --action leave-canary
# after validation:
python pipelines/promote_deploy_canary.py --action promote
# or:
python pipelines/promote_deploy_canary.py --action rollback
```

## Compile for Data Science Pipelines

```bash
python pipelines/promote_deploy_canary.py --compile /tmp/promote_deploy_canary.yaml
```

Upload the YAML in the OpenShift AI dashboard (**Data Science Pipelines** → Import), then create a run with:

| Parameter | Example |
|-----------|---------|
| `model_registry_url` | in-cluster registry URL |
| `model_name` | `xray-detector` |
| `namespace` | your DS project |
| `service_name` | `xray-detector` |
| `canary_percent` | `10` |
| `action` | `leave-canary` then a second run with `promote` |
| `skip_validate` | `true` unless `validate_url` is set |

Override `PIPELINE_RUNTIME_IMAGE` if the default workbench image lacks `oc`.

## ServiceAccount permissions

The pipeline step SA needs:

- Access to the Model Registry API (token / network policy as configured by your admin)
- `get,patch` on `inferenceservices` in the target namespace

Example Role (adjust subject):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: xray-isvc-patcher
  namespace: REPLACE_ME_NAMESPACE
rules:
  - apiGroups: ["serving.kserve.io"]
    resources: ["inferenceservices"]
    verbs: ["get", "list", "patch", "update"]
```

## Path to full automation

Demo trigger: run this pipeline after notebook `04_promote_prod.ipynb`.

Production pattern: the same pipeline is invoked when production designation changes — e.g. webhook on Model Registry update, EventListener, or GitOps reconcile watching `stage=prod`. No custom controller is required for the demo.
