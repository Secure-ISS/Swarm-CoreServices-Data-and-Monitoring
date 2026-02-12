#!/usr/bin/env bash
################################################################################
# Production Readiness Validation Script
#
# This script performs comprehensive validation of the distributed PostgreSQL
# cluster to ensure it's ready for production deployment.
#
# Exit codes:
#   0 = All checks passed (production ready)
#   1 = Critical failures (not production ready)
#   2 = Warnings present (production ready with caveats)
################################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

# Track blockers vs warnings
declare -a BLOCKERS
declare -a WARNINGS

# Log file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="${PROJECT_ROOT}/production-readiness-$(date +%Y%m%d-%H%M%S).log"

# Initialize log file
echo "Production Readiness Check - $(date)" > "$LOG_FILE"
echo "========================================" >> "$LOG_FILE"

################################################################################
# Utility Functions
################################################################################

log() {
    echo "$@" | tee -a "$LOG_FILE"
}

log_silent() {
    echo "$@" >> "$LOG_FILE"
}

print_header() {
    local title="$1"
    log ""
    log "${BLUE}========================================${NC}"
    log "${BLUE}$title${NC}"
    log "${BLUE}========================================${NC}"
}

print_check() {
    local name="$1"
    log ""
    log "${BLUE}[CHECK] $name${NC}"
    ((TOTAL_CHECKS++))
}

pass_check() {
    local msg="$1"
    log "${GREEN}✓ PASS${NC}: $msg"
    ((PASSED_CHECKS++))
}

fail_check() {
    local msg="$1"
    local is_blocker="${2:-true}"
    log "${RED}✗ FAIL${NC}: $msg"
    ((FAILED_CHECKS++))

    if [[ "$is_blocker" == "true" ]]; then
        BLOCKERS+=("$msg")
    else
        WARNINGS+=("$msg")
        ((WARNING_CHECKS++))
    fi
}

warn_check() {
    local msg="$1"
    log "${YELLOW}⚠ WARN${NC}: $msg"
    WARNINGS+=("$msg")
    ((WARNING_CHECKS++))
}

################################################################################
# Infrastructure Checks
################################################################################

check_infrastructure() {
    print_header "1. Infrastructure Validation"

    # Docker version
    print_check "Docker Installation"
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version | awk '{print $3}' | sed 's/,//')
        pass_check "Docker installed: $DOCKER_VERSION"
        log_silent "Docker info: $(docker info 2>&1)"
    else
        fail_check "Docker is not installed" true
        return
    fi

    # Docker Compose version
    print_check "Docker Compose Installation"
    if docker compose version &> /dev/null; then
        COMPOSE_VERSION=$(docker compose version --short)
        pass_check "Docker Compose installed: $COMPOSE_VERSION"
    else
        fail_check "Docker Compose is not installed" true
        return
    fi

    # Docker Swarm mode
    print_check "Docker Swarm Mode"
    if docker info 2>/dev/null | grep -q "Swarm: active"; then
        SWARM_NODE_COUNT=$(docker node ls 2>/dev/null | grep -c Ready || echo "0")
        pass_check "Docker Swarm is active with $SWARM_NODE_COUNT nodes"
        log_silent "Swarm nodes: $(docker node ls)"
    else
        warn_check "Docker Swarm is not active (single-node mode)"
    fi

    # Network connectivity
    print_check "Network Connectivity"
    if docker network ls | grep -q dpg-network; then
        pass_check "Docker network 'dpg-network' exists"
    else
        warn_check "Docker network 'dpg-network' not found"
    fi

    # Storage capacity
    print_check "Storage Capacity"
    AVAILABLE_SPACE=$(df -BG "$PROJECT_ROOT" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ $AVAILABLE_SPACE -gt 50 ]]; then
        pass_check "Available storage: ${AVAILABLE_SPACE}GB (>50GB)"
    elif [[ $AVAILABLE_SPACE -gt 20 ]]; then
        warn_check "Available storage: ${AVAILABLE_SPACE}GB (recommend >50GB)"
    else
        fail_check "Available storage: ${AVAILABLE_SPACE}GB (need >20GB)" true
    fi

    # SSL certificates
    print_check "SSL Certificates"
    CERT_DIR="${PROJECT_ROOT}/config/ssl"
    if [[ -d "$CERT_DIR" ]]; then
        if [[ -f "$CERT_DIR/server.crt" ]] && [[ -f "$CERT_DIR/server.key" ]]; then
            # Check certificate expiry
            EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_DIR/server.crt" 2>/dev/null | cut -d= -f2)
            EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$EXPIRY" +%s 2>/dev/null)
            NOW_EPOCH=$(date +%s)
            DAYS_UNTIL_EXPIRY=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

            if [[ $DAYS_UNTIL_EXPIRY -gt 30 ]]; then
                pass_check "SSL certificates valid for $DAYS_UNTIL_EXPIRY days"
            elif [[ $DAYS_UNTIL_EXPIRY -gt 0 ]]; then
                warn_check "SSL certificates expire in $DAYS_UNTIL_EXPIRY days"
            else
                fail_check "SSL certificates have expired" true
            fi
        else
            warn_check "SSL certificates not found in $CERT_DIR"
        fi
    else
        warn_check "SSL certificate directory not found"
    fi
}

