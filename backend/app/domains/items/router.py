"""Item API routes — thin layer, delegates all logic to the service.

Single Responsibility: HTTP concerns only (path ops, status codes, serialization).

Authorization:
- read endpoints  → role: user or admin
- write endpoints → role: admin
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import AuthenticatedUser, require_any_role, require_role
from app.db.session import get_db
from app.domains.items.repository import ItemRepository
from app.domains.items.schemas import ItemCreate, ItemResponse, ItemUpdate
from app.domains.items.service import ItemService
from app.services.protocols import Page

router = APIRouter(prefix="/items", tags=["Items"])

_read_role = require_any_role("user", "admin")
_write_role = require_role("admin")


def _get_service(request: Request, db: AsyncSession) -> ItemService:
    """Factory: create a fresh ItemService per request."""
    return ItemService(repo=ItemRepository(session=db))


@router.get("", response_model=Page[ItemResponse])
async def list_items(
    request: Request,
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
    _user: AuthenticatedUser = Depends(_read_role),
) -> Page[ItemResponse]:
    svc = _get_service(request, db)
    return await svc.list(page=page, page_size=page_size)


@router.get("/{item_id}", response_model=ItemResponse)
async def get_item(
    item_id: int,
    request: Request,
    db: AsyncSession = Depends(get_db),
    _user: AuthenticatedUser = Depends(_read_role),
) -> ItemResponse:
    svc = _get_service(request, db)
    try:
        return await svc.get(item_id)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc


@router.post("", response_model=ItemResponse, status_code=status.HTTP_201_CREATED)
async def create_item(
    data: ItemCreate,
    request: Request,
    db: AsyncSession = Depends(get_db),
    _user: AuthenticatedUser = Depends(_write_role),
) -> ItemResponse:
    svc = _get_service(request, db)
    return await svc.create(data)


@router.put("/{item_id}", response_model=ItemResponse)
async def update_item(
    item_id: int,
    data: ItemUpdate,
    request: Request,
    db: AsyncSession = Depends(get_db),
    _user: AuthenticatedUser = Depends(_write_role),
) -> ItemResponse:
    svc = _get_service(request, db)
    try:
        return await svc.update(item_id, data)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc


@router.delete("/{item_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_item(
    item_id: int,
    request: Request,
    db: AsyncSession = Depends(get_db),
    _user: AuthenticatedUser = Depends(_write_role),
) -> None:
    svc = _get_service(request, db)
    try:
        await svc.delete(item_id)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
