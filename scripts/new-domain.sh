#!/usr/bin/env bash
# new-domain.sh — scaffold a new backend domain (router + service + repository
# + schemas + models + tests). Mirrors the structure of `app/domains/items/`.
#
# Usage: scripts/new-domain.sh <name>          # singular snake_case, e.g. "task"
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:-}"
if [ -z "$NAME" ] || ! [[ "$NAME" =~ ^[a-z][a-z0-9_]*$ ]]; then
  echo "Usage: $0 <snake_case_singular_name>"
  exit 1
fi

DOMAIN_DIR="$ROOT_DIR/backend/app/domains/${NAME}s"
if [ -d "$DOMAIN_DIR" ]; then
  echo "❌ Already exists: $DOMAIN_DIR"
  exit 1
fi

# Capitalised class name
CLASS="$(echo "$NAME" | sed -E 's/(^|_)([a-z])/\U\2/g')"

mkdir -p "$DOMAIN_DIR"
cat > "$DOMAIN_DIR/__init__.py" <<EOF
"""$CLASS domain — router, service, repository, schemas, models."""
EOF

cat > "$DOMAIN_DIR/models.py" <<EOF
"""SQLAlchemy model for $CLASS."""
from __future__ import annotations

from datetime import datetime
from sqlalchemy import DateTime, Integer, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class ${CLASS}Model(Base):
    __tablename__ = "${NAME}s"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    title: Mapped[str] = mapped_column(String(255), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )
EOF

cat > "$DOMAIN_DIR/schemas.py" <<EOF
"""Pydantic schemas for $CLASS."""
from __future__ import annotations

from datetime import datetime
from pydantic import BaseModel, ConfigDict


class ${CLASS}Base(BaseModel):
    title: str


class ${CLASS}Create(${CLASS}Base):
    pass


class ${CLASS}Update(BaseModel):
    title: str | None = None


class ${CLASS}Response(${CLASS}Base):
    model_config = ConfigDict(from_attributes=True)

    id: int
    created_at: datetime
    updated_at: datetime
EOF

cat > "$DOMAIN_DIR/repository.py" <<EOF
"""Repository for $CLASS."""
from __future__ import annotations

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.domains.${NAME}s.models import ${CLASS}Model
from app.services.protocols import Page


class ${CLASS}Repository:
    __slots__ = ("_session",)

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(self, id: int) -> ${CLASS}Model | None:
        return await self._session.get(${CLASS}Model, id)

    async def list(self, page: int = 1, page_size: int = 20) -> Page[${CLASS}Model]:
        offset = (page - 1) * page_size
        total = (await self._session.execute(select(func.count()).select_from(${CLASS}Model))).scalar_one()
        items = list((await self._session.execute(
            select(${CLASS}Model).offset(offset).limit(page_size).order_by(${CLASS}Model.id)
        )).scalars().all())
        return Page(items=items, total=total, page=page, page_size=page_size)
EOF

cat > "$DOMAIN_DIR/service.py" <<EOF
"""Service for $CLASS."""
from __future__ import annotations

from app.domains.${NAME}s.repository import ${CLASS}Repository
from app.domains.${NAME}s.schemas import ${CLASS}Response
from app.services.protocols import Page


class ${CLASS}Service:
    __slots__ = ("_repo",)

    def __init__(self, repo: ${CLASS}Repository) -> None:
        self._repo = repo

    async def list(self, page: int = 1, page_size: int = 20) -> Page[${CLASS}Response]:
        db_page = await self._repo.list(page, page_size)
        return Page(
            items=[${CLASS}Response.model_validate(x) for x in db_page.items],
            total=db_page.total,
            page=db_page.page,
            page_size=db_page.page_size,
        )
EOF

cat > "$DOMAIN_DIR/router.py" <<EOF
"""HTTP routes for $CLASS."""
from __future__ import annotations

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.domains.${NAME}s.repository import ${CLASS}Repository
from app.domains.${NAME}s.schemas import ${CLASS}Response
from app.domains.${NAME}s.service import ${CLASS}Service
from app.services.protocols import Page

router = APIRouter(prefix="/${NAME}s", tags=["${CLASS}s"])


@router.get("", response_model=Page[${CLASS}Response])
async def list_${NAME}s(
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
) -> Page[${CLASS}Response]:
    svc = ${CLASS}Service(repo=${CLASS}Repository(session=db))
    return await svc.list(page=page, page_size=page_size)
EOF

mkdir -p "$ROOT_DIR/backend/tests"
cat > "$ROOT_DIR/backend/tests/test_${NAME}s.py" <<EOF
"""Tests for $CLASS domain."""
import pytest


@pytest.mark.asyncio
async def test_placeholder() -> None:
    assert True
EOF

echo "✅ Scaffolded domain '${NAME}' at $DOMAIN_DIR"
echo "   Next:"
echo "   1. Add the schema to api/openapi.yaml"
echo "   2. Wire the router in backend/app/api/__init__.py"
echo "   3. Create an Alembic migration: cd backend && uv run alembic revision --autogenerate -m 'add ${NAME}s'"
echo "   4. Run: scripts/generate.sh"