################################################################################
# Database Checks
################################################################################

check_database() {
    print_header "2. Database Configuration & Health"

    # Load environment
    if [[ -f "$PROJECT_ROOT/.env" ]]; then
        source "$PROJECT_ROOT/.env"
        pass_check "Environment file loaded"
    else
        fail_check ".env file not found" true
        return
    fi

    # PostgreSQL version
    print_check "PostgreSQL Version"
    if docker ps | grep -q dpg-postgres; then
        PG_VERSION=$(docker exec dpg-postgres-dev psql -U "${POSTGRES_USER:-dpg_cluster}" -d "${POSTGRES_DB:-distributed_postgres_cluster}" -tAc "SELECT version();" 2>/dev/null || echo "")
        if [[ -n "$PG_VERSION" ]]; then
            pass_check "PostgreSQL: $PG_VERSION"
        else
            fail_check "Cannot query PostgreSQL version" true
        fi
    else
        fail_check "PostgreSQL container not running" true
        return
    fi

    # RuVector extension
    print_check "RuVector Extension"
    RUVECTOR_VERSION=$(docker exec dpg-postgres-dev psql -U "${POSTGRES_USER:-dpg_cluster}" -d "${POSTGRES_DB:-distributed_postgres_cluster}" -tAc "SELECT extversion FROM pg_extension WHERE extname = 'ruvector';" 2>/dev/null || echo "")
    if [[ -n "$RUVECTOR_VERSION" ]]; then
        pass_check "RuVector extension installed: $RUVECTOR_VERSION"
    else
        fail_check "RuVector extension not installed" true
    fi

    # Configuration parameters
    print_check "PostgreSQL Configuration"
    MAX_CONNECTIONS=$(docker exec dpg-postgres-dev psql -U "${POSTGRES_USER:-dpg_cluster}" -d "${POSTGRES_DB:-distributed_postgres_cluster}" -tAc "SHOW max_connections;" 2>/dev/null || echo "0")
    SHARED_BUFFERS=$(docker exec dpg-postgres-dev psql -U "${POSTGRES_USER:-dpg_cluster}" -d "${POSTGRES_DB:-distributed_postgres_cluster}" -tAc "SHOW shared_buffers;" 2>/dev/null || echo "0")

    if [[ $MAX_CONNECTIONS -ge 100 ]]; then
        pass_check "max_connections=$MAX_CONNECTIONS (≥100)"
    else
        warn_check "max_connections=$MAX_CONNECTIONS (recommend ≥100)"
    fi

    pass_check "shared_buffers=$SHARED_BUFFERS"

    # Replication setup (if Patroni enabled)
    print_check "Replication Configuration"
    if [[ "${ENABLE_PATRONI:-false}" == "true" ]]; then
        REPLICATION_LAG=$(docker exec dpg-postgres-dev psql -U "${POSTGRES_USER:-dpg_cluster}" -d "${POSTGRES_DB:-distributed_postgres_cluster}" -tAc "SELECT COALESCE(EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::INTEGER, 0);" 2>/dev/null || echo "-1")

        if [[ $REPLICATION_LAG -eq 0 ]]; then
            pass_check "This is the primary node (no replication lag)"
        elif [[ $REPLICATION_LAG -gt 0 ]] && [[ $REPLICATION_LAG -lt 5 ]]; then
            pass_check "Replication lag: ${REPLICATION_LAG}s (<5s)"
        elif [[ $REPLICATION_LAG -ge 5 ]]; then
            warn_check "Replication lag: ${REPLICATION_LAG}s (>5s)"
        fi
    else
        warn_check "Patroni HA not enabled (single-node mode)"
    fi

    # Connection pool limits
    print_check "Connection Pool Configuration"
    if [[ -f "$PROJECT_ROOT/src/db/pool.py" ]]; then
        PROJECT_POOL=$(grep -oP 'maxconn":\s*\K\d+' "$PROJECT_ROOT/src/db/pool.py" | head -1)
        SHARED_POOL=$(grep -oP 'maxconn":\s*\K\d+' "$PROJECT_ROOT/src/db/pool.py" | tail -1)

        if [[ ${PROJECT_POOL:-0} -ge 40 ]] && [[ ${SHARED_POOL:-0} -ge 15 ]]; then
            pass_check "Connection pools: project=$PROJECT_POOL, shared=$SHARED_POOL"
        else
            warn_check "Connection pools may be undersized: project=$PROJECT_POOL, shared=$SHARED_POOL"
        fi
    fi

    # Backup system
    print_check "Backup Configuration"
    if [[ -f "$PROJECT_ROOT/scripts/deployment/backup-distributed.sh" ]]; then
        pass_check "Backup script exists"

        # Check if backups are scheduled
        if crontab -l 2>/dev/null | grep -q backup-distributed.sh; then
            pass_check "Backup cron job configured"
        else
            warn_check "No backup cron job found"
        fi
    else
        fail_check "Backup script not found" false
    fi
}

