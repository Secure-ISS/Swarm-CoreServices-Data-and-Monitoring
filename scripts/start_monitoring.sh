#!/bin/bash
#
# Start Monitoring Stack
# Starts Prometheus, Grafana, AlertManager, and all exporters
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Project root
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo -e "${GREEN}Starting Distributed PostgreSQL Cluster Monitoring Stack${NC}"
echo "========================================================"

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}Error: Docker is not running${NC}"
    exit 1
fi

# Check if dev stack is running
if ! docker ps | grep -q dpg-postgres-dev; then
    echo -e "${YELLOW}Warning: Development stack is not running${NC}"
    echo "Starting development stack first..."
    docker compose -f docker-compose.dev.yml up -d
    echo "Waiting for services to be healthy..."
    sleep 10
fi

# Create necessary directories
echo "Creating configuration directories..."
mkdir -p config/prometheus/alerts
mkdir -p config/alertmanager
mkdir -p config/grafana/provisioning/datasources
mkdir -p config/grafana/provisioning/dashboards
mkdir -p config/grafana/dashboards

# Build custom exporter
echo "Building custom application exporter..."
docker compose -f docker/monitoring/docker-compose.yml build app-exporter

# Start monitoring stack
echo "Starting monitoring stack..."
docker compose -f docker/monitoring/docker-compose.yml up -d

# Wait for services to be healthy
echo "Waiting for services to be healthy..."
sleep 15

# Check service status
echo ""
echo "Service Status:"
echo "---------------"

services=(
    "dpg-prometheus:9090"
    "dpg-grafana:3000"
    "dpg-alertmanager:9093"
    "dpg-postgres-exporter:9187"
    "dpg-redis-exporter:9121"
    "dpg-node-exporter:9100"
    "dpg-app-exporter:9999"
)

all_healthy=true

for service in "${services[@]}"; do
    container="${service%%:*}"
    port="${service##*:}"

    if docker ps | grep -q "$container"; then
        if curl -s "http://localhost:$port" > /dev/null 2>&1 || \
           curl -s "http://localhost:$port/metrics" > /dev/null 2>&1 || \
           curl -s "http://localhost:$port/-/healthy" > /dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} $container (port $port) - Running"
        else
            echo -e "${YELLOW}?${NC} $container (port $port) - Starting..."
            all_healthy=false
        fi
    else
        echo -e "${RED}✗${NC} $container - Not running"
        all_healthy=false
    fi
done

# Check Prometheus targets
echo ""
echo "Checking Prometheus targets..."
sleep 5

targets=$(curl -s http://localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.job) - \(.health)"' 2>/dev/null)

if [ -n "$targets" ]; then
    echo "$targets" | while read -r target; do
        if echo "$target" | grep -q "up"; then
            echo -e "${GREEN}✓${NC} $target"
        else
            echo -e "${RED}✗${NC} $target"
        fi
    done
else
    echo -e "${YELLOW}Unable to fetch Prometheus targets${NC}"
fi

echo ""
echo "========================================================"
echo -e "${GREEN}Monitoring stack started successfully!${NC}"
echo ""
echo "Access URLs:"
echo "  - Prometheus:  http://localhost:9090"
echo "  - Grafana:     http://localhost:3000 (admin/admin)"
echo "  - AlertManager: http://localhost:9093"
echo ""
echo "Metrics endpoints:"
echo "  - PostgreSQL:  http://localhost:9187/metrics"
echo "  - Redis:       http://localhost:9121/metrics"
echo "  - System:      http://localhost:9100/metrics"
echo "  - Application: http://localhost:9999/metrics"
echo ""
echo "Useful commands:"
echo "  - View logs:   docker compose -f docker/monitoring/docker-compose.yml logs -f"
echo "  - Stop stack:  docker compose -f docker/monitoring/docker-compose.yml down"
echo "  - Restart:     docker compose -f docker/monitoring/docker-compose.yml restart"
echo ""

if [ "$all_healthy" = false ]; then
    echo -e "${YELLOW}Note: Some services are still starting up. Check logs if issues persist.${NC}"
    exit 1
fi
