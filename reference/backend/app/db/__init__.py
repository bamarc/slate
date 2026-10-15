"""Re-export base for Alembic — import all models so they register."""

from app.db.base import Base  # noqa: F401

# ── Import all SQLAlchemy models here for Alembic auto-detection ──
from app.domains.items.models import ItemModel  # noqa: F401
