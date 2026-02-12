#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PATRONI_DIR="${PROJECT_ROOT}/docker/patroni"

echo "=== Patroni HA Cluster Status ==="
echo ""

# Navigate to patroni directory
cd "${PATRONI_DIR}"

# Check Docker Compose services
echo "Docker Compose Services:"
docker-compose ps
echo ""

# Check etcd cluster health
echo "=== etcd Cluster Health ==="
if docker exec etcd-1 etcdctl endpoint health 2>/dev/null; then
    echo "✓ etcd cluster is healthy"
else
    echo "✗ etcd cluster is unhealthy"
fi
echo ""

# Check Patroni cluster status via REST API
echo "=== Patroni Cluster Status ==="
echo ""
echo "Patroni Node 1 (localhost:8008):"
curl -s http://localhost:8008/patroni || echo "✗ Node 1 not responding"
echo ""
echo ""

echo "Patroni Node 2 (localhost:8009):"
curl -s http://localhost:8009/patroni || echo "✗ Node 2 not responding"
echo ""
echo ""

echo "Patroni Node 3 (localhost:8010):"
curl -s http://localhost:8010/patroni || echo "✗ Node 3 not responding"
echo ""
echo ""

# Check which node is primary
echo "=== Primary/Replica Status ==="
for port in 8008 8009 8010; do
    role=$(curl -s http://localhost:${port}/patroni 2>/dev/null | grep -o '"role":"[^"]*"' | cut -d'"' -f4)
    node_name=$(curl -s http://localhost:${port}/patroni 2>/dev/null | grep -o '"scope":"[^"]*"' | cut -d'"' -f4)
    if [ -n "$role" ]; then
        echo "Node at port ${port}: ${role}"
    fi
done
echo ""

# Check HAProxy stats
echo "=== HAProxy Status ==="
echo "HAProxy stats page: http://localhost:7000 (admin/admin)"
echo ""

# Test connections
echo "=== Connection Tests ==="
echo "Testing primary connection (port 5000)..."
if nc -z localhost 5000 2>/dev/null; then
    echo "✓ Primary endpoint is reachable"
else
    echo "✗ Primary endpoint is not reachable"
fi

echo "Testing replica connection (port 5001)..."
if nc -z localhost 5001 2>/dev/null; then
    echo "✓ Replica endpoint is reachable"
else
    echo "✗ Replica endpoint is not reachable"
fi
echo ""

echo "=== Cluster Endpoints ==="
echo "Primary (writes): localhost:5000"
echo "Replicas (reads): localhost:5001"
echo "HAProxy stats:    http://localhost:7000"
echo ""
echo "Individual nodes:"
echo "  patroni-1: localhost:5432 (REST: localhost:8008)"
echo "  patroni-2: localhost:5433 (REST: localhost:8009)"
echo "  patroni-3: localhost:5434 (REST: localhost:8010)"
