#!/bin/bash
# RuVector Performance Optimization Script
# HNSW index tuning, vector operation profiling, batch optimization
# Usage: ./optimize-ruvector.sh [action: analyze|tune|benchmark|profile]

set -euo pipefail

# Configuration
CONTAINER_NAME="ruvector-db"
BENCHMARK_VECTORS="${BENCHMARK_VECTORS:-1000}"
BATCH_SIZE="${BATCH_SIZE:-100}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_perf() { echo -e "${MAGENTA}[PERF]${NC} $*"; }

# Check if container is running
check_container() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_error "Container ${CONTAINER_NAME} is not running"
        exit 1
    fi
}

# Analyze current HNSW indexes
analyze_indexes() {
    log_info "Analyzing RuVector HNSW indexes..."

    docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster <<'EOF'
\echo '════════════════════════════════════════════════════════════════'
\echo '  RuVector HNSW Index Analysis'
\echo '════════════════════════════════════════════════════════════════'
\echo ''

\echo '=== HNSW Indexes Overview ==='
\echo ''
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan AS scans,
    idx_tup_read AS tuples_read,
    idx_tup_fetch AS tuples_fetched
FROM pg_stat_user_indexes
WHERE indexname LIKE '%hnsw%'
ORDER BY schemaname, tablename;

\echo ''
\echo '=== Index Definitions and Parameters ==='
\echo ''
SELECT
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE indexname LIKE '%hnsw%'
ORDER BY schemaname, tablename;

\echo ''
\echo '=== Table Statistics (with vector columns) ==='
\echo ''
SELECT
    schemaname || '.' || tablename AS table_name,
    n_live_tup AS row_count,
    n_dead_tup AS dead_rows,
    last_vacuum,
    last_analyze,
    pg_size_pretty(pg_relation_size(schemaname || '.' || tablename)) AS table_size
FROM pg_stat_user_tables
WHERE schemaname IN ('public', 'claude_flow')
    AND tablename IN (
        SELECT DISTINCT tablename
        FROM pg_indexes
        WHERE indexname LIKE '%hnsw%'
    )
ORDER BY schemaname, tablename;

\echo ''
\echo '=== Vector Column Statistics ==='
\echo ''
SELECT
    schemaname || '.' || tablename AS table_name,
    attname AS column_name,
    n_distinct AS distinct_values,
    correlation
FROM pg_stats
WHERE schemaname IN ('public', 'claude_flow')
    AND attname LIKE '%embedding%'
ORDER BY schemaname, tablename;
EOF
}

# Benchmark HNSW parameters
benchmark_hnsw_params() {
    log_info "Benchmarking HNSW parameters (m and ef_construction)..."
    log_info "This may take several minutes..."

    local report_file="/tmp/hnsw_benchmark_$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "════════════════════════════════════════════════════════════════"
        echo "  RuVector HNSW Parameter Benchmark"
        echo "  Generated: $(date)"
        echo "════════════════════════════════════════════════════════════════"
        echo ""
        echo "Test Configuration:"
        echo "  Vectors: ${BENCHMARK_VECTORS}"
        echo "  Dimension: 1536 (OpenAI embedding dimension)"
        echo ""
    } > "$report_file"

    # Test different m values (default: 16)
    log_info "Testing m parameter (connectivity)..."
    for m in 8 16 32; do
        log_perf "Testing m=$m..."

        # Create test table
        docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster <<EOF >> "$report_file" 2>&1
DROP TABLE IF EXISTS hnsw_benchmark_m${m};
CREATE TABLE hnsw_benchmark_m${m} (
    id SERIAL PRIMARY KEY,
    embedding ruvector(1536)
);

-- Insert random vectors
INSERT INTO hnsw_benchmark_m${m} (embedding)
SELECT ('['||string_agg(random()::text, ',')||']')::ruvector(1536)
FROM generate_series(1, ${BENCHMARK_VECTORS}) s
CROSS JOIN generate_series(1, 1536);

