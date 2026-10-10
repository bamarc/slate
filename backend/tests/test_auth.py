"""Tests for the auth module — DevProvider, role guards, /v1/auth/me."""

from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient

from app.core.auth.models import AuthenticatedUser, Role
from app.core.auth.provider import (
    DevProvider,
    InvalidTokenError,
    reset_provider,
    set_provider,
)
from app.core.config import settings
from app.main import create_app
from app.services.container import create_services

# ── Provider unit tests ──────────────────────────────────────


@pytest.fixture(autouse=True)
def _reset_provider_after_test():
    yield
    reset_provider()


async def test_dev_provider_accepts_valid_token():
    provider = DevProvider()
    user = await provider.verify_token("alice:admin")
    assert user.subject == "alice"
    assert user.has_role(Role.ADMIN)
    assert user.issuer == "dev"


async def test_dev_provider_accepts_multiple_roles():
    provider = DevProvider()
    user = await provider.verify_token("bob:user,admin")
    assert user.has_role("user")
    assert user.has_role("admin")


async def test_dev_provider_rejects_malformed_token():
    provider = DevProvider()
    with pytest.raises(InvalidTokenError):
        await provider.verify_token("garbage")


async def test_dev_provider_rejects_unknown_role():
    provider = DevProvider()
    with pytest.raises(InvalidTokenError):
        await provider.verify_token("eve:superuser")


def test_authenticated_user_role_helpers():
    user = AuthenticatedUser(
        subject="alice",
        roles=frozenset({"user", "admin"}),
        issuer="dev",
        raw_claims={},
    )
    assert user.has_role("user")
    assert user.has_any_role(["admin", "ghost"])
    assert not user.has_role("ghost")


# ── /v1/auth/me integration tests ───────────────────────────


@pytest.fixture
async def authed_client(monkeypatch):
    """Yield a client with auth_required=True and DevProvider installed."""
    monkeypatch.setattr(settings, "auth_required", True)
    monkeypatch.setattr(settings, "auth_provider", "dev")
    monkeypatch.setattr(settings, "environment", "test")
    set_provider(DevProvider())

    app = create_app()
    app.state.services = create_services()
    transport = ASGITransport(app=app)  # type: ignore[arg-type]
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


async def test_me_requires_auth(authed_client: AsyncClient):
    resp = await authed_client.get("/api/v1/auth/me")
    assert resp.status_code == 401


async def test_me_returns_user(authed_client: AsyncClient):
    resp = await authed_client.get(
        "/api/v1/auth/me",
        headers={"Authorization": "Bearer alice:admin"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["subject"] == "alice"
    assert "admin" in body["roles"]
    assert body["issuer"] == "dev"


async def test_me_rejects_invalid_token(authed_client: AsyncClient):
    resp = await authed_client.get(
        "/api/v1/auth/me",
        headers={"Authorization": "Bearer not-a-token"},
    )
    assert resp.status_code == 401
