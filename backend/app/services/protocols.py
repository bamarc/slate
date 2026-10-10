"""Service layer abstractions — Dependency Inversion principle.

Every service in the application implements one of these abstract protocols.
Routes depend on these interfaces, never on concrete implementations.
This keeps the system open for extension, closed for modification (OCP).
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Protocol, TypeVar

# ---------------------------------------------------------------------------
# Generic type helpers
# ---------------------------------------------------------------------------

T = TypeVar("T", covariant=True)


@dataclass(frozen=True)
class Page[T]:
    """Paginated result envelope."""

    items: list[T]
    total: int
    page: int
    page_size: int

    @property
    def pages(self) -> int:
        return max(1, (self.total + self.page_size - 1) // self.page_size)


# ---------------------------------------------------------------------------
# Repository protocol  (Interface Segregation — focused on persistence)
# ---------------------------------------------------------------------------


class Repository[T](Protocol):
    """Abstract persistence contract — single responsibility: data access."""

    async def get(self, id: int) -> T | None: ...
    async def list(self, page: int = 1, page_size: int = 20) -> Page[T]: ...
    async def create(self, obj: T) -> T: ...
    async def update(self, id: int, obj: T) -> T | None: ...
    async def delete(self, id: int) -> bool: ...


# ---------------------------------------------------------------------------
# Service protocol  (Interface Segregation — focused on business logic)
# ---------------------------------------------------------------------------


class Service[T](ABC):
    """Abstract business-logic contract.

    Subclasses orchestrate domain rules, validation, and cross-cutting
    concerns (logging, caching, authz).  They *depend on* a Repository
    rather than reaching into the database directly.
    """

    __slots__ = ()

    @abstractmethod
    async def get(self, id: int) -> T:
        """Retrieve a single entity by id.  Raises if not found."""
        ...

    @abstractmethod
    async def list(self, page: int = 1, page_size: int = 20) -> Page[T]:
        """Return a paginated list of entities."""
        ...

    @abstractmethod
    async def create(self, data: object) -> T:
        """Create a new entity from validated input data."""
        ...

    @abstractmethod
    async def update(self, id: int, data: object) -> T:
        """Update an existing entity.  Raises if not found."""
        ...

    @abstractmethod
    async def delete(self, id: int) -> None:
        """Delete an entity by id.  Raises if not found."""
        ...


# ---------------------------------------------------------------------------
# Marker protocol for health-check-like services (no CRUD)
# ---------------------------------------------------------------------------


class ReadOnlyService[T](ABC):
    """Service contract for read-only or stateless operations."""

    __slots__ = ()

    @abstractmethod
    async def get_status(self) -> T: ...
