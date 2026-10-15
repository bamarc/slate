"""Tests for global error handlers and correlation-id middleware."""

from __future__ import annotations

from httpx import ASGITransport, AsyncClient
from starlette.status import (
    HTTP_404_NOT_FOUND,
    HTTP_405_METHOD_NOT_ALLOWED,
    HTTP_422_UNPROCESSABLE_ENTITY,
    HTTP_500_INTERNAL_SERVER_ERROR,
)


class TestCorrelationId:
    """Every response must carry X-Correlation-ID."""

    async def test_response_includes_correlation_id_header(self, async_client: AsyncClient):
        response = await async_client.get("/api/v1/health")
        assert "x-correlation-id" in response.headers
        assert len(response.headers["x-correlation-id"]) > 0

    async def test_correlation_id_passed_through(self, async_client: AsyncClient):
        response = await async_client.get(
            "/api/v1/health",
            headers={"x-correlation-id": "deadbeef"},
        )
        assert response.headers["x-correlation-id"] == "deadbeef"

    async def test_correlation_id_on_404(self, async_client: AsyncClient):
        """Even 404s get a correlation-id."""
        response = await async_client.get("/nonexistent")
        assert response.status_code == HTTP_404_NOT_FOUND
        assert "x-correlation-id" in response.headers

    async def test_correlation_id_on_405(self, async_client: AsyncClient):
        """Even 405s get a correlation-id."""
        response = await async_client.post("/api/v1/health")
        assert response.status_code == HTTP_405_METHOD_NOT_ALLOWED
        assert "x-correlation-id" in response.headers


class TestValidationErrors:
    """422 responses — test via a dedicated test app with a POST route."""

    async def test_422_structured_error(self):
        """Send an invalid body to a route that requires validation."""
        # Build a minimal test app WITH a POST route and our error handlers
        from fastapi import FastAPI
        from pydantic import BaseModel

        from app.core.errors import register_error_handlers

        test_app = FastAPI()
        register_error_handlers(test_app)

        class _Item(BaseModel):
            title: str
            count: int

        @test_app.post("/items")
        async def create_item(item: _Item):
            return item

        transport = ASGITransport(app=test_app)  # type: ignore[arg-type]
        async with AsyncClient(transport=transport, base_url="http://test") as ac:
            response = await ac.post("/items", json={"title": "missing count"})

        assert response.status_code == HTTP_422_UNPROCESSABLE_ENTITY
        assert response.headers["content-type"] == "application/problem+json"
        body = response.json()
        assert body["type"] == "about:blank"
        assert body["status"] == HTTP_422_UNPROCESSABLE_ENTITY
        assert body["detail"] == "Validation error"
        assert "errors" in body
        assert len(body["errors"]) > 0


class TestInternalServerError:
    """500 handler — test via a dedicated test app."""

    async def test_500_structured_response(self):
        """An unhandled exception becomes a safe 500."""
        from fastapi import FastAPI

        from app.core.errors import register_error_handlers

        test_app = FastAPI()
        register_error_handlers(test_app)

        @test_app.get("/boom")
        async def boom():
            raise RuntimeError("simulated crash")

        transport = ASGITransport(app=test_app, raise_app_exceptions=False)  # type: ignore[arg-type]
        async with AsyncClient(transport=transport, base_url="http://test") as ac:
            response = await ac.get("/boom")

        assert response.status_code == HTTP_500_INTERNAL_SERVER_ERROR
        assert response.headers["content-type"] == "application/problem+json"
        body = response.json()
        assert body["type"] == "about:blank"
        assert body["status"] == HTTP_500_INTERNAL_SERVER_ERROR
        assert body["detail"] == "Internal server error"
        assert "correlation_id" in body
        # Stack trace must NOT leak
        assert "RuntimeError" not in str(body)
        assert "simulated crash" not in str(body)
