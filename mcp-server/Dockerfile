FROM python:3.11-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        build-essential \
        libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy postgres-mcp submodule
COPY postgres-mcp/pyproject.toml postgres-mcp/uv.lock ./postgres-mcp/
COPY postgres-mcp/src ./postgres-mcp/src

# Copy distributed extensions
COPY distributed-extensions ./distributed-extensions

# Install uv (fast Python package installer)
RUN pip install --no-cache-dir uv

# Install postgres-mcp and dependencies
WORKDIR /app/postgres-mcp
RUN uv pip install --system -e .

# Install additional dependencies for distributed extensions
RUN uv pip install --system \
    asyncpg \
    httpx \
    pydantic

WORKDIR /app

# Create entrypoint script
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
# Wait for coordinator to be ready\n\
echo "Waiting for PostgreSQL coordinator..."\n\
until PGPASSFILE=<(echo "*:*:*:*:$(cat /run/secrets/postgres_password)") psql -h pg-coordinator -U dpg_cluster -d distributed_postgres_cluster -c "SELECT 1" > /dev/null 2>&1; do\n\
  echo "Coordinator is unavailable - sleeping"\n\
  sleep 2\n\
done\n\
\n\
echo "Coordinator is ready - starting MCP server"\n\
\n\
# Start postgres-mcp with distributed extensions\n\
exec python -m postgres_mcp \\\n\
  --transport ${MCP_TRANSPORT:-sse} \\\n\
  --port ${MCP_PORT:-3000} \\\n\
  --host ${MCP_HOST:-0.0.0.0}\n\
' > /app/entrypoint.sh && chmod +x /app/entrypoint.sh

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD curl -f http://localhost:3000/health || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
