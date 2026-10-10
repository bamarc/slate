"""Service container — simple, explicit dependency injection.

Instead of a framework-heavy DI container, we use a plain dict registry
that is populated once at application startup and exposed via FastAPI's
``request.app.state``.  This keeps the wiring explicit and searchable.

Usage in a route handler::

    from app.services.container import get_service
    from app.services.protocols import ReadOnlyService
    from app.services.health import HealthStatus

    svc: ReadOnlyService[HealthStatus] = get_service(request, "health")
    status = await svc.get_status()
"""

from __future__ import annotations

from collections.abc import MutableMapping
from typing import Any

from fastapi import Request

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

_registry: MutableMapping[str, Any] = {}


def register(name: str, instance: Any) -> None:
    """Register a service instance under *name*."""
    _registry[name] = instance


def resolve(name: str) -> Any:
    """Return the registered service instance, or raise ``KeyError``."""
    return _registry[name]


def get_service(request: Request, name: str) -> Any:
    """Convenience shortcut — reads from ``app.state.services``."""
    services: MutableMapping[str, Any] = request.app.state.services  # type: ignore[assignment]
    return services[name]


# ---------------------------------------------------------------------------
# Lifespan helpers
# ---------------------------------------------------------------------------


def create_services() -> MutableMapping[str, Any]:
    """Factory: build all service instances and return as a dict.

    Call once during application startup and attach to ``app.state``.
    """
    from app.services.health import HealthService

    services: dict[str, Any] = {}

    # --- System services ---
    services["health"] = HealthService()

    return services
