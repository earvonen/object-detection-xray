"""Dataset fingerprint helpers for MLflow lineage."""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATA_YAML = REPO_ROOT / "images" / "data.yaml"


def _count_images(split_dir: Path) -> int:
    if not split_dir.is_dir():
        return 0
    return sum(1 for p in split_dir.iterdir() if p.suffix.lower() in {".jpg", ".jpeg", ".png", ".bmp", ".webp"})


def fingerprint_dataset(data_yaml: Path | str = DEFAULT_DATA_YAML) -> dict[str, Any]:
    """Return traceable dataset metadata suitable for MLflow params/tags."""
    path = Path(data_yaml)
    text = path.read_text(encoding="utf-8")
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    cfg = yaml.safe_load(text) or {}

    base = path.parent
    train_rel = cfg.get("train", "train/images")
    val_rel = cfg.get("val", "valid/images")
    test_rel = cfg.get("test", "test/images")

    roboflow = cfg.get("roboflow") or {}
    info: dict[str, Any] = {
        "data_yaml": str(path.relative_to(REPO_ROOT)) if path.is_relative_to(REPO_ROOT) else str(path),
        "data_yaml_sha256": digest,
        "nc": cfg.get("nc"),
        "names": cfg.get("names"),
        "train_images": _count_images(base / train_rel),
        "val_images": _count_images(base / val_rel),
        "test_images": _count_images(base / test_rel),
        "roboflow_workspace": roboflow.get("workspace"),
        "roboflow_project": roboflow.get("project"),
        "roboflow_version": roboflow.get("version"),
        "roboflow_url": roboflow.get("url"),
        "dataset_license": roboflow.get("license"),
    }
    return info


def flatten_for_mlflow(info: dict[str, Any], prefix: str = "dataset") -> tuple[dict[str, str], dict[str, str]]:
    """Split fingerprint into MLflow params and tags (string values only)."""
    params: dict[str, str] = {}
    tags: dict[str, str] = {}
    for key, value in info.items():
        if value is None:
            continue
        if key == "names":
            tags[f"{prefix}.names"] = ",".join(str(x) for x in value)
            continue
        rendered = str(value)
        if key.endswith("_url") or key.endswith("sha256") or key in {"data_yaml"}:
            tags[f"{prefix}.{key}"] = rendered
        else:
            params[f"{prefix}.{key}"] = rendered
    return params, tags
