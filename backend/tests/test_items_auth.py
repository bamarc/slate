"""Auth gating tests for the items domain.

Covers only the cases that short-circuit before the DB dependency runs:
  401 — no token
  403 — token lacks required role

Full 200/201 path requires a live database and is exercised by integration tests.
"""

from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient

from app.core.auth.provider import DevProvider, reset_provider, set_provider
from app.core.config import settings
from app.main import create_app
from app.services.container import create_services


@pytest.fixture(autouse=True)
def _reset_provider_after_test():
    yield
    reset_provider()


@pytest.fixture
async def authed_client(monkeypatch):
    monkeypatch.setattr(settings, "auth_required", True)
    monkeypatch.setattr(settings, "auth_provider", "dev")
    monkeypatch.setattr(settings, "environment", "test")
    set_provider(DevProvider())

    app = create_app()
    app.state.services = create_services()
    transport = ASGITransport(app=app)  # type: ignore[arg-type]
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


# ── 401: missing token ──────────────────────────────────────


async def test_list_items_requires_auth(authed_client: AsyncClient):
    resp = await authed_client.get("/api/v1/items")
    assert resp.status_code == 401


async def test_get_item_requires_auth(authed_client: AsyncClient):
    resp = await authed_client.get("/api/v1/items/1")
    assert resp.status_code == 401


async def test_create_item_requires_auth(authed_client: AsyncClient):
    resp = await authed_client.post("/api/v1/items", json={"name": "x"})
    assert resp.status_code == 401


async def test_update_item_requires_auth(authed_client: AsyncClient):
    resp = await authed_client.put("/api/v1/items/1", json={"name": "x"})
    assert resp.status_code == 401


async def test_delete_item_requires_auth(authed_client: AsyncClient):
    resp = await authed_client.delete("/api/v1/items/1")
    assert resp.status_code == 401


# ── 403: user role cannot write ─────────────────────────────


async def test_user_cannot_create_item(authed_client: AsyncClient):
    resp = await authed_client.post(
        "/api/v1/items",
        json={"name": "x"},
        headers={"Authorization": "Bearer bob:user"},
    )
    assert resp.status_code == 403


async def test_user_cannot_update_item(authed_client: AsyncClient):
    resp = await authed_client.put(
        "/api/v1/items/1",
        json={"name": "x"},
        headers={"Authorization": "Bearer bob:user"},
    )
    assert resp.status_code == 403


async def test_user_cannot_delete_item(authed_client: AsyncClient):
    resp = await authed_client.delete(
        "/api/v1/items/1",
        headers={"Authorization": "Bearer bob:user"},
    )
    assert resp.status_code == 403
