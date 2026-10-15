# Slate

Slate is a high-performance, declarative desktop UI framework written in **DLang** on top of **[Slint](https://slint.dev)**, inspired by Libadwaita/Kirigami and mirroring a modern web-app design language 1:1. Slate combines the expressive power, type safety, and `@nogc` real-time capabilities of D with Slint's reactive declarative UI and rich multi-protocol agent automation.

## Workspace Layout

Slate is designed with **DLang at its core**, featuring native D bindings to Slint, a complete D application framework, network stacks (HTTP/1.1, HTTP/2, HTTP/3 QUIC), embedded Model Context Protocol (MCP) server, and cross-language interoperability (Rust and Carbon):

| Path | Package / Layer | Purpose |
|------|-----------------|---------|
| `slate-dlang/` | `slate` (DUB) | **Core Slate DLang framework**: AppBuilder, reactive controllers, theme engine, fibers/tasks, HTTP/3 QUIC, MCP server & agent automation, rich component controllers |
| `slint-d/` | `slint-d` (DUB) | **DLang Slint runtime bindings**: idiomatic D bindings to Slint runtime via C-ABI bridge crate (`bridge/`) |
| `ui/` | Shared UI Markup | Declarative Slint components (`components/`), layouts (`layouts/`), charts, media, data grid, and entry point (`index.slint`) |
| `slate-rust/` | Multi-language / Reference | Rust crates, reference implementation, agent/MCP test harnesses, and desktop showcase |
| `slate-carbon/` | Google Carbon bindings | Carbon package definitions and C++ runtime bridge on top of Slint C++ |

---

## DLang Core Architecture (`slate-dlang` & `slint-d`)

### 1. `slate-dlang` — The Core Slate Framework (`dub: slate`)

The core framework provides all building blocks needed for full-featured, reactive desktop applications:

* **Application Lifecycle & Builder (`slate.app`)**: Fluent `AppBuilder` value-type builder for window configuration, event loops, theme selection, and plugin registration.
* **Component Controllers & Widgets (`slate.components.*`)**:
  * `layouts`: Resizable panel groups, bento grids, master-detail, dock, wizard, and wrap layouts.
  * `datagrid`: Reactive data table controller with sorting, filtering, and selection models.
  * `log_viewer`: High-throughput, virtualized log viewer with level filtering and search.
  * `media`: Media player controller with playback state, volume, scrubbing, and duration tracking.
  * `dropzone` & `file_dialog`: Drag-and-drop file upload integration and native file/directory dialogs.
* **Agent Automation & Bridge (`slate.agent.*`)**:
  * Full UI inspection, element tree querying, and action dispatching.
  * Decoupled architecture: `model`, `engine`, `protocol`, `bridge`, `fiber`, and `slint_backend`.
  * Declarative traits and builders to connect AI agents directly to running UI components.
* **Model Context Protocol Server (`slate.mcp.*`)**:
  * Embedded JSON-RPC 2.0 / MCP endpoint exposing UI automation tools to LLMs and agents.
  * Standardized tools: `get_state`, `inspect_tree`, `click_element`, `send_keys`, `get_screenshot`.
  * Transports: stdio (`slate.mcp.transport.stdio`) and in-memory (`slate.mcp.transport.memory`).
* **High-Performance Networking (`slate.http` & `slate.quic`)**:
  * `slate.http`: Memory-safe, idiomatic libcurl client supporting HTTP/1.1, HTTP/2, and HTTP/3 with asynchronous tasks (`HttpTask`).
  * `slate.quic`: Pure D, sans-I/O implementation of the complete QUIC protocol suite (RFC 9000, 9001, 9002), including wire codecs, crypto (AEAD, HP, initial keys via OpenSSL), stream maps, and loss recovery/congestion control.
  * `slate.bin.durl`: CLI tool showcasing the HTTP/QUIC networking engine.
* **Theme & UI State (`slate.theme`, `slate.controller`, `slate.tasks`)**:
  * Dark/Light mode theme switching and system theme integration (`slate.platform`).
  * `ComputeController`: Background compute scheduling with cooperative cancellation (`TaskCancellation`).
  * `slate.tasks`: Thread-pool and fiber-backed background concurrency with UI event loop marshaling.
* **Utilities (`slate.utils.*`)**:
  * Color manipulation and palette generation (`slate.utils.color`).
  * Number and string formatting (`slate.utils.format`).
  * Fast JSON serialization/deserialization helpers (`slate.utils.json`).
  * Pure math routines and PRNG demo workloads (`slate.utils.math`, `slate.demo`).
  * Chart data series adapters (`slate.utils.chart`).

### 2. `slint-d` — Slint Bindings for D (`dub: slint-d`)

Idiomatic D bindings wrapping Slint's dynamic runtime via a high-performance C-ABI bridge crate:
* **Value & Types (`slint.value`)**: Bi-directional conversion between D types and Slint dynamic values (strings, numbers, booleans, structs, brushes/colors, arrays).
* **Compiler & Loader (`slint.compiler`, `slint.loader`)**: On-the-fly and ahead-of-time compilation of `.slint` markup files with diagnostics reporting.
* **Component Instance & Callbacks (`slint.instance`, `slint.callback`)**: Dynamic property access, global singleton access, and callback handler registration with scoped lifetimes.
* **Models (`slint.model`)**: `Model!T`, `ArrayModel!T`, and dynamic adapters feeding Slint `for ... in` repeaters.
* **Event Loop & Timers (`slint.eventloop`, `slint.timer`)**: Event loop control, native timers, and thread-safe UI marshaling (`invokeFromEventLoop`).
* **Fiber Integration (`slint.fiber`)**: Cooperative UI tasks executed on D fibers.

---

## Quick Start (DLang)

### Prerequisites

* **DMD 2.113+** and **DUB 1.42+**:
  ```sh
  curl -fsS https://dlang.org/install.sh | bash -s install dmd
  source ~/dlang/dmd-*/activate
  ```
* **Rust Toolchain** (required for building the `slint-d` C-ABI bridge):
  ```sh
  cargo --version
  ```

### Building & Running with Just

| Recipe | Description |
|--------|-------------|
| `just d-test` | Run all `slint-d` pure-D unit tests (no display needed) |
| `just d-build` | Build `slint-d` library package |
| `just d-bridge` | Build the Rust C-ABI bridge (`libslint_d_bridge`) |
| `just d-example` | Run the `slint-d` hello counter example |
| `just d-gallery` | Render the component gallery from D offscreen into `renders/dlang-gallery` |
| `just slate-test` | Run `slate-dlang` pure-D unit tests |
| `just slate-build` | Build `slate-dlang` core framework |

### Additional Toolchain Recipes

| Recipe | What it does |
|--------|--------------|
| `just build` / `check` / `test` / `fmt` | Cargo commands for Rust crates / reference implementation |
| `just run` (`showcase`) | Launch interactive desktop showcase app |
| `just web-mirror` | Web-layout mirror showcase |
| `just render [dir]` | Offline PNG snapshots (software renderer) into `renders/` |
| `just optical-check` | Render to temp dir and compare with golden images |
| `just optical-bless` | Regenerate golden images |

---

## Legacy webapp stack (preserved, not the Slate framework)

The remainder of this file describes the original Python/React webapp template that still lives in
`backend/`, `frontend/`, `api/`, `infrastructure/`.

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
