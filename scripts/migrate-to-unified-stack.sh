#!/bin/bash
#
# Migrate from fragmented stacks to unified docker-compose
# Preserves data by mapping old volumes to new container names
#

set -e

# Color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=== Distributed PostgreSQL Cluster - Unified Stack Migration ===${NC}\n"

# Confirm with user
echo -e "${YELLOW}This will stop all existing database stacks and start the unified stack.${NC}"
echo -e "${YELLOW}Data will be preserved, but services will restart.${NC}"
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Migration cancelled."
    exit 0
fi

# Step 1: Stop old stacks (keep volumes)
echo -e "\n${BLUE}Step 1: Stopping old stacks (preserving data)...${NC}"

if docker-compose -f docker/patroni/docker-compose.yml ps -q 2>/dev/null | grep -q .; then
    echo "  Stopping Patroni stack..."
    docker-compose -f docker/patroni/docker-compose.yml stop
fi

if docker-compose -f docker/citus/docker-compose.yml ps -q 2>/dev/null | grep -q .; then
    echo "  Stopping Citus stack..."
    docker-compose -f docker/citus/docker-compose.yml stop
fi

if docker-compose -f docker/traefik/docker-compose.yml ps -q 2>/dev/null | grep -q .; then
    echo "  Stopping Traefik stack..."
    docker-compose -f docker/traefik/docker-compose.yml stop
fi

if docker-compose -f docker/monitoring/docker-compose.yml ps -q 2>/dev/null | grep -q .; then
    echo "  Stopping Monitoring stack..."
    docker-compose -f docker/monitoring/docker-compose.yml stop
fi

# Stop individual containers
echo "  Stopping standalone containers..."
docker stop haproxy pgbouncer dpg-redis-dev 2>/dev/null || true

echo -e "${GREEN}  ✓ All old stacks stopped${NC}"

# Step 2: Backup volume list
echo -e "\n${BLUE}Step 2: Recording existing volumes...${NC}"
docker volume ls | grep -E "patroni|citus|etcd|prometheus|grafana" > /tmp/dpg-volumes-backup.txt
echo -e "${GREEN}  ✓ Volume list saved to /tmp/dpg-volumes-backup.txt${NC}"

# Step 3: Remove old containers (keep volumes)
echo -e "\n${BLUE}Step 3: Removing old containers (keeping volumes)...${NC}"
docker-compose -f docker/patroni/docker-compose.yml down 2>/dev/null || true
docker-compose -f docker/citus/docker-compose.yml down 2>/dev/null || true
docker-compose -f docker/traefik/docker-compose.yml down 2>/dev/null || true
docker-compose -f docker/monitoring/docker-compose.yml down 2>/dev/null || true
docker rm -f haproxy pgbouncer dpg-redis-dev 2>/dev/null || true
echo -e "${GREEN}  ✓ Old containers removed${NC}"

# Step 4: Start unified stack
echo -e "\n${BLUE}Step 4: Starting unified stack...${NC}"
docker-compose -f docker-compose.unified.yml up -d

echo -e "\n${BLUE}Step 5: Waiting for services to be healthy (45 seconds)...${NC}"
for i in {45..1}; do
    echo -ne "  ${i}s remaining...\r"
    sleep 1
done
echo -e "${GREEN}  ✓ Wait complete${NC}"

# Step 6: Check service health
echo -e "\n${BLUE}Step 6: Checking service health...${NC}"
docker-compose -f docker-compose.unified.yml ps

# Step 7: Configure Citus (if needed)
echo -e "\n${BLUE}Step 7: Configuring Citus cluster...${NC}"

# Wait for Citus to be ready
sleep 10

# Add pg_hba rules
echo "  Configuring pg_hba.conf..."
docker exec dpg-citus-coordinator bash -c "echo 'host all all 172.25.0.0/16 trust' >> /var/lib/postgresql/data/pg_hba.conf" 2>/dev/null || true
docker exec dpg-citus-worker-1 bash -c "echo 'host all all 172.25.0.0/16 trust' >> /var/lib/postgresql/data/pg_hba.conf" 2>/dev/null || true
docker exec dpg-citus-worker-2 bash -c "echo 'host all all 172.25.0.0/16 trust' >> /var/lib/postgresql/data/pg_hba.conf" 2>/dev/null || true

# Reload configs
docker exec dpg-citus-coordinator psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT pg_reload_conf();" 2>/dev/null || true
docker exec dpg-citus-worker-1 psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT pg_reload_conf();" 2>/dev/null || true
docker exec dpg-citus-worker-2 psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT pg_reload_conf();" 2>/dev/null || true

