#!/bin/bash
# Slow Query Analysis Script for Distributed PostgreSQL Cluster
# Enables pg_stat_statements, analyzes slow queries, generates recommendations
# Usage: ./analyze-slow-queries.sh [action: setup|report|reset]

set -euo pipefail

# Configuration
CONTAINER_NAME="ruvector-db"
MIN_DURATION_MS="${MIN_DURATION_MS:-100}" # Queries slower than 100ms
TOP_N="${TOP_N:-20}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Check if container is running
check_container() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_error "Container ${CONTAINER_NAME} is not running"
        exit 1
    fi
}

# Setup pg_stat_statements
setup_pg_stat_statements() {
    log_info "Setting up pg_stat_statements extension..."

    # Check if extension exists
    local ext_exists=$(docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -t -A -c "
        SELECT COUNT(*) FROM pg_extension WHERE extname = 'pg_stat_statements';
    ")

    if [ "$ext_exists" -eq 0 ]; then
        log_info "Creating pg_stat_statements extension..."
        docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster <<EOF
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
EOF
        log_success "pg_stat_statements extension created"
    else
        log_info "pg_stat_statements extension already exists"
    fi

    # Configure extension
    docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster <<EOF
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';
ALTER SYSTEM SET pg_stat_statements.track = all;
ALTER SYSTEM SET pg_stat_statements.max = 10000;
ALTER SYSTEM SET track_activity_query_size = 2048;
EOF

    log_warning "PostgreSQL restart required for shared_preload_libraries change:"
    log_info "docker restart ${CONTAINER_NAME}"
    log_info "After restart, run: $0 report"
}

# Generate slow query report
generate_report() {
    log_info "Analyzing slow queries (threshold: ${MIN_DURATION_MS}ms)..."

    # Check if pg_stat_statements is available
    local ext_exists=$(docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -t -A -c "
        SELECT COUNT(*) FROM pg_extension WHERE extname = 'pg_stat_statements';
    " 2>/dev/null || echo "0")

    if [ "$ext_exists" -eq 0 ]; then
        log_error "pg_stat_statements extension not found. Run: $0 setup"
        exit 1
    fi

    local report_file="/tmp/slow_queries_report_$(date +%Y%m%d_%H%M%S).txt"

    docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster > "$report_file" <<EOF
\echo '════════════════════════════════════════════════════════════════'
\echo '  Slow Query Analysis Report'
\echo '  Generated: $(date)'
\echo '  Threshold: ${MIN_DURATION_MS}ms'
\echo '════════════════════════════════════════════════════════════════'
\echo ''

\echo '=== TOP ${TOP_N} SLOWEST QUERIES (by total time) ==='
\echo ''
SELECT
    ROUND(total_exec_time::numeric, 2) AS total_time_ms,
    calls,
    ROUND(mean_exec_time::numeric, 2) AS mean_time_ms,
    ROUND(max_exec_time::numeric, 2) AS max_time_ms,
    ROUND((100 * total_exec_time / SUM(total_exec_time) OVER ())::numeric, 2) AS percent_total,
    LEFT(query, 120) AS query_preview
FROM pg_stat_statements
WHERE mean_exec_time > ${MIN_DURATION_MS}
ORDER BY total_exec_time DESC
LIMIT ${TOP_N};

\echo ''
\echo '=== TOP ${TOP_N} MOST FREQUENTLY CALLED SLOW QUERIES ==='
\echo ''
SELECT
    calls,
    ROUND(total_exec_time::numeric, 2) AS total_time_ms,
    ROUND(mean_exec_time::numeric, 2) AS mean_time_ms,
    ROUND(stddev_exec_time::numeric, 2) AS stddev_time_ms,
    LEFT(query, 120) AS query_preview
FROM pg_stat_statements
WHERE mean_exec_time > ${MIN_DURATION_MS}
ORDER BY calls DESC
LIMIT ${TOP_N};

\echo ''
\echo '=== QUERIES WITH HIGH VARIANCE (potential optimization targets) ==='
\echo ''
SELECT
    ROUND(mean_exec_time::numeric, 2) AS mean_time_ms,
    ROUND(stddev_exec_time::numeric, 2) AS stddev_time_ms,
    ROUND(max_exec_time::numeric, 2) AS max_time_ms,
    calls,
    ROUND((stddev_exec_time / NULLIF(mean_exec_time, 0))::numeric, 2) AS variance_ratio,
    LEFT(query, 120) AS query_preview
FROM pg_stat_statements
WHERE mean_exec_time > ${MIN_DURATION_MS}
    AND stddev_exec_time > 0
ORDER BY (stddev_exec_time / NULLIF(mean_exec_time, 0)) DESC
LIMIT ${TOP_N};

\echo ''
\echo '=== SEQUENTIAL SCANS ON LARGE TABLES ==='
\echo ''
SELECT
    schemaname || '.' || tablename AS table_name,
    seq_scan AS sequential_scans,
    seq_tup_read AS rows_read_seq,
    idx_scan AS index_scans,
    n_tup_ins + n_tup_upd + n_tup_del AS write_activity,
    pg_size_pretty(pg_relation_size(schemaname || '.' || tablename)) AS table_size
FROM pg_stat_user_tables
WHERE seq_scan > 0
    AND schemaname IN ('public', 'claude_flow')
ORDER BY seq_tup_read DESC
LIMIT ${TOP_N};

\echo ''
\echo '=== TABLE BLOAT ANALYSIS ==='
\echo ''
SELECT
    schemaname || '.' || tablename AS table_name,
    n_live_tup AS live_rows,
    n_dead_tup AS dead_rows,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_row_percent,
    last_vacuum,
    last_autovacuum,
    pg_size_pretty(pg_relation_size(schemaname || '.' || tablename)) AS table_size
FROM pg_stat_user_tables
WHERE n_dead_tup > 0
    AND schemaname IN ('public', 'claude_flow')
ORDER BY n_dead_tup DESC
LIMIT ${TOP_N};

\echo ''
\echo '=== QUERY STATISTICS SUMMARY ==='
\echo ''
SELECT
    COUNT(*) AS total_queries,
    SUM(calls) AS total_calls,
    ROUND(SUM(total_exec_time)::numeric, 2) AS total_time_ms,
    ROUND(AVG(mean_exec_time)::numeric, 2) AS avg_mean_time_ms,
    COUNT(*) FILTER (WHERE mean_exec_time > ${MIN_DURATION_MS}) AS slow_queries,
    ROUND((100.0 * COUNT(*) FILTER (WHERE mean_exec_time > ${MIN_DURATION_MS}) / COUNT(*))::numeric, 2) AS slow_query_percent
FROM pg_stat_statements;

\echo ''
\echo '=== RECOMMENDATIONS ==='
\echo ''
EOF

    # Generate recommendations
    cat >> "$report_file" <<EOF

Query Optimization Recommendations:
-----------------------------------

1. HIGH TOTAL TIME QUERIES
   - Review queries with highest total execution time
   - Consider adding indexes, rewriting queries, or caching results
   - Check if query plans are using indexes effectively

2. FREQUENT SLOW QUERIES
   - Queries called frequently with high execution time need optimization
   - Consider materialized views for complex aggregations
   - Implement query result caching at application level

3. HIGH VARIANCE QUERIES
   - Inconsistent execution times indicate:
     * Missing or ineffective indexes
     * Lock contention
     * Variable data distributions
   - Run EXPLAIN ANALYZE on these queries to understand plan variations

4. SEQUENTIAL SCANS
   - Tables with high sequential scan counts may need indexes
   - For small tables (<1000 rows), sequential scans may be optimal
   - Consider partial indexes for queries with WHERE clauses

5. TABLE BLOAT
   - Tables with >10% dead rows should be vacuumed
   - Run: VACUUM ANALYZE tablename;
   - Consider auto_vacuum tuning for write-heavy tables

Next Steps:
-----------
1. Analyze specific slow queries with EXPLAIN ANALYZE:
   docker exec ${CONTAINER_NAME} psql -U dpg_cluster -d distributed_postgres_cluster \\
     -c "EXPLAIN ANALYZE <your_query>;"

2. Create indexes based on WHERE/JOIN clauses:
   CREATE INDEX CONCURRENTLY idx_name ON table_name (column_name);

3. Use covering indexes for frequently accessed columns:
   CREATE INDEX idx_name ON table_name (key_col) INCLUDE (other_cols);

4. Monitor index usage after creation:
   ./scripts/performance/tune-postgresql.sh indexes

5. Reset statistics after optimization to measure improvements:
   $0 reset

EOF

    cat "$report_file"
    log_success "Report saved to: $report_file"
}

# Generate index recommendations
generate_index_recommendations() {
    log_info "Generating index recommendations..."

    docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster <<'EOF'
\echo '=== INDEX RECOMMENDATIONS ==='
\echo ''
\echo 'Tables with Sequential Scans (may need indexes):'
SELECT
    schemaname || '.' || tablename AS table_name,
    seq_scan AS seq_scans,
    idx_scan AS idx_scans,
    ROUND(100.0 * seq_scan / NULLIF(seq_scan + idx_scan, 0), 2) AS seq_scan_percent,
    pg_size_pretty(pg_relation_size(schemaname || '.' || tablename)) AS size,
    'CREATE INDEX CONCURRENTLY idx_' || tablename || '_<column> ON ' ||
    schemaname || '.' || tablename || ' (<column>);' AS suggested_command
FROM pg_stat_user_tables
WHERE schemaname IN ('public', 'claude_flow')
    AND seq_scan > 100
    AND idx_scan < seq_scan
ORDER BY seq_scan DESC
LIMIT 10;

\echo ''
\echo 'Unused Indexes (consider dropping):'
SELECT
    schemaname || '.' || tablename AS table_name,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size,
    'DROP INDEX CONCURRENTLY ' || schemaname || '.' || indexname || ';' AS suggested_command
FROM pg_stat_user_indexes
WHERE idx_scan = 0
    AND schemaname IN ('public', 'claude_flow')
    AND indexname NOT LIKE '%_pkey'
ORDER BY pg_relation_size(indexrelid) DESC;
EOF
}

# Reset statistics
reset_statistics() {
    log_warning "Resetting pg_stat_statements statistics..."
    read -p "This will clear all query statistics. Continue? (y/N) " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster <<EOF
SELECT pg_stat_statements_reset();
SELECT pg_stat_reset();
EOF
        log_success "Statistics reset"
    else
        log_info "Reset cancelled"
    fi
}

# Export slow queries for external analysis
export_slow_queries() {
    log_info "Exporting slow queries to CSV..."

    local csv_file="/tmp/slow_queries_$(date +%Y%m%d_%H%M%S).csv"

    docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -c "
        COPY (
            SELECT
                queryid,
                calls,
                ROUND(total_exec_time::numeric, 2) AS total_time_ms,
                ROUND(mean_exec_time::numeric, 2) AS mean_time_ms,
                ROUND(stddev_exec_time::numeric, 2) AS stddev_time_ms,
                ROUND(min_exec_time::numeric, 2) AS min_time_ms,
                ROUND(max_exec_time::numeric, 2) AS max_time_ms,
                rows,
                shared_blks_hit,
                shared_blks_read,
                query
            FROM pg_stat_statements
            WHERE mean_exec_time > ${MIN_DURATION_MS}
            ORDER BY total_exec_time DESC
        ) TO STDOUT WITH CSV HEADER;
    " > "$csv_file"

    log_success "Slow queries exported to: $csv_file"
}

# Main execution
main() {
    check_container

    echo "╔════════════════════════════════════════════════════════╗"
    echo "║        Slow Query Analysis for Distributed Cluster     ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo

    case "${1:-report}" in
        setup)
            setup_pg_stat_statements
            ;;
        report)
            generate_report
            echo
            log_info "For index recommendations, run: $0 indexes"
            ;;
        indexes)
            generate_index_recommendations
            ;;
        reset)
            reset_statistics
            ;;
        export)
            export_slow_queries
            ;;
        *)
            log_error "Unknown action: $1"
            echo "Usage: $0 [action]"
            echo "  setup   - Enable pg_stat_statements extension"
            echo "  report  - Generate slow query report (default)"
            echo "  indexes - Generate index recommendations"
            echo "  reset   - Reset query statistics"
            echo "  export  - Export slow queries to CSV"
            echo
            echo "Environment variables:"
            echo "  MIN_DURATION_MS - Minimum query duration threshold (default: 100)"
            echo "  TOP_N           - Number of top results to show (default: 20)"
            exit 1
            ;;
    esac
}

main "$@"
