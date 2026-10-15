"""Authentication & authorization layer — pluggable OAuth2 / OIDC.

Supports any RFC 7519 + OIDC-compliant identity provider:
- **Microsoft Entra ID** (Azure AD)
- **Keycloak**
- **Google Cloud Identity Platform** (GCP)
- Any other OIDC IdP

Routes consume FastAPI dependencies from `dependencies.py`:

    from app.core.auth import require_role, CurrentUser

    @router.get("/admin")
    async def admin_only(user: CurrentUser = Depends(require_role("admin"))):
        ...

The active provider is selected by `settings.auth_provider` and configured
under `settings.auth_*`. See `providers/` for IdP-specific helpers.
"""

from app.core.auth.dependencies import (
    CurrentUser,
    get_current_user,
    get_optional_user,
    require_any_role,
    require_role,
)
from app.core.auth.models import AuthenticatedUser, Role
from app.core.auth.provider import OAuth2Provider, get_provider

__all__ = [
    "AuthenticatedUser",
    "CurrentUser",
    "OAuth2Provider",
    "Role",
    "get_current_user",
    "get_optional_user",
    "get_provider",
    "require_any_role",
    "require_role",
]
