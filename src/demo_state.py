"""Persist demo selection across notebooks.

Jupyter kernels do not share os.environ. Notebooks 02→03→04 write/read
``.demo_state.json`` in the repo root so SELECTED_* values survive kernel switches.
Environment variables still win when set (workbench/pipeline injection).
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, Optional

STATE_FILE = ".demo_state.json"
KEYS = ("SELECTED_RUN_ID", "SELECTED_VERSION_ID")


def _repo_root(start: Optional[Path] = None) -> Path:
    here = (start or Path.cwd()).resolve()
    for candidate in [here, *here.parents]:
        if (candidate / "src").is_dir() and (candidate / "notebooks").is_dir():
            return candidate
    return here


def state_path(repo_root: Optional[Path] = None) -> Path:
    return _repo_root(repo_root) / STATE_FILE


def load_state(repo_root: Optional[Path] = None) -> dict[str, Any]:
    path = state_path(repo_root)
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def save_state(updates: dict[str, Any], repo_root: Optional[Path] = None) -> Path:
    path = state_path(repo_root)
    data = load_state(repo_root)
    for key, value in updates.items():
        if value is None:
            data.pop(key, None)
        else:
            data[key] = value
            os.environ[key] = str(value)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    return path


def get_value(key: str, default: Optional[str] = None, repo_root: Optional[Path] = None) -> Optional[str]:
    env = os.environ.get(key)
    if env:
        return env
    value = load_state(repo_root).get(key)
    if value is None or value == "":
        return default
    return str(value)


def require(key: str, hint: str, repo_root: Optional[Path] = None) -> str:
    value = get_value(key, repo_root=repo_root)
    if not value:
        raise SystemExit(f"Set {key} ({hint}). Env vars do not persist across notebooks; re-run the prior notebook.")
    os.environ[key] = value
    return value