################################################################################
# Security Checks
################################################################################

check_security() {
    print_header "3. Security Validation"

    # Docker secrets
    print_check "Docker Secrets Management"
    if docker secret ls 2>/dev/null | grep -q postgres_password; then
        pass_check "Docker secrets configured"
    else
        warn_check "Docker secrets not configured (using environment variables)"
    fi

    # SSL/TLS enabled
    print_check "SSL/TLS Configuration"
    if [[ "${RUVECTOR_SSLMODE:-prefer}" == "require" ]] || [[ "${RUVECTOR_SSLMODE:-prefer}" == "verify-full" ]]; then
        pass_check "SSL/TLS enforcement: ${RUVECTOR_SSLMODE}"
    elif [[ "${RUVECTOR_SSLMODE:-prefer}" == "prefer" ]]; then
        warn_check "SSL/TLS mode is 'prefer' (recommend 'require' or 'verify-full')"
    else
        warn_check "SSL/TLS disabled or set to 'allow' (not recommended for production)"
    fi

    # Firewall rules
    print_check "Firewall Configuration"
    if command -v ufw &> /dev/null; then
        if ufw status | grep -q "Status: active"; then
            pass_check "UFW firewall is active"

            if ufw status | grep -q "5432"; then
                pass_check "PostgreSQL port 5432 has firewall rules"
            else
                warn_check "No firewall rules for PostgreSQL port 5432"
            fi
        else
            warn_check "UFW firewall is not active"
        fi
    elif command -v firewalld &> /dev/null; then
        if systemctl is-active --quiet firewalld; then
            pass_check "firewalld is active"
        else
            warn_check "firewalld is not active"
        fi
    else
        warn_check "No firewall detected (ufw/firewalld)"
    fi

    # User permissions
    print_check "Database User Permissions"
    if [[ -f "$PROJECT_ROOT/.env" ]]; then
        source "$PROJECT_ROOT/.env"

        # Check if using default passwords
        if [[ "${POSTGRES_PASSWORD:-}" == "dpg_cluster_2026" ]] || [[ "${POSTGRES_PASSWORD:-}" == "password" ]]; then
            fail_check "Using default/weak PostgreSQL password" true
        else
            pass_check "Custom PostgreSQL password configured"
        fi
    fi

    # Audit logging
    print_check "Audit Logging"
    LOG_STATEMENT=$(docker exec dpg-postgres-dev psql -U "${POSTGRES_USER:-dpg_cluster}" -d "${POSTGRES_DB:-distributed_postgres_cluster}" -tAc "SHOW log_statement;" 2>/dev/null || echo "none")

    if [[ "$LOG_STATEMENT" == "all" ]] || [[ "$LOG_STATEMENT" == "ddl" ]]; then
        pass_check "Audit logging enabled: log_statement=$LOG_STATEMENT"
    else
        warn_check "Audit logging disabled or limited: log_statement=$LOG_STATEMENT"
    fi
}