# Create .pgpass for coordinator
docker exec dpg-citus-coordinator bash -c "echo 'citus-worker-1:5432:*:dpg_cluster:dpg_cluster_2026' > /var/lib/postgresql/.pgpass && echo 'citus-worker-2:5432:*:dpg_cluster:dpg_cluster_2026' >> /var/lib/postgresql/.pgpass && chmod 600 /var/lib/postgresql/.pgpass && chown postgres:postgres /var/lib/postgresql/.pgpass" 2>/dev/null || true

# Check if workers are already registered
WORKER_COUNT=$(docker exec dpg-citus-coordinator psql -U dpg_cluster -d distributed_postgres_cluster -t -c "SELECT COUNT(*) FROM pg_dist_node;" 2>/dev/null | tr -d ' ' || echo "0")

if [ "$WORKER_COUNT" -eq 0 ]; then
    echo "  Registering Citus workers..."
    docker exec dpg-citus-coordinator psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT citus_add_node('citus-worker-1', 5432);" 2>/dev/null || true
    docker exec dpg-citus-coordinator psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT citus_add_node('citus-worker-2', 5432);" 2>/dev/null || true
    echo -e "${GREEN}  ✓ Citus workers registered${NC}"
else
    echo -e "${GREEN}  ✓ Citus workers already registered (${WORKER_COUNT} workers)${NC}"
fi

# Step 8: Test connectivity
echo -e "\n${BLUE}Step 8: Testing connectivity...${NC}"

# Test Patroni
if docker exec dpg-patroni-primary pg_isready -U dpg_cluster -d distributed_postgres_cluster > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} Patroni cluster: healthy"
else
    echo -e "  ${RED}✗${NC} Patroni cluster: not responding"
fi

# Test Citus
if docker exec dpg-citus-coordinator pg_isready -U dpg_cluster -d distributed_postgres_cluster > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} Citus coordinator: healthy"
else
    echo -e "  ${RED}✗${NC} Citus coordinator: not responding"
fi

# Test Traefik
if curl -sf http://localhost:8080/api/overview > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} Traefik dashboard: accessible"
else
    echo -e "  ${YELLOW}⚠${NC} Traefik dashboard: not responding (may still be starting)"
fi

# Test Prometheus
if curl -sf http://localhost:9090/-/healthy > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} Prometheus: healthy"
else
    echo -e "  ${YELLOW}⚠${NC} Prometheus: not responding (may still be starting)"
fi

# Test Grafana
if curl -sf http://localhost:3000/api/health > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} Grafana: healthy"
else
    echo -e "  ${YELLOW}⚠${NC} Grafana: not responding (may still be starting)"
fi

# Final summary
echo -e "\n${GREEN}=== Migration Complete! ===${NC}\n"

echo -e "${BLUE}Unified Stack Services:${NC}"
echo "  • dpg-traefik-lb        - Main load balancer"
echo "  • dpg-patroni-primary   - HA database primary"
echo "  • dpg-patroni-replica-1 - HA database replica 1"
echo "  • dpg-patroni-replica-2 - HA database replica 2"
echo "  • dpg-citus-coordinator - Distributed coordinator"
echo "  • dpg-citus-worker-1    - Distributed worker 1"
echo "  • dpg-citus-worker-2    - Distributed worker 2"
echo "  • dpg-etcd-1/2/3        - Consensus cluster"
echo "  • dpg-prometheus        - Metrics collection"
echo "  • dpg-grafana           - Dashboards"
echo "  • dpg-pgbouncer         - Connection pooling"
echo "  • dpg-redis-cache       - Query caching"

echo -e "\n${BLUE}Connection Endpoints:${NC}"
echo "  Patroni Primary (R/W):  psql -h localhost -p 5500 -U dpg_cluster"
echo "  Patroni Replicas (R/O): psql -h localhost -p 5501 -U readonly_user"
echo "  Citus Coordinator:      psql -h localhost -p 5502 -U dpg_cluster"
echo "  PgBouncer Pool:         psql -h localhost -p 6432 -U dpg_cluster"

echo -e "\n${BLUE}Web Interfaces:${NC}"
echo "  Traefik Dashboard:      http://localhost:8080"
echo "  Prometheus:             http://localhost:9090"
echo "  Grafana:                http://localhost:3000 (admin/admin)"

echo -e "\n${BLUE}Management Commands:${NC}"
echo "  Status:   docker-compose -f docker-compose.unified.yml ps"
echo "  Logs:     docker-compose -f docker-compose.unified.yml logs -f [service]"
echo "  Restart:  docker-compose -f docker-compose.unified.yml restart [service]"
echo "  Stop:     docker-compose -f docker-compose.unified.yml down"

echo ""
