"""Item repository — database access layer.

Single Responsibility: owns all SQLAlchemy queries for the Item entity.
Liskov Substitution: follows the ``Repository`` protocol shape.
"""

from __future__ import annotations

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.domains.items.models import ItemModel
from app.services.protocols import Page


class ItemRepository:
    """Concrete repository backed by SQLAlchemy async session.

    Dependency Inversion: the service depends on this via the Repository
    protocol — we could swap to a different backend without changing
    business logic.
    """

    __slots__ = ("_session",)

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(self, id: int) -> ItemModel | None:
        return await self._session.get(ItemModel, id)

    async def list(self, page: int = 1, page_size: int = 20) -> Page[ItemModel]:
        offset = (page - 1) * page_size

        # Total count
        count_q = select(func.count()).select_from(ItemModel)
        total_result = await self._session.execute(count_q)
        total: int = total_result.scalar_one()

        # Items
        stmt = select(ItemModel).offset(offset).limit(page_size).order_by(ItemModel.id)
        result = await self._session.execute(stmt)
        items = list(result.scalars().all())

        return Page(items=items, total=total, page=page, page_size=page_size)

    async def create(self, obj: ItemModel) -> ItemModel:
        self._session.add(obj)
        await self._session.flush()
        await self._session.refresh(obj)
        return obj

    async def update(self, id: int, obj: ItemModel) -> ItemModel | None:
        existing = await self.get(id)
        if existing is None:
            return None
        for key, value in obj.__dict__.items():
            if key != "_sa_instance_state" and value is not None:
                setattr(existing, key, value)
        await self._session.flush()
        await self._session.refresh(existing)
        return existing

    async def delete(self, id: int) -> bool:
        existing = await self.get(id)
        if existing is None:
            return False
        await self._session.delete(existing)
        await self._session.flush()
        return True
