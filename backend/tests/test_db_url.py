"""Tests for local and Azure PostgreSQL URL resolution."""

from __future__ import annotations

from app.core.db_url import is_entra_auth, resolve_database_url


def test_resolve_database_url_uses_database_url(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "postgresql://user:pass@db:5432/app")

    assert resolve_database_url("postgresql+asyncpg://localhost/app") == (
        "postgresql+asyncpg://user:pass@db:5432/app"
    )


def test_resolve_database_url_builds_entra_url(monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setenv("DB_AUTH_MODE", "entra")
    monkeypatch.setenv("DB_HOST", "db.postgres.database.azure.com")
    monkeypatch.setenv("DB_USER", "app_identity")
    monkeypatch.setenv("DB_NAME", "template")
    monkeypatch.setenv("DB_SSLMODE", "require")
    monkeypatch.setenv("MANAGED_IDENTITY_CLIENT_ID", "client-id")

    assert is_entra_auth()
    assert resolve_database_url("fallback") == (
        "postgresql+asyncpg://db.postgres.database.azure.com:5432/template?sslmode=require"
    )
