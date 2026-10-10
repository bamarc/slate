"""Global error handling and correlation-id middleware.

Registers handlers that wrap every error in a structured JSON response
carrying a correlation_id so clients can trace failed requests.
"""

from __future__ import annotations

import uuid
from collections.abc import Awaitable, Callable
from http import HTTPStatus

from fastapi import HTTPException, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.status import (
    HTTP_422_UNPROCESSABLE_ENTITY,
    HTTP_500_INTERNAL_SERVER_ERROR,
)

from app.core.context import get_correlation_id, set_correlation_id

# ---------------------------------------------------------------------------
# Correlation-ID middleware — runs first in the stack
# ---------------------------------------------------------------------------

_CORRELATION_HEADER = "X-Correlation-ID"
_PROBLEM_MEDIA_TYPE = "application/problem+json"


def _problem_details(
    request: Request, status_code: int, detail: str, **extensions: object
) -> dict[str, object]:
    try:
        title = HTTPStatus(status_code).phrase
    except ValueError:
        title = "HTTP Error"
    body: dict[str, object] = {
        "type": "about:blank",
        "title": title,
        "status": status_code,
        "detail": detail,
        "instance": request.url.path,
        "correlation_id": get_correlation_id() or request.headers.get(_CORRELATION_HEADER, ""),
    }
    body.update(extensions)
    return body


def _problem_response(
    request: Request,
    status_code: int,
    detail: str,
    *,
    headers: dict[str, str] | None = None,
    **extensions: object,
) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content=_problem_details(request, status_code, detail, **extensions),
        headers=headers,
        media_type=_PROBLEM_MEDIA_TYPE,
    )


class CorrelationIdMiddleware(BaseHTTPMiddleware):
    """Extract or generate a correlation-id for every request."""

    async def dispatch(
        self, request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        cid = request.headers.get(_CORRELATION_HEADER) or uuid.uuid4().hex[:12]
        set_correlation_id(cid)
        response = await call_next(request)
        response.headers[_CORRELATION_HEADER] = cid
        return response


# ---------------------------------------------------------------------------
# Exception handlers — registered on the FastAPI app
# ---------------------------------------------------------------------------


async def validation_exception_handler(
    request: Request, exc: RequestValidationError
) -> JSONResponse:
    """Return structured 422 for Pydantic validation failures."""
    return _problem_response(
        request,
        HTTP_422_UNPROCESSABLE_ENTITY,
        "Validation error",
        errors=exc.errors(),
    )


async def http_exception_handler(request: Request, exc: StarletteHTTPException) -> JSONResponse:
    detail = exc.detail if isinstance(exc.detail, str) else str(exc.detail)
    headers = dict(exc.headers) if exc.headers else None
    return _problem_response(request, exc.status_code, detail, headers=headers)


async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    """Catch-all for unexpected errors — 500 with a safe message."""
    import logging

    logger = logging.getLogger("app")
    cid = request.headers.get(_CORRELATION_HEADER, "")
    logger.exception("Unhandled exception | correlation_id=%s", cid)

    return _problem_response(
        request,
        HTTP_500_INTERNAL_SERVER_ERROR,
        "Internal server error",
    )


def register_error_handlers(app) -> None:
    """Wire exception handlers and correlation-id middleware into *app*."""
    app.add_middleware(CorrelationIdMiddleware)
    app.add_exception_handler(HTTPException, http_exception_handler)
    app.add_exception_handler(StarletteHTTPException, http_exception_handler)
    app.add_exception_handler(RequestValidationError, validation_exception_handler)
    app.add_exception_handler(Exception, unhandled_exception_handler)
