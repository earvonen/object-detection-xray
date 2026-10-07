"""MLflow helpers for experiment tracking (not production registry)."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Optional

import mlflow
from mlflow.tracking import MlflowClient

from .dataset_info import fingerprint_dataset, flatten_for_mlflow


def configure_tracking(experiment_name: Optional[str] = None) -> str:
    uri = os.environ.get("MLFLOW_TRACKING_URI")
    if uri:
        mlflow.set_tracking_uri(uri)
    token = os.environ.get("MLFLOW_TRACKING_TOKEN")
    if token:
        os.environ.setdefault("MLFLOW_TRACKING_TOKEN", token)
    name = experiment_name or os.environ.get("MLFLOW_EXPERIMENT_NAME", "xray-detector")
    mlflow.set_experiment(name)
    return name


def log_dataset_lineage(data_yaml: str | Path = "images/data.yaml") -> dict[str, Any]:
    info = fingerprint_dataset(data_yaml)
    params, tags = flatten_for_mlflow(info)
    mlflow.log_params(params)
    mlflow.set_tags(tags)
    return info


def log_yolo_metrics(metrics: Any) -> dict[str, float]:
    """Log Ultralytics validator/trainer metrics to the active MLflow run."""
    box = getattr(metrics, "box", None)
    recorded: dict[str, float] = {}
    mapping = {
        "metrics/mAP50": getattr(box, "map50", None) if box is not None else None,
        "metrics/mAP50-95": getattr(box, "map", None) if box is not None else None,
        "metrics/precision": getattr(box, "mp", None) if box is not None else None,
        "metrics/recall": getattr(box, "mr", None) if box is not None else None,
    }
    results_dict = getattr(metrics, "results_dict", None) or {}
    for key, value in results_dict.items():
        if isinstance(value, (int, float)):
            mapping[str(key)] = float(value)
    for key, value in mapping.items():
        if value is None:
            continue
        recorded[key] = float(value)
        mlflow.log_metric(key.replace("/", "_"), float(value))
    return recorded


def search_runs_table(experiment_name: Optional[str] = None, max_results: int = 50):
    configure_tracking(experiment_name)
    client = MlflowClient()
    exp_name = experiment_name or os.environ.get("MLFLOW_EXPERIMENT_NAME", "xray-detector")
    exp = client.get_experiment_by_name(exp_name)
    if exp is None:
        return []
    runs = client.search_runs(
        experiment_ids=[exp.experiment_id],
        order_by=["attributes.start_time DESC"],
        max_results=max_results,
    )
    rows = []
    for run in runs:
        m = run.data.metrics
        p = run.data.params
        rows.append(
            {
                "run_id": run.info.run_id,
                "status": run.info.status,
                "mAP50": m.get("metrics_mAP50", m.get("metrics/mAP50")),
                "mAP50-95": m.get("metrics_mAP50-95", m.get("metrics/mAP50-95")),
                "precision": m.get("metrics_precision"),
                "recall": m.get("metrics_recall"),
                "epochs": p.get("epochs"),
                "imgsz": p.get("imgsz"),
                "lr0": p.get("lr0"),
                "model": p.get("model"),
                "run_name": p.get("run_name") or run.info.run_name,
                "artifact_uri": run.info.artifact_uri,
            }
        )
    rows.sort(key=lambda r: (r.get("mAP50") is not None, r.get("mAP50") or 0.0), reverse=True)
    return rows


def pick_best_run(rows: list[dict[str, Any]], metric: str = "mAP50") -> Optional[dict[str, Any]]:
    scored = [r for r in rows if r.get(metric) is not None]
    if not scored:
        return None
    return max(scored, key=lambda r: float(r[metric]))
