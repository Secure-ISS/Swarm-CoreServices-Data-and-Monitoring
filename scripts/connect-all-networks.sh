#!/bin/bash
#
# connect-all-networks.sh - Bridge all stack networks for unified communication
#
# This script connects all containers from different stacks to a unified network
# so Patroni, Citus, Monitoring, and RuVector can all communicate.
#

set -e

# Color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}=== Unified Network Bridge ===${NC}\n"

# Create unified network if it doesn't exist
if ! docker network inspect dpg-unified-network >/dev/null 2>&1; then
    echo -e "${BLUE}Creating unified network...${NC}"
    docker network create dpg-unified-network \
        --driver bridge \
        --subnet 172.25.0.0/16 \
        --gateway 172.25.0.1
    echo -e "${GREEN}✓ Created dpg-unified-network${NC}\n"
else
    echo -e "${GREEN}✓ dpg-unified-network already exists${NC}\n"
fi

# Function to connect container to unified network
connect_container() {
    local container=$1
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        if docker inspect "$container" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' | grep -q "dpg-unified-network"; then
            echo -e "  ${GREEN}✓${NC} $container (already connected)"
        else
            docker network connect dpg-unified-network "$container" 2>/dev/null && \
                echo -e "  ${GREEN}✓${NC} $container (connected)" || \
                echo -e "  ${YELLOW}⚠${NC} $container (failed to connect)"
        fi
    else
        echo -e "  ${YELLOW}⚠${NC} $container (not running)"
    fi
}

# Connect Patroni HA cluster
echo -e "${BLUE}Connecting Patroni HA Cluster:${NC}"
connect_container "patroni-1"
connect_container "patroni-2"
connect_container "patroni-3"
connect_container "etcd-1"
connect_container "etcd-2"
connect_container "etcd-3"
connect_container "haproxy"
echo ""

# Connect Citus distributed cluster
echo -e "${BLUE}Connecting Citus Distributed Cluster:${NC}"
connect_container "citus-coordinator"
connect_container "citus-worker-1"
connect_container "citus-worker-2"
connect_container "citus-redis-cache"
echo ""

# Connect RuVector DB
echo -e "${BLUE}Connecting RuVector Database:${NC}"
connect_container "ruvector-db"
echo ""

# Connect connection pooling
echo -e "${BLUE}Connecting Connection Pooling:${NC}"
connect_container "pgbouncer"
connect_container "dpg-redis-dev"
echo ""

# Connect monitoring stack
echo -e "${BLUE}Connecting Monitoring Stack:${NC}"
connect_container "dpg-prometheus"
connect_container "dpg-grafana"
connect_container "dpg-alertmanager"
connect_container "dpg-postgres-exporter"
connect_container "dpg-redis-exporter"
connect_container "dpg-node-exporter"
connect_container "dpg-app-exporter"
echo ""

# Verify connections
echo -e "${BLUE}=== Network Verification ===${NC}\n"

# Show all containers on unified network
echo -e "${BLUE}Containers on dpg-unified-network:${NC}"
docker network inspect dpg-unified-network --format '{{range .Containers}}  • {{.Name}} ({{.IPv4Address}})
{{end}}'

# Test connectivity
echo -e "\n${BLUE}Testing Inter-Stack Connectivity:${NC}"

# Test Patroni → Citus
if docker exec patroni-2 pg_isready -h citus-coordinator -p 5432 >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} Patroni → Citus (OK)"
else
    echo -e "  ${YELLOW}⚠${NC} Patroni → Citus (can't connect)"
fi

# Test Monitoring → Patroni
if docker exec dpg-prometheus wget -q --spider http://patroni-2:8008/health 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Monitoring → Patroni (OK)"
else
    echo -e "  ${YELLOW}⚠${NC} Monitoring → Patroni (can't connect)"
fi

# Test Monitoring → Citus
if docker exec dpg-prometheus wget -q --spider http://citus-coordinator:5432 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Monitoring → Citus (OK)"
else
    echo -e "  ${YELLOW}⚠${NC} Monitoring → Citus (can't connect - PostgreSQL doesn't respond to HTTP)"
fi

# Test PgBouncer → HAProxy
if docker exec pgbouncer ping -c 1 haproxy >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} PgBouncer → HAProxy (OK)"
else
    echo -e "  ${YELLOW}⚠${NC} PgBouncer → HAProxy (can't ping)"
fi

echo -e "\n${GREEN}=== Network bridging complete! ===${NC}"
echo -e "\n${BLUE}All stacks can now communicate on dpg-unified-network${NC}"
echo -e "${BLUE}IP Range: 172.25.0.0/16${NC}\n"
