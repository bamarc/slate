"""FastAPI dependencies for authentication & role-based authorization.

Routes consume these building blocks:

    user: CurrentUser = Depends(get_current_user)        # any authenticated user
    user: CurrentUser = Depends(require_role("admin"))   # exactly one role
    user: CurrentUser = Depends(require_any_role("user", "admin"))

`get_optional_user` returns `None` when no token is supplied — for endpoints
that vary their behaviour based on auth but don't strictly require it.
"""

from __future__ import annotations

import base64
import json
import logging
import os
from typing import Annotated

import jwt
from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.core.auth.models import AuthenticatedUser
from app.core.auth.provider import InvalidTokenError, get_provider
from app.core.config import settings
from app.core.rbac import get_permissions_for_role

logger = logging.getLogger(__name__)

_bearer = HTTPBearer(auto_error=False, scheme_name="OAuth2Bearer")
MVP_MOCK_SECRET = os.getenv("MVP_MOCK_SECRET", "super-secret-template-key-123")
ALGORITHM = "HS256"


def is_local() -> bool:
    """Determine if running in local development or test mode."""
    env = os.getenv("ENV") or os.getenv("APP_ENV") or settings.environment or "local"
    return env.lower() in ("local", "development", "dev", "test")


def _unauthorized(detail: str = "Not authenticated") -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": 'Bearer realm="api"'},
    )


def _forbidden(detail: str = "Insufficient role") -> HTTPException:
    return HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=detail)


def _extract_claim(claims: list[dict], claim_type: str) -> str | None:
    """Extract a claim value from Azure principal claims."""
    for claim in claims:
        if claim.get("typ") == claim_type:
            return claim.get("val")
    return None


def _parse_client_principal(header_value: str) -> dict | None:
    """Decode and parse base64 principal header."""
    try:
        decoded = base64.b64decode(header_value)
        return json.loads(decoded)
    except Exception:
        logger.warning("Failed to decode X-MS-CLIENT-PRINCIPAL header")
        return None


def _build_user_from_easy_auth(principal: dict) -> dict:
    """Extract identity fields from parsed Azure claims."""
    claims = principal.get("claims", [])

    preferred_username = _extract_claim(claims, "preferred_username")
    if preferred_username:
        kid = preferred_username.split("@")[0].upper()
    else:
        kid = (
            _extract_claim(
                claims,
                "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/nameidentifier",
            )
            or _extract_claim(claims, "oid")
            or ""
        )

    name = (
        _extract_claim(claims, "name")
        or _extract_claim(claims, "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name")
        or ""
    )

    email = (
        _extract_claim(claims, "emailaddress")
        or _extract_claim(
            claims, "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress"
        )
        or ""
    )

    role = (
        _extract_claim(claims, "roles")
        or _extract_claim(claims, "http://schemas.microsoft.com/ws/2008/06/identity/claims/role")
        or "user"
    )

    return {
        "kid": kid,
        "name": name,
        "email": email,
        "role": role,
    }


