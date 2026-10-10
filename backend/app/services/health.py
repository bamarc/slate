"""Health service — reports application and database availability."""

from __future__ import annotations

from pydantic import BaseModel
from sqlalchemy import text

from app.core.config import settings
from app.db.session import async_session_factory
from app.services.protocols import ReadOnlyService


class HealthStatus(BaseModel):
    """Response value object for health data."""

    status: str
    version: str
    database: str


class HealthService(ReadOnlyService[HealthStatus]):
    """Stateless service that reports application health.

    Single Responsibility: owns the health-check concern.
    Dependency Inversion: routes depend on ReadOnlyService[HealthStatus],
    not on this concrete class.
    """

    async def get_status(self) -> HealthStatus:
        db_status = await self._check_database()
        overall = "ok" if db_status == "connected" else "degraded"
        return HealthStatus(
            status=overall,
            version=settings.app_version,
            database=db_status,
        )

    async def _check_database(self) -> str:
        """Ping the database with a lightweight query."""
        try:
            async with async_session_factory() as session:
                await session.execute(text("SELECT 1"))
            return "connected"
        except Exception:
            return "unreachable"
