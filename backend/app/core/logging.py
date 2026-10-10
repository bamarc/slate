"""Structured JSON logging with correlation-id and OTEL trace linkage.

Every log line is a JSON object containing:
  - timestamp, level, logger, message
  - correlation_id   (operation-scoped)
  - trace_id, span_id   (from OpenTelemetry, if active)
"""

from __future__ import annotations

import logging
import sys
from datetime import UTC

from app.core.config import settings
from app.core.context import get_correlation_id, get_otel_context


def _json_formatter() -> logging.Formatter:
    """Build a JSON-structured formatter compatible with OTEL collectors."""

    import json
    from datetime import datetime

    class _JsonFormatter(logging.Formatter):
        def format(self, record: logging.LogRecord) -> str:
            payload: dict[str, object] = {
                "timestamp": datetime.now(UTC).isoformat(),
                "level": record.levelname,
                "logger": record.name,
                "message": record.getMessage(),
                "correlation_id": get_correlation_id(),
            }

            otel = get_otel_context()
            if otel:
                payload.update(otel)

            if record.exc_info and record.exc_info[1]:
                payload["exception"] = str(record.exc_info[1])

            return json.dumps(payload, default=str)

    return _JsonFormatter()


def setup_logging() -> None:
    """Replace the root logger handler with a structured JSON stream."""

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(_json_formatter() if settings.log_format == "json" else None)
    handler.setLevel(settings.log_level.upper())

    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(settings.log_level.upper())

    # Silence noisy libraries
    logging.getLogger("uvicorn.access").disabled = True
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)

    # ── Alembic / SQLAlchemy ────────────────────────────
    # Set to INFO to trace every migration step; WARNING for production
    db_level = "INFO" if settings.debug else "WARNING"
    logging.getLogger("alembic").setLevel(db_level)
    logging.getLogger("sqlalchemy.engine").setLevel(db_level)
