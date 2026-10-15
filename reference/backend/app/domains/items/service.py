"""Item service — business logic layer.

Single Responsibility: orchestrates item CRUD with domain rules.
Open/Closed: extend behaviour via composition (repository) not subclassing.
Dependency Inversion: depends on ``ItemRepository`` (concrete but could
accept a ``Repository[ItemModel]`` protocol for full abstraction).
"""

from __future__ import annotations

from app.domains.items.models import ItemModel
from app.domains.items.repository import ItemRepository
from app.domains.items.schemas import ItemCreate, ItemResponse, ItemUpdate
from app.services.protocols import Page, Service


class ItemService(Service[ItemResponse]):
    """Item business logic."""

    __slots__ = ("_repo",)

    def __init__(self, repo: ItemRepository) -> None:
        self._repo = repo

    async def get(self, id: int) -> ItemResponse:
        item = await self._repo.get(id)
        if item is None:
            raise ValueError(f"Item {id} not found")
        return ItemResponse.model_validate(item)

    async def list(self, page: int = 1, page_size: int = 20) -> Page[ItemResponse]:
        db_page = await self._repo.list(page, page_size)
        return Page(
            items=[ItemResponse.model_validate(item) for item in db_page.items],
            total=db_page.total,
            page=db_page.page,
            page_size=db_page.page_size,
        )

    async def create(self, data: ItemCreate) -> ItemResponse:  # type: ignore[override]
        item = ItemModel(title=data.title, description=data.description)
        created = await self._repo.create(item)
        return ItemResponse.model_validate(created)

    async def update(self, id: int, data: ItemUpdate) -> ItemResponse:  # type: ignore[override]
        patch = ItemModel(title=data.title or "", description=data.description)
        updated = await self._repo.update(id, patch)
        if updated is None:
            raise ValueError(f"Item {id} not found")
        return ItemResponse.model_validate(updated)

    async def delete(self, id: int) -> None:
        deleted = await self._repo.delete(id)
        if not deleted:
            raise ValueError(f"Item {id} not found")
