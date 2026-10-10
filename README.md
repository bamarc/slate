# ${{ values.projectTitle }} (`${{ values.projectName }}`)

> ${{ values.projectDescription }}

- **Jira Onboarding Ticket**: `${{ values.jiraTicket }}`
- **LeanIX Application ID (APL)**: `${{ values.aplId }}`
- **Application Class**: `${{ values.applicationClass | upper }}`
- **Domain**: `${{ values.domain }}`
- **Contact Person**: `${{ values.contactPerson }}`

---

## Architecture Overview

This template adopts a highly optimized **Combined Container** design for production execution, alongside decoupled standalone services for local development:

```
Combined Production Runtime Container (Port 80)
 └── Supervisord (Process Manager, PID 1)
      ├── Nginx (Reverse Proxy & Static Files server for React SPA at `/`)
      └── FastAPI / Uvicorn (FastAPI API server running at `http://127.0.0.1:8000`)
```

### Key Benefits
* **Shared Session Security**: Both frontend and backend share the same origin, allowing Azure Easy Auth to protect both paths transparently.
* **No CORS Issues**: Local development and production use single-port routing, completely eliminating CORS configuration bugs.
* **Cost Efficiency**: Runs as a single container instance inside Azure Container Apps (ACA).

---

## Identity & Access Management (Dual-Mode Auth)

The template implements a dual-mode authentication model to make local development fast and effortless, while retaining strict zero-trust identity extraction in cloud environments.

### 1. Production Mode (Azure Easy Auth)
When deployed to Azure, the application relies entirely on gateway-level authentication:
* **Mechanism**: Azure App Service / Container Apps verify the user identity and forward the verified claims to the container in the `X-MS-CLIENT-PRINCIPAL` base64-encoded header.
* **FastAPI Extraction**: The backend automatically base64-decodes the header and maps identity claims (`preferred_username` -> `kid`, `name`, `email`) and roles (from Entra App Registration).
* **VNet Safety**: Eliminates outbound connection requirements (JWKS endpoints) from inside secure backends.

### 2. Local Development & Testing Mode
When running locally (detected via `ENV=local` or `ENV=development`):
* **Fallback Bearer Verification**: FastAPI falls back to validating standard signed JWTs on the `Authorization: Bearer <token>` header.
* **Mock Token Issuer**: Exposes a POST endpoint `/api/v1/auth/mock-token` to issue signed mock JWTs with customizable roles and identity claims for debugging.
* **Environment Protection**: The `/mock-token` endpoint returns `HTTP 404 Not Found` in non-local environments.

### 3. Role-Based Access Control (RBAC)
Roles are mapped to granular permission strings defined centrally in `app/core/rbac.py`:
```python
ROLE_PERMISSIONS = {
    UserRole.user: ["User.Read"],
    UserRole.admin: ["User.Read", "Administration.Read"],
}
```
Route protection is enforced via declarative FastAPI dependencies:
```python
@router.get("/admin/dashboard", dependencies=[Depends(RequirePermission("Administration.Read"))])
async def admin_dashboard():
    return {"message": "Welcome, Administrator."}
```

---

## Local Development Setup

### Prerequisites
* [uv](https://github.com/astral-sh/uv) (Fast Python Package Installer & Resolver)
* [pnpm](https://pnpm.io/) & [Node.js 22](https://nodejs.org/)
* Docker & Docker Compose

### Fast Bootstrap
Run the bootstrap script to install dependencies for both the frontend and backend, generate API clients, and set up git pre-commit hooks:
```bash
scripts/bootstrap.sh
```

### Running Locally
To launch the database, backend development server, and Vite frontend hot-reload server simultaneously:
```bash
scripts/dev.sh
```

---

## CI/CD & Enterprise Deployment (ACA + JFrog Artifactory)

Azure Container Apps (ACA) is the only supported hosting target. **JFrog Artifactory** is the mandatory container image registry; Azure Container Registry (ACR) is not supported.

### Required CI/CD Variables
Before enabling image build and deployment jobs in your own GitLab project, ensure that the following variables are configured in GitLab CI/CD settings:
* `ARTIFACTORY_USERNAME`: Your enterprise technical user or personal Artifactory username.
* `ARTIFACTORY_TOKEN`: Your Artifactory API key or access token.
* `JFROG_REGISTRY`: The JFrog registry host/repository path.

The infrastructure layer also requires Atlantis-managed VNet and delegated
subnets. The app subnet must be delegated to `Microsoft.App/environments` and
the database subnet to `Microsoft.DBforPostgreSQL/flexibleServers`.

The local Compose stack always includes an OpenTelemetry collector sidecar and
Jaeger. Open `http://localhost:16686` to inspect traces.

### Image Build & Deployment Workflow
The centralized pipeline (`ci-support` `v1.2.0-beta`) supports both single-container and multi-container architectures:
- **Single-Container Mode (Default)**: Builds the unified container image using the root `Dockerfile` (combining the FastAPI API and built React static assets behind port 80) and deploys it to the target Azure Container App.
- **Multi-Container Mode**: For applications requiring separate containers (e.g., dedicated backend and frontend containers, or worker/optimizer sidecars), specify a `containers.json` file (see `containers.example.json`) or configure the `containers` JSON input in `.gitlab-ci.yml`. The CI pipeline automatically iterates through each defined container for both Docker build/push and Azure Container App deployment.


---

## Testing & Verification

### Run Automated Tests
```bash
scripts/test.sh          # Runs pytest (backend) and vitest (frontend)
scripts/test.sh backend  # Runs backend-only pytest with coverage enforcement
```

### Build & Run Combined Docker Locally
To verify the production Combined target on your local machine:
```bash
# Build combined stage
docker build --target combined -t ${{ values.projectName }}:local .

# Run with local database or mock configuration
docker run -p 8080:80 -e ENV=local -e AUTH_REQUIRED=false ${{ values.projectName }}:local
```
Visit `http://localhost:8080` to interact with the SPA and verify routing proxies.
