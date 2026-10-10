---
name: auth-integration
description: 'How to use, switch, and extend the OAuth2/OIDC auth layer (dev, Entra, Keycloak, Google Cloud). Use when the user asks about authentication, login, roles, JWTs, identity providers, or protecting an endpoint.'
allowed-tools: [shell]
---

# Auth Integration

The backend uses a pluggable **OAuth2 / OIDC** layer that supports four
providers behind one interface:

| Provider | `AUTH_PROVIDER=` | Module |
|---|---|---|
| Local dev (unsigned tokens) | `dev` | `app/core/auth/provider.py::DevProvider` |
| Generic OIDC (Auth0/Okta/…) | `oidc` | `app/core/auth/provider.py::OIDCProvider` |
| Microsoft Entra ID | `entra` | `app/core/auth/providers/entra.py` |
| Keycloak | `keycloak` | `app/core/auth/providers/keycloak.py` |
| Google Cloud Identity | `gcloud` | `app/core/auth/providers/gcloud.py` |

Two roles ship out of the box: **`user`** and **`admin`**. Add more via
`Role.register("editor")` at startup.

## Local dev — no IdP needed

```bash
# .env
AUTH_REQUIRED=true
AUTH_PROVIDER=dev
```

Then call endpoints with a fake bearer token shaped `<sub>:<role>[,<role>]`:

```bash
curl -H "Authorization: Bearer alice:admin"     http://localhost:8000/api/v1/auth/me
curl -H "Authorization: Bearer bob:user"        http://localhost:8000/api/v1/items
```

`DevProvider` refuses to load outside `ENVIRONMENT in {dev,test}`.

## Switching providers

### Microsoft Entra ID
```env
AUTH_PROVIDER=entra
AUTH_TENANT_ID=<your-tenant-guid>
AUTH_AUDIENCE=<your-api-app-id-or-uri>
AUTH_ROLES_CLAIM=roles            # or "groups" + AUTH_ROLE_MAPPING
```
Discovery URL: `https://login.microsoftonline.com/{tenant}/v2.0/.well-known/openid-configuration`.

### Keycloak
```env
AUTH_PROVIDER=keycloak
AUTH_KEYCLOAK_URL=https://keycloak.example.com
AUTH_KEYCLOAK_REALM=myrealm
AUTH_AUDIENCE=<your-client-id>    # IMPORTANT: also used to look up resource_access[client_id].roles
```
Realm + resource roles are flattened automatically by `KeycloakProvider`.

### Google Cloud Identity Platform / Firebase Auth
```env
AUTH_PROVIDER=gcloud
AUTH_GCLOUD_PROJECT_ID=<your-gcp-project>
AUTH_AUDIENCE=<same-project-id>
```
Issuer: `https://securetoken.google.com/{project}`. JWKS:
`https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com`.

## Mapping IdP-specific role names → template roles

```env
AUTH_ROLE_MAPPING={"Admins":"admin","BasicUsers":"user","myrealm/admin":"admin"}
```

The OIDC provider lowercases the claim value, looks it up in this dict, and
validates the result against `Role.known()`. Unknown roles are dropped silently.

## Protecting endpoints

```python
from app.core.auth import CurrentUser, require_any_role, require_role

@router.get("/items")
async def list_items(user: CurrentUser):  # any authenticated user
    ...

_read = require_any_role("user", "admin")
_write = require_role("admin")

@router.get("/items", dependencies=[Depends(_read)])  ...
@router.post("/items", dependencies=[Depends(_write)]) ...
```

## Adding a new role

```python
# Run once at startup (e.g. in main.py before app creation)
from app.core.auth.models import Role
Role.register("editor")
```

Then update `AUTH_ROLE_MAPPING` so your IdP's "Editors" group maps to `editor`.

## Frontend integration

The Vite app reads `VITE_DEV_AUTH_TOKEN` for local dev. Wire a real provider
(MSAL.js / `keycloak-js` / Firebase Auth SDK) by calling
`setAuthTokenProvider(...)` from `frontend/src/api/fetcher.ts` once on app
boot, returning `idToken` / `accessToken` from the SDK.

## Testing

Use the `set_provider()` helper:

```python
from app.core.auth.provider import DevProvider, set_provider

set_provider(DevProvider())
# Then `Authorization: Bearer alice:admin` works in the test client.
```

See `backend/tests/test_auth.py` for a full example.
