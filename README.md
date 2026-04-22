# X-ray prohibited-item detection (OpenShift AI demo)

This repository is a compact **OpenShift AI** demo that trains a small object detector on thousands of **X-ray scans** (baggage / container-style imagery) where **prohibited or illicit items** are marked with bounding boxes. The goal is to show an end-to-end ML workflow on the platform: notebook-based training, quick inference, and export toward deployment runtimes.

## What it does

- **Task:** Multi-class **object detection** (YOLO format: one `.txt` label file per image with normalized box coordinates).
- **Model:** [Ultralytics](https://docs.ultralytics.com/) **YOLOv8n** (nano), fine-tuned from COCO pretrained weights.
- **Data:** A YOLOv8 export of an X-ray **prohibited items** dataset (see [Dataset](#dataset)). The export defines **5 classes** (indexed `0`–`4` in `images/data.yaml`; human-readable names live in the upstream Roboflow project).
- **Artifacts:** Training writes to `runs-openshift/exp1/` (weights, curves, `args.yaml`). The demo name matches typical **OpenShift AI Workbench** paths (`/opt/app-root/src/...` in the checked-in notebook outputs).

## Repository layout

| Path | Purpose |
|------|--------|
| `images/` | Dataset root: `train/`, `valid/`, `test/` splits (`images/` + `labels/` per split), `data.yaml`, Roboflow readme files. |
| `train.ipynb` | Trains YOLOv8n for 50 epochs on `images/data.yaml`, `imgsz=640`, project `runs-openshift`, run name `exp1`. |
| `test.ipynb` | Loads `runs-openshift/exp1/weights/best.pt` and runs detection on `knife.jpg`. |
| `export.ipynb` | Exports `best.pt` to **ONNX**, then converts toward **OpenVINO** IR (FP16) for edge/server inference stacks. |
| `install-dependencies.sh` | `pip install` line for NumPy, PyTorch, Ultralytics, OpenVINO, ONNX, ONNX Runtime. |
| `yolov8n.pt`, `yolo11n.pt` | Base checkpoints used or downloaded by Ultralytics during train/AMP checks. |
| `runs-openshift/exp1/` | Example training run (weights, metrics, plots). |
| `Containerfile` | Builds a **modelcar**-style image: copies `best.pt` and `images/data.yaml` into `/models` for OCI-based serving. |
| `pipelines/train_and_modelcar.pipeline` | **Elyra** pipeline (KFP): train → **Kaniko** build-and-push (same pattern as Tekton `task-build-push`). |
| `pipelines/kaniko_build_push.ipynb` | Pipeline step: ServiceAccount token → `config.json`, then **Kaniko** `--destination` push (non-privileged). |
| `pipelines/elyra-kaniko-runtime.Containerfile` | Optional image recipe: **Python + `/kaniko/executor`** for Elyra. Stages are ordered so **OpenShift Build** (which may rewrite the first `FROM`) still leaves the final image on **UBI Python**, not the distroless Kaniko-only image. |

## Elyra pipeline (OpenShift AI Data Science Pipelines)

Open `pipelines/train_and_modelcar.pipeline` in the **Elyra Pipeline Editor** (after cloning this repo into a workbench). The flow matches a two-step Tekton-style job:

1. **Train YOLO** — runs `train.ipynb` (runtime image is set in the pipeline file; override in Elyra if needed).
2. **Kaniko build and push** — runs `pipelines/kaniko_build_push.ipynb`, mirroring the Tekton **Kaniko** task pattern (e.g. `task-build-push.yaml`: prepare registry auth from the **pod ServiceAccount token** — `openshift:<token>` in `config.json` for `REGISTRY_HOST` — then run the Kaniko executor with `--dockerfile`, `--context=dir://<repo root>`, `--destination=<IMAGE>`, `--skip-tls-verify`, and `DOCKER_CONFIG` pointing at that config; executor version **v1.23.2** in the reference Task).

Grant the **pipeline step ServiceAccount** the **`system:image-pusher`** role on the target namespace (same expectation as the Tekton task comments).

### Placeholders to replace before running

| Placeholder | Where | Purpose |
|-------------|--------|--------|
| `REPLACE_ME_KANIKO_ELYRA_RUNTIME_IMAGE` | Kaniko node → *Runtime Image* | Image that has **Python** (for Elyra/papermill) **and** `/kaniko/executor`. Build `pipelines/elyra-kaniko-runtime.Containerfile` or use your own equivalent. |
| `REPLACE_ME_DSP_OR_KFP_RUNTIME_CONFIG` | Pipeline properties → *Runtime configuration* | Your **Data Science Pipelines** / Kubeflow Pipelines metadata entry in Elyra. |
| `REPLACE_ME_NAMESPACE` / `REPLACE_ME_IMAGESTREAM_NAME` | Kaniko node → `IMAGE` env var | Full destination reference, e.g. `image-registry.openshift-image-registry.svc:5000/<namespace>/<imagestream>:<tag>`. |

Optional env vars on the Kaniko node (defaults match the Tekton task): `REGISTRY_HOST` (default internal registry host:port), `CONTAINERFILE` (default `Containerfile`), `REPO_ROOT`, `KANIKO_EXECUTOR` (default `/kaniko/executor`).

The Kaniko notebook refuses to run while `IMAGE` still contains `REPLACE_ME_`.

**Data for training:** The train node declares no large file dependencies (to avoid packaging the whole `images/` tree). In production, mount object storage or a PVC that already contains the dataset, or add Elyra **File Dependencies** / pipeline parameters appropriate to your environment.

**Further reading:** [Build and deploy a ModelCar container in OpenShift AI](https://developers.redhat.com/articles/2025/01/30/build-and-deploy-modelcar-container-openshift-ai) (Red Hat Developer).

## Prerequisites

- Python **3.11+** or **3.12** (matches the checked-in notebook metadata).
- A **GPU** is recommended for training; CPU works but is slower.
- On **OpenShift AI**, create a workbench, clone this repo into the workbench’s source directory, and open the notebooks from the **repository root** so paths like `images/data.yaml` resolve correctly.

## Setup

From the repository root:

```bash
bash install-dependencies.sh
```

Or install the same packages manually:

```bash
pip install "numpy>=2.0.0,<3" "torch>=2.4" ultralytics "openvino>=2024.5" onnx onnxruntime
```

On Windows without Bash, run the `pip install` command in PowerShell.

## How to run the demo

1. **Train** — Open `train.ipynb` and execute the cell. This will:
   - Load `yolov8n.pt`
   - Train on `images/data.yaml` for **50 epochs**
   - Write results under `runs-openshift/exp1/`

2. **Infer** — After training (or using the bundled `best.pt`), run `test.ipynb` to score `knife.jpg`.

3. **Export** — Run `export.ipynb` to produce ONNX under `runs-openshift/exp1/weights/` and OpenVINO IR via `openvino.tools.mo.convert_model` (the notebook output notes OpenVINO’s migration from MO to OVC; newer OpenVINO versions may prefer `openvino.convert_model`).

## Dataset

- **Source:** [Roboflow Universe — X-ray baggage detection](https://universe.roboflow.com/malek-mhnrl/x-ray-baggage-detection) (also referenced in `images/data.yaml` and `images/README.roboflow.txt`).
- **License:** **CC BY 4.0** (see Roboflow export metadata).
- **Scale:** The Roboflow export notes on the order of **~8.8k images** with **prohibited-item** annotations in YOLOv8 layout; this clone includes the train/validation/test folders produced from that export.
- **Splits:** Training logs in the repo reference roughly **6k** training images and **~1.7k** validation images; a held-out **test** split is under `images/test/`.

The demo is for **education and platform illustration**; detection quality and class semantics depend on the upstream dataset and labels—not on-site physical security decisions.

## Tips

- To change the experiment name or avoid overwriting `exp1`, edit `name=` in `train.ipynb` or pass a different `--name` if you switch to CLI training.
- For CLI parity with the notebook:  
  `yolo detect train data=images/data.yaml model=yolov8n.pt epochs=50 imgsz=640 project=runs-openshift name=exp1`
- If you only need inference, you can skip training and point `YOLO()` at an existing `best.pt` in `runs-openshift/exp1/weights/`.
