---
name: deploy-xray-demo
description: >-
  Deploy the object-detection-xray OpenShift AI lifecycle demo onto a cluster
  (MLflow → Model Registry → KServe canary). Use when installing on a new
  cluster, running deploy.sh, bootstrapping workbench/InferenceService, or
  when the user mentions OpenTLC, RHOAI demo deploy, or “set up the xray demo”.
---

# Deploy X-ray detection demo

Do **not** invent S3 (workspace rule `s3-ask-user`). Prefer **speed**: one parallel probe, fix platform gaps from recipes, then `deploy.sh` — do not serial-debug each component from scratch.

## Agent speed rules

1. Run **all** precondition probes in **one** `oc` shell with `required_permissions: ["all"]` (sandbox → `Forbidden` / false negatives).
2. If platform pieces are missing, run **`./openshift/ensure-platform.sh --wait`** (or `./deploy.sh --ensure-platform …`) — uses checked-in `openshift/mlflow.yaml` / `model-registry-xray.yaml`. Do not invent CRs from docs memory.
3. Prefer one shot: `./deploy.sh --ensure-platform --build-workbench --skip-isvc` when `.env`/`AWS_*` are good.
4. **Stale `.env` hosts kill demos.** Before discover/deploy, ensure `MODEL_REGISTRY_URL` / `MLFLOW_TRACKING_URI` (if set) match `oc whoami --show-server` hostname. OpenTLC sandboxes change every lab — rewrite hosts or `unset` those vars so discover uses live routes.
5. Do not poll MLflow for a `Ready` condition type that may never appear. Treat **Available=True** + `.status.url` + tracking pod Running as done.
6. Skip `--build-workbench` only if ImageStream `xray-workbench:latest` already exists in the demo namespace **and** user wants a fast re-apply.

## Preconditions (one probe)

```bash
oc whoami && oc whoami --show-server
oc get dsc default-dsc -o jsonpath='kserve={.spec.components.kserve.managementState} mlflowop={.spec.components.mlflowoperator.managementState}{"\n"}'
oc get knativeserving -n knative-serving
oc get mlflow -A -o wide 2>/dev/null; oc api-resources | rg -i '^mlflows'
oc get mr -n rhoai-model-registries 2>/dev/null; oc get role registry-user-xray-model-registry -n rhoai-model-registries 2>/dev/null
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name} gpu={.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
# .env: AWS_* present; MODEL_REGISTRY_URL/MLFLOW hosts vs current API server host
```

| Need | Ready when | Fix |
|------|------------|-----|
| `oc` login | server + user print | login |
| KServe Managed | DSC `kserve=Managed` | out of scope (cluster install) |
| KnativeServing | Ready True | `oc apply -f openshift/knative-serving.yaml` |
| MLflow | `oc get mlflow` has URL; Available | [platform-bootstrap.md](platform-bootstrap.md) |
| MR instance `xray-model-registry` | Available + Role `registry-user-xray-model-registry` | [platform-bootstrap.md](platform-bootstrap.md) — component Managed ≠ instance |
| GPU | allocatable `nvidia.com/gpu>=1` | free consumers if needed |
| S3 | `.env` or Connection / user `AWS_*` | ask user — never MinIO |

`default-modelregistry` (components.platform) only means the **operator** is on. Demo needs **`mr/xray-model-registry`** in `rhoai-model-registries` and route `xray-model-registry-https`.

## Bootstrap checklist

```
- [ ] Parallel probe; fix platform gaps (platform-bootstrap.md) if needed
- [ ] .env hosts match this cluster; AWS_* set
- [ ] ./deploy.sh --build-workbench --skip-isvc
- [ ] Fix ConfigMap if discover inherited stale MODEL_REGISTRY_URL; --restart
- [ ] Workbench 2/2 Running; mlflow-instance=mlflow annotation
- [ ] notebooks/00_seed_baseline.ipynb  # before audience
- [ ] ./openshift/discover-demo-env.sh --restart   # fills INFERENCE_* when ISVC Ready
- [ ] Live demo: notebooks 01→05
```

## Agent: discover env into the workbench

```bash
# Prefer live discovery when switching clusters:
unset MODEL_REGISTRY_URL MLFLOW_TRACKING_URI INFERENCE_ENDPOINT
# Or source .env only after hosts were rewritten to this cluster
./openshift/discover-demo-env.sh --restart
```

`discover-demo-env.sh` **keeps** an already-set `MODEL_REGISTRY_URL` — stale exports win over routes. Always verify the ConfigMap host matches `oc get route xray-model-registry-https -n rhoai-model-registries`.

| Var | Source |
|-----|--------|
| `MODEL_REGISTRY_URL` | Route `xray-model-registry-https` in `rhoai-model-registries` |
| `MODEL_REGISTRY_VERIFY_SSL` | default `false` (lab) |
| `INFERENCE_ENDPOINT` | ISVC `status.components.predictor.url` (when Ready) |
| `INFERENCE_ENDPOINT_LATEST` / `_PREV` | ISVC traffic tag URLs (canary) |
| names / prefix / STORAGE_KEY | defaults / deploy |

**MLflow:** Notebook annotation `opendatahub.io/mlflow-instance=mlflow` only — do not put `MLFLOW_TRACKING_URI` in the ConfigMap.

**S3:** Connection Secret only.

## Commands (repo root)

```bash
set -a && source .env && set +a   # after host rewrite if needed

./deploy.sh --ensure-platform --build-workbench --skip-isvc
# Platform-only: ./openshift/ensure-platform.sh --wait

# After notebook 00 / ISVC Ready:
./openshift/discover-demo-env.sh --restart
```

## Auth gotchas (do not re-debug)

**MLflow:** annotation injects URI + `kubernetes-namespaced` auth. Bare public URI → `UNAUTHENTICATED`. Ultralytics: `settings.update({"mlflow": False})`.

**Model Registry:** kube-rbac-proxy; `openshift/rbac-workbench-model-registry.yaml` (own RoleBinding). SA token if `MODEL_REGISTRY_TOKEN` unset.

**Selection handoff:** `.demo_state.json` across notebooks 02–04.

**Workbench RAM:** `DEMO_BATCH=8`, `DEMO_WORKERS=2` for 16Gi.

## InferenceService timing

Notebook **00** seeds `…/baseline` + ISVC before the live demo. Canary after 04 must change `storage.path`. OVMS needs `{prefix}/1/model.onnx`. Smoke-test **predictor** URL, not `status.url`. See [troubleshooting.md](troubleshooting.md).
