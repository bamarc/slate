---
description: 'Python conventions for this project: FastAPI, Pydantic v2, async SQLAlchemy, ruff linting, pytest'
applyTo: '**.py'
---

# Python project conventions

## Style
- `ruff` enforces E, F, I, W rules — run `uv run ruff check .`
- Line length: 100 characters
- Quotes: double quotes `""` always
- Always start with `from __future__ import annotations`

## Typing
- Always annotate function signatures (PEP 484)
- Use `| None` instead of `Optional[...]`
- Prefer `Protocol` over ABC for interfaces

## Async
- FastAPI routes are `async def`
- All service/repository methods are `async`
- Use `asyncpg` for PostgreSQL, not sync drivers

## Testing
- `pytest` with `pytest-asyncio` (auto mode)
- Use `AsyncClient` from httpx, not FastAPI TestClient
- Test files: `tests/test_<module>.py`

## Services
- Business logic in `app/services/` or `app/domains/<name>/service.py`
- Data access in `app/domains/<name>/repository.py`
- Routes in `app/api/v1/` (thin — delegate to services)
