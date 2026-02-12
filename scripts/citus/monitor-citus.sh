#!/bin/bash
# Citus Cluster Monitoring Script
# Real-time monitoring dashboard for Citus distributed PostgreSQL
# Version: 1.0.0

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
COORDINATOR_HOST="${CITUS_COORDINATOR_HOST:-citus-coordinator}"
COORDINATOR_PORT="${CITUS_COORDINATOR_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-dpg_cluster}"
POSTGRES_DB="${POSTGRES_DB:-distributed_postgres_cluster}"

REFRESH_INTERVAL=${REFRESH_INTERVAL:-5}  # seconds

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to clear screen
clear_screen() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         Citus Cluster Monitor - $(date '+%Y-%m-%d %H:%M:%S')          ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Function to show cluster overview
show_cluster_overview() {
    echo -e "${BLUE}━━━ Cluster Overview ━━━${NC}"

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -F '|' <<-EOSQL
        SELECT
            'Worker Nodes' as metric,
            COUNT(*) as value,
            'active' as unit
        FROM citus_get_active_worker_nodes()
        UNION ALL
        SELECT
            'Distributed Tables' as metric,
            COUNT(*) as value,
            'tables' as unit
        FROM citus_tables
        UNION ALL
        SELECT
            'Total Shards' as metric,
            COUNT(*) as value,
            'shards' as unit
        FROM citus_shards
        UNION ALL
        SELECT
            'Database Size' as metric,
            pg_size_pretty(SUM(shard_size))::text as value,
            '' as unit
        FROM citus_shards;
EOSQL
    echo ""
}

# Function to show worker node status
show_worker_status() {
    echo -e "${BLUE}━━━ Worker Nodes ━━━${NC}"

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
        SELECT
            nodename,
            nodeport,
            CASE WHEN isactive THEN '✓ Active' ELSE '✗ Inactive' END as status,
            CASE WHEN shouldhaveshards THEN 'Yes' ELSE 'No' END as has_shards
        FROM pg_dist_node
        ORDER BY nodename;
EOSQL
    echo ""
}

# Function to show shard distribution
show_shard_distribution() {
    echo -e "${BLUE}━━━ Shard Distribution ━━━${NC}"

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
        SELECT
            nodename,
            COUNT(*) as shard_count,
            pg_size_pretty(SUM(shard_size)) as total_size,
            pg_size_pretty(AVG(shard_size)) as avg_size,
            ROUND(COUNT(*)::numeric / (SELECT COUNT(*) FROM citus_shards) * 100, 1) as percentage
        FROM citus_shards
        GROUP BY nodename
        ORDER BY shard_count DESC;
EOSQL
    echo ""
}

# Function to show active queries
show_active_queries() {
    echo -e "${BLUE}━━━ Active Queries (Distributed) ━━━${NC}"

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
        SELECT
            distributed_query_activity_id as query_id,
            node_name,
            node_port,
            LEFT(query, 60) as query,
            state,
            EXTRACT(EPOCH FROM (NOW() - query_start))::int as runtime_sec
        FROM citus_dist_stat_activity
        WHERE state != 'idle'
        ORDER BY query_start DESC
        LIMIT 5;
EOSQL
    echo ""
}

# Function to show connection stats
show_connection_stats() {
    echo -e "${BLUE}━━━ Connection Statistics ━━━${NC}"

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
        SELECT
            datname as database,
            COUNT(*) as connections,
            COUNT(*) FILTER (WHERE state = 'active') as active,
            COUNT(*) FILTER (WHERE state = 'idle') as idle,
            COUNT(*) FILTER (WHERE state = 'idle in transaction') as idle_in_txn
        FROM pg_stat_activity
        WHERE datname IS NOT NULL
        GROUP BY datname
        ORDER BY connections DESC;
EOSQL
    echo ""
}

