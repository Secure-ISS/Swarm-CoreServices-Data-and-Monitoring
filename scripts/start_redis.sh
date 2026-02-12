#!/bin/bash
# Redis Cache Startup Script
# Distributed PostgreSQL Cluster - Query Caching Layer

set -e

CONTAINER_NAME="redis-cache"
REDIS_PORT=6379
REDIS_IMAGE="redis:7-alpine"

echo "======================================"
echo "Redis Cache Startup"
echo "======================================"

# Check if container exists
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    # Container exists - check if running
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "✓ Redis already running"
        docker exec ${CONTAINER_NAME} redis-cli ping > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "✓ Redis responding to ping"
        else
            echo "⚠ Redis not responding, restarting..."
            docker restart ${CONTAINER_NAME}
            sleep 2
        fi
    else
        # Container exists but not running
        echo "⚠ Redis container stopped, starting..."
        docker start ${CONTAINER_NAME}
        sleep 2
    fi
else
    # Container doesn't exist - create it
    echo "⚙ Creating Redis container..."
    docker run -d \
        --name ${CONTAINER_NAME} \
        -p ${REDIS_PORT}:${REDIS_PORT} \
        --restart unless-stopped \
        ${REDIS_IMAGE}

    echo "⏳ Waiting for Redis to start..."
    sleep 3
fi

# Verify Redis is working
echo -n "Testing Redis connection... "
if docker exec ${CONTAINER_NAME} redis-cli ping > /dev/null 2>&1; then
    echo "✓ OK"
else
    echo "✗ FAILED"
    exit 1
fi

# Display Redis info
echo ""
echo "Redis Status:"
docker exec ${CONTAINER_NAME} redis-cli INFO server | grep -E "redis_version|uptime_in_seconds|tcp_port"

echo ""
echo "Memory Usage:"
docker exec ${CONTAINER_NAME} redis-cli INFO memory | grep -E "used_memory_human|used_memory_peak_human"

echo ""
echo "======================================"
echo "✅ Redis cache ready!"
echo "   Host: localhost"
echo "   Port: ${REDIS_PORT}"
echo "======================================"
