"""Tests for Azure Easy Auth extraction, mock JWT, and RBAC permissions."""

from __future__ import annotations

import base64
import json

import pytest
from fastapi import Depends
from httpx import ASGITransport, AsyncClient

from app.core.auth.dependencies import RequirePermission, is_local
from app.core.config import settings
from app.main import create_app
from app.services.container import create_services


# Helper to build mock principal
def make_principal(kid: str, name: str, email: str, role: str) -> str:
    principal = {
        "auth_typ": "aad",
        "claims": [
            {"typ": "preferred_username", "val": f"{kid}@example.com"},
            {"typ": "name", "val": name},
            {"typ": "emailaddress", "val": email},
            {"typ": "roles", "val": role},
        ],
        "name_typ": "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name",
        "role_typ": "http://schemas.microsoft.com/ws/2008/06/identity/claims/role",
    }
    return base64.b64encode(json.dumps(principal).encode()).decode()


@pytest.fixture
def clean_env(monkeypatch):
    """Clean all relevant environment variables."""
    monkeypatch.delenv("ENV", raising=False)
    monkeypatch.delenv("APP_ENV", raising=False)


# ── 1. Production Mode Easy Auth Tests ──────────────────────


@pytest.mark.asyncio
async def test_production_easy_auth_valid(monkeypatch, clean_env):
    # Force production mode
    monkeypatch.setenv("ENV", "production")
    monkeypatch.setattr(settings, "environment", "production")
    monkeypatch.setattr(settings, "auth_required", True)

    assert not is_local()

    app = create_app()
    app.state.services = create_services()

    # Create base64 header
    principal_b64 = make_principal("M12345", "Alice Prod", "alice@prod.com", "admin")

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        resp = await ac.get("/api/v1/auth/me", headers={"X-MS-CLIENT-PRINCIPAL": principal_b64})
        assert resp.status_code == 200
        body = resp.json()
        assert body["subject"] == "M12345"
        assert body["name"] == "Alice Prod"
        assert body["email"] == "alice@prod.com"
        assert "admin" in body["roles"]
        assert body["issuer"] == "azure-easy-auth"


@pytest.mark.asyncio
async def test_production_easy_auth_missing_header(monkeypatch, clean_env):
    monkeypatch.setenv("ENV", "production")
    monkeypatch.setattr(settings, "environment", "production")
    monkeypatch.setattr(settings, "auth_required", True)

    app = create_app()
    app.state.services = create_services()

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        resp = await ac.get("/api/v1/auth/me")
        assert resp.status_code == 401
        assert resp.json()["detail"] == "Missing X-MS-CLIENT-PRINCIPAL header"


@pytest.mark.asyncio
async def test_production_easy_auth_invalid_header(monkeypatch, clean_env):
    monkeypatch.setenv("ENV", "production")
    monkeypatch.setattr(settings, "environment", "production")
    monkeypatch.setattr(settings, "auth_required", True)

    app = create_app()
    app.state.services = create_services()

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        resp = await ac.get(
            "/api/v1/auth/me", headers={"X-MS-CLIENT-PRINCIPAL": "invalid_base64_json"}
        )
        assert resp.status_code == 401
        assert resp.json()["detail"] == "Invalid X-MS-CLIENT-PRINCIPAL header"


# ── 2. Local Mode Easy Auth & JWT Mock Tests ────────────────


@pytest.mark.asyncio
async def test_local_easy_auth_works(monkeypatch, clean_env):
    # Local mode
    monkeypatch.setenv("ENV", "local")
    monkeypatch.setattr(settings, "environment", "local")
    monkeypatch.setattr(settings, "auth_required", True)

    assert is_local()

    app = create_app()
    app.state.services = create_services()

    principal_b64 = make_principal("L54321", "Bob Local", "bob@local.com", "user")

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        resp = await ac.get("/api/v1/auth/me", headers={"X-MS-CLIENT-PRINCIPAL": principal_b64})
        assert resp.status_code == 200
        body = resp.json()
        assert body["subject"] == "L54321"
        assert body["issuer"] == "azure-easy-auth"


