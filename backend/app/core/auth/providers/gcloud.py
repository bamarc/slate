"""Google Cloud Identity Platform / Firebase Auth provider.

Required settings:
- `AUTH_GCLOUD_PROJECT_ID` — GCP project id (used as issuer + audience)

For Firebase Auth tokens the issuer is
``https://securetoken.google.com/<project>`` and the JWKS lives at
``https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com``.

Roles are not native to GCIP. Use a custom claim (default key:
``roles``) set via the Admin SDK at sign-up / promotion time.
"""

from __future__ import annotations

from app.core.auth.provider import OIDCProvider
from app.core.config import settings


def build_gcloud_provider() -> OIDCProvider:
    project = settings.auth_gcloud_project_id
    if not project:
        raise ValueError("auth_gcloud_project_id is required for the GCloud provider.")
    issuer = f"https://securetoken.google.com/{project}"
    jwks_url = (
        "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"
    )
    return OIDCProvider(
        issuer=issuer,
        audience=project,
        jwks_url=jwks_url,
        algorithms=["RS256"],
        roles_claim=settings.auth_roles_claim or "roles",
    )
