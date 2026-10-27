---
name: reset-xray-demo
description: >-
  Reset the object-detection-xray demo environment (MLflow runs/experiments,
  Model Registry archive, delete project namespace and MR RoleBinding). Use when
  the user wants to start fresh, tear down the demo, wipe demo state, or
  re-install cleanly on the same cluster.
---

# Reset X-ray demo environment

## Do this

1. Confirm `oc` is logged into the target cluster (`oc whoami --show-server`).
2. Remind the user: **S3 is not cleared** (they handle the bucket); **KnativeServing stays**.
3. From the repo root, run the orchestrator **non-interactively**:

```bash
./openshift/reset-demo.sh --yes
```

That script:

1. Runs `openshift/reset-mlflow-registry.sh` — deletes MLflow runs, renames experiments to `*-archived-reset`, soft-deletes them (so `xray-detector` can be recreated); archives Model Registry `xray-detector` versions/model (API hard-delete often returns 405).
2. Deletes RoleBinding `xray-workbench-model-registry` in `rhoai-model-registries`.
3. Deletes Namespace `object-detection-xray`.
4. Removes local `.demo_state.json` if present.

4. Report what succeeded / failed. If Model Registry remains as `ARCHIVED` under the same name, note that notebook 03 `get_or_create` may reuse it — suggest fixing the client to skip `ARCHIVED` or using a new `REGISTERED_MODEL_NAME` if that blocks a clean story.

5. Optional next step for the user: re-deploy via skill `deploy-xray-demo` (`source .env` then `./deploy.sh --build-workbench --skip-isvc`).

## Do not

- Delete `KnativeServing` / Serverless operator
- Stand up or wipe S3 unless the user explicitly asks
- Skip the `--yes` flag when running as an agent (avoid hanging on `read`)

## Partial resets

| Goal | Command |
|------|---------|
| Only MLflow + Model Registry data | `./openshift/reset-mlflow-registry.sh` |
| Only namespace + RoleBinding | `./openshift/teardown-demo.sh` (interactive) |
| Full reset | `./openshift/reset-demo.sh --yes` |
