"""Alembic configuration — with structured OTEL-aware logging.

Every migration step is logged as a structured JSON line carrying
correlation_id, trace_id, and span_id when running inside an
instrumented OTEL context (e.g. under uvicorn with the FastAPI
instrumentor or wrapped in a manual span).
"""

from __future__ import annotations

import logging

from opentelemetry import trace
from sqlalchemy import engine_from_config, pool

from alembic import context

# ── Bootstrap structured logging early ───────────────────────
# This ensures migration log lines carry the same JSON envelope
# as the application logs.
from app.core.logging import setup_logging
from app.db import Base

setup_logging()

logger = logging.getLogger("alembic")

# ── Read DB URL from the app config (swap async driver for sync Alembic) ──
config = context.config
from app.core.config import settings

config.set_main_option(
    "sqlalchemy.url",
    settings.database_url.replace("+asyncpg", "+psycopg2"),
)

target_metadata = Base.metadata

tracer = trace.get_tracer(__name__)


def run_migrations_offline() -> None:
    """Run migrations in 'offline' mode (generates SQL script)."""
    url = config.get_main_option("sqlalchemy.url")
    logger.info("Running offline migrations against %s", url)
    context.configure(url=url, target_metadata=target_metadata, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    """Run migrations in 'online' mode (streams to live DB).

    Wrapped in a manual OTEL span so migration execution is
    visible in the trace graph alongside request spans.
    """
    with tracer.start_as_current_span("db.migrate") as span:
        url = config.get_main_option("sqlalchemy.url")
        span.set_attribute("db.url", url or "unknown")
        logger.info("Running online migrations — acquired connection")

        connectable = engine_from_config(
            config.get_section(config.config_ini_section, {}),
            prefix="sqlalchemy.",
            poolclass=pool.NullPool,
        )
        with connectable.connect() as connection:
            logger.info("Applying migrations...")
            context.configure(connection=connection, target_metadata=target_metadata)
            with context.begin_transaction():
                context.run_migrations()

        logger.info("Migrations complete")
        span.set_attribute("db.migration.status", "complete")


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
