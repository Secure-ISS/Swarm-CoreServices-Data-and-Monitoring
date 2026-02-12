#!/bin/bash
# Test Citus Distribution and Query Performance
# Verifies sharding, co-location, and query routing
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
COORDINATOR_HOST="${CITUS_COORDINATOR_HOST:-localhost}"
COORDINATOR_PORT="${CITUS_COORDINATOR_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-dpg_cluster}"
POSTGRES_DB="${POSTGRES_DB:-distributed_postgres_cluster}"

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_test() { echo -e "${CYAN}[TEST]${NC} $1"; }

# Test result tracking
test_passed() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    PASSED_TESTS=$((PASSED_TESTS + 1))
    log_success "PASSED: $1"
}

test_failed() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    FAILED_TESTS=$((FAILED_TESTS + 1))
    log_error "FAILED: $1"
}

# Execute SQL and check result
run_test() {
    local test_name=$1
    local sql=$2
    local expected_result=$3

    log_test "Running: $test_name"

    local result=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c "$sql" 2>&1)

    if [[ "$result" == *"$expected_result"* ]]; then
        test_passed "$test_name"
        return 0
    else
        test_failed "$test_name - Expected: $expected_result, Got: $result"
        return 1
    fi
}

# Test 1: Verify Citus extension
test_citus_extension() {
    log_info "Test 1: Verifying Citus extension..."

    run_test "Citus extension exists" \
        "SELECT extname FROM pg_extension WHERE extname = 'citus';" \
        "citus"

    run_test "RuVector extension exists" \
        "SELECT extname FROM pg_extension WHERE extname = 'ruvector';" \
        "ruvector"
}

# Test 2: Verify worker nodes
test_worker_nodes() {
    log_info "Test 2: Verifying worker nodes..."

    run_test "3 worker nodes registered" \
        "SELECT COUNT(*) FROM citus_get_active_worker_nodes();" \
        "3"

    run_test "All workers active" \
        "SELECT COUNT(*) FROM pg_dist_node WHERE isactive = true AND groupid > 0;" \
        "3"
}

# Test 3: Test distributed table creation
test_distributed_tables() {
    log_info "Test 3: Testing distributed table creation..."

    # Create test table
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL > /dev/null 2>&1
        DROP TABLE IF EXISTS test_users CASCADE;
        CREATE TABLE test_users (
            user_id BIGSERIAL PRIMARY KEY,
            username VARCHAR(255) NOT NULL,
            email VARCHAR(255) NOT NULL
        );
        SELECT create_distributed_table('test_users', 'user_id');
EOSQL

    run_test "Distributed table created" \
        "SELECT table_name FROM citus_tables WHERE table_name::text = 'test_users';" \
        "test_users"

    run_test "Shards created across workers" \
        "SELECT COUNT(DISTINCT nodename) FROM citus_shards WHERE table_name::text = 'test_users';" \
        "3"
}

# Test 4: Test data distribution
test_data_distribution() {
    log_info "Test 4: Testing data distribution..."

    # Insert test data
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL > /dev/null 2>&1
        INSERT INTO test_users (username, email)
        SELECT 'user_' || i, 'user' || i || '@example.com'
        FROM generate_series(1, 1000) i;
EOSQL

    run_test "1000 rows inserted" \
        "SELECT COUNT(*) FROM test_users;" \
        "1000"

    # Check distribution across shards
    local min_shards=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c \
        "SELECT MIN(cnt) FROM (SELECT nodename, COUNT(*) as cnt FROM citus_shards WHERE table_name::text = 'test_users' GROUP BY nodename) t;")

    if [ "$min_shards" -gt 8 ]; then
        test_passed "Shards balanced across workers (min: $min_shards per node)"
    else
        test_failed "Uneven shard distribution (min: $min_shards per node)"
    fi
}

