# API Specifications

This directory contains the OpenAPI 3.1 specification that drives both backend and frontend development.

## Files

- `openapi.yaml` — Main OpenAPI specification (source of truth)
- `schemas/` — Reusable schema components (optional, for large specs)

## Workflow

1. Edit `openapi.yaml` to define or modify endpoints
2. Backend: Generate/update Pydantic models to match the spec
3. Frontend: Run `pnpm orval` to regenerate the API client

## Convention

All API changes start here before any implementation code is written.
