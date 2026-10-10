"""Application-level dependencies."""

from __future__ import annotations

from collections.abc import AsyncGenerator

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.config import settings
from app.core.db_url import create_asyncpg_connection, is_entra_auth

engine = create_async_engine(
    settings.database_url,
    echo=settings.database_echo,
    async_creator=create_asyncpg_connection if is_entra_auth() else None,
    pool_recycle=1800 if is_entra_auth() else -1,
)
async_session_factory = async_sessionmaker(engine, expire_on_commit=False)


async def get_db() -> AsyncGenerator[AsyncSession, None]:
    """Yield an async database session."""
    async with async_session_factory() as session:
        yield session
