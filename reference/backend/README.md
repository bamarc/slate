# Backend — FastAPI + SQLAlchemy + Alembic + OpenTelemetry

## Quick Start

```bash
cd backend
uv sync                           # Install dependencies
uv sync --group migrations        # Include sync DB driver for Alembic
uv run alembic upgrade head       # Run migrations
uv run uvicorn app.main:app --reload  # Start dev server (port 8000)
```

## Database

- **Default**: PostgreSQL via SQLAlchemy 2.0 (async with asyncpg)
- **Alternative**: MongoDB via Motor/Beanie (`uv sync --group mongodb`)
- **Migrations**: Alembic uses a sync driver — activate with `uv sync --group migrations`

Configure connection in `backend/app/core/config.py` or via environment variables.

## Configuration — layered priority

The config system loads settings with this priority (lowest → highest):

```
1. Pydantic field defaults   (in config.py)
2. config.yaml                (general, committed)
3. config.{APP_ENV}.yaml      (environment-scoped, e.g. config.dev.yaml)
4. Environment variables      (overrides everything)
```

| File | Purpose |
|------|---------|
| `config.yaml` | General config — lowest YAML priority |
| `config.dev.yaml` | Development overrides (debug logging, echo SQL) |
| `config.prod.yaml` | Production overrides (quiet logging, restricted CORS) |
| `.env.example` | All supported environment variables documented |

Switch environments:
```bash
APP_ENV=prod uv run uvicorn app.main:app
APP_ENV=test uv run pytest
```

## Code Generation — contract‑first

The project root `generate.sh` syncs backend models and frontend client from
the OpenAPI spec:

```bash
./generate.sh          # full regeneration
./generate.sh --dry-run  # preview only
```

This runs:
1. **Backend**: `datamodel-code-generator` → `backend/app/models/_generated/` (Pydantic v2)
2. **Frontend**: `orval` → `frontend/src/api/generated/` (TypeScript + React Query)

⚠️ **Never edit generated files** — they are regenerated from the OpenAPI spec.
If the generated types don't match what you need, change `api/openapi.yaml`.

## Observability — OpenTelemetry

Every HTTP request and database query produces spans exported via OTLP.

| Env var | Purpose | Default |
|---------|---------|---------|
| `OTEL_ENABLED` | Enable/disable tracing | `true` |
| `OTEL_SERVICE_NAME` | Service name in traces | `fullstack-template` |
| `OTEL_EXPORTER_ENDPOINT` | OTLP collector address | `http://localhost:4317` |
| `OTEL_EXPORTER_PROTOCOL` | `grpc` or `http/protobuf` | `grpc` |

### Running a collector (optional)
```bash
docker run -p 4317:4317 otel/opentelemetry-collector-contrib
```

All logs are structured JSON carrying `correlation_id`, `trace_id`, and `span_id`.

## Error handling

- `X-Correlation-ID` header on every response (extracted or generated)
- `422` → structured validation errors with field details
- `500` → safe message with correlation ID, full traceback in logs
- Custom exception handlers in `app/core/errors.py`

## Architecture — SOLID Services

```
backend/
├── app/
│   ├── api/              # HTTP layer (FastAPI routers — thin)
│   │   └── v1/           #   Routes delegate to services, never touch DB
│   ├── core/             # Config, logging, OTEL, error handling
│   ├── db/               # SQLAlchemy engine, session, declarative base
│   ├── models/           # Pydantic schemas (hand-written + _generated)
│   ├── services/         # Business-logic layer (SOLID)
│   │   ├── protocols.py  #   Abstract interfaces (DIP, ISP)
│   │   ├── container.py  #   DI container — wired at startup
│   │   └── health.py     #   Concrete service
│   ├── domains/          # Business domains (bounded contexts)
│   │   └── items/        #   Full CRUD example
│   └── main.py           # App factory + lifespan wiring
├── alembic/              # Database migrations (OTEL-instrumented)
├── config.yaml           # General config (lowest priority)
├── config.dev.yaml       # Dev overrides
├── config.prod.yaml      # Prod overrides
├── .env.example          # Env var documentation
├── tests/                # Pytest test suite
└── pyproject.toml        # uv-managed dependencies
```

### Request flow with tracing

```
HTTP → CorrelationId → FastAPI span → Service → Repository → SQLAlchemy span → DB
  │         │              │              │            │             │
  │    X-Correlation-ID   trace_id      span_id     span_attrs   db.statement
  └── All logs carry correlation_id + trace_id + span_id
```

## Testing

```bash
uv run pytest          # Run all tests
uv run pytest -v       # Verbose output
uv run ruff check .    # Lint
```

## Adding a new domain

1. Create `app/domains/<name>/` with `models.py`, `schemas.py`, `repository.py`, `service.py`, `router.py`
2. Register the router in `app/api/v1/__init__.py`
3. Import the SQLAlchemy model in `app/db/__init__.py` for Alembic discovery
4. Add schemas to `api/openapi.yaml`
5. Run `./generate.sh` to regenerate Pydantic models + TypeScript client
