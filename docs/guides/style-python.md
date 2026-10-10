# Style Guide — Python

## Formatting
- Line length: 100 characters
- Indentation: 4 spaces (no tabs)
- Quotes: double quotes (`"`) for strings
- Imports: grouped and sorted via ruff (see `pyproject.toml`)

## Naming
| Element | Convention | Example |
|---------|-----------|---------|
| Modules | `snake_case` | `health_service.py` |
| Classes | `PascalCase` | `HealthService` |
| Functions/Methods | `snake_case` | `get_status()` |
| Variables | `snake_case` | `db_session` |
| Private | Prefix `_` | `_build_query()` |
| Constants | `UPPER_CASE` | `MAX_RETRIES` |

## Typing
- Always annotate function signatures (PEP 484)
- Use `from __future__ import annotations` at the top of every module
- Prefer `| None` over `Optional[...]`
- Use `Self` return type for class methods returning `self`
- Use `Protocol` (structural subtyping) over ABC for interfaces

## Async
- FastAPI routes are `async def`
- Services expose `async` methods
- Use `asyncio.gather()` for parallel independent operations
- Never `sync_to_async` — prefer native async libraries

## Imports order
```
# 1. Future
from __future__ import annotations

# 2. Standard library
from collections.abc import ...
import dataclasses

# 3. Third-party
from fastapi import ...
from pydantic import ...

# 4. Application
from app.core.config import ...
from app.services.protocols import ...

# 5. Type-checking only
from typing import TYPE_CHECKING
if TYPE_CHECKING:
    from app.domains.items.service import ItemService
```

## Error handling
- Use `from_exc` / `from exc` chaining for exception context
- Domain-specific exceptions live in the domain's `exceptions.py`
- FastAPI routes catch domain exceptions and map to HTTP status codes
- Do NOT catch bare `Exception` — prefer specific exception types

## Testing
- Test files mirror source: `tests/test_{module}.py`
- Use `pytest` with async fixtures
- Prefer `AsyncClient` (httpx) over FastAPI's `TestClient`
- One assertion per test when practical
- Fixtures in `conftest.py` for shared state