async def get_current_user(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> AuthenticatedUser:
    """Resolve and verify authentication using Easy Auth in production or JWT bearer locally."""
    # 1. Check for X-MS-CLIENT-PRINCIPAL (production Easy Auth)
    principal_header = request.headers.get("X-MS-CLIENT-PRINCIPAL")

    if not is_local():
        # Production/Staging: X-MS-CLIENT-PRINCIPAL is MANDATORY. No fallbacks.
        if not principal_header:
            logger.error("Production request missing X-MS-CLIENT-PRINCIPAL header")
            raise _unauthorized("Missing X-MS-CLIENT-PRINCIPAL header")

        principal = _parse_client_principal(principal_header)
        if not principal:
            logger.error("Production request has unparseable X-MS-CLIENT-PRINCIPAL header")
            raise _unauthorized("Invalid X-MS-CLIENT-PRINCIPAL header")

        raw = _build_user_from_easy_auth(principal)
        kid = raw.get("kid")
        if not kid:
            logger.error("Could not extract user identity from Easy Auth principal")
            raise _unauthorized("Could not extract user identity from Easy Auth")

        roles_set = frozenset([raw.get("role", "user")])
        permissions = []
        for r in roles_set:
            permissions.extend(get_permissions_for_role(r))
        permissions = sorted(set(permissions))

        user = AuthenticatedUser(
            subject=kid,
            email=raw.get("email") or None,
            name=raw.get("name") or None,
            roles=roles_set,
            issuer="azure-easy-auth",
            permissions=permissions,
            raw_claims=principal,
        )
        request.state.user = user
        return user

    # 2. Local / testing mode (is_local() is True)
    # If the Easy Auth header is present locally (e.g. for docker-compose
    # combined testing), accept it
    if principal_header:
        principal = _parse_client_principal(principal_header)
        if principal:
            raw = _build_user_from_easy_auth(principal)
            kid = raw.get("kid", "UNKNOWN")
            roles_set = frozenset([raw.get("role", "user")])
            permissions = []
            for r in roles_set:
                permissions.extend(get_permissions_for_role(r))
            permissions = sorted(set(permissions))

            user = AuthenticatedUser(
                subject=kid,
                email=raw.get("email") or None,
                name=raw.get("name") or None,
                roles=roles_set,
                issuer="azure-easy-auth",
                permissions=permissions,
                raw_claims=principal,
            )
            request.state.user = user
            return user

    if not settings.auth_required and (credentials is None or not credentials.credentials):
        return AuthenticatedUser(
            subject="anonymous",
            issuer="disabled",
            roles=frozenset(),
            permissions=[],
            raw_claims={},
        )

    if credentials is None or not credentials.credentials:
        raise _unauthorized()

    # Try local mock token first, then fallback to standard OIDC/JWKS if needed
    try:
        payload = jwt.decode(
            credentials.credentials,
            MVP_MOCK_SECRET,
            algorithms=[ALGORITHM],
            options={"verify_exp": True, "verify_aud": False},
        )
        kid = payload.get("kid", payload.get("sub", "UNKNOWN"))
        roles_list = payload.get("roles", payload.get("role", ["user"]))
        if isinstance(roles_list, str):
            roles_list = [roles_list]
        roles_set = frozenset(roles_list)
        permissions = []
        for r in roles_set:
            permissions.extend(get_permissions_for_role(r))
        permissions = sorted(set(permissions))

        user = AuthenticatedUser(
            subject=kid,
            email=payload.get("email"),
            name=payload.get("name"),
            roles=roles_set,
            issuer="mock-jwt",
            permissions=permissions,
            raw_claims=payload,
        )
        request.state.user = user
        return user
    except Exception as e:
        logger.debug(
            f"Failed to decode local token as mock JWT: {e}. Trying configured auth provider."
        )
        try:
            user_provider = await get_provider().verify_token(credentials.credentials)
            permissions = []
            for r in user_provider.roles:
                permissions.extend(get_permissions_for_role(r))
            permissions = sorted(set(permissions))

            user = AuthenticatedUser(
                subject=user_provider.subject,
                email=user_provider.email,
                name=user_provider.name,
                roles=user_provider.roles,
                issuer=user_provider.issuer,
                permissions=permissions,
                raw_claims=user_provider.raw_claims,
            )
            request.state.user = user
            return user
        except InvalidTokenError as exc:
            raise _unauthorized(f"Invalid token: {exc}") from exc


async def get_optional_user(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> AuthenticatedUser | None:
    """Return the authenticated user when a token is present, else `None`."""
    try:
        return await get_current_user(request, credentials)
    except HTTPException:
        return None


def require_role(role: str):
    """Dependency factory: require an exact role on the principal."""

    async def _dep(user: AuthenticatedUser = Depends(get_current_user)) -> AuthenticatedUser:
        if not user.has_role(role) and not user.has_role("admin"):
            raise _forbidden(f"Role '{role}' required")
        return user

    _dep.__name__ = f"require_role_{role}"
    return _dep


def require_any_role(*roles: str):
    """Dependency factory: require at least one of the provided roles."""
    if not roles:
        raise ValueError("require_any_role needs at least one role")

    async def _dep(user: AuthenticatedUser = Depends(get_current_user)) -> AuthenticatedUser:
        if not user.has_any_role(roles) and not user.has_role("admin"):
            raise _forbidden(f"One of roles {sorted(roles)} required")
        return user

    _dep.__name__ = "require_any_role_" + "_".join(sorted(roles))
    return _dep


class RequirePermission:
    """Require a specific fine-grained permission string."""

    def __init__(self, permission: str):
        self.permission = permission

    async def __call__(
        self, user: AuthenticatedUser = Depends(get_current_user)
    ) -> AuthenticatedUser:
        if self.permission not in (user.permissions or []):
            raise _forbidden(f"Missing permission '{self.permission}'")
        return user


CurrentUser = Annotated[AuthenticatedUser, Depends(get_current_user)]
"""Type alias for handler signatures: `user: CurrentUser`."""