################################################################################
# Monitoring Checks
################################################################################

check_monitoring() {
    print_header "4. Monitoring & Observability"

    # Prometheus
    print_check "Prometheus Configuration"
    if [[ -f "$PROJECT_ROOT/config/prometheus/prometheus.yml" ]]; then
        pass_check "Prometheus config exists"

        # Check if Prometheus is running
        if docker ps | grep -q prometheus; then
            pass_check "Prometheus container is running"

            # Check Prometheus is accessible
            if curl -sf http://localhost:9090/-/healthy &>/dev/null; then
                pass_check "Prometheus is healthy and accessible"
            else
                warn_check "Prometheus is not accessible on port 9090"
            fi
        else
            warn_check "Prometheus container not running"
        fi
    else
        warn_check "Prometheus configuration not found"
    fi

    # Grafana
    print_check "Grafana Dashboards"
    if [[ -d "$PROJECT_ROOT/config/grafana/dashboards" ]]; then
        DASHBOARD_COUNT=$(find "$PROJECT_ROOT/config/grafana/dashboards" -name "*.json" | wc -l)
        pass_check "Found $DASHBOARD_COUNT Grafana dashboard(s)"

        # Check if Grafana is running
        if docker ps | grep -q grafana; then
            pass_check "Grafana container is running"

            if curl -sf http://localhost:3000/api/health &>/dev/null; then
                pass_check "Grafana is healthy and accessible"
            else
                warn_check "Grafana is not accessible on port 3000"
            fi
        else
            warn_check "Grafana container not running"
        fi
    else
        warn_check "No Grafana dashboards found"
    fi

    # Alert rules
    print_check "Alert Rules Configuration"
    if [[ -d "$PROJECT_ROOT/config/prometheus/alerts" ]]; then
        ALERT_FILES=$(find "$PROJECT_ROOT/config/prometheus/alerts" -name "*.yml" | wc -l)
        pass_check "Found $ALERT_FILES alert rule file(s)"
    else
        warn_check "No alert rules configured"
    fi

    # Alertmanager
    print_check "Alertmanager Configuration"
    if [[ -f "$PROJECT_ROOT/config/alertmanager/config.yml" ]]; then
        pass_check "Alertmanager config exists"

        if docker ps | grep -q alertmanager; then
            pass_check "Alertmanager container is running"
        else
            warn_check "Alertmanager container not running"
        fi
    else
        warn_check "Alertmanager not configured"
    fi

    # Notification channels
    print_check "Notification Channels"
    if [[ -f "$PROJECT_ROOT/config/alertmanager/config.yml" ]]; then
        if grep -q "receivers:" "$PROJECT_ROOT/config/alertmanager/config.yml"; then
            RECEIVER_COUNT=$(grep -c "name:" "$PROJECT_ROOT/config/alertmanager/config.yml" || echo "0")
            pass_check "Configured $RECEIVER_COUNT notification receiver(s)"
        else
            warn_check "No notification receivers configured"
        fi
    fi
}

