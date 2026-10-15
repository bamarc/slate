"""Application configuration — layered priority.

Priority chain (lowest to highest):
  1. Pydantic field defaults
  2. config.yaml (general, committed)
  3. config.{APP_ENV}.yaml (environment-scoped, e.g. config.dev.yaml)
  4. Environment variables (overrides everything)

Usage:
    from app.core.config import settings
    print(settings.database_url)

Run-time env switching:
    APP_ENV=prod uv run uvicorn app.main:app
"""

from __future__ import annotations

import os
from pathlib import Path

import yaml
from pydantic_settings import BaseSettings, SettingsConfigDict

from app.core.db_url import resolve_database_url


def _load_yaml(path: Path) -> dict[str, object]:
    """Read a YAML file, return empty dict if missing/unreadable."""
    if path.is_file():
        with open(path) as f:
            data = yaml.safe_load(f)
            return data if isinstance(data, dict) else {}
    return {}


def _build_values() -> dict[str, object]:
    """Merge config files with priority: general < env-scoped < env vars."""
    base = _load_yaml(Path("config.yaml"))
    env_name = os.getenv("APP_ENV", "dev")
    env_override = _load_yaml(Path(f"config.{env_name}.yaml"))
    merged = {**base, **env_override}
    # Drop keys also present in env so BaseSettings' env source wins over YAML.
    return {k: v for k, v in merged.items() if k.upper() not in os.environ}


class Settings(BaseSettings):
    """Application settings loaded from layered YAML + env vars."""

    model_config = SettingsConfigDict(
        case_sensitive=False,
        env_prefix="",
        extra="ignore",
    )

    # ── Application ──────────────────────────────────────────
    app_name: str = "Slate API"
    app_version: str = "0.1.0"
    debug: bool = True
    environment: str = "dev"  # dev | test | staging | prod

    # ── Database ─────────────────────────────────────────────
    database_url: str = "postgresql+asyncpg://postgres:postgres@localhost:5432/${{ values.projectName | replace('-', '_') }}"
    database_echo: bool = False
    database_pool_size: int = 5
    database_max_overflow: int = 10
    db_auth_mode: str = ""

    # ── MongoDB (alternative) ────────────────────────────────
    mongodb_url: str = "mongodb://localhost:27017"
    mongodb_db_name: str = "${{ values.projectName | replace('-', '_') }}"

    # ── CORS ─────────────────────────────────────────────────
    cors_origins: list[str] = ["http://localhost:5173"]

    # ── OpenTelemetry ────────────────────────────────────────
    otel_enabled: bool = True
    otel_service_name: str = "${{ values.projectName }}"
    otel_exporter_endpoint: str = "http://localhost:4317"
    otel_exporter_protocol: str = "grpc"  # grpc | http/protobuf

    # ── Logging ──────────────────────────────────────────────
    log_level: str = "INFO"
    log_format: str = "json"  # json | text

    # ── Auth (OAuth2 / OIDC) ────────────────────────────────
    # Provider selection: "dev" | "oidc" | "entra" | "keycloak" | "gcloud"
    auth_required: bool = False
    auth_provider: str = "dev"
    auth_audience: str = ""
    auth_issuer: str = ""  # for the generic "oidc" provider
    auth_jwks_url: str = ""  # for the generic "oidc" provider
    auth_algorithms: list[str] = ["RS256"]
    auth_roles_claim: str = "roles"
    # Optional map of IdP-side role/group names to internal role names.
    # Example: {"00000000-aaaa-bbbb-cccc-000000000000": "admin"}
    auth_role_mapping: dict[str, str] = {}

    # Provider-specific knobs
    auth_tenant_id: str = ""  # Entra / Azure AD
    auth_keycloak_url: str = ""
    auth_keycloak_realm: str = ""
    auth_gcloud_project_id: str = ""


# Build the global settings instance from layered config
settings = Settings(**_build_values())  # type: ignore[arg-type]
settings.database_url = resolve_database_url(settings.database_url, async_driver=True)
