"""Microsoft Entra ID (Azure AD) OAuth2 provider.

Required settings (env or config):
- `AUTH_TENANT_ID`         — directory tenant id
- `AUTH_AUDIENCE`          — application/client id (api://<guid> or guid)
- `AUTH_ROLES_CLAIM`       — defaults to "roles" (app roles) — set to "groups" for AAD groups

Entra issues `roles` for app roles assigned to the user. For AAD security
groups, set `auth_roles_claim="groups"` and map group object-ids via
`auth_role_mapping`.
"""

from __future__ import annotations

from app.core.auth.provider import OIDCProvider
from app.core.config import settings


def build_entra_provider() -> OIDCProvider:
    tenant = settings.auth_tenant_id
    if not tenant:
        raise ValueError("auth_tenant_id is required for the Entra provider.")
    issuer = f"https://login.microsoftonline.com/{tenant}/v2.0"
    jwks_url = f"https://login.microsoftonline.com/{tenant}/discovery/v2.0/keys"
    return OIDCProvider(
        issuer=issuer,
        audience=settings.auth_audience,
        jwks_url=jwks_url,
        algorithms=settings.auth_algorithms,
        roles_claim=settings.auth_roles_claim or "roles",
    )