################################################################################
# Performance Checks
################################################################################

check_performance() {
    print_header "5. Performance Validation"

    # Run quick benchmark
    print_check "Database Performance Benchmark"
    if [[ -f "$PROJECT_ROOT/scripts/benchmark/quick_benchmark.py" ]]; then
        log "Running benchmark (this may take 30-60 seconds)..."
        BENCHMARK_OUTPUT=$(python3 "$PROJECT_ROOT/scripts/benchmark/quick_benchmark.py" 2>&1 || echo "FAILED")

        if [[ "$BENCHMARK_OUTPUT" != "FAILED" ]]; then
            AVG_QUERY_TIME=$(echo "$BENCHMARK_OUTPUT" | grep -oP 'Average query time: \K[\d.]+' || echo "0")

            if (( $(echo "$AVG_QUERY_TIME < 50" | bc -l 2>/dev/null || echo "0") )); then
                pass_check "Average query time: ${AVG_QUERY_TIME}ms (<50ms target)"
            elif (( $(echo "$AVG_QUERY_TIME < 100" | bc -l 2>/dev/null || echo "0") )); then
                warn_check "Average query time: ${AVG_QUERY_TIME}ms (target <50ms)"
            else
                warn_check "Average query time: ${AVG_QUERY_TIME}ms (performance may be degraded)"
            fi
        else
            warn_check "Benchmark failed to run"
        fi
    else
        warn_check "Benchmark script not found - skipping performance test"
    fi

    # Connection pool capacity
    print_check "Connection Pool Capacity"
    if [[ -f "$PROJECT_ROOT/scripts/test_pool_capacity.py" ]]; then
        log "Testing connection pool capacity..."
        POOL_OUTPUT=$(python3 "$PROJECT_ROOT/scripts/test_pool_capacity.py" 2>&1 || echo "FAILED")

        if echo "$POOL_OUTPUT" | grep -q "100% success"; then
            pass_check "Connection pool can handle concurrent load"
        else
            warn_check "Connection pool may have capacity issues"
        fi
    else
        warn_check "Pool capacity test not found"
    fi

    # Resource utilization
    print_check "Resource Utilization"
    if docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null | grep -q postgres; then
        POSTGRES_STATS=$(docker stats --no-stream --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null | grep postgres)
        log_silent "PostgreSQL stats: $POSTGRES_STATS"
        pass_check "Resource monitoring operational"
    else
        warn_check "Cannot retrieve resource utilization"
    fi
}

################################################################################
# High Availability Checks
################################################################################

check_high_availability() {
    print_header "6. High Availability & Disaster Recovery"

    # Patroni cluster status
    print_check "Patroni Cluster Status"
    if [[ "${ENABLE_PATRONI:-false}" == "true" ]]; then
        if command -v patronictl &> /dev/null; then
            PATRONI_STATUS=$(patronictl -c /etc/patroni/patroni.yml list 2>&1 || echo "FAILED")

            if [[ "$PATRONI_STATUS" != "FAILED" ]]; then
                pass_check "Patroni cluster operational"
                log_silent "Patroni status: $PATRONI_STATUS"
            else
                fail_check "Patroni cluster not responding" true
            fi
        else
            warn_check "patronictl not found (cannot verify cluster status)"
        fi
    else
        warn_check "Patroni HA not enabled (single-node deployment)"
    fi

    # Failover testing
    print_check "Failover Procedures"
    if [[ -f "$PROJECT_ROOT/docs/operations/FAILOVER_RUNBOOK.md" ]]; then
        pass_check "Failover runbook documented"
    else
        warn_check "No failover runbook found"
    fi

    # Backup restoration test
    print_check "Backup Restoration"
    LATEST_BACKUP=$(find /var/backups/postgres 2>/dev/null -name "*.sql.gz" -mtime -1 | head -1)
    if [[ -n "$LATEST_BACKUP" ]]; then
        pass_check "Recent backup found: $(basename "$LATEST_BACKUP")"
    else
        warn_check "No recent backups found (< 24 hours old)"
    fi

    # Disaster recovery procedures
    print_check "Disaster Recovery Documentation"
    if [[ -f "$PROJECT_ROOT/docs/operations/DISASTER_RECOVERY.md" ]] || [[ -f "$PROJECT_ROOT/deployment/DEPLOYMENT_GUIDE.md" ]]; then
        pass_check "Disaster recovery procedures documented"
    else
        warn_check "Disaster recovery procedures not documented"
    fi
}