# Test 5: Test co-location
test_colocation() {
    log_info "Test 5: Testing table co-location..."

    # Create co-located table
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL > /dev/null 2>&1
        DROP TABLE IF EXISTS test_orders CASCADE;
        CREATE TABLE test_orders (
            order_id BIGSERIAL,
            user_id BIGINT NOT NULL,
            total DECIMAL(10,2),
            PRIMARY KEY (order_id, user_id)
        );
        SELECT create_distributed_table('test_orders', 'user_id', colocate_with => 'test_users');

        INSERT INTO test_orders (user_id, total)
        SELECT (i % 1000) + 1, RANDOM() * 1000
        FROM generate_series(1, 5000) i;
EOSQL

    run_test "Co-located table created" \
        "SELECT COUNT(*) FROM citus_tables WHERE table_name::text IN ('test_users', 'test_orders');" \
        "2"

    # Test join performance
    local join_result=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c \
        "EXPLAIN (FORMAT JSON) SELECT COUNT(*) FROM test_users u JOIN test_orders o ON u.user_id = o.user_id;" | grep -c "Distributed")

    if [ "$join_result" -gt 0 ]; then
        test_passed "Co-located join executed correctly"
    else
        test_failed "Co-located join not optimized"
    fi
}

# Test 6: Test reference tables
test_reference_tables() {
    log_info "Test 6: Testing reference tables..."

    # Create reference table
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL > /dev/null 2>&1
        DROP TABLE IF EXISTS test_config CASCADE;
        CREATE TABLE test_config (
            key VARCHAR(255) PRIMARY KEY,
            value TEXT
        );
        SELECT create_reference_table('test_config');

        INSERT INTO test_config VALUES
            ('setting1', 'value1'),
            ('setting2', 'value2');
EOSQL

    run_test "Reference table created" \
        "SELECT citus_table_type FROM citus_tables WHERE table_name::text = 'test_config';" \
        "reference"

    # Reference tables should be replicated to all workers
    local worker_count=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c \
        "SELECT COUNT(DISTINCT nodename) FROM citus_shards WHERE table_name::text = 'test_config';")

    if [ "$worker_count" -eq 3 ]; then
        test_passed "Reference table replicated to all workers"
    else
        test_failed "Reference table not replicated correctly (on $worker_count workers)"
    fi
}

# Test 7: Test query routing
test_query_routing() {
    log_info "Test 7: Testing query routing..."

    # Test single-shard query (should prune to 1 shard)
    local single_shard=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c \
        "EXPLAIN (FORMAT JSON) SELECT * FROM test_users WHERE user_id = 123;" | grep -c "Task Count.*: 1")

    if [ "$single_shard" -gt 0 ]; then
        test_passed "Single-shard query routed correctly"
    else
        test_failed "Single-shard query not optimized"
    fi

    # Test multi-shard query
    local multi_shard=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c \
        "EXPLAIN (FORMAT JSON) SELECT COUNT(*) FROM test_users;" | grep -c "Distributed")

    if [ "$multi_shard" -gt 0 ]; then
        test_passed "Multi-shard query distributed correctly"
    else
        test_failed "Multi-shard query not distributed"
    fi
}

# Test 8: Test RuVector integration
test_ruvector() {
    log_info "Test 8: Testing RuVector integration..."

    # Create vector table
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL > /dev/null 2>&1
        DROP TABLE IF EXISTS test_embeddings CASCADE;
        CREATE TABLE test_embeddings (
            embedding_id BIGSERIAL,
            user_id BIGINT NOT NULL,
            content TEXT,
            embedding ruvector(128),
            PRIMARY KEY (embedding_id, user_id)
        );
        SELECT create_distributed_table('test_embeddings', 'user_id', colocate_with => 'test_users');

        INSERT INTO test_embeddings (user_id, content, embedding)
        SELECT
            (i % 1000) + 1,
            'content ' || i,
            ('[' || string_agg((RANDOM()::text), ',') || ']')::ruvector
        FROM generate_series(1, 100) i, generate_series(1, 128)
        GROUP BY i;
EOSQL

    run_test "RuVector table created" \
        "SELECT COUNT(*) FROM test_embeddings;" \
        "100"

    # Test vector operations
    local vector_query=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c \
        "SELECT COUNT(*) FROM test_embeddings WHERE user_id = 1 ORDER BY embedding <=> '[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8]'::ruvector LIMIT 10;" 2>&1)

    if [[ ! "$vector_query" =~ "ERROR" ]]; then
        test_passed "RuVector distance query executed"
    else
        test_failed "RuVector distance query failed: $vector_query"
    fi
}

