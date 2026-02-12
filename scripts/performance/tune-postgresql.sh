#!/bin/bash
# PostgreSQL Auto-Tuning Script for Distributed PostgreSQL Cluster
# Analyzes workload patterns and auto-tunes PostgreSQL parameters
# Usage: ./tune-postgresql.sh [workload_type: read-heavy|write-heavy|mixed|auto]

set -euo pipefail

# Configuration
CONTAINER_NAME="ruvector-db"
WORKLOAD_TYPE="${1:-auto}"
BACKUP_SUFFIX=$(date +%Y%m%d_%H%M%S)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_error "Container ${CONTAINER_NAME} is not running"
    exit 1
fi

# Get system information
get_system_info() {
    log_info "Analyzing system resources..."

    # Get total system memory (in GB)
    TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    TOTAL_RAM_MB=$((TOTAL_RAM_GB * 1024))

    # Get CPU cores
    CPU_CORES=$(nproc)

    # Get available disk space (in GB)
    DISK_SPACE_GB=$(df -BG /var/lib/docker | awk 'NR==2 {print $4}' | sed 's/G//')

    log_info "System: ${TOTAL_RAM_GB}GB RAM, ${CPU_CORES} CPU cores, ${DISK_SPACE_GB}GB disk"
}

# Analyze workload patterns
analyze_workload() {
    log_info "Analyzing workload patterns..."

    local stats=$(docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -t -A -c "
        SELECT
            COALESCE(SUM(tup_inserted), 0) as inserts,
            COALESCE(SUM(tup_updated), 0) as updates,
            COALESCE(SUM(tup_deleted), 0) as deletes,
            COALESCE(SUM(seq_scan), 0) as seq_scans,
            COALESCE(SUM(idx_scan), 0) as idx_scans,
            COALESCE(SUM(tup_fetched), 0) as rows_fetched
        FROM pg_stat_user_tables;
    " 2>/dev/null || echo "0|0|0|0|0|0")

    IFS='|' read -r INSERTS UPDATES DELETES SEQ_SCANS IDX_SCANS ROWS_FETCHED <<< "$stats"

    WRITES=$((INSERTS + UPDATES + DELETES))
    READS=$((SEQ_SCANS + IDX_SCANS))

    if [ "$WORKLOAD_TYPE" = "auto" ]; then
        if [ "$WRITES" -eq 0 ] && [ "$READS" -eq 0 ]; then
            WORKLOAD_TYPE="mixed"
            log_info "No activity detected, using mixed workload profile"
        elif [ "$WRITES" -gt $((READS * 2)) ]; then
            WORKLOAD_TYPE="write-heavy"
            log_info "Detected write-heavy workload (writes: $WRITES, reads: $READS)"
        elif [ "$READS" -gt $((WRITES * 2)) ]; then
            WORKLOAD_TYPE="read-heavy"
            log_info "Detected read-heavy workload (writes: $WRITES, reads: $READS)"
        else
            WORKLOAD_TYPE="mixed"
            log_info "Detected mixed workload (writes: $WRITES, reads: $READS)"
        fi
    fi

    log_success "Workload type: $WORKLOAD_TYPE"
}

# Calculate optimal parameters
calculate_parameters() {
    log_info "Calculating optimal PostgreSQL parameters..."

    # shared_buffers: 25% of RAM (up to 8GB for smaller systems)
    SHARED_BUFFERS_MB=$((TOTAL_RAM_MB / 4))
    if [ "$SHARED_BUFFERS_MB" -gt 8192 ]; then
        SHARED_BUFFERS_MB=8192
    fi

    # effective_cache_size: 50-75% of RAM
    EFFECTIVE_CACHE_SIZE_MB=$((TOTAL_RAM_MB * 2 / 3))

    # maintenance_work_mem: RAM / 16 (up to 2GB)
    MAINTENANCE_WORK_MEM_MB=$((TOTAL_RAM_MB / 16))
    if [ "$MAINTENANCE_WORK_MEM_MB" -gt 2048 ]; then
        MAINTENANCE_WORK_MEM_MB=2048
    fi

    # work_mem: Depends on workload and max_connections
    # Formula: (RAM - shared_buffers) / (max_connections * 3)
    MAX_CONNECTIONS=$(docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -t -A -c "SHOW max_connections;" 2>/dev/null || echo "100")
    WORK_MEM_MB=$(((TOTAL_RAM_MB - SHARED_BUFFERS_MB) / (MAX_CONNECTIONS * 3)))

    # Adjust based on workload
    case "$WORKLOAD_TYPE" in
        read-heavy)
            WORK_MEM_MB=$((WORK_MEM_MB * 2))
            RANDOM_PAGE_COST="1.1"
            EFFECTIVE_IO_CONCURRENCY="200"
            ;;
        write-heavy)
            WAL_BUFFERS_MB="16"
            CHECKPOINT_COMPLETION_TARGET="0.9"
            EFFECTIVE_IO_CONCURRENCY="100"
            RANDOM_PAGE_COST="1.5"
            ;;
        mixed)
            RANDOM_PAGE_COST="1.3"
            EFFECTIVE_IO_CONCURRENCY="150"
            ;;
    esac

    # Limit work_mem to reasonable values
    if [ "$WORK_MEM_MB" -gt 512 ]; then
        WORK_MEM_MB=512
    elif [ "$WORK_MEM_MB" -lt 4 ]; then
        WORK_MEM_MB=4
    fi

    # wal_buffers: -1 (auto) or 16MB for write-heavy
    WAL_BUFFERS_MB="${WAL_BUFFERS_MB:-"-1"}"

    # checkpoint_completion_target
    CHECKPOINT_COMPLETION_TARGET="${CHECKPOINT_COMPLETION_TARGET:-0.7}"

    # max_wal_size: 2-4GB for write-heavy, 1GB otherwise
    if [ "$WORKLOAD_TYPE" = "write-heavy" ]; then
        MAX_WAL_SIZE_MB="4096"
    else
        MAX_WAL_SIZE_MB="1024"
    fi

    # min_wal_size: 1/4 of max_wal_size
    MIN_WAL_SIZE_MB=$((MAX_WAL_SIZE_MB / 4))

    # default_statistics_target: 100-500
    if [ "$WORKLOAD_TYPE" = "read-heavy" ]; then
        DEFAULT_STATISTICS_TARGET="500"
    else
        DEFAULT_STATISTICS_TARGET="100"
    fi
}

