#!/bin/bash
# RuVector PostgreSQL Database Startup Script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load environment variables
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
    echo "✓ Loaded environment from .env"
else
    echo "✗ No .env file found at $PROJECT_ROOT/.env"
    exit 1
fi

# Configuration
CONTAINER_NAME="ruvector-db"
IMAGE="ruvnet/ruvector-postgres:latest"
PORT="${RUVECTOR_PORT:-5432}"

echo "========================================="
echo "🚀 Starting RuVector PostgreSQL Database"
echo "========================================="

# Check if container already exists
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "📦 Container '$CONTAINER_NAME' exists"

    # Check if running
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "✓ Container is already running"
        docker ps --filter "name=$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        exit 0
    else
        echo "🔄 Starting existing container..."
        docker start "$CONTAINER_NAME"
        echo "✓ Container started"
    fi
else
    echo "🆕 Creating new container '$CONTAINER_NAME'..."

    # Pull latest image
    echo "📥 Pulling image $IMAGE..."
    docker pull "$IMAGE" || {
        echo "⚠ Failed to pull image, using local if available"
    }

    # Create and start container
    docker run -d \
        --name "$CONTAINER_NAME" \
        -e POSTGRES_PASSWORD="${RUVECTOR_PASSWORD}" \
        -e POSTGRES_USER="${RUVECTOR_USER}" \
        -e POSTGRES_DB="${RUVECTOR_DB}" \
        -p "${PORT}:5432" \
        --health-cmd='pg_isready -U ${POSTGRES_USER}' \
        --health-interval=10s \
        --health-timeout=5s \
        --health-retries=5 \
        "$IMAGE"

    echo "✓ Container created and started"
fi

# Wait for database to be ready
echo ""
echo "⏳ Waiting for PostgreSQL to be ready..."
MAX_ATTEMPTS=30
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if docker exec "$CONTAINER_NAME" pg_isready -U "$RUVECTOR_USER" > /dev/null 2>&1; then
        echo "✓ PostgreSQL is ready!"
        break
    fi

    ATTEMPT=$((ATTEMPT + 1))
    echo "   Attempt $ATTEMPT/$MAX_ATTEMPTS..."
    sleep 2
done

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    echo "✗ Database failed to start after $MAX_ATTEMPTS attempts"
    echo "   Check logs with: docker logs $CONTAINER_NAME"
    exit 1
fi

# Verify RuVector extension
echo ""
echo "🔍 Verifying RuVector extension..."
EXTENSION_CHECK=$(docker exec "$CONTAINER_NAME" psql -U "$RUVECTOR_USER" -d "$RUVECTOR_DB" -tAc \
    "SELECT extversion FROM pg_extension WHERE extname = 'ruvector';")

if [ -n "$EXTENSION_CHECK" ]; then
    echo "✓ RuVector extension version: $EXTENSION_CHECK"
else
    echo "⚠ RuVector extension not installed - installing..."
    docker exec "$CONTAINER_NAME" psql -U "$RUVECTOR_USER" -d "$RUVECTOR_DB" -c \
        "CREATE EXTENSION IF NOT EXISTS ruvector;"
    echo "✓ RuVector extension installed"
fi

# Show container status
echo ""
echo "========================================="
echo "✅ Database Status"
echo "========================================="
docker ps --filter "name=$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo ""
echo "📊 Connection Info:"
echo "   Host: ${RUVECTOR_HOST:-localhost}"
echo "   Port: $PORT"
echo "   Database: $RUVECTOR_DB"
echo "   User: $RUVECTOR_USER"
echo ""
echo "🔗 Connection string:"
echo "   postgresql://$RUVECTOR_USER:***@${RUVECTOR_HOST:-localhost}:$PORT/$RUVECTOR_DB"
echo ""
echo "🏥 Run health check with:"
echo "   python3 $SCRIPT_DIR/db_health_check.py"
echo ""
