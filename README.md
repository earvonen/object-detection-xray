# X-ray object detection (OpenShift AI demo)

This repository is a compact demo for **Red Hat OpenShift AI**: train a small object detector on thousands of X-ray style scans of baggage or containers, where some images contain **prohibited items** and are annotated with bounding boxes.

The workflow is notebook-driven: train with [Ultralytics](https://docs.ultralytics.com/) YOLO, run quick inference, then optionally export the best weights for **ONNX** and **OpenVINO** for edge or CPU-oriented deployment stories.

## What is in the dataset?

- **Source**: [Roboflow Universe — X-ray baggage detection (prohibited items)](https://universe.roboflow.com/malek-mhnrl/x-ray-baggage-detection/dataset/1), exported in **YOLO** format (CC BY 4.0). See `images/README.roboflow.txt` and `images/README.dataset.txt` for export metadata.
- **Layout** (under `images/`): `train/`, `valid/`, and `test/` each contain `images/` and `labels/` (YOLO `.txt` per image: `class cx cy w h` in normalized coordinates).
- **Task**: **5-class object detection** (`nc: 5` in `images/data.yaml`). Class names in the YAML are numeric placeholders (`0`–`4`); the Roboflow project page describes the semantic item categories.

## Repository layout

| Path | Purpose |
|------|---------|
| `train.ipynb` | Train `yolov8n.pt` on `images/data.yaml`, writing runs to `runs-openshift/exp1/` (`project=runs-openshift`, `name=exp1`). |
| `test.ipynb` | Load `runs-openshift/exp1/weights/best.pt` and run detection on `knife.jpg` (example single-image inference). |
| `export.ipynb` | Export `best.pt` to **ONNX**, then convert toward **OpenVINO IR** via `openvino.tools.mo.convert_model` (legacy MO API; see notebook output for OpenVINO migration notes). |
| `install-dependencies.sh` | Example `pip install` line for training, export, and OpenVINO tooling. |
| `images/data.yaml` | YOLO dataset config: paths are **relative to this file’s directory** (`images/`). |
| `runs-openshift/exp1/` | Training outputs (e.g. `args.yaml`, `results.csv`, weights when you train). The repo may ship only partial artifacts; run `train.ipynb` to regenerate `weights/`. |
| `yolov8n.pt` / `yolo11n.pt` | Optional local base checkpoints; Ultralytics can also download weights on first use. |

## Prerequisites

- Python **3.12** (matches notebook metadata used in this project).
- **GPU** recommended for training (the checked-in logs reference CUDA on an A100-class GPU); CPU is possible but slow.
- Dependencies (see `install-dependencies.sh`):

```bash
pip install "numpy>=2.0.0,<3" "torch>=2.4" ultralytics "openvino>=2024.5" onnx onnxruntime
```

## Running the demo

1. **Install** the packages above in your OpenShift AI workbench or local environment.
2. Open **`train.ipynb`** and execute the training cell. This calls `YOLO("yolov8n.pt").train(...)` with `data="images/data.yaml"`, `epochs=50`, `imgsz=640`, and logs under `runs-openshift/exp1/`.
3. Open **`test.ipynb`** to run inference on `knife.jpg` using `runs-openshift/exp1/weights/best.pt`.
4. Optionally run **`export.ipynb`** after training to produce ONNX and OpenVINO-oriented artifacts under `runs-openshift/exp1/weights/`.

## Notes for presenters

- **Narrative**: screening / contraband detection is a relatable use case for regulated or security-adjacent ML; emphasize responsible use, dataset licensing, and that metrics on a public demo set do not imply production readiness.
- **OpenShift AI**: mount or clone this repo into a workbench, use a GPU-enabled notebook image, and keep run artifacts on persistent storage (`runs-openshift/`).
- **Class names**: replace the placeholder names in `images/data.yaml` with human-readable labels if you publish plots or a UI, as long as they stay aligned with the integer IDs in the label files.

## License

Dataset terms are described in the Roboflow export files under `images/` (CC BY 4.0 for the linked Roboflow version). Add or adjust a top-level license for your own code and artifacts if you distribute them beyond this demo.
