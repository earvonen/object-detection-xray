---
name: reset-xray-demo
description: >-
  Reset the object-detection-xray demo environment (MLflow runs/experiments,
  Model Registry stage reset, delete project namespace and MR RoleBinding). Use
  when the user wants to start fresh, tear down the demo, wipe demo state, or
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

1. Runs `openshift/reset-mlflow-registry.sh` — deletes MLflow runs, renames experiments to `*-archived-reset`, soft-deletes them (so `xray-detector` can be recreated); for Model Registry, keeps/restores `xray-detector` as **LIVE** and clears `stage=prod` on versions. **Do not archive** — the API has no hard DELETE (405), and ARCHIVED hides the model in the UI while notebooks still attach versions under it.
2. Deletes RoleBinding `xray-workbench-model-registry` in `rhoai-model-registries`.
3. Deletes Namespace `object-detection-xray`.
4. Removes local `.demo_state.json` if present.

4. Report what succeeded / failed. Old Model Registry versions remain visible under the LIVE model (API cannot delete them); only `stage=prod` is cleared so the next promote cycle is clean.

5. Optional next step for the user: re-deploy via skill `deploy-xray-demo` (`source .env` then `./deploy.sh --build-workbench --skip-isvc`).

## Do not

- Archive the registered model (hides UI; notebooks still use that model id)
- Delete `KnativeServing` / Serverless operator
- Stand up or wipe S3 unless the user explicitly asks
- Skip the `--yes` flag when running as an agent (avoid hanging on `read`)

## Partial resets

| Goal | Command |
|------|---------|
| Only MLflow + Model Registry data | `./openshift/reset-mlflow-registry.sh` |
| Only namespace + RoleBinding | `./openshift/teardown-demo.sh` (interactive) |
| Full reset | `./openshift/reset-demo.sh --yes` |
