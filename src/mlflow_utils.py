"""MLflow helpers for experiment tracking (not production registry)."""

from __future__ import annotations

import os
import re
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


def _safe_metric_key(key: str) -> str:
    """MLflow metric names: replace path separators; keep alphanumerics."""
    return re.sub(r"[^\w.\-/:]", "_", key.replace("/", "_"))


def _results_dict_from(metrics: Any) -> dict[str, Any]:
    """Normalize Ultralytics metrics object or plain results_dict."""
    if metrics is None:
        return {}
    if isinstance(metrics, dict):
        return metrics
    rd = getattr(metrics, "results_dict", None)
    if isinstance(rd, dict) and rd:
        return rd
    # DetMetrics / Metric containers expose .box
    out: dict[str, Any] = {}
    box = getattr(metrics, "box", None)
    if box is not None:
        for attr, key in (
            ("map50", "metrics/mAP50"),
            ("map", "metrics/mAP50-95"),
            ("mp", "metrics/precision"),
            ("mr", "metrics/recall"),
        ):
            val = getattr(box, attr, None)
            if isinstance(val, (int, float)):
                out[key] = float(val)
    return out


def _canonical_map_keys(key: str, value: float) -> dict[str, float]:
    """Map Ultralytics names like metrics/mAP50(B) onto stable demo keys."""
    compact = re.sub(r"[^a-z0-9]", "", key.lower())
    extras: dict[str, float] = {}
    # mAP50-95 / map5095 before plain mAP50
    if "map5095" in compact or "map50_95" in key.lower() or "map50-95" in key.lower():
        extras["mAP50-95"] = value
        extras["metrics_mAP50-95"] = value
    elif "map50" in compact:
        extras["mAP50"] = value
        extras["metrics_mAP50"] = value
    elif compact.endswith("mp") or "precision" in compact:
        extras["precision"] = value
    elif compact.endswith("mr") or "recall" in compact:
        extras["recall"] = value
    return extras


def log_yolo_metrics(metrics: Any) -> dict[str, float]:
    """Log Ultralytics validator/trainer metrics to the active MLflow run."""
    results_dict = _results_dict_from(metrics)
    recorded: dict[str, float] = {}

    for key, value in results_dict.items():
        if not isinstance(value, (int, float)):
            continue
        value_f = float(value)
        recorded[str(key)] = value_f
        mlflow.log_metric(_safe_metric_key(str(key)), value_f)
        for canon, canon_val in _canonical_map_keys(str(key), value_f).items():
            recorded[canon] = canon_val
            mlflow.log_metric(canon, canon_val)

    return recorded


def _lookup_metric(metrics: dict[str, Any], *names: str, contains: Optional[str] = None) -> Optional[float]:
    for name in names:
        if name in metrics and metrics[name] is not None:
            return float(metrics[name])
    if contains:
        needle = contains.lower()
        for key, value in metrics.items():
            if value is None:
                continue
            if needle in key.lower().replace(" ", ""):
                # Prefer non 50-95 when looking for map50
                if needle == "map50" and ("95" in key or "50-95" in key or "5095" in key.lower().replace("-", "").replace("_", "")):
                    continue
                try:
                    return float(value)
                except (TypeError, ValueError):
                    continue
    return None


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
                "mAP50": _lookup_metric(
                    m,
                    "mAP50",
                    "metrics_mAP50",
                    "metrics/mAP50",
                    "metrics_mAP50(B)",
                    "metrics_mAP50_B_",
                    contains="map50",
                ),
                "mAP50-95": _lookup_metric(
                    m,
                    "mAP50-95",
                    "metrics_mAP50-95",
                    "metrics/mAP50-95",
                    contains="map50-95",
                )
                or _lookup_metric(m, contains="map5095"),
                "precision": _lookup_metric(m, "precision", "metrics_precision", contains="precision"),
                "recall": _lookup_metric(m, "recall", "metrics_recall", contains="recall"),
                "epochs": p.get("epochs"),
                "imgsz": p.get("imgsz"),
                "lr0": p.get("lr0"),
                "model": p.get("model"),
                "run_name": p.get("run_name") or run.info.run_name,
                "artifact_uri": run.info.artifact_uri,
                "metric_keys": sorted(m.keys()),
            }
        )
    rows.sort(key=lambda r: (r.get("mAP50") is not None, r.get("mAP50") or 0.0), reverse=True)
    return rows


def pick_best_run(rows: list[dict[str, Any]], metric: str = "mAP50") -> Optional[dict[str, Any]]:
    scored = [r for r in rows if r.get(metric) is not None]
    if scored:
        return max(scored, key=lambda r: float(r[metric]))
    # Fallback: newest finished run (demo-friendly when metrics were not logged)
    finished = [r for r in rows if r.get("status") == "FINISHED"]
    return finished[0] if finished else (rows[0] if rows else None)
