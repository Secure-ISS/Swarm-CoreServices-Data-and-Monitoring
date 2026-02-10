#!/bin/bash
# Comprehensive health check for PostgreSQL mesh cluster
# Usage: ./health-check.sh <stack_name> [check_level]

set -euo pipefail

# Configuration
STACK_NAME="${1:-postgres-mesh}"
CHECK_LEVEL="${2:-standard}"  # basic, standard, comprehensive
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_section() { echo -e "${CYAN}=== $1 ===${NC}"; }

# Health check results
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

check_result() {
    local status=$1
    local message=$2

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    case $status in
        pass)
            log_success "$message"
            PASSED_CHECKS=$((PASSED_CHECKS + 1))
            ;;
        fail)
            log_error "$message"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
            ;;
        warn)
            log_warning "$message"
            WARNING_CHECKS=$((WARNING_CHECKS + 1))
            ;;
    esac
}

# Check Docker Swarm status
check_swarm_status() {
    log_section "Docker Swarm Status"

    # Check if Swarm is active
    if docker info --format '{{.Swarm.LocalNodeState}}' | grep -q "active"; then
        check_result pass "Docker Swarm is active"
    else
        check_result fail "Docker Swarm is not active"
        return 1
    fi

    # Check node count
    local node_count=$(docker node ls -q | wc -l)
    local manager_count=$(docker node ls --filter role=manager -q | wc -l)
    local worker_count=$(docker node ls --filter role=worker -q | wc -l)

    check_result pass "Nodes: ${node_count} (Managers: ${manager_count}, Workers: ${worker_count})"

    # Check for node issues
    local down_nodes=$(docker node ls --filter "availability=drain" -q | wc -l)
    if [ "$down_nodes" -gt 0 ]; then
        check_result warn "${down_nodes} node(s) are drained"
    fi
}

