FROM python:3.12-slim

WORKDIR /app

ENV PYTHONPATH=/app
ENV UV_LINK_MODE=copy

RUN pip install uv

COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --no-dev --all-extras --no-install-project

COPY . .
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --no-dev --all-extras


EXPOSE 8000

CMD ["uv", "run", "--no-sync", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