# Backup current configuration
backup_config() {
    log_info "Backing up current configuration..."
    docker exec "$CONTAINER_NAME" bash -c "
        if [ -f /var/lib/postgresql/data/postgresql.auto.conf ]; then
            cp /var/lib/postgresql/data/postgresql.auto.conf /var/lib/postgresql/data/postgresql.auto.conf.backup.$BACKUP_SUFFIX
        fi
    " 2>/dev/null || true
    log_success "Configuration backed up"
}

# Apply tuning parameters
apply_tuning() {
    log_info "Applying tuning parameters..."

    docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster <<EOF
-- Memory Configuration
ALTER SYSTEM SET shared_buffers = '${SHARED_BUFFERS_MB}MB';
ALTER SYSTEM SET effective_cache_size = '${EFFECTIVE_CACHE_SIZE_MB}MB';
ALTER SYSTEM SET maintenance_work_mem = '${MAINTENANCE_WORK_MEM_MB}MB';
ALTER SYSTEM SET work_mem = '${WORK_MEM_MB}MB';

-- WAL Configuration
ALTER SYSTEM SET wal_buffers = '${WAL_BUFFERS_MB}MB';
ALTER SYSTEM SET checkpoint_completion_target = ${CHECKPOINT_COMPLETION_TARGET};
ALTER SYSTEM SET max_wal_size = '${MAX_WAL_SIZE_MB}MB';
ALTER SYSTEM SET min_wal_size = '${MIN_WAL_SIZE_MB}MB';

-- Query Planning
ALTER SYSTEM SET random_page_cost = ${RANDOM_PAGE_COST};
ALTER SYSTEM SET effective_io_concurrency = ${EFFECTIVE_IO_CONCURRENCY};
ALTER SYSTEM SET default_statistics_target = ${DEFAULT_STATISTICS_TARGET};

-- Parallel Query
ALTER SYSTEM SET max_parallel_workers_per_gather = ${CPU_CORES};
ALTER SYSTEM SET max_parallel_workers = ${CPU_CORES};
ALTER SYSTEM SET max_worker_processes = $((CPU_CORES * 2));

-- Logging (for performance analysis)
ALTER SYSTEM SET log_min_duration_statement = 1000; -- Log queries > 1s
ALTER SYSTEM SET log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h ';
ALTER SYSTEM SET log_checkpoints = on;
ALTER SYSTEM SET log_connections = on;
ALTER SYSTEM SET log_disconnections = on;
ALTER SYSTEM SET log_lock_waits = on;
ALTER SYSTEM SET log_temp_files = 0;
ALTER SYSTEM SET log_autovacuum_min_duration = 0;

-- Autovacuum
ALTER SYSTEM SET autovacuum = on;
ALTER SYSTEM SET autovacuum_max_workers = 3;
ALTER SYSTEM SET autovacuum_naptime = '10s';
EOF

    log_success "Tuning parameters applied"
}

