---
name: local-stack-management
description: 'Manage the local compose stack (db + backend + frontend): start, stop, reset, inspect logs, open psql, troubleshoot port/env errors. Use whenever the user wants to run, restart, or debug the dockerised stack.'
allowed-tools: [shell]
---

# Local Stack Management

The local stack is defined in `compose.yaml` and parameterised entirely via
`.env`. Three services: **db** (postgres:16.4-alpine), **backend** (FastAPI),
**frontend** (nginx serving the Vite build).

## First-time setup

```bash
cp .env.example .env
# Edit .env — at minimum set POSTGRES_PASSWORD to something non-default.
just up                # builds images, starts in background, waits for health
```

## Day-to-day

| Need | Command |
|---|---|
| Foreground (logs streamed) | `just dev` |
| Background | `just up` |
| Stop, keep data | `just down` |
| Full reset incl. db volume | `just down-hard` |
| One service's logs | `just logs backend` |
| Shell into a service | `docker compose exec backend bash` |
| psql in the db container | `just psql` |
| Rebuild after Dockerfile change | `docker compose build --no-cache <svc>` |

## Environment knobs (`.env`)

Compose interpolates these — missing required ones fail fast:

- `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` — **required**, no defaults
- `BACKEND_PORT` (default `8000`)
- `FRONTEND_PORT` (default `8080`)
- `POSTGRES_PORT` (default `5432`)
- `AUTH_REQUIRED`, `AUTH_PROVIDER` — wired through to the backend
- `VITE_API_BASE_URL` — baked into the frontend at build time

## Healthchecks

Each service has a healthcheck — `depends_on` uses `condition: service_healthy`,
so `backend` won't start until `db` answers `pg_isready`, and `frontend` waits
for the backend's `/api/v1/health`.

If `just up` hangs on "waiting for healthy", check:

```bash
docker compose ps              # see health column
docker compose logs db | tail
docker compose logs backend | tail
```

## Resource limits

Each service is capped at 1 CPU / 512MB via the `x-resources` anchor. If a
service is OOM-killed under load, bump those numbers — but only locally; in
production the orchestrator (k8s/ECS) sets limits.

## Troubleshooting

- **`bind: address already in use`** → another process on `BACKEND_PORT`/
  `FRONTEND_PORT`/`POSTGRES_PORT`. Change the variable in `.env` and re-up.
- **CORS error in browser** → `CORS_ORIGINS` in `compose.yaml` includes
  `http://localhost:${FRONTEND_PORT}`. If you serve the frontend from a
  different origin (e.g. `vite dev`), add it.
- **Migrations didn't run** → the backend command chain is
  `alembic upgrade head && uvicorn ...`. Check `just logs backend` for the
  alembic output. To run them manually inside the container:
  `docker compose exec backend uv run alembic upgrade head`.
- **`AUTH_REQUIRED=true` but no IdP** → use `AUTH_PROVIDER=dev` and the dev
  token format `<sub>:<role>` (e.g. `alice:admin`) in the
  `Authorization: Bearer ...` header. See the `auth-integration` skill.
