"""Resolve local and Azure PostgreSQL connection settings."""

from __future__ import annotations

import logging
import os
from functools import lru_cache
from typing import Any
from urllib.parse import quote_plus

logger = logging.getLogger(__name__)

POSTGRES_TOKEN_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"  # noqa: S105
_AZURE_CONNECTION_VARS = (
    "DB_HOST",
    "DB_USER",
    "DB_NAME",
    "DB_SSLMODE",
    "MANAGED_IDENTITY_CLIENT_ID",
)
_PASSWORD_AUTH_VARS = (*_AZURE_CONNECTION_VARS, "KEYVAULT_URL", "KEYVAULT_DB_SECRET_NAME")


def _database_auth_mode() -> str:
    mode = os.environ.get("DB_AUTH_MODE")
    if mode is None:
        return "entra" if os.environ.get("MANAGED_IDENTITY_CLIENT_ID") else "password"
    if mode not in {"entra", "password"}:
        raise ValueError("DB_AUTH_MODE must be either 'entra' or 'password'.")
    return mode


def is_entra_auth() -> bool:
    """Return whether all settings for Entra token authentication are present."""
    return _database_auth_mode() == "entra" and all(
        os.environ.get(variable) for variable in _AZURE_CONNECTION_VARS
    )


def _is_password_auth() -> bool:
    return _database_auth_mode() == "password" and all(
        os.environ.get(variable) for variable in _PASSWORD_AUTH_VARS
    )


@lru_cache(maxsize=1)
def _managed_identity_credential(client_id: str):
    from azure.identity import ManagedIdentityCredential

    return ManagedIdentityCredential(client_id=client_id)


def _fetch_password_from_keyvault(keyvault_url: str, secret_name: str, client_id: str) -> str:
    from azure.keyvault.secrets import SecretClient

    secret = SecretClient(
        vault_url=keyvault_url,
        credential=_managed_identity_credential(client_id),
    ).get_secret(secret_name)
    if secret.value is None:
        raise RuntimeError(f"Key Vault secret '{secret_name}' exists but has no value.")
    return secret.value


def _azure_url(*, async_driver: bool) -> str:
    driver = "+asyncpg" if async_driver else "+psycopg2"
    return (
        f"postgresql{driver}://{os.environ['DB_HOST']}:5432/{os.environ['DB_NAME']}"
        f"?sslmode={os.environ['DB_SSLMODE']}"
    )


def resolve_database_url(default: str, *, async_driver: bool = True) -> str:
    """Resolve explicit, Entra, Key Vault password, or default database settings."""
    if database_url := os.environ.get("DATABASE_URL"):
        if async_driver and database_url.startswith("postgresql://"):
            database_url = database_url.replace("postgresql://", "postgresql+asyncpg://", 1)
        elif not async_driver and database_url.startswith("postgresql://"):
            database_url = database_url.replace("postgresql://", "postgresql+psycopg2://", 1)
        return (
            database_url.replace("+psycopg2", "+asyncpg")
            if async_driver
            else database_url.replace("+asyncpg", "+psycopg2")
        )

    if is_entra_auth():
        logger.info("Using Entra database authentication for host %s", os.environ["DB_HOST"])
        return _azure_url(async_driver=async_driver)

    if _is_password_auth():
        password = _fetch_password_from_keyvault(
            os.environ["KEYVAULT_URL"],
            os.environ["KEYVAULT_DB_SECRET_NAME"],
            os.environ["MANAGED_IDENTITY_CLIENT_ID"],
        )
        driver = "+asyncpg" if async_driver else "+psycopg2"
        return (
            f"postgresql{driver}://{quote_plus(os.environ['DB_USER'])}:{quote_plus(password)}"
            f"@{os.environ['DB_HOST']}:5432/{os.environ['DB_NAME']}"
            f"?sslmode={os.environ['DB_SSLMODE']}"
        )

    return default


async def create_asyncpg_connection() -> Any:
    """Create an asyncpg connection using a fresh Managed Identity token."""
    import asyncpg  # type: ignore[import-untyped]

    token = (
        _managed_identity_credential(os.environ["MANAGED_IDENTITY_CLIENT_ID"])
        .get_token(POSTGRES_TOKEN_SCOPE)
        .token
    )
    return await asyncpg.connect(
        host=os.environ["DB_HOST"],
        port=5432,
        database=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=token,
        ssl=os.environ["DB_SSLMODE"] != "disable",
    )
