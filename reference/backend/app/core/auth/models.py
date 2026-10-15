"""Auth domain models — authenticated user + role registry.

Roles are extendable: register new ones via `Role.register("editor")` or
extend the `Role` enum-like at startup. The two template roles (`user`,
`admin`) cover the default scaffold.
"""

from __future__ import annotations

from collections.abc import Iterable
from typing import ClassVar

from pydantic import BaseModel, ConfigDict, Field


class Role(str):
    """String-typed role with a class-level registry.

    Use as a plain string in code (`"user"`, `"admin"`) — the registry
    exists so that role mapping config and audit tooling can iterate
    over all known roles.

        Role.register("editor", "viewer")
        Role.known()        # frozenset({"user", "admin", "editor", "viewer"})
    """

    _registry: ClassVar[set[str]] = {"user", "admin"}

    USER: ClassVar[str] = "user"
    ADMIN: ClassVar[str] = "admin"

    @classmethod
    def register(cls, *names: str) -> None:
        """Add new role names to the registry. Names are lowercased."""
        for name in names:
            cls._registry.add(name.strip().lower())

    @classmethod
    def known(cls) -> frozenset[str]:
        return frozenset(cls._registry)

    @classmethod
    def validate(cls, role: str) -> str:
        """Return *role* if known; raise `ValueError` otherwise."""
        norm = role.strip().lower()
        if norm not in cls._registry:
            raise ValueError(f"Unknown role: {role!r}. Register with Role.register() first.")
        return norm


class AuthenticatedUser(BaseModel):
    """The principal extracted from a verified access token.

    Maps the IdP-specific claims into a stable shape. Provider adapters
    are responsible for filling this in.
    """

    model_config = ConfigDict(frozen=True)

    subject: str = Field(..., description="Stable user id (the `sub` claim).")
    email: str | None = Field(None, description="Primary email if present.")
    name: str | None = Field(None, description="Display name if present.")
    roles: frozenset[str] = Field(default_factory=frozenset, description="Granted role set.")
    issuer: str = Field(..., description="`iss` claim of the access token.")
    permissions: list[str] = Field(default_factory=list, description="Resolved permissions.")
    raw_claims: dict[str, object] = Field(
        default_factory=dict,
        description="Original claims dict for advanced authz checks.",
        repr=False,
    )

    def has_role(self, role: str) -> bool:
        return role.lower() in self.roles

    def has_any_role(self, roles: Iterable[str]) -> bool:
        wanted = {r.lower() for r in roles}
        return bool(wanted & self.roles)
