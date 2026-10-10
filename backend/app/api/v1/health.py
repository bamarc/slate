"""API v1 routes."""

from __future__ import annotations

from fastapi import APIRouter, Request

from app.services.container import get_service
from app.services.health import HealthStatus
from app.services.protocols import ReadOnlyService

router = APIRouter()


@router.get("/health", response_model=HealthStatus)
async def health_check(request: Request) -> HealthStatus:
    """Return service health status."""
    svc: ReadOnlyService[HealthStatus] = get_service(request, "health")
    return await svc.get_status()