# Function to show top queries by execution time
show_top_queries() {
    echo -e "${BLUE}━━━ Top Queries by Execution Time ━━━${NC}"

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
        SELECT
            LEFT(query, 80) as query,
            calls,
            ROUND(mean_exec_time::numeric, 2) as avg_time_ms,
            ROUND(total_exec_time::numeric, 2) as total_time_ms
        FROM pg_stat_statements
        WHERE query NOT LIKE '%pg_stat_statements%'
        ORDER BY mean_exec_time DESC
        LIMIT 5;
EOSQL
    echo ""
}

# Function to show replication lag
show_replication_lag() {
    echo -e "${BLUE}━━━ Replication Status ━━━${NC}"

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
        SELECT
            client_addr,
            application_name,
            state,
            sync_state,
            pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)) as send_lag,
            pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) as replay_lag
        FROM pg_stat_replication;
EOSQL
    echo ""
}

# Function to show cache hit ratio
show_cache_stats() {
    echo -e "${BLUE}━━━ Cache Statistics ━━━${NC}"

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
        SELECT
            'Buffer Cache Hit Ratio' as metric,
            ROUND(
                100.0 * sum(blks_hit) / NULLIF(sum(blks_hit) + sum(blks_read), 0),
                2
            )::text || '%' as value
        FROM pg_stat_database
        WHERE datname = current_database()
        UNION ALL
        SELECT
            'Shared Buffers Size' as metric,
            pg_size_pretty(
                (SELECT setting::bigint * 8192 FROM pg_settings WHERE name = 'shared_buffers')
            ) as value
        UNION ALL
        SELECT
            'Effective Cache Size' as metric,
            pg_size_pretty(
                (SELECT setting::bigint * 8192 FROM pg_settings WHERE name = 'effective_cache_size')
            ) as value;
EOSQL
    echo ""
}

# Function to show table sizes
show_table_sizes() {
    echo -e "${BLUE}━━━ Largest Distributed Tables ━━━${NC}"

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
        SELECT
            table_name::text,
            citus_table_type::text as type,
            shard_count,
            pg_size_pretty(SUM(shard_size)) as total_size
        FROM citus_shards
        GROUP BY table_name, citus_table_type, shard_count
        ORDER BY SUM(shard_size) DESC
        LIMIT 5;
EOSQL
    echo ""
}

# Function to show alerts
show_alerts() {
    echo -e "${YELLOW}━━━ Alerts ━━━${NC}"

    local alerts=0

    # Check for inactive workers
    local inactive_workers=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c \
        "SELECT COUNT(*) FROM pg_dist_node WHERE NOT isactive;")

    if [ "$inactive_workers" -gt 0 ]; then
        log_error "Inactive workers detected: $inactive_workers"
        alerts=$((alerts + 1))
    fi

    # Check for long-running queries (>60 seconds)
    local long_queries=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c \
        "SELECT COUNT(*) FROM citus_dist_stat_activity WHERE state = 'active' AND EXTRACT(EPOCH FROM (NOW() - query_start)) > 60;")

    if [ "$long_queries" -gt 0 ]; then
        log_warning "Long-running queries detected: $long_queries (>60s)"
        alerts=$((alerts + 1))
    fi

    # Check cache hit ratio
    local cache_hit=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c \
        "SELECT ROUND(100.0 * sum(blks_hit) / NULLIF(sum(blks_hit) + sum(blks_read), 0), 2) FROM pg_stat_database WHERE datname = current_database();")

    if (( $(echo "$cache_hit < 90" | bc -l) )); then
        log_warning "Low cache hit ratio: ${cache_hit}% (target: >90%)"
        alerts=$((alerts + 1))
    fi

    if [ $alerts -eq 0 ]; then
        log_success "No alerts - cluster healthy"
    fi

    echo ""
}

# Function for continuous monitoring
continuous_monitor() {
    while true; do
        clear_screen
        show_cluster_overview
        show_worker_status
        show_shard_distribution
        show_active_queries
        show_connection_stats
        show_alerts

        echo -e "${CYAN}Refreshing in $REFRESH_INTERVAL seconds... (Ctrl+C to exit)${NC}"
        sleep $REFRESH_INTERVAL
    done
}

