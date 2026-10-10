"""Tests for the health endpoint."""

from __future__ import annotations

from httpx import AsyncClient


class TestHealthEndpoint:
    async def test_returns_200(self, async_client: AsyncClient):
        response = await async_client.get("/api/v1/health")
        assert response.status_code == 200

    async def test_returns_version_from_settings(self, async_client: AsyncClient):
        response = await async_client.get("/api/v1/health")
        data = response.json()
        assert data["version"] == "0.1.0"

    async def test_includes_database_status(self, async_client: AsyncClient):
        """Database field is present even without a running DB (shows 'unreachable')."""
        response = await async_client.get("/api/v1/health")
        data = response.json()
        assert data["database"] in ("connected", "unreachable")

    async def test_overall_status_is_not_ok_when_db_unreachable(self, async_client: AsyncClient):
        response = await async_client.get("/api/v1/health")
        data = response.json()
        if data["database"] == "unreachable":
            assert data["status"] == "degraded"
        else:
            assert data["status"] == "ok"

    async def test_content_type_is_json(self, async_client: AsyncClient):
        response = await async_client.get("/api/v1/health")
        assert "application/json" in response.headers["content-type"]
