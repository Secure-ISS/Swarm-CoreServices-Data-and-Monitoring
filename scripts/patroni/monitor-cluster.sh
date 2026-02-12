#!/usr/bin/env bash

###############################################################################
# Patroni Cluster Monitoring Script
#
# Description: Real-time monitoring of Patroni cluster health
# Usage: ./monitor-cluster.sh [--watch] [--health-check] [--json]
#
# Options:
#   --watch: Continuous monitoring (refreshes every 5 seconds)
#   --health-check: Run health checks and exit
#   --json: Output in JSON format
#
# Author: Database Operations Team
# Version: 1.0
# Last Updated: 2026-02-12
###############################################################################

set -euo pipefail

# Configuration
PATRONICTL="${PATRONICTL:-patronictl}"
PATRONI_CONFIG="${PATRONI_CONFIG:-/etc/patroni/patroni.yml}"
ETCD_ENDPOINTS="${ETCD_ENDPOINTS:-etcd-1:2379,etcd-2:2379,etcd-3:2379}"
POSTGRES_HOST="${POSTGRES_HOST:-pg-coordinator}"
POSTGRES_USER="${POSTGRES_USER:-admin}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
REFRESH_INTERVAL=5

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Parse command line arguments
WATCH_MODE=false
HEALTH_CHECK=false
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --watch)
            WATCH_MODE=true
            shift
            ;;
        --health-check)
            HEALTH_CHECK=true
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --watch          Continuous monitoring (refresh every 5s)"
            echo "  --health-check   Run health checks and exit"
            echo "  --json           Output in JSON format"
            echo "  -h, --help       Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

###############################################################################
# Helper Functions
###############################################################################

print_header() {
    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e " ${BOLD}PATRONI CLUSTER MONITOR${NC} - $1"
        echo -e " Last Updated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
    fi
}

get_patroni_status() {
    $PATRONICTL -c "$PATRONI_CONFIG" list 2>/dev/null || echo "ERROR: Failed to get Patroni status"
}

check_etcd_health() {
    local result
    result=$(etcdctl --endpoints="$ETCD_ENDPOINTS" endpoint health 2>&1 || true)

    local healthy_count
    healthy_count=$(echo "$result" | grep -c "is healthy" || echo "0")

    echo "$healthy_count|$result"
}

check_replication_lag() {
    if [[ -z "$POSTGRES_PASSWORD" ]]; then
        echo "ERROR: POSTGRES_PASSWORD not set"
        return 1
    fi

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d postgres -t -A -c "
        SELECT
            COALESCE(application_name, 'N/A') || '|' ||
            COALESCE(client_addr::text, 'N/A') || '|' ||
            COALESCE(state, 'N/A') || '|' ||
            COALESCE(sync_state, 'N/A') || '|' ||
            COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) / 1024 / 1024, 0)::text || '|' ||
            COALESCE(EXTRACT(EPOCH FROM (now() - replay_timestamp))::int, 0)::text
        FROM pg_stat_replication;
    " 2>/dev/null || echo "ERROR: Failed to check replication"
}

check_connection_count() {
    if [[ -z "$POSTGRES_PASSWORD" ]]; then
        echo "ERROR: POSTGRES_PASSWORD not set"
        return 1
    fi

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d postgres -t -A -c "
        SELECT
            count(*)::text || '|' ||
            count(*) FILTER (WHERE state = 'active')::text || '|' ||
            count(*) FILTER (WHERE state = 'idle')::text || '|' ||
            current_setting('max_connections')
        FROM pg_stat_activity;
    " 2>/dev/null || echo "ERROR: Failed to check connections"
}

check_blocking_queries() {
    if [[ -z "$POSTGRES_PASSWORD" ]]; then
        echo "ERROR: POSTGRES_PASSWORD not set"
        return 1
    fi

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d postgres -t -A -c "
        SELECT count(*)
        FROM pg_stat_activity
        WHERE wait_event_type = 'Lock';
    " 2>/dev/null || echo "ERROR"
}

###############################################################################
# Display Functions
###############################################################################

display_patroni_status() {
    local status
    status=$(get_patroni_status)

    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "${BOLD}CLUSTER TOPOLOGY${NC}"
        echo ""
        echo "$status"
        echo ""
    else
        echo "\"patroni_status\": $(echo "$status" | jq -R -s -c '.')"
    fi
}