# Test 9: Test rebalancing
test_rebalancing() {
    log_info "Test 9: Testing shard rebalancing..."

    # Check if rebalance function works
    local rebalance_result=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c \
        "SELECT rebalance_table_shards('test_users', threshold => 0.1);" 2>&1)

    if [[ ! "$rebalance_result" =~ "ERROR" ]]; then
        test_passed "Shard rebalancing executed"
    else
        test_failed "Shard rebalancing failed: $rebalance_result"
    fi
}

# Test 10: Performance benchmark
test_performance() {
    log_info "Test 10: Running performance benchmark..."

    # Simple insert benchmark
    local start_time=$(date +%s%N)
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
        "INSERT INTO test_users (username, email) SELECT 'perf_' || i, 'perf' || i || '@example.com' FROM generate_series(1, 10000) i;" > /dev/null 2>&1
    local end_time=$(date +%s%N)
    local insert_time=$(( (end_time - start_time) / 1000000 ))

    log_info "Insert 10k rows: ${insert_time}ms"

    # Simple select benchmark
    start_time=$(date +%s%N)
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
        "SELECT COUNT(*) FROM test_users;" > /dev/null 2>&1
    end_time=$(date +%s%N)
    local select_time=$(( (end_time - start_time) / 1000000 ))

    log_info "Count query: ${select_time}ms"

    if [ "$insert_time" -lt 5000 ] && [ "$select_time" -lt 1000 ]; then
        test_passed "Performance benchmark (insert: ${insert_time}ms, select: ${select_time}ms)"
    else
        test_warning "Performance slower than expected (insert: ${insert_time}ms, select: ${select_time}ms)"
    fi
}

# Cleanup test tables
cleanup_tests() {
    log_info "Cleaning up test tables..."

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL > /dev/null 2>&1
        DROP TABLE IF EXISTS test_embeddings CASCADE;
        DROP TABLE IF EXISTS test_orders CASCADE;
        DROP TABLE IF EXISTS test_users CASCADE;
        DROP TABLE IF EXISTS test_config CASCADE;
EOSQL

    log_success "Test tables cleaned up"
}

# Print test summary
print_summary() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          Test Summary                  ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "Total Tests:  $TOTAL_TESTS"
    echo -e "Passed:       ${GREEN}$PASSED_TESTS${NC}"
    echo -e "Failed:       ${RED}$FAILED_TESTS${NC}"
    echo ""

    if [ $FAILED_TESTS -eq 0 ]; then
        log_success "All tests passed!"
        return 0
    else
        log_error "Some tests failed"
        return 1
    fi
}

# Main test execution
main() {
    echo -e "${CYAN}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   Citus Distribution and Performance Tests     ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════╝${NC}"
    echo ""

    log_info "Starting tests..."
    echo ""

    test_citus_extension
    echo ""

    test_worker_nodes
    echo ""

    test_distributed_tables
    echo ""

    test_data_distribution
    echo ""

    test_colocation
    echo ""

    test_reference_tables
    echo ""

    test_query_routing
    echo ""

    test_ruvector
    echo ""

    test_rebalancing
    echo ""

    test_performance
    echo ""

    cleanup_tests
    echo ""

    print_summary
}

# Run main function
main "$@"
