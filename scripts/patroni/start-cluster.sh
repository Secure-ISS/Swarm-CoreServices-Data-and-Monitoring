#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PATRONI_DIR="${PROJECT_ROOT}/docker/patroni"

echo "=== Starting Patroni HA Cluster ==="

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo "ERROR: Docker is not running. Please start Docker first."
    exit 1
fi

# Navigate to patroni directory
cd "${PATRONI_DIR}"

# Load environment variables
if [ -f .env.patroni ]; then
    export $(grep -v '^#' .env.patroni | xargs)
    echo "✓ Loaded environment variables from .env.patroni"
else
    echo "WARNING: .env.patroni not found, using defaults"
fi

# Build images
echo "Building Patroni images..."
docker-compose build

# Start etcd cluster first
echo "Starting etcd consensus cluster..."
docker-compose up -d etcd-1 etcd-2 etcd-3

# Wait for etcd to be healthy
echo "Waiting for etcd cluster to be ready..."
for i in {1..30}; do
    if docker exec etcd-1 etcdctl endpoint health > /dev/null 2>&1; then
        echo "✓ etcd cluster is healthy"
        break
    fi
    echo -n "."
    sleep 2
done

# Start Patroni nodes
echo "Starting Patroni nodes..."
docker-compose up -d patroni-1 patroni-2 patroni-3

# Wait for Patroni nodes to be ready
echo "Waiting for Patroni nodes to initialize..."
sleep 10

# Start HAProxy
echo "Starting HAProxy load balancer..."
docker-compose up -d haproxy

# Wait for services to be fully ready
echo "Waiting for all services to be ready..."
sleep 5

# Check cluster status
echo ""
echo "=== Cluster Status ==="
docker-compose ps

echo ""
echo "=== Patroni Cluster Information ==="
echo "Primary (writes): localhost:5000"
echo "Replicas (reads): localhost:5001"
echo "HAProxy stats:    http://localhost:7000 (admin/admin)"
echo ""
echo "Individual nodes:"
echo "  patroni-1: localhost:5432 (REST API: localhost:8008)"
echo "  patroni-2: localhost:5433 (REST API: localhost:8009)"
echo "  patroni-3: localhost:5434 (REST API: localhost:8010)"
echo ""
echo "To check cluster status: ./status.sh"
echo "To stop cluster: ./stop-cluster.sh"
echo ""
echo "✓ Patroni HA cluster started successfully!"
