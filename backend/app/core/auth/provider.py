"""OAuth2 / OIDC provider abstraction.

A provider knows how to:
1. Discover JWKS (signing keys) from the IdP.
2. Verify an access token's signature, expiry, issuer, and audience.
3. Project the verified claims onto our `AuthenticatedUser` shape, including
   mapping IdP-specific role claims onto our internal `Role` registry.

The concrete provider is selected at startup based on `settings.auth_provider`
and lives in `providers/`. The selection is intentionally a simple registry
lookup — no DI framework needed.
"""

from __future__ import annotations

import time
from collections.abc import Mapping
from typing import Any, Protocol

import httpx
import jwt
from jwt import PyJWKClient

from app.core.auth.models import AuthenticatedUser, Role
from app.core.config import settings


class OAuth2Provider(Protocol):
    """Pluggable identity-provider contract."""

    name: str

    async def verify_token(self, token: str) -> AuthenticatedUser:  # pragma: no cover - protocol
        ...


# ---------------------------------------------------------------------------
# Generic OIDC provider — works for Entra, Keycloak, GCP, Auth0, Okta, ...
# ---------------------------------------------------------------------------


class OIDCProvider:
    """OIDC-compliant provider using JWKS for signature verification.

    Concrete providers (Entra, Keycloak, GCP) subclass this only to tweak
    claim-to-role mapping. Token validation is identical across IdPs.
    """

    name = "oidc"

    def __init__(
        self,
        *,
        issuer: str,
        audience: str,
        jwks_url: str,
        algorithms: list[str] | None = None,
        roles_claim: str = "roles",
        leeway_seconds: int = 30,
    ) -> None:
        if not issuer or not audience or not jwks_url:
            raise ValueError("OIDCProvider requires issuer, audience, and jwks_url.")
        self._issuer = issuer
        self._audience = audience
        self._algorithms = algorithms or ["RS256"]
        self._roles_claim = roles_claim
        self._leeway = leeway_seconds
        # cache_keys=True keeps fetched JWKS in memory; max_cached_keys bounds it.
        self._jwks = PyJWKClient(jwks_url, cache_keys=True, max_cached_keys=16)

    async def verify_token(self, token: str) -> AuthenticatedUser:
        try:
            signing_key = self._jwks.get_signing_key_from_jwt(token).key
            claims = jwt.decode(
                token,
                key=signing_key,
                algorithms=self._algorithms,
                audience=self._audience,
                issuer=self._issuer,
                leeway=self._leeway,
                options={"require": ["exp", "iat", "iss", "sub"]},
            )
        except jwt.PyJWTError as exc:
            raise InvalidTokenError(str(exc)) from exc

        return self._build_user(claims)

    # ── claim → user mapping ──────────────────────────────────────────

    def _build_user(self, claims: Mapping[str, Any]) -> AuthenticatedUser:
        roles = self._extract_roles(claims)
        return AuthenticatedUser(
            subject=str(claims["sub"]),
            email=claims.get("email") or claims.get("preferred_username"),
            name=claims.get("name"),
            roles=frozenset(roles),
            issuer=str(claims["iss"]),
            raw_claims=dict(claims),
        )

    def _extract_roles(self, claims: Mapping[str, Any]) -> set[str]:
        raw = claims.get(self._roles_claim, [])
        if isinstance(raw, str):
            raw = [r.strip() for r in raw.replace(",", " ").split() if r.strip()]
        elif not isinstance(raw, list):
            raw = []
        return {self._map_role(str(r)) for r in raw if self._map_role(str(r))}

    def _map_role(self, claim_value: str) -> str:
        """Translate an IdP role string into one of `Role.known()`.

        Override in subclasses for IdP-specific group naming.
        """
        normalised = claim_value.strip().lower()
        mapping = getattr(settings, "auth_role_mapping", {}) or {}
        translated = mapping.get(claim_value) or mapping.get(normalised) or normalised
        return translated if translated in Role.known() else ""


class InvalidTokenError(Exception):
    """Raised when an access token fails validation."""


# ---------------------------------------------------------------------------
# Dev-only provider — accepts any unsigned JWT-like token for local testing
# ---------------------------------------------------------------------------


class DevProvider:
    """Local-only provider — accepts unsigned tokens of the form
    ``<sub>:<role>[,<role>...]`` (e.g. ``alice:admin`` or ``bob:user``).

    Active when `settings.auth_provider == "dev"`. Refuses to start when
    `settings.environment` is anything other than ``dev`` or ``test``.
    """

    name = "dev"

    def __init__(self) -> None:
        if settings.environment not in {"dev", "test", "local", "development"}:
            raise RuntimeError(
                f"DevProvider is not allowed in environment={settings.environment!r}"
            )

    async def verify_token(self, token: str) -> AuthenticatedUser:
        token = token.strip()
        if not token or ":" not in token:
            raise InvalidTokenError("Dev token must be '<sub>:<role>[,<role>...]'")
        sub, roles_part = token.split(":", 1)
        roles = {r.strip().lower() for r in roles_part.split(",") if r.strip()}
        unknown = roles - Role.known()
        if unknown:
            raise InvalidTokenError(f"Unknown roles in dev token: {sorted(unknown)}")
        return AuthenticatedUser(
            subject=sub,
            email=f"{sub}@dev.local",
            name=sub.title(),
            roles=frozenset(roles),
            issuer="dev",
            raw_claims={
                "sub": sub,
                "roles": sorted(roles),
                "iss": "dev",
                "exp": int(time.time()) + 3600,
            },
        )


# ---------------------------------------------------------------------------
# Provider selection
# ---------------------------------------------------------------------------

_provider: OAuth2Provider | None = None


def get_provider() -> OAuth2Provider:
    """Return the configured provider, building it on first use."""
    global _provider
    if _provider is not None:
        return _provider

    name = (settings.auth_provider or "dev").strip().lower()
    if name == "dev" or not settings.auth_required:
        _provider = DevProvider()
        return _provider

    if name == "entra":
        from app.core.auth.providers.entra import build_entra_provider

        _provider = build_entra_provider()
    elif name == "keycloak":
        from app.core.auth.providers.keycloak import build_keycloak_provider

        _provider = build_keycloak_provider()
    elif name in {"gcloud", "google", "gcp"}:
        from app.core.auth.providers.gcloud import build_gcloud_provider

        _provider = build_gcloud_provider()
    elif name == "oidc":
        _provider = OIDCProvider(
            issuer=settings.auth_issuer,
            audience=settings.auth_audience,
            jwks_url=settings.auth_jwks_url,
            algorithms=settings.auth_algorithms,
            roles_claim=settings.auth_roles_claim,
        )
    else:
        raise ValueError(f"Unknown auth_provider: {name!r}")

    return _provider


def reset_provider() -> None:
    """Reset the cached provider (tests / hot-reload)."""
    global _provider
    _provider = None


# Helper for testing: replace the provider with a fake.
def set_provider(provider: OAuth2Provider) -> None:
    global _provider
    _provider = provider


async def _discover_oidc(issuer: str) -> dict[str, Any]:
    """Fetch `<issuer>/.well-known/openid-configuration`."""
    url = issuer.rstrip("/") + "/.well-known/openid-configuration"
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(url)
        resp.raise_for_status()
        return resp.json()