@pytest.mark.asyncio
async def test_mock_token_generation_and_consumption(monkeypatch, clean_env):
    monkeypatch.setenv("ENV", "local")
    monkeypatch.setattr(settings, "environment", "local")
    monkeypatch.setattr(settings, "auth_required", True)

    app = create_app()
    app.state.services = create_services()

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        # Generate token
        req_payload = {
            "kid": "TESTUSER",
            "name": "Test User",
            "email": "test@example.com",
            "roles": ["admin"],
        }
        resp = await ac.post("/api/v1/auth/mock-token", json=req_payload)
        assert resp.status_code == 200
        token_data = resp.json()
        token = token_data["access_token"]
        assert token_data["token_type"] == "Bearer"

        # Use token to call /me
        me_resp = await ac.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {token}"})
        assert me_resp.status_code == 200
        me_data = me_resp.json()
        assert me_data["subject"] == "TESTUSER"
        assert me_data["name"] == "Test User"
        assert me_data["email"] == "test@example.com"
        assert "admin" in me_data["roles"]
        assert me_data["issuer"] == "mock-jwt"


@pytest.mark.asyncio
async def test_mock_token_endpoint_disabled_in_prod(monkeypatch, clean_env):
    monkeypatch.setenv("ENV", "production")
    monkeypatch.setattr(settings, "environment", "production")

    app = create_app()
    app.state.services = create_services()

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        req_payload = {"kid": "TESTUSER", "roles": ["admin"]}
        resp = await ac.post("/api/v1/auth/mock-token", json=req_payload)
        assert resp.status_code == 404


# ── 3. RBAC Permission Guard Tests ──────────────────────────


# Define a temporary app and router to test RequirePermission
@pytest.mark.asyncio
async def test_rbac_permission_guard(monkeypatch, clean_env):
    monkeypatch.setenv("ENV", "local")
    monkeypatch.setattr(settings, "environment", "local")
    monkeypatch.setattr(settings, "auth_required", True)

    app = create_app()
    app.state.services = create_services()

    # Define some dummy routes on the router that use our permission guards
    # We can inject a route directly to test RequirePermission
    @app.get(
        "/test-admin-permission", dependencies=[Depends(RequirePermission("Administration.Read"))]
    )
    async def admin_route():
        return {"status": "ok"}

    @app.get(
        "/test-missing-permission",
        dependencies=[Depends(RequirePermission("SuperAdmin.Permission"))],
    )
    async def super_admin_route():
        return {"status": "ok"}

    # Let's generate tokens for user (who lacks admin) and admin (who has admin permissions)
    # Role admin permissions in rbac.py should map to Administration.Read
    # Let's check using mock tokens
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        # Token for admin
        resp_admin = await ac.post(
            "/api/v1/auth/mock-token", json={"kid": "ADM", "roles": ["admin"]}
        )
        admin_token = resp_admin.json()["access_token"]

        # Token for user
        resp_user = await ac.post("/api/v1/auth/mock-token", json={"kid": "USR", "roles": ["user"]})
        user_token = resp_user.json()["access_token"]

        # 1. Admin accesses /test-admin-permission -> 200
        r1 = await ac.get(
            "/test-admin-permission", headers={"Authorization": f"Bearer {admin_token}"}
        )
        assert r1.status_code == 200

        # 2. Regular user accesses /test-admin-permission -> 403 (Forbidden)
        r2 = await ac.get(
            "/test-admin-permission", headers={"Authorization": f"Bearer {user_token}"}
        )
        assert r2.status_code == 403
        assert "Missing permission" in r2.json()["detail"]

        # 3. Admin accesses /test-missing-permission (requires
        # SuperAdmin.Permission which nobody has) -> 403
        r3 = await ac.get(
            "/test-missing-permission", headers={"Authorization": f"Bearer {admin_token}"}
        )
        assert r3.status_code == 403


# ── 4. RBAC module unit tests ────────────────────────────────


def test_rbac_get_permissions_for_role_various_inputs():
    from app.core.rbac import UserRole, get_permissions_for_role

    # None
    assert get_permissions_for_role(None) == []

    # UserRole Enum
    assert get_permissions_for_role(UserRole.admin) == ["User.Read", "Administration.Read"]

    # String exact and mixed case
    assert get_permissions_for_role("admin ") == ["User.Read", "Administration.Read"]
    assert get_permissions_for_role(" USER ") == ["User.Read"]

    # Invalid string
    assert get_permissions_for_role("nonexistent_role") == []

    # Invalid type
    assert get_permissions_for_role(12345) == []


def test_rbac_has_permission_helper():
    from app.core.rbac import has_permission

    class MockUser:
        def __init__(self, permissions):
            self.permissions = permissions

    u1 = MockUser(["Read", "Write"])
    assert has_permission(u1, "Read") is True
    assert has_permission(u1, "Execute") is False

    u2 = MockUser(None)
    assert has_permission(u2, "Read") is False
