#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PATRONI_DIR="${PROJECT_ROOT}/docker/patroni"

echo "=== Stopping Patroni HA Cluster ==="

# Navigate to patroni directory
cd "${PATRONI_DIR}"

# Stop all services gracefully
echo "Stopping HAProxy..."
docker-compose stop haproxy

echo "Stopping Patroni nodes..."
docker-compose stop patroni-1 patroni-2 patroni-3

echo "Stopping etcd cluster..."
docker-compose stop etcd-1 etcd-2 etcd-3

# Remove containers
echo "Removing containers..."
docker-compose down

echo ""
echo "✓ Patroni HA cluster stopped successfully!"
echo ""
echo "Note: Data volumes are preserved. To remove data volumes as well, run:"
echo "  cd ${PATRONI_DIR} && docker-compose down -v"