-- Create index with timing
\timing on
CREATE INDEX idx_benchmark_m${m}_hnsw ON hnsw_benchmark_m${m}
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = ${m}, ef_construction = 100);
\timing off

-- Test query performance
\echo ''
\echo 'Query Performance (m=${m}):'
\timing on
SELECT id FROM hnsw_benchmark_m${m}
ORDER BY embedding <=> (SELECT embedding FROM hnsw_benchmark_m${m} LIMIT 1)
LIMIT 10;
\timing off
EOF
    done

    # Test different ef_construction values (default: 100)
    log_info "Testing ef_construction parameter (build quality)..."
    for ef in 50 100 200; do
        log_perf "Testing ef_construction=$ef..."

        docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster <<EOF >> "$report_file" 2>&1
DROP TABLE IF EXISTS hnsw_benchmark_ef${ef};
CREATE TABLE hnsw_benchmark_ef${ef} (
    id SERIAL PRIMARY KEY,
    embedding ruvector(1536)
);

-- Insert random vectors
INSERT INTO hnsw_benchmark_ef${ef} (embedding)
SELECT ('['||string_agg(random()::text, ',')||']')::ruvector(1536)
FROM generate_series(1, ${BENCHMARK_VECTORS}) s
CROSS JOIN generate_series(1, 1536);

-- Create index with timing
\timing on
CREATE INDEX idx_benchmark_ef${ef}_hnsw ON hnsw_benchmark_ef${ef}
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 16, ef_construction = ${ef});
\timing off

-- Test query performance
\echo ''
\echo 'Query Performance (ef_construction=${ef}):'
\timing on
SELECT id FROM hnsw_benchmark_ef${ef}
ORDER BY embedding <=> (SELECT embedding FROM hnsw_benchmark_ef${ef} LIMIT 1)
LIMIT 10;
\timing off
EOF
    done

    # Cleanup
    docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster <<EOF >> "$report_file" 2>&1
\echo ''
\echo 'Cleaning up benchmark tables...'
DROP TABLE IF EXISTS hnsw_benchmark_m8, hnsw_benchmark_m16, hnsw_benchmark_m32;
DROP TABLE IF EXISTS hnsw_benchmark_ef50, hnsw_benchmark_ef100, hnsw_benchmark_ef200;
EOF

    {
        echo ""
        echo "════════════════════════════════════════════════════════════════"
        echo "  Recommendations"
        echo "════════════════════════════════════════════════════════════════"
        echo ""
        echo "HNSW Parameter Tuning Guidelines:"
        echo ""
        echo "1. m (connectivity):"
        echo "   - Default: 16"
        echo "   - Lower (8): Faster build, less accurate, smaller index"
        echo "   - Higher (32): Slower build, more accurate, larger index"
        echo "   - Recommendation: 16 for balanced performance"
        echo ""
        echo "2. ef_construction (build quality):"
        echo "   - Default: 100"
        echo "   - Lower (50): Faster build, less accurate queries"
        echo "   - Higher (200): Slower build, more accurate queries"
        echo "   - Recommendation:"
        echo "     * 50-100 for development/testing"
        echo "     * 100-200 for production"
        echo "     * 200+ for high-accuracy requirements"
        echo ""
        echo "3. ef_search (query quality):"
        echo "   - Set at query time with SET hnsw.ef_search = N;"
        echo "   - Higher values = more accurate but slower queries"
        echo "   - Default: 100"
        echo "   - Recommendation: 100-200 for most use cases"
        echo ""
        echo "Trade-offs:"
        echo "  - Build time vs Query accuracy"
        echo "  - Index size vs Query performance"
        echo "  - Memory usage vs Throughput"
    } >> "$report_file"

    cat "$report_file"
    log_success "Benchmark report saved to: $report_file"
}

# Optimize existing indexes
tune_indexes() {
    log_info "Tuning existing HNSW indexes..."

    # Get current indexes
    local indexes=$(docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -t -A -c "
        SELECT schemaname || '.' || tablename AS table_name, indexname
        FROM pg_stat_user_indexes
        WHERE indexname LIKE '%hnsw%'
        ORDER BY schemaname, tablename;
    ")

    if [ -z "$indexes" ]; then
        log_warning "No HNSW indexes found"
        return
    fi

    log_info "Found HNSW indexes:"
    echo "$indexes"
    echo

    log_warning "Recreating indexes with optimized parameters..."
    read -p "This will temporarily drop and recreate indexes. Continue? (y/N) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Tuning cancelled"
        return
    fi

    # Recommended parameters for production
    local M=16
    local EF_CONSTRUCTION=200

    while IFS='|' read -r table_name index_name; do
        log_info "Optimizing index: $index_name on $table_name"

        # Get column name
        local column_name=$(docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -t -A -c "
            SELECT a.attname
            FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
            WHERE i.indexrelid = '$index_name'::regclass;
        ")

        docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster <<EOF
-- Drop old index
DROP INDEX IF EXISTS $index_name;

-- Create optimized index
CREATE INDEX CONCURRENTLY $index_name ON $table_name
USING hnsw ($column_name ruvector_cosine_ops)
WITH (m = $M, ef_construction = $EF_CONSTRUCTION);

-- Analyze table
ANALYZE $table_name;
EOF
        log_success "Optimized $index_name (m=$M, ef_construction=$EF_CONSTRUCTION)"
    done <<< "$indexes"
}

# Profile vector operations
profile_operations() {
    log_info "Profiling vector operations..."

    local profile_file="/tmp/ruvector_profile_$(date +%Y%m%d_%H%M%S).txt"

    docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster > "$profile_file" <<'EOF'
\echo '════════════════════════════════════════════════════════════════'
\echo '  RuVector Operation Profile'
\echo '════════════════════════════════════════════════════════════════'
\echo ''

\echo '=== Vector Insert Performance ==='
\timing on
DO $$
DECLARE
    start_time timestamp;
    end_time timestamp;
    vectors_count int := 100;
BEGIN
    start_time := clock_timestamp();

    CREATE TEMP TABLE temp_vectors (
        id SERIAL PRIMARY KEY,
        embedding ruvector(1536)
    );

    INSERT INTO temp_vectors (embedding)
    SELECT ('['||string_agg(random()::text, ',')||']')::ruvector(1536)
    FROM generate_series(1, vectors_count) s
    CROSS JOIN generate_series(1, 1536);

    end_time := clock_timestamp();

    RAISE NOTICE 'Inserted % vectors in %', vectors_count, end_time - start_time;
    RAISE NOTICE 'Average: % per vector', (end_time - start_time) / vectors_count;

    DROP TABLE temp_vectors;
END $$;
\timing off

\echo ''
\echo '=== Vector Search Performance (without index) ==='
\timing on
SELECT id FROM (
    SELECT id, ('['||string_agg(random()::text, ',')||']')::ruvector(1536) as emb
    FROM generate_series(1, 100) id
    CROSS JOIN generate_series(1, 1536)
    GROUP BY id
) t
ORDER BY emb <=> ('['||string_agg(random()::text, ',')||']')::ruvector(1536)
LIMIT 10;
\timing off

\echo ''
\echo '=== Batch Insert vs Single Insert Comparison ==='
DO $$
DECLARE
    start_time timestamp;
    end_time timestamp;
    batch_time interval;
    single_time interval;
BEGIN
    -- Batch insert
    CREATE TEMP TABLE temp_batch (embedding ruvector(1536));
    start_time := clock_timestamp();

    INSERT INTO temp_batch (embedding)
    SELECT ('['||string_agg(random()::text, ',')||']')::ruvector(1536)
    FROM generate_series(1, 100) s
    CROSS JOIN generate_series(1, 1536)
    GROUP BY s;

    end_time := clock_timestamp();
    batch_time := end_time - start_time;

    DROP TABLE temp_batch;

    -- Single inserts
    CREATE TEMP TABLE temp_single (embedding ruvector(1536));
    start_time := clock_timestamp();

    FOR i IN 1..100 LOOP
        INSERT INTO temp_single (embedding)
        SELECT ('['||string_agg(random()::text, ',')||']')::ruvector(1536)
        FROM generate_series(1, 1536);
    END LOOP;

    end_time := clock_timestamp();
    single_time := end_time - start_time;

    DROP TABLE temp_single;

    RAISE NOTICE '';
    RAISE NOTICE 'Batch insert (100 vectors): %', batch_time;
    RAISE NOTICE 'Single inserts (100 vectors): %', single_time;
    RAISE NOTICE 'Batch speedup: %x', ROUND((EXTRACT(EPOCH FROM single_time) / EXTRACT(EPOCH FROM batch_time))::numeric, 2);
END $$;

\echo ''
\echo '=== Memory Usage ==='
SELECT
    pg_size_pretty(pg_database_size(current_database())) AS database_size,
    pg_size_pretty(SUM(pg_relation_size(schemaname || '.' || tablename))) AS total_table_size,
    pg_size_pretty(SUM(pg_relation_size(indexrelid))) AS total_index_size
FROM pg_stat_user_tables
JOIN pg_stat_user_indexes USING (schemaname, tablename)
WHERE schemaname IN ('public', 'claude_flow');
EOF

    cat "$profile_file"
    log_success "Profile saved to: $profile_file"
}

# Quick benchmark
quick_benchmark() {
    log_info "Running quick RuVector benchmark..."

    docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster <<'EOF'
\echo '════════════════════════════════════════════════════════════════'
\echo '  Quick RuVector Benchmark'
\echo '════════════════════════════════════════════════════════════════'
\echo ''

DO $$
DECLARE
    start_time timestamp;
    end_time timestamp;
    search_time interval;
BEGIN
    -- Create test data
    CREATE TEMP TABLE benchmark_vectors (
        id SERIAL PRIMARY KEY,
        embedding ruvector(1536)
    );

    \echo 'Creating 1000 test vectors...'
    INSERT INTO benchmark_vectors (embedding)
    SELECT ('['||string_agg(random()::text, ',')||']')::ruvector(1536)
    FROM generate_series(1, 1000) s
    CROSS JOIN generate_series(1, 1536)
    GROUP BY s;

    -- Create HNSW index
    \echo 'Creating HNSW index...'
    start_time := clock_timestamp();
    CREATE INDEX idx_benchmark_hnsw ON benchmark_vectors
    USING hnsw (embedding ruvector_cosine_ops)
    WITH (m = 16, ef_construction = 100);
    end_time := clock_timestamp();

    RAISE NOTICE 'Index creation time: %', end_time - start_time;

    -- Test search performance
    \echo '';
    \echo 'Running 10 similarity searches...';
    start_time := clock_timestamp();

    FOR i IN 1..10 LOOP
        PERFORM id FROM benchmark_vectors
        ORDER BY embedding <=> (SELECT embedding FROM benchmark_vectors ORDER BY random() LIMIT 1)
        LIMIT 10;
    END LOOP;

    end_time := clock_timestamp();
    search_time := end_time - start_time;

    RAISE NOTICE 'Total search time: %', search_time;
    RAISE NOTICE 'Average per search: %', search_time / 10;
    RAISE NOTICE 'Searches per second: %', ROUND(10 / EXTRACT(EPOCH FROM search_time), 2);

    DROP TABLE benchmark_vectors;
END $$;
EOF
}

# Generate optimization recommendations
generate_recommendations() {
    log_info "Generating RuVector optimization recommendations..."

    cat <<'EOF'
════════════════════════════════════════════════════════════════
  RuVector Optimization Recommendations
════════════════════════════════════════════════════════════════

1. HNSW Index Parameters
   ----------------------
   For DEVELOPMENT:
     CREATE INDEX idx_name ON table_name USING hnsw (embedding ruvector_cosine_ops)
     WITH (m = 16, ef_construction = 100);

   For PRODUCTION:
     CREATE INDEX idx_name ON table_name USING hnsw (embedding ruvector_cosine_ops)
     WITH (m = 16, ef_construction = 200);

   For HIGH ACCURACY:
     CREATE INDEX idx_name ON table_name USING hnsw (embedding ruvector_cosine_ops)
     WITH (m = 32, ef_construction = 200);

2. Query-Time Optimization
   -----------------------
   Adjust ef_search for accuracy/speed trade-off:
     SET hnsw.ef_search = 100;  -- Default
     SET hnsw.ef_search = 200;  -- Higher accuracy
     SET hnsw.ef_search = 50;   -- Faster queries

3. Batch Operations
   ----------------
   ALWAYS use batch inserts instead of single inserts:
     -- Good: Batch insert
     INSERT INTO table_name (embedding)
     SELECT ... FROM generate_series(...);

     -- Bad: Single inserts in loop
     FOR i IN 1..N LOOP
       INSERT INTO table_name (embedding) VALUES (...);
     END LOOP;

   Speedup: 10-50x for large batches

4. Memory Configuration
   --------------------
   For vector-heavy workloads, increase:
     shared_buffers = 4GB-8GB
     work_mem = 256MB-512MB
     maintenance_work_mem = 2GB

5. Index Maintenance
   -----------------
   Regular maintenance for optimal performance:
     VACUUM ANALYZE table_name;  -- Weekly
     REINDEX INDEX CONCURRENTLY idx_name;  -- Monthly or after major changes

6. Connection Pooling
   ------------------
   For high-concurrency vector operations:
     - Use PgBouncer or similar
     - Pool size: CPU cores * 2-4
     - Max connections: Pool size * 10

7. Monitoring
   ----------
   Track these metrics:
     - Average query time: SELECT avg(mean_exec_time) FROM pg_stat_statements WHERE query LIKE '%<=>%';
     - Index size: SELECT pg_size_pretty(pg_relation_size('idx_name'));
     - Cache hit ratio: SELECT sum(idx_blks_hit) / nullif(sum(idx_blks_hit + idx_blks_read), 0) FROM pg_statio_user_indexes;

8. Performance Targets
   -------------------
   Typical performance for 1M vectors (1536 dimensions):
     - Index build: 5-15 minutes
     - Query latency: 5-50ms (k=10)
     - Throughput: 100-1000 queries/sec
     - Index size: 1-5GB

EOF
}

# Main execution
main() {
    check_container

    echo "╔════════════════════════════════════════════════════════╗"
    echo "║        RuVector Performance Optimization Tool          ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo

    case "${1:-analyze}" in
        analyze)
            analyze_indexes
            ;;
        tune)
            tune_indexes
            ;;
        benchmark)
            benchmark_hnsw_params
            ;;
        profile)
            profile_operations
            ;;
        quick)
            quick_benchmark
            ;;
        recommendations|recommend)
            generate_recommendations
            ;;
        *)
            log_error "Unknown action: $1"
            echo "Usage: $0 [action]"
            echo "  analyze         - Analyze current HNSW indexes (default)"
            echo "  tune            - Optimize existing indexes"
            echo "  benchmark       - Benchmark HNSW parameters"
            echo "  profile         - Profile vector operations"
            echo "  quick           - Quick performance benchmark"
            echo "  recommendations - Show optimization recommendations"
            echo
            echo "Environment variables:"
            echo "  BENCHMARK_VECTORS - Number of vectors for benchmarking (default: 1000)"
            echo "  BATCH_SIZE        - Batch size for operations (default: 100)"
            exit 1
            ;;
    esac
}

main "$@"