# Generate tuning report
generate_report() {
    log_info "Generating tuning report..."

    cat > "/tmp/postgresql_tuning_report_${BACKUP_SUFFIX}.txt" <<EOF
PostgreSQL Auto-Tuning Report
=============================
Date: $(date)
Workload Type: $WORKLOAD_TYPE

System Resources:
- Total RAM: ${TOTAL_RAM_GB}GB (${TOTAL_RAM_MB}MB)
- CPU Cores: ${CPU_CORES}
- Disk Space: ${DISK_SPACE_GB}GB

Applied Parameters:
-------------------
Memory Configuration:
- shared_buffers: ${SHARED_BUFFERS_MB}MB
- effective_cache_size: ${EFFECTIVE_CACHE_SIZE_MB}MB
- maintenance_work_mem: ${MAINTENANCE_WORK_MEM_MB}MB
- work_mem: ${WORK_MEM_MB}MB

WAL Configuration:
- wal_buffers: ${WAL_BUFFERS_MB}MB
- checkpoint_completion_target: ${CHECKPOINT_COMPLETION_TARGET}
- max_wal_size: ${MAX_WAL_SIZE_MB}MB
- min_wal_size: ${MIN_WAL_SIZE_MB}MB

Query Planning:
- random_page_cost: ${RANDOM_PAGE_COST}
- effective_io_concurrency: ${EFFECTIVE_IO_CONCURRENCY}
- default_statistics_target: ${DEFAULT_STATISTICS_TARGET}

Parallel Query:
- max_parallel_workers_per_gather: ${CPU_CORES}
- max_parallel_workers: ${CPU_CORES}
- max_worker_processes: $((CPU_CORES * 2))

Workload Statistics:
- Inserts: ${INSERTS}
- Updates: ${UPDATES}
- Deletes: ${DELETES}
- Sequential Scans: ${SEQ_SCANS}
- Index Scans: ${IDX_SCANS}
- Rows Fetched: ${ROWS_FETCHED}

Next Steps:
-----------
1. Restart PostgreSQL for changes to take effect:
   docker restart ${CONTAINER_NAME}

2. Monitor performance after restart

3. Run VACUUM ANALYZE on all tables:
   ./scripts/performance/tune-postgresql.sh vacuum

4. Review slow queries:
   ./scripts/performance/analyze-slow-queries.sh

Configuration Backup:
--------------------
postgresql.auto.conf.backup.$BACKUP_SUFFIX
EOF

    cat "/tmp/postgresql_tuning_report_${BACKUP_SUFFIX}.txt"
    log_success "Report saved to: /tmp/postgresql_tuning_report_${BACKUP_SUFFIX}.txt"
}

# VACUUM and ANALYZE operations
run_maintenance() {
    log_info "Running VACUUM ANALYZE on all tables..."

    # Get all tables
    tables=$(docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -t -A -c "
        SELECT schemaname || '.' || tablename
        FROM pg_tables
        WHERE schemaname IN ('public', 'claude_flow')
        ORDER BY schemaname, tablename;
    ")

    for table in $tables; do
        log_info "Processing $table..."
        docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -c "VACUUM ANALYZE $table;" || log_warning "Failed to VACUUM ANALYZE $table"
    done

    log_success "VACUUM ANALYZE completed"
}

# Index optimization
optimize_indexes() {
    log_info "Analyzing index usage and recommending optimizations..."

    docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster <<'EOF'
\echo '=== Unused Indexes (consider dropping) ==='
SELECT
    schemaname || '.' || tablename AS table,
    indexname AS index,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
    AND schemaname IN ('public', 'claude_flow')
ORDER BY pg_relation_size(indexrelid) DESC;

\echo '\n=== Missing Indexes (based on sequential scans) ==='
SELECT
    schemaname || '.' || tablename AS table,
    seq_scan AS sequential_scans,
    seq_tup_read AS rows_read,
    idx_scan AS index_scans,
    CASE
        WHEN seq_scan = 0 THEN 0
        ELSE ROUND(100.0 * idx_scan / (seq_scan + idx_scan), 2)
    END AS index_scan_percentage
FROM pg_stat_user_tables
WHERE schemaname IN ('public', 'claude_flow')
    AND seq_scan > 100
    AND idx_scan < seq_scan
ORDER BY seq_scan DESC
LIMIT 10;

\echo '\n=== Index Statistics ==='
SELECT
    schemaname || '.' || tablename AS table,
    indexname AS index,
    idx_scan AS scans,
    idx_tup_read AS tuples_read,
    idx_tup_fetch AS tuples_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname IN ('public', 'claude_flow')
    AND idx_scan > 0
ORDER BY idx_scan DESC
LIMIT 20;
EOF
}

# Main execution
main() {
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║   PostgreSQL Auto-Tuning for Distributed Cluster      ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo

    case "${1:-analyze}" in
        vacuum)
            run_maintenance
            ;;
        indexes)
            optimize_indexes
            ;;
        analyze)
            get_system_info
            analyze_workload
            calculate_parameters
            backup_config
            apply_tuning
            generate_report
            echo
            log_warning "Configuration changes require PostgreSQL restart:"
            log_info "docker restart ${CONTAINER_NAME}"
            ;;
        *)
            log_error "Unknown command: $1"
            echo "Usage: $0 [analyze|vacuum|indexes] [workload_type]"
            echo "  analyze  - Auto-tune PostgreSQL parameters (default)"
            echo "  vacuum   - Run VACUUM ANALYZE on all tables"
            echo "  indexes  - Analyze index usage and recommend optimizations"
            echo
            echo "Workload types: read-heavy, write-heavy, mixed, auto (default)"
            exit 1
            ;;
    esac
}

main "$@"