# Function for single snapshot
single_snapshot() {
    clear_screen
    show_cluster_overview
    show_worker_status
    show_shard_distribution
    show_active_queries
    show_connection_stats
    show_top_queries
    show_cache_stats
    show_table_sizes
    show_alerts
}

# Function to export metrics to JSON
export_metrics() {
    local output_file=${1:-"citus-metrics-$(date +%Y%m%d-%H%M%S).json"}

    log_info "Exporting metrics to: $output_file"

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A <<-EOSQL > "$output_file"
        SELECT json_build_object(
            'timestamp', NOW(),
            'cluster', json_build_object(
                'workers', (SELECT COUNT(*) FROM citus_get_active_worker_nodes()),
                'tables', (SELECT COUNT(*) FROM citus_tables),
                'shards', (SELECT COUNT(*) FROM citus_shards),
                'total_size', (SELECT pg_size_pretty(SUM(shard_size)) FROM citus_shards)
            ),
            'workers', (
                SELECT json_agg(json_build_object(
                    'name', nodename,
                    'port', nodeport,
                    'active', isactive,
                    'has_shards', shouldhaveshards
                ))
                FROM pg_dist_node
            ),
            'shards', (
                SELECT json_agg(json_build_object(
                    'node', nodename,
                    'count', cnt,
                    'size', sz
                ))
                FROM (
                    SELECT nodename, COUNT(*) as cnt, pg_size_pretty(SUM(shard_size)) as sz
                    FROM citus_shards
                    GROUP BY nodename
                ) t
            ),
            'connections', (
                SELECT json_build_object(
                    'total', COUNT(*),
                    'active', COUNT(*) FILTER (WHERE state = 'active'),
                    'idle', COUNT(*) FILTER (WHERE state = 'idle')
                )
                FROM pg_stat_activity
            )
        );
EOSQL

    log_success "Metrics exported to: $output_file"
}

# Main function
main() {
    local command=${1:-watch}

    case "$command" in
        watch)
            continuous_monitor
            ;;
        snapshot)
            single_snapshot
            ;;
        export)
            export_metrics "$2"
            ;;
        overview)
            show_cluster_overview
            ;;
        workers)
            show_worker_status
            ;;
        shards)
            show_shard_distribution
            ;;
        queries)
            show_active_queries
            show_top_queries
            ;;
        connections)
            show_connection_stats
            ;;
        cache)
            show_cache_stats
            ;;
        tables)
            show_table_sizes
            ;;
        alerts)
            show_alerts
            ;;
        *)
            echo "Usage: $0 <command> [options]"
            echo ""
            echo "Commands:"
            echo "  watch         Continuous monitoring (default, refreshes every ${REFRESH_INTERVAL}s)"
            echo "  snapshot      Single snapshot of all metrics"
            echo "  export [file] Export metrics to JSON file"
            echo "  overview      Show cluster overview only"
            echo "  workers       Show worker node status"
            echo "  shards        Show shard distribution"
            echo "  queries       Show active and top queries"
            echo "  connections   Show connection statistics"
            echo "  cache         Show cache statistics"
            echo "  tables        Show largest tables"
            echo "  alerts        Show alerts only"
            echo ""
            echo "Environment Variables:"
            echo "  CITUS_COORDINATOR_HOST  Coordinator host (default: citus-coordinator)"
            echo "  CITUS_COORDINATOR_PORT  Coordinator port (default: 5432)"
            echo "  POSTGRES_USER           PostgreSQL user (default: dpg_cluster)"
            echo "  POSTGRES_PASSWORD       PostgreSQL password (required)"
            echo "  REFRESH_INTERVAL        Refresh interval in seconds (default: 5)"
            echo ""
            echo "Examples:"
            echo "  $0 watch"
            echo "  $0 snapshot"
            echo "  REFRESH_INTERVAL=10 $0 watch"
            echo "  $0 export metrics.json"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
