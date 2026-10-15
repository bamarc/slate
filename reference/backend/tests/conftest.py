"""Shared test fixtures — async HTTP client, test settings, DB session.

Usage in tests:
    async def test_something(client):
        response = await client.get("/api/v1/health")
        assert response.status_code == 200
"""

from __future__ import annotations

from collections.abc import AsyncIterator

import pytest
from httpx import ASGITransport, AsyncClient

from app.core.config import Settings
from app.main import create_app

# ── Settings override ────────────────────────────────────────


@pytest.fixture
def test_settings(monkeypatch) -> Settings:
    """Return a Settings instance with test-safe defaults.

    Every value is pinned so no config file or env var can surprise us.
    """
    overrides: dict[str, object] = {
        "app_name": "Fullstack Template API (test)",
        "app_version": "0.1.0",
        "debug": True,
        "environment": "test",
        "database_url": "postgresql+asyncpg://postgres:postgres@localhost:5432/${{ values.projectName | replace('-', '_') }}_test",
        "database_echo": False,
        "cors_origins": ["http://test"],
        "otel_enabled": False,
        "log_level": "ERROR",
        "log_format": "text",
    }
    for key, value in overrides.items():
        monkeypatch.setenv(key.upper(), str(value))

    return Settings(**overrides)


# ── Application factory ──────────────────────────────────────


def _build_test_app():
    """Create a fresh FastAPI app with test settings.

    We bypass the module-level singleton so every test module gets a clean instance.
    """
    from app.core.config import settings as gs

    # Temporarily morph global settings (avoids rewriting main.py for tests)
    app = create_app()
    app.state.settings = gs
    # Ensure services are registered (ASGITransport doesn't trigger lifespan)
    from app.services.container import create_services

    app.state.services = create_services()
    return app


# ── HTTP client ──────────────────────────────────────────────


@pytest.fixture
async def async_client() -> AsyncIterator[AsyncClient]:
    """Yield an httpx AsyncClient pointed at a test FastAPI app.

    The client base_url is http://test so href-less redirects resolve.
    """
    app = _build_test_app()
    transport = ASGITransport(app=app)  # type: ignore[arg-type]
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac
