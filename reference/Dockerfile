# =============================================================================
# Unified Dockerfile — UI, API, and Combined targets
# =============================================================================
# Build targets:
#   docker build --target combined -t ${{ values.projectName }}:latest .
#
# Standalone targets (local development):
#   docker build --target ui -t ${{ values.projectName }}-ui:latest .
#   docker build --target api -t ${{ values.projectName }}-api:latest .
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build React SPA (used by combined and ui)
# ---------------------------------------------------------------------------
FROM node:22-alpine AS ui-build
WORKDIR /app

# Enable corepack for pnpm
RUN corepack enable && corepack prepare pnpm@latest --activate

# Copy package config and lockfile
COPY frontend/package.json frontend/pnpm-lock.yaml* frontend/pnpm-workspace.yaml* ./

# Install dependencies
RUN pnpm install --frozen-lockfile || pnpm install

# Copy source
COPY frontend/ ./
COPY api/openapi.yaml ../api/openapi.yaml

# Generate API client
RUN pnpm orval

# Build with possible API base URL
ARG VITE_API_BASE_URL=""
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL
RUN pnpm build

# ---------------------------------------------------------------------------
# Stage 2: UI standalone (only for local development via docker-compose)
# ---------------------------------------------------------------------------
FROM nginx:alpine AS ui
COPY --from=ui-build /app/dist /usr/share/nginx/html
COPY frontend/nginx.conf /etc/nginx/templates/default.conf.template
EXPOSE 80
ENV BACKEND_URL=http://localhost:8000
CMD ["sh", "-c", "envsubst '${BACKEND_URL}' < /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf && nginx -g 'daemon off;'"]

# ---------------------------------------------------------------------------
# Stage 3: Build FastAPI application
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS api-build

# Copy the binary for uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

ENV UV_COMPILE_BYTECODE=1
ENV UV_LINK_MODE=copy

WORKDIR /app

# Install dependencies
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=backend/uv.lock,target=uv.lock \
    --mount=type=bind,source=backend/pyproject.toml,target=pyproject.toml \
    uv sync --frozen --no-install-project --no-dev --all-extras

# Copy the backend source code
COPY backend/ /app

# Install the project
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --all-extras

# Generate Pydantic models from OpenAPI spec
COPY api/openapi.yaml /tmp/openapi.yaml
RUN mkdir -p /app/app/models/_generated && \
    touch /app/app/models/_generated/__init__.py && \
    uv run datamodel-codegen \
    --input /tmp/openapi.yaml \
    --input-file-type openapi \
    --output /app/app/models/_generated/__init__.py \
    --output-model-type pydantic_v2.BaseModel \
    --target-python-version 3.12 \
    --use-schema-description \
    --collapse-root-models \
    --field-constraints \
    --snake-case-field \
    --allow-population-by-field-name

# ---------------------------------------------------------------------------
# Stage 4: API standalone (only for local development via docker-compose)
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS api

WORKDIR /app

# Copy the virtual environment from the builder
COPY --from=api-build /app/.venv /app/.venv
# Copy alembic configuration & migrations
COPY --from=api-build /app/alembic.ini /app/alembic.ini
COPY --from=api-build /app/alembic /app/alembic
# Copy app source code (from builder, which includes generated models)
COPY --from=api-build /app/app /app/app
# Copy runtime configuration
COPY --from=api-build /app/config*.yaml /app/

# Ensure the app uses the virtualenv
ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONUNBUFFERED=1

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

# ---------------------------------------------------------------------------
# Stage 5: Combined runtime — DEPLOY-ZIEL fuer CI/CD und Azure Container App
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS combined

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        nginx supervisor && \
    rm -rf /var/lib/apt/lists/*

# --- API setup ---
WORKDIR /app
COPY --from=api-build /app/.venv /app/.venv
COPY --from=api-build /app/alembic.ini /app/alembic.ini
COPY --from=api-build /app/alembic /app/alembic
COPY --from=api-build /app/app /app/app
COPY --from=api-build /app/config*.yaml /app/
ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONUNBUFFERED=1

# --- UI setup ---
COPY --from=ui-build /app/dist /usr/share/nginx/html

# --- Configuration ---
COPY nginx.conf /etc/nginx/conf.d/default.conf
# Remove default nginx site to avoid conflicts
RUN rm -f /etc/nginx/sites-enabled/default
COPY supervisord.conf /etc/supervisor/conf.d/app.conf

EXPOSE 80

CMD ["sh", "-c", "alembic upgrade head && supervisord -c /etc/supervisor/conf.d/app.conf"]
