FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Avoid prompts from apt
ENV DEBIAN_FRONTEND=noninteractive

# Install essential development utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    ripgrep \
    jq \
    postgresql-client \
    build-essential \
    libpq-dev \
    ca-certificates \
    yamllint \
    graphviz \
    default-jre-headless \
    ruby-full \
    perl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install uv (Astral fast Python package manager) for all users
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# Install hadolint (Dockerfile linter)
COPY --from=hadolint/hadolint:latest /bin/hadolint /usr/local/bin/hadolint

# Install just command runner
RUN curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin

# Set environment variables
ENV UV_LINK_MODE=copy \
    PYTHONUNBUFFERED=1

# Ensure vscode user has local bin on PATH
USER vscode
ENV PATH="/home/vscode/.local/bin:${PATH}"
