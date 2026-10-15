"""Structured context propagation — correlation-id, otel linkage.

Exposes thread/asyncio-safe context vars so every log line carries:
  - correlation_id   (single request / operation)
  - trace_id          (from the current OpenTelemetry span)
  - span_id           (from the current OpenTelemetry span)
"""

from __future__ import annotations

import contextvars
import uuid

from opentelemetry import trace

# ---------------------------------------------------------------------------
# Context variables — bound once at the start of a request / operation
# ---------------------------------------------------------------------------

_correlation_id: contextvars.ContextVar[str] = contextvars.ContextVar("correlation_id", default="")


def set_correlation_id(cid: str | None = None) -> str:
    """Store (or generate) a correlation id for the current context."""
    if cid is None:
        cid = uuid.uuid4().hex[:12]
    _correlation_id.set(cid)
    return cid


def get_correlation_id() -> str:
    """Return the current correlation id, or empty string."""
    return _correlation_id.get()


# ---------------------------------------------------------------------------
# OTEL helpers
# ---------------------------------------------------------------------------


def get_otel_context() -> dict[str, str]:
    """Return trace_id + span_id from the current OTEL span, if any."""
    span = trace.get_current_span()
    if span is None:
        return {}
    ctx = span.get_span_context()
    if ctx == trace.INVALID_SPAN_CONTEXT:
        return {}
    return {
        "trace_id": trace.format_trace_id(ctx.trace_id),
        "span_id": trace.format_span_id(ctx.span_id),
    }
