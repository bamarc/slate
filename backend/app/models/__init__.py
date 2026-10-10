"""Hand-written Pydantic models — domain-specific schemas.

Generated models from the OpenAPI spec live in `_generated/` (gitignored).
Run `./generate.sh` from the project root to regenerate them.

Usage:
    from app.models import HealthResponse
    # or from generated:
    # from app.models._generated import HealthResponse
"""

from __future__ import annotations

from pydantic import BaseModel


class HealthResponse(BaseModel):
    """Health check response (hand-written — mirrors the OpenAPI spec)."""

    status: str
    version: str