display_etcd_health() {
    local health_data
    health_data=$(check_etcd_health)

    local healthy_count
    healthy_count=$(echo "$health_data" | cut -d'|' -f1)

    local health_output
    health_output=$(echo "$health_data" | cut -d'|' -f2-)

    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "${BOLD}ETCD CLUSTER HEALTH${NC}"
        echo ""

        if [[ "$healthy_count" -ge 2 ]]; then
            echo -e "${GREEN}✓${NC} etcd cluster healthy ($healthy_count/3 members)"
        elif [[ "$healthy_count" -eq 1 ]]; then
            echo -e "${YELLOW}⚠${NC} etcd cluster degraded ($healthy_count/3 members) - No quorum!"
        else
            echo -e "${RED}✗${NC} etcd cluster down (0/3 members)"
        fi

        echo ""
        echo "$health_output" | while IFS= read -r line; do
            if [[ "$line" == *"is healthy"* ]]; then
                echo -e "  ${GREEN}●${NC} $line"
            else
                echo -e "  ${RED}●${NC} $line"
            fi
        done
        echo ""
    else
        echo "\"etcd_health\": {\"healthy_count\": $healthy_count, \"total\": 3, \"status\": \"$health_output\"}"
    fi
}

display_replication_status() {
    local replication_data
    replication_data=$(check_replication_lag)

    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "${BOLD}REPLICATION STATUS${NC}"
        echo ""
        printf "%-20s %-15s %-12s %-10s %-12s %-12s\n" \
            "Application Name" "Client Addr" "State" "Sync State" "Lag (MB)" "Lag (seconds)"
        echo "────────────────────────────────────────────────────────────────────────────────────"

        if [[ "$replication_data" == ERROR* ]]; then
            echo -e "${RED}$replication_data${NC}"
        elif [[ -z "$replication_data" ]]; then
            echo "No replication connections found (this node may be a replica)"
        else
            echo "$replication_data" | while IFS='|' read -r app_name client_addr state sync_state lag_mb lag_sec; do
                local color="$GREEN"

                # Set color based on lag
                if (( $(echo "$lag_mb > 100" | bc -l) )) || (( lag_sec > 60 )); then
                    color="$RED"
                elif (( $(echo "$lag_mb > 10" | bc -l) )) || (( lag_sec > 10 )); then
                    color="$YELLOW"
                fi

                printf "${color}%-20s %-15s %-12s %-10s %-12.2f %-12d${NC}\n" \
                    "$app_name" "$client_addr" "$state" "$sync_state" "$lag_mb" "$lag_sec"
            done
        fi
        echo ""
    else
        echo "\"replication_status\": \"$replication_data\""
    fi
}

display_connection_stats() {
    local conn_data
    conn_data=$(check_connection_count)

    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "${BOLD}CONNECTION STATISTICS${NC}"
        echo ""

        if [[ "$conn_data" == ERROR* ]]; then
            echo -e "${RED}$conn_data${NC}"
        else
            IFS='|' read -r total active idle max_conn <<< "$conn_data"

            local usage_pct
            usage_pct=$(echo "scale=2; $total * 100 / $max_conn" | bc)

            local color="$GREEN"
            if (( $(echo "$usage_pct > 90" | bc -l) )); then
                color="$RED"
            elif (( $(echo "$usage_pct > 80" | bc -l) )); then
                color="$YELLOW"
            fi

            echo -e "  Total Connections: ${color}$total / $max_conn (${usage_pct}%)${NC}"
            echo -e "  Active: $active"
            echo -e "  Idle: $idle"
        fi
        echo ""
    else
        echo "\"connection_stats\": \"$conn_data\""
    fi
}

display_blocking_queries() {
    local blocked_count
    blocked_count=$(check_blocking_queries)

    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "${BOLD}BLOCKING QUERIES${NC}"
        echo ""

        if [[ "$blocked_count" == "ERROR" ]]; then
            echo -e "${RED}Failed to check blocking queries${NC}"
        elif [[ "$blocked_count" -eq 0 ]]; then
            echo -e "${GREEN}✓${NC} No blocked queries"
        elif [[ "$blocked_count" -lt 5 ]]; then
            echo -e "${YELLOW}⚠${NC} $blocked_count queries blocked by locks"
        else
            echo -e "${RED}✗${NC} $blocked_count queries blocked by locks (CRITICAL)"
        fi
        echo ""
    else
        echo "\"blocking_queries\": $blocked_count"
    fi
}

###############################################################################
# Main Monitoring Function
###############################################################################

