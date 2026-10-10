"""FastAPI application factory."""

from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api import router
from app.core.config import settings
from app.core.errors import register_error_handlers
from app.core.logging import setup_logging
from app.core.otel import init_otel, instrument_app
from app.services.container import create_services


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan — setup/teardown with OTEL tracing."""
    # ── Startup ──────────────────────────────────────────────
    init_otel()
    setup_logging()

    import logging

    logger = logging.getLogger("app")
    logger.info(
        "Starting %s v%s | env=%s", settings.app_name, settings.app_version, settings.environment
    )

    app.state.services = create_services()
    yield
    # ── Shutdown ─────────────────────────────────────────────
    logger.info("Shutting down %s", settings.app_name)


def create_app() -> FastAPI:
    """Create and configure the FastAPI application."""

    app = FastAPI(
        title=settings.app_name,
        version=settings.app_version,
        lifespan=lifespan,
    )

    # ── Error handling + correlation-id (first middleware) ───
    register_error_handlers(app)

    # ── CORS ─────────────────────────────────────────────────
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    # ── Routes ───────────────────────────────────────────────
    app.include_router(router)

    # ── OTEL instrumentation (auto-spans HTTP + DB) ─────────
    instrument_app(app)

    return app


app = create_app()