# Check stack status
check_stack_status() {
    log_section "Stack Status: ${STACK_NAME}"

    # Check if stack exists
    if ! docker stack ls --format "{{.Name}}" | grep -q "^${STACK_NAME}$"; then
        check_result fail "Stack ${STACK_NAME} not found"
        return 1
    fi

    check_result pass "Stack ${STACK_NAME} exists"

    # List all services in stack
    local services=($(docker stack services "${STACK_NAME}" --format "{{.Name}}"))
    local service_count=${#services[@]}

    check_result pass "Services in stack: ${service_count}"

    # Check each service
    for service in "${services[@]}"; do
        local replicas=$(docker service ls --filter "name=${service}" --format "{{.Replicas}}")
        local desired=$(echo "$replicas" | cut -d'/' -f2)
        local running=$(echo "$replicas" | cut -d'/' -f1)

        if [ "$running" -eq "$desired" ]; then
            check_result pass "${service}: ${replicas}"
        elif [ "$running" -gt 0 ]; then
            check_result warn "${service}: ${replicas} (not all replicas running)"
        else
            check_result fail "${service}: ${replicas} (no replicas running)"
        fi
    done
}

# Check coordinator health
check_coordinator_health() {
    log_section "Coordinator Health"

    # Get coordinator task
    local task_id=$(docker service ps "${STACK_NAME}_coordinator" --filter "desired-state=running" -q | head -n 1)

    if [ -z "$task_id" ]; then
        check_result fail "Coordinator is not running"
        return 1
    fi

    local container_id=$(docker inspect --format '{{.Status.ContainerStatus.ContainerID}}' "$task_id" 2>/dev/null || echo "")

    if [ -z "$container_id" ]; then
        check_result fail "Could not get coordinator container"
        return 1
    fi

    check_result pass "Coordinator container found: ${container_id:0:12}"

    # Check PostgreSQL is ready
    if docker exec "$container_id" pg_isready -U dpg_cluster -d distributed_postgres_cluster > /dev/null 2>&1; then
        check_result pass "Coordinator PostgreSQL is ready"
    else
        check_result fail "Coordinator PostgreSQL is not ready"
        return 1
    fi

    # Check database connectivity
    if docker exec "$container_id" psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT 1" > /dev/null 2>&1; then
        check_result pass "Coordinator database is accessible"
    else
        check_result fail "Coordinator database is not accessible"
        return 1
    fi

    # Check RuVector extension
    local has_ruvector=$(docker exec "$container_id" psql -U dpg_cluster -d distributed_postgres_cluster -t -c \
        "SELECT count(*) FROM pg_extension WHERE extname='ruvector';" 2>/dev/null | xargs || echo "0")

    if [ "$has_ruvector" -gt 0 ]; then
        local ruvector_version=$(docker exec "$container_id" psql -U dpg_cluster -d distributed_postgres_cluster -t -c \
            "SELECT extversion FROM pg_extension WHERE extname='ruvector';" 2>/dev/null | xargs || echo "unknown")
        check_result pass "RuVector extension installed (version: ${ruvector_version})"
    else
        check_result warn "RuVector extension not installed"
    fi

    if [ "$CHECK_LEVEL" != "basic" ]; then
        # Check connections
        local active_conns=$(docker exec "$container_id" psql -U dpg_cluster -d distributed_postgres_cluster -t -c \
            "SELECT count(*) FROM pg_stat_activity WHERE datname='distributed_postgres_cluster';" 2>/dev/null | xargs || echo "0")

        local max_conns=$(docker exec "$container_id" psql -U dpg_cluster -d distributed_postgres_cluster -t -c \
            "SHOW max_connections;" 2>/dev/null | xargs || echo "unknown")

        check_result pass "Active connections: ${active_conns}/${max_conns}"

        # Check for long-running queries
        local long_queries=$(docker exec "$container_id" psql -U dpg_cluster -d distributed_postgres_cluster -t -c \
            "SELECT count(*) FROM pg_stat_activity WHERE state='active' AND now() - query_start > interval '5 minutes';" \
            2>/dev/null | xargs || echo "0")

        if [ "$long_queries" -gt 0 ]; then
            check_result warn "${long_queries} long-running queries (>5 min)"
        else
            check_result pass "No long-running queries detected"
        fi

        # Check replication slots
        local replication_slots=$(docker exec "$container_id" psql -U dpg_cluster -d distributed_postgres_cluster -t -c \
            "SELECT count(*) FROM pg_replication_slots;" 2>/dev/null | xargs || echo "0")

        check_result pass "Replication slots: ${replication_slots}"
    fi
}

# Check worker health
check_worker_health() {
    log_section "Worker Node Health"

    # Get all worker services
    local workers=($(docker service ls --filter "name=${STACK_NAME}_worker" --format "{{.Name}}"))
    local worker_count=${#workers[@]}

    if [ "$worker_count" -eq 0 ]; then
        check_result warn "No worker nodes found"
        return 0
    fi

    check_result pass "Found ${worker_count} worker services"

    for worker in "${workers[@]}"; do
        local worker_name=$(basename "$worker")
        log_info "Checking ${worker_name}..."

        # Get worker task
        local task_id=$(docker service ps "$worker" --filter "desired-state=running" -q | head -n 1)

        if [ -z "$task_id" ]; then
            check_result fail "${worker_name}: Not running"
            continue
        fi

        local container_id=$(docker inspect --format '{{.Status.ContainerStatus.ContainerID}}' "$task_id" 2>/dev/null || echo "")

        if [ -z "$container_id" ]; then
            check_result fail "${worker_name}: Container not found"
            continue
        fi

        # Check PostgreSQL is ready
        if docker exec "$container_id" pg_isready -U dpg_cluster -d distributed_postgres_cluster > /dev/null 2>&1; then
            check_result pass "${worker_name}: PostgreSQL ready"
        else
            check_result fail "${worker_name}: PostgreSQL not ready"
            continue
        fi

        # Check database connectivity
        if docker exec "$container_id" psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT 1" > /dev/null 2>&1; then
            check_result pass "${worker_name}: Database accessible"
        else
            check_result fail "${worker_name}: Database not accessible"
            continue
        fi

        if [ "$CHECK_LEVEL" == "comprehensive" ]; then
            # Check disk usage
            local disk_usage=$(docker exec "$container_id" df -h /var/lib/postgresql/data | tail -n 1 | awk '{print $5}' | sed 's/%//')
            if [ "$disk_usage" -lt 80 ]; then
                check_result pass "${worker_name}: Disk usage ${disk_usage}%"
            elif [ "$disk_usage" -lt 90 ]; then
                check_result warn "${worker_name}: Disk usage ${disk_usage}%"
            else
                check_result fail "${worker_name}: Disk usage ${disk_usage}% (critical)"
            fi

            # Check table count
            local table_count=$(docker exec "$container_id" psql -U dpg_cluster -d distributed_postgres_cluster -t -c \
                "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | xargs || echo "0")

            check_result pass "${worker_name}: Tables ${table_count}"
        fi
    done
}

# Check connection pooler health
check_pooler_health() {
    log_section "Connection Pooler Health"

    # Check if pooler service exists
    if ! docker service ls --filter "name=${STACK_NAME}_pgbouncer" --format "{{.Name}}" | grep -q pgbouncer; then
        check_result warn "PgBouncer service not found"
        return 0
    fi

    # Get pooler tasks
    local tasks=($(docker service ps "${STACK_NAME}_pgbouncer" --filter "desired-state=running" -q))
    local task_count=${#tasks[@]}

    if [ "$task_count" -eq 0 ]; then
        check_result fail "PgBouncer: No replicas running"
        return 1
    fi

    check_result pass "PgBouncer: ${task_count} replica(s) running"

    # Check first pooler instance
    local container_id=$(docker inspect --format '{{.Status.ContainerStatus.ContainerID}}' "${tasks[0]}" 2>/dev/null || echo "")

    if [ -n "$container_id" ]; then
        # Check if pooler is accepting connections
        if docker exec "$container_id" psql -U dpg_cluster -h localhost -p 6432 -d distributed_postgres_cluster -c "SELECT 1" > /dev/null 2>&1; then
            check_result pass "PgBouncer: Accepting connections"
        else
            check_result fail "PgBouncer: Not accepting connections"
        fi

        if [ "$CHECK_LEVEL" != "basic" ]; then
            # Check pool status
            local active_clients=$(docker exec "$container_id" psql -U dpg_cluster -h localhost -p 6432 -d pgbouncer -t -c \
                "SHOW POOLS;" 2>/dev/null | grep distributed_postgres_cluster | awk '{print $4}' | head -n 1 || echo "0")

            check_result pass "PgBouncer: Active clients ${active_clients}"
        fi
    fi
}

# Check network connectivity
check_network() {
    log_section "Network Connectivity"

    # Check if overlay network exists
    if docker network ls --filter "name=${STACK_NAME}_postgres_mesh" --format "{{.Name}}" | grep -q postgres_mesh; then
        check_result pass "Overlay network exists"

        # Get network details
        local network_driver=$(docker network inspect "${STACK_NAME}_postgres_mesh" --format "{{.Driver}}")
        check_result pass "Network driver: ${network_driver}"

        # Check connected services
        local connected_services=$(docker network inspect "${STACK_NAME}_postgres_mesh" --format "{{range .Containers}}{{.Name}} {{end}}" | wc -w)
        check_result pass "Connected containers: ${connected_services}"
    else
        check_result fail "Overlay network not found"
    fi
}

# Check volumes
check_volumes() {
    log_section "Volume Health"

    local volumes=($(docker volume ls --filter "name=${STACK_NAME}" --format "{{.Name}}"))
    local volume_count=${#volumes[@]}

    if [ "$volume_count" -eq 0 ]; then
        check_result warn "No volumes found for stack"
        return 0
    fi

    check_result pass "Found ${volume_count} volumes"

    if [ "$CHECK_LEVEL" == "comprehensive" ]; then
        for volume in "${volumes[@]}"; do
            local volume_size=$(docker system df -v | grep "$volume" | awk '{print $3}' || echo "unknown")
            log_info "${volume}: ${volume_size}"
        done
    fi
}

# Performance metrics
check_performance() {
    log_section "Performance Metrics"

    # Get coordinator container
    local coordinator_task=$(docker service ps "${STACK_NAME}_coordinator" --filter "desired-state=running" -q | head -n 1)

    if [ -z "$coordinator_task" ]; then
        check_result warn "Cannot check performance - coordinator not running"
        return 0
    fi

    local coordinator_container=$(docker inspect --format '{{.Status.ContainerStatus.ContainerID}}' "$coordinator_task" 2>/dev/null || echo "")

    if [ -z "$coordinator_container" ]; then
        return 0
    fi

    # Check query performance
    local avg_query_time=$(docker exec "$coordinator_container" psql -U dpg_cluster -d distributed_postgres_cluster -t -c \
        "SELECT ROUND(AVG(mean_exec_time)::numeric, 2) FROM pg_stat_statements;" 2>/dev/null | xargs || echo "N/A")

    if [ "$avg_query_time" != "N/A" ]; then
        check_result pass "Average query time: ${avg_query_time}ms"
    fi

    # Check cache hit ratio
    local cache_hit_ratio=$(docker exec "$coordinator_container" psql -U dpg_cluster -d distributed_postgres_cluster -t -c \
        "SELECT ROUND(100.0 * sum(blks_hit) / (sum(blks_hit) + sum(blks_read)), 2) FROM pg_stat_database WHERE datname='distributed_postgres_cluster';" \
        2>/dev/null | xargs || echo "N/A")

    if [ "$cache_hit_ratio" != "N/A" ]; then
        local ratio_int=${cache_hit_ratio%.*}
        if [ "$ratio_int" -ge 90 ]; then
            check_result pass "Cache hit ratio: ${cache_hit_ratio}%"
        elif [ "$ratio_int" -ge 80 ]; then
            check_result warn "Cache hit ratio: ${cache_hit_ratio}% (consider increasing shared_buffers)"
        else
            check_result fail "Cache hit ratio: ${cache_hit_ratio}% (poor cache performance)"
        fi
    fi
}

# Generate summary report
generate_summary() {
    log_section "Health Check Summary"

    local pass_percent=0
    if [ "$TOTAL_CHECKS" -gt 0 ]; then
        pass_percent=$((PASSED_CHECKS * 100 / TOTAL_CHECKS))
    fi

    echo ""
    echo "Total checks: ${TOTAL_CHECKS}"
    echo -e "${GREEN}Passed: ${PASSED_CHECKS}${NC}"
    echo -e "${YELLOW}Warnings: ${WARNING_CHECKS}${NC}"
    echo -e "${RED}Failed: ${FAILED_CHECKS}${NC}"
    echo ""
    echo "Success rate: ${pass_percent}%"
    echo ""

    if [ "$FAILED_CHECKS" -eq 0 ] && [ "$WARNING_CHECKS" -eq 0 ]; then
        log_success "Cluster is healthy!"
        return 0
    elif [ "$FAILED_CHECKS" -eq 0 ]; then
        log_warning "Cluster is operational with warnings"
        return 0
    else
        log_error "Cluster has critical issues"
        return 1
    fi
}

# Main execution
main() {
    log_info "PostgreSQL Mesh Cluster Health Check"
    log_info "Stack: ${STACK_NAME}"
    log_info "Check level: ${CHECK_LEVEL}"
    echo ""

    check_swarm_status
    check_stack_status
    check_coordinator_health
    check_worker_health
    check_pooler_health
    check_network
    check_volumes

    if [ "$CHECK_LEVEL" == "comprehensive" ]; then
        check_performance
    fi

    echo ""
    generate_summary
}

# Run main function
main "$@"
