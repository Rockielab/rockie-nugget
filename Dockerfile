FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    RESEARCH_ENV_CONTRACT_DIR=/app/contract/research-env-v1 \
    RESEARCH_ENV_WORKSPACE=/workspace

WORKDIR /app

RUN useradd --create-home --uid 10001 --user-group rockie \
    && install -d --owner=rockie --group=rockie /workspace

COPY contract/research-env-v1/ ./contract/research-env-v1/
COPY mcp/research-env-mcp/ ./mcp/research-env-mcp/

USER 10001:10001
WORKDIR /app/mcp/research-env-mcp

ENTRYPOINT ["python3", "server.py"]
