"""OpenShift AI / Kubeflow Model Registry REST client (v1alpha3).

Production designation for this demo is the custom property ``stage=prod``
on a model version (not an MLflow Model Registry alias).
"""

from __future__ import annotations

import os
from typing import Any, Optional

import requests


class ModelRegistryError(RuntimeError):
    pass


class ModelRegistryClient:
    def __init__(
        self,
        base_url: Optional[str] = None,
        token: Optional[str] = None,
        verify_ssl: Optional[bool] = None,
        timeout: float = 60.0,
    ) -> None:
        self.base_url = (base_url or os.environ.get("MODEL_REGISTRY_URL", "")).rstrip("/")
        if not self.base_url:
            raise ModelRegistryError("MODEL_REGISTRY_URL is not set")
        self.token = token if token is not None else os.environ.get("MODEL_REGISTRY_TOKEN")
        if verify_ssl is None:
            verify_ssl = os.environ.get("MODEL_REGISTRY_VERIFY_SSL", "true").lower() not in {
                "0",
                "false",
                "no",
            }
        self.verify_ssl = verify_ssl
        self.timeout = timeout
        self.api = f"{self.base_url}/api/model_registry/v1alpha3"

    def _headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        return headers

    def _request(self, method: str, path: str, **kwargs: Any) -> Any:
        url = f"{self.api}{path}"
        resp = requests.request(
            method,
            url,
            headers=self._headers(),
            timeout=self.timeout,
            verify=self.verify_ssl,
            **kwargs,
        )
        if resp.status_code >= 400:
            raise ModelRegistryError(f"{method} {path} -> {resp.status_code}: {resp.text}")
        if resp.status_code == 204 or not resp.content:
            return None
        return resp.json()

    # --- registered models ---

    def list_registered_models(self, name: Optional[str] = None) -> list[dict[str, Any]]:
        params = {}
        if name:
            params["name"] = name
        data = self._request("GET", "/registered_models", params=params) or {}
        if isinstance(data, list):
            return data
        return data.get("items") or data.get("registeredModels") or []

    def get_registered_model_by_name(self, name: str) -> Optional[dict[str, Any]]:
        models = self.list_registered_models(name=name)
        for model in models:
            if model.get("name") == name:
                return model
        # Some servers ignore the name filter; scan all.
        if not models:
            models = self.list_registered_models()
        for model in models:
            if model.get("name") == name:
                return model
        return None

    def create_registered_model(
        self,
        name: str,
        description: str = "",
        owner: str = "",
        custom_properties: Optional[dict[str, Any]] = None,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {"name": name, "state": "LIVE"}
        if description:
            body["description"] = description
        if owner:
            body["owner"] = owner
        if custom_properties:
            body["customProperties"] = _to_custom_properties(custom_properties)
        return self._request("POST", "/registered_models", json=body)

    def get_or_create_registered_model(self, name: str, **kwargs: Any) -> dict[str, Any]:
        existing = self.get_registered_model_by_name(name)
        if existing:
            return existing
        return self.create_registered_model(name, **kwargs)

    # --- versions ---

    def list_model_versions(self, registered_model_id: str) -> list[dict[str, Any]]:
        data = self._request("GET", f"/registered_models/{registered_model_id}/versions") or {}
        if isinstance(data, list):
            return data
        return data.get("items") or data.get("modelVersions") or []

    def create_model_version(
        self,
        registered_model_id: str,
        name: str,
        description: str = "",
        author: str = "",
        custom_properties: Optional[dict[str, Any]] = None,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {
            "registeredModelId": str(registered_model_id),
            "name": name,
            "state": "LIVE",
        }
        if description:
            body["description"] = description
        if author:
            body["author"] = author
        if custom_properties:
            body["customProperties"] = _to_custom_properties(custom_properties)
        return self._request("POST", "/model_versions", json=body)

    def get_model_version(self, version_id: str) -> dict[str, Any]:
        return self._request("GET", f"/model_versions/{version_id}")

    def patch_model_version(
        self,
        version_id: str,
        custom_properties: Optional[dict[str, Any]] = None,
        description: Optional[str] = None,
        state: Optional[str] = None,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {}
        if custom_properties is not None:
            body["customProperties"] = _to_custom_properties(custom_properties)
        if description is not None:
            body["description"] = description
        if state is not None:
            body["state"] = state
        # Prefer PATCH; fall back to PUT-style update if needed.
        try:
            return self._request("PATCH", f"/model_versions/{version_id}", json=body)
        except ModelRegistryError:
            current = self.get_model_version(version_id)
            merged = {**current, **body}
            return self._request("PUT", f"/model_versions/{version_id}", json=merged)

    # --- artifacts ---

    def create_model_artifact(
        self,
        model_version_id: str,
        name: str,
        uri: str,
        model_format_name: str = "onnx",
        model_format_version: str = "1",
        storage_key: Optional[str] = None,
        storage_path: Optional[str] = None,
        custom_properties: Optional[dict[str, Any]] = None,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {
            "modelVersionId": str(model_version_id),
            "name": name,
            "uri": uri,
            "modelFormatName": model_format_name,
            "modelFormatVersion": model_format_version,
            "artifactType": "model-artifact",
            "state": "LIVE",
        }
        if storage_key:
            body["storageKey"] = storage_key
        if storage_path:
            body["storagePath"] = storage_path
        if custom_properties:
            body["customProperties"] = _to_custom_properties(custom_properties)
        return self._request("POST", f"/model_versions/{model_version_id}/artifacts", json=body)

    def list_model_artifacts(self, model_version_id: str) -> list[dict[str, Any]]:
        data = self._request("GET", f"/model_versions/{model_version_id}/artifacts") or {}
        if isinstance(data, list):
            return data
        return data.get("items") or data.get("artifacts") or data.get("modelArtifacts") or []

    # --- high-level demo operations ---

    def register_onnx_model(
        self,
        model_name: str,
        version_name: str,
        s3_uri: str,
        mlflow_run_id: str,
        metrics: Optional[dict[str, Any]] = None,
        storage_key: Optional[str] = None,
        storage_path: Optional[str] = None,
        description: str = "",
        author: str = "xray-demo",
    ) -> dict[str, Any]:
        """Register a curated ONNX artifact as a new Model Registry version."""
        registered = self.get_or_create_registered_model(
            model_name,
            description="X-ray baggage object detector (OpenShift AI lifecycle demo)",
        )
        props: dict[str, Any] = {
            "stage": "candidate",
            "mlflow_run_id": mlflow_run_id,
            "serving_format": "onnx",
        }
        if metrics:
            for key, value in metrics.items():
                props[f"metric.{key}"] = value

        version = self.create_model_version(
            registered_model_id=str(registered["id"]),
            name=version_name,
            description=description or f"Candidate from MLflow run {mlflow_run_id}",
            author=author,
            custom_properties=props,
        )
        path = storage_path or _path_from_s3_uri(s3_uri)
        artifact = self.create_model_artifact(
            model_version_id=str(version["id"]),
            name="model.onnx",
            uri=s3_uri,
            model_format_name="onnx",
            storage_key=storage_key or os.environ.get("STORAGE_KEY"),
            storage_path=path,
        )
        return {
            "registered_model": registered,
            "model_version": version,
            "artifact": artifact,
        }

    def find_prod_version(self, model_name: str) -> Optional[dict[str, Any]]:
        registered = self.get_registered_model_by_name(model_name)
        if not registered:
            return None
        for version in self.list_model_versions(str(registered["id"])):
            props = _from_custom_properties(version.get("customProperties") or {})
            if props.get("stage") == "prod":
                return version
        return None

    def resolve_prod(self, model_name: str) -> dict[str, Any]:
        """Return prod version + primary artifact URI/path for the pipeline."""
        registered = self.get_registered_model_by_name(model_name)
        if not registered:
            raise ModelRegistryError(f"Registered model not found: {model_name}")
        version = self.find_prod_version(model_name)
        if not version:
            raise ModelRegistryError(f"No version with stage=prod for model {model_name}")
        artifacts = self.list_model_artifacts(str(version["id"]))
        if not artifacts:
            raise ModelRegistryError(f"No artifacts on prod version {version.get('id')}")
        artifact = artifacts[0]
        props = _from_custom_properties(version.get("customProperties") or {})
        return {
            "registered_model_id": str(registered["id"]),
            "registered_model_name": model_name,
            "version_id": str(version["id"]),
            "version_name": version.get("name"),
            "uri": artifact.get("uri"),
            "storage_key": artifact.get("storageKey"),
            "storage_path": artifact.get("storagePath") or _path_from_s3_uri(artifact.get("uri") or ""),
            "mlflow_run_id": props.get("mlflow_run_id"),
            "custom_properties": props,
            "artifact": artifact,
            "model_version": version,
        }

    def promote_to_prod(self, model_name: str, version_id: str) -> dict[str, Any]:
        """Clear stage=prod on other versions, then set it on ``version_id``."""
        registered = self.get_registered_model_by_name(model_name)
        if not registered:
            raise ModelRegistryError(f"Registered model not found: {model_name}")

        cleared: list[str] = []
        for version in self.list_model_versions(str(registered["id"])):
            vid = str(version["id"])
            props = _from_custom_properties(version.get("customProperties") or {})
            if props.get("stage") == "prod" and vid != str(version_id):
                props["stage"] = "archived_prod"
                self.patch_model_version(vid, custom_properties=props)
                cleared.append(vid)

        target = self.get_model_version(str(version_id))
        props = _from_custom_properties(target.get("customProperties") or {})
        props["stage"] = "prod"
        updated = self.patch_model_version(str(version_id), custom_properties=props)
        return {"promoted_version": updated, "cleared_version_ids": cleared}


def _to_custom_properties(props: dict[str, Any]) -> dict[str, Any]:
    """Encode plain dict values as Model Registry typed customProperties."""
    encoded: dict[str, Any] = {}
    for key, value in props.items():
        if isinstance(value, bool):
            encoded[key] = {"metadataType": "MetadataBoolValue", "bool_value": value}
        elif isinstance(value, int) and not isinstance(value, bool):
            encoded[key] = {"metadataType": "MetadataIntValue", "int_value": str(value)}
        elif isinstance(value, float):
            encoded[key] = {"metadataType": "MetadataDoubleValue", "double_value": value}
        else:
            encoded[key] = {"metadataType": "MetadataStringValue", "string_value": str(value)}
    return encoded


def _from_custom_properties(props: dict[str, Any]) -> dict[str, Any]:
    decoded: dict[str, Any] = {}
    for key, value in props.items():
        if not isinstance(value, dict):
            decoded[key] = value
            continue
        if "string_value" in value:
            decoded[key] = value["string_value"]
        elif "double_value" in value:
            decoded[key] = value["double_value"]
        elif "int_value" in value:
            raw = value["int_value"]
            try:
                decoded[key] = int(raw)
            except (TypeError, ValueError):
                decoded[key] = raw
        elif "bool_value" in value:
            decoded[key] = value["bool_value"]
        else:
            decoded[key] = value
    return decoded


def _path_from_s3_uri(s3_uri: str) -> str:
    if not s3_uri.startswith("s3://"):
        return s3_uri
    without = s3_uri[len("s3://") :]
    _, _, path = without.partition("/")
    return path