run_monitoring() {
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "{"
    fi

    if [[ "$JSON_OUTPUT" == "false" ]]; then
        if [[ "$WATCH_MODE" == "true" ]]; then
            clear
        fi
        print_header "Coordinator Cluster"
    fi

    display_patroni_status

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo ","
    fi

    display_etcd_health

    if [[ "$POSTGRES_PASSWORD" ]]; then
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            echo ","
        fi

        display_replication_status

        if [[ "$JSON_OUTPUT" == "true" ]]; then
            echo ","
        fi

        display_connection_stats

        if [[ "$JSON_OUTPUT" == "true" ]]; then
            echo ","
        fi

        display_blocking_queries
    else
        if [[ "$JSON_OUTPUT" == "false" ]]; then
            echo -e "${YELLOW}⚠ POSTGRES_PASSWORD not set - skipping database checks${NC}"
            echo ""
        fi
    fi

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "}"
    fi
}

###############################################################################
# Health Check Function
###############################################################################

run_health_check() {
    local exit_code=0

    echo "=== PATRONI CLUSTER HEALTH CHECK ==="
    echo ""

    # Check 1: Patroni cluster status
    echo "1. Patroni Cluster Status:"
    local patroni_status
    patroni_status=$(get_patroni_status)

    if echo "$patroni_status" | grep -q "ERROR"; then
        echo "  ✗ FAILED: Cannot connect to Patroni"
        exit_code=1
    else
        local leader_count
        leader_count=$(echo "$patroni_status" | grep -c "Leader" || echo "0")

        if [[ "$leader_count" -eq 1 ]]; then
            echo "  ✓ PASS: Cluster has a leader"
        else
            echo "  ✗ FAILED: Cluster has $leader_count leaders (expected 1)"
            exit_code=1
        fi
    fi
    echo ""

    # Check 2: etcd health
    echo "2. etcd Cluster Health:"
    local etcd_health
    etcd_health=$(check_etcd_health)
    local healthy_count
    healthy_count=$(echo "$etcd_health" | cut -d'|' -f1)

    if [[ "$healthy_count" -ge 2 ]]; then
        echo "  ✓ PASS: etcd cluster healthy ($healthy_count/3 members)"
    else
        echo "  ✗ FAILED: etcd cluster unhealthy ($healthy_count/3 members)"
        exit_code=1
    fi
    echo ""

    # Check 3: Replication lag
    if [[ -n "$POSTGRES_PASSWORD" ]]; then
        echo "3. Replication Lag:"
        local replication_data
        replication_data=$(check_replication_lag)

        if [[ "$replication_data" == ERROR* ]]; then
            echo "  ✗ FAILED: Cannot check replication"
            exit_code=1
        else
            local max_lag_mb=0
            local max_lag_sec=0

            while IFS='|' read -r _ _ _ _ lag_mb lag_sec; do
                if (( $(echo "$lag_mb > $max_lag_mb" | bc -l) )); then
                    max_lag_mb=$lag_mb
                fi
                if (( lag_sec > max_lag_sec )); then
                    max_lag_sec=$lag_sec
                fi
            done <<< "$replication_data"

            if (( $(echo "$max_lag_mb > 100" | bc -l) )) || (( max_lag_sec > 60 )); then
                echo "  ✗ FAILED: High replication lag (${max_lag_mb}MB, ${max_lag_sec}s)"
                exit_code=1
            elif (( $(echo "$max_lag_mb > 10" | bc -l) )) || (( max_lag_sec > 10 )); then
                echo "  ⚠ WARNING: Moderate replication lag (${max_lag_mb}MB, ${max_lag_sec}s)"
            else
                echo "  ✓ PASS: Replication lag acceptable (${max_lag_mb}MB, ${max_lag_sec}s)"
            fi
        fi
        echo ""
    fi

    # Overall result
    echo "=== HEALTH CHECK COMPLETE ==="
    if [[ "$exit_code" -eq 0 ]]; then
        echo "Status: ✓ ALL CHECKS PASSED"
    else
        echo "Status: ✗ SOME CHECKS FAILED"
    fi
    echo ""

    return $exit_code
}

###############################################################################
# Main Execution
###############################################################################

main() {
    if [[ "$HEALTH_CHECK" == "true" ]]; then
        run_health_check
        exit $?
    fi

    if [[ "$WATCH_MODE" == "true" ]]; then
        while true; do
            run_monitoring
            sleep "$REFRESH_INTERVAL"
        done
    else
        run_monitoring
    fi
}

main
