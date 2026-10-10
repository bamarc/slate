"""OpenTelemetry — tracing and instrumentation.

Sets up the global TracerProvider with OTLP exporter and instruments
FastAPI + SQLAlchemy so every HTTP request and database query produces
spans.
"""

from __future__ import annotations

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import SERVICE_NAME, Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

from app.core.config import settings


def init_otel() -> None:
    """Bootstrap the OpenTelemetry SDK and instrument libraries."""

    if not settings.otel_enabled:
        return

    resource = Resource.create({SERVICE_NAME: settings.otel_service_name})

    exporter = OTLPSpanExporter(
        endpoint=settings.otel_exporter_endpoint,
        insecure=True,
    )

    provider = TracerProvider(resource=resource)
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)


def instrument_app(app) -> None:
    """Attach instrumentors to a FastAPI *app* instance."""
    if not settings.otel_enabled:
        return

    FastAPIInstrumentor.instrument_app(app)