################################################################################
# Generate Report
################################################################################

generate_report() {
    print_header "Production Readiness Report"

    # Calculate score
    TOTAL_POSSIBLE=$((TOTAL_CHECKS * 100))
    SCORE=$((PASSED_CHECKS * 100))
    PERCENTAGE=$((SCORE * 100 / TOTAL_POSSIBLE))

    log ""
    log "Total Checks: $TOTAL_CHECKS"
    log "${GREEN}Passed: $PASSED_CHECKS${NC}"
    log "${RED}Failed: $FAILED_CHECKS${NC}"
    log "${YELLOW}Warnings: $WARNING_CHECKS${NC}"
    log ""
    log "Overall Readiness Score: ${PERCENTAGE}%"

    # Determine readiness level
    if [[ $PERCENTAGE -ge 90 ]] && [[ ${#BLOCKERS[@]} -eq 0 ]]; then
        log "${GREEN}✓ PRODUCTION READY${NC}"
        READINESS="READY"
    elif [[ $PERCENTAGE -ge 75 ]] && [[ ${#BLOCKERS[@]} -eq 0 ]]; then
        log "${YELLOW}⚠ PRODUCTION READY (with warnings)${NC}"
        READINESS="READY_WITH_WARNINGS"
    else
        log "${RED}✗ NOT PRODUCTION READY${NC}"
        READINESS="NOT_READY"
    fi

    # List blockers
    if [[ ${#BLOCKERS[@]} -gt 0 ]]; then
        log ""
        log "${RED}CRITICAL BLOCKERS:${NC}"
        for blocker in "${BLOCKERS[@]}"; do
            log "  • $blocker"
        done
    fi

    # List warnings
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        log ""
        log "${YELLOW}WARNINGS (recommended to address):${NC}"
        for warning in "${WARNINGS[@]}"; do
            log "  • $warning"
        done
    fi

    # Recommendations
    log ""
    log "RECOMMENDATIONS:"

    if [[ ${#BLOCKERS[@]} -gt 0 ]]; then
        log "  1. Address all critical blockers before production deployment"
    fi

    if [[ $WARNING_CHECKS -gt 0 ]]; then
        log "  2. Review and address warnings where possible"
    fi

    log "  3. Review full log at: $LOG_FILE"
    log "  4. Consult docs/PRODUCTION_READINESS.md for detailed guidance"

    # Exit code
    if [[ "$READINESS" == "READY" ]]; then
        return 0
    elif [[ "$READINESS" == "READY_WITH_WARNINGS" ]]; then
        return 2
    else
        return 1
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    log "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    log "${BLUE}║         Production Readiness Validation Check             ║${NC}"
    log "${BLUE}║     Distributed PostgreSQL Cluster with RuVector          ║${NC}"
    log "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    log ""
    log "Started: $(date)"
    log "Log file: $LOG_FILE"

    # Run all checks
    check_infrastructure
    check_database
    check_security
    check_monitoring
    check_performance
    check_high_availability

    # Generate final report
    generate_report

    EXIT_CODE=$?
    log ""
    log "Completed: $(date)"
    log "Full report: $LOG_FILE"

    exit $EXIT_CODE
}

# Run main function
main "$@"
