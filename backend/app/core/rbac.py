from __future__ import annotations

from enum import StrEnum


class UserRole(StrEnum):
    user = "user"
    admin = "admin"


ROLE_PERMISSIONS: dict[UserRole, list[str]] = {
    UserRole.user: [
        "User.Read",
    ],
    UserRole.admin: [
        "User.Read",
        "Administration.Read",
    ],
}


def get_permissions_for_role(role: str | UserRole | None) -> list[str]:
    """Return permissions for the given role."""
    if role is None:
        return []
    if isinstance(role, UserRole):
        key = role
    elif isinstance(role, str):
        try:
            key = UserRole(role.lower().strip())
        except ValueError:
            return []
    else:
        return []
    return list(ROLE_PERMISSIONS.get(key, []))


def has_permission(user: object, permission: str) -> bool:
    """Check if the user has the given permission."""
    permissions = getattr(user, "permissions", None)
    return permission in (permissions or [])
