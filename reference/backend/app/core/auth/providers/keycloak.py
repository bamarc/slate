"""Keycloak OAuth2 provider.

Required settings:
- `AUTH_KEYCLOAK_URL`  — base URL of the Keycloak server (e.g. https://kc.example.com)
- `AUTH_KEYCLOAK_REALM` — realm name
- `AUTH_AUDIENCE`      — client id

Keycloak places client-specific roles under
`resource_access.<client_id>.roles` and realm roles under `realm_access.roles`.
This provider flattens both into the `roles` set.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from app.core.auth.provider import OIDCProvider
from app.core.config import settings


def build_keycloak_provider() -> OIDCProvider:
    base = (settings.auth_keycloak_url or "").rstrip("/")
    realm = settings.auth_keycloak_realm
    if not base or not realm:
        raise ValueError("auth_keycloak_url and auth_keycloak_realm are required.")

    issuer = f"{base}/realms/{realm}"
    jwks_url = f"{issuer}/protocol/openid-connect/certs"
    return _KeycloakProvider(
        issuer=issuer,
        audience=settings.auth_audience,
        jwks_url=jwks_url,
        algorithms=settings.auth_algorithms,
        roles_claim=settings.auth_roles_claim or "realm_access",
    )


class _KeycloakProvider(OIDCProvider):
    name = "keycloak"

    def _extract_roles(self, claims: Mapping[str, Any]) -> set[str]:  # type: ignore[override]
        roles: set[str] = set()

        # realm roles
        realm_access = claims.get("realm_access") or {}
        if isinstance(realm_access, Mapping):
            for r in realm_access.get("roles", []) or []:
                mapped = self._map_role(str(r))
                if mapped:
                    roles.add(mapped)

        # client roles (resource_access.<client_id>.roles)
        resource_access = claims.get("resource_access") or {}
        if isinstance(resource_access, Mapping):
            client = resource_access.get(settings.auth_audience) or {}
            if isinstance(client, Mapping):
                for r in client.get("roles", []) or []:
                    mapped = self._map_role(str(r))
                    if mapped:
                        roles.add(mapped)

        return roles
