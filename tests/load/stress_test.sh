#!/bin/bash
# Stress Testing Script for Distributed PostgreSQL Cluster
#
# This script performs aggressive stress testing including:
# - Connection pool exhaustion
# - Failover scenarios (requires Patroni)
# - Network partition simulation
# - Resource saturation tests

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="$PROJECT_ROOT/tests/load/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Database configuration
DB_HOST="${RUVECTOR_HOST:-localhost}"
DB_PORT="${RUVECTOR_PORT:-5432}"
DB_NAME="${RUVECTOR_DB:-distributed_postgres_cluster}"
DB_USER="${RUVECTOR_USER:-dpg_cluster}"
export PGPASSWORD="${RUVECTOR_PASSWORD:-dpg_cluster_2026}"

# Test configuration
MAX_CONNECTIONS=100
STRESS_DURATION=60
FAILOVER_TEST=${FAILOVER_TEST:-false}

# Create results directory
mkdir -p "$RESULTS_DIR"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_dependencies() {
    log_info "Checking dependencies..."

    local missing=()

    command -v psql >/dev/null 2>&1 || missing+=("psql")
    command -v pgbench >/dev/null 2>&1 || missing+=("pgbench")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing dependencies: ${missing[*]}"
        log_info "Install with: sudo apt-get install postgresql-client postgresql-contrib python3"
        exit 1
    fi

    log_info "✓ All dependencies found"
}

check_database() {
    log_info "Checking database connectivity..."

    if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1" >/dev/null 2>&1; then
        log_info "✓ Database is accessible"
        return 0
    else
        log_error "Cannot connect to database"
        return 1
    fi
}

get_db_stats() {
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "
        SELECT json_build_object(
            'active_connections', (SELECT count(*) FROM pg_stat_activity WHERE state = 'active'),
            'idle_connections', (SELECT count(*) FROM pg_stat_activity WHERE state = 'idle'),
            'total_connections', (SELECT count(*) FROM pg_stat_activity),
            'max_connections', (SELECT setting::int FROM pg_settings WHERE name = 'max_connections'),
            'db_size_mb', (SELECT pg_database_size(current_database()) / 1024 / 1024)
        )::text
    "
}

test_connection_exhaustion() {
    log_info "Test 1: Connection Pool Exhaustion"
    log_info "Testing up to $MAX_CONNECTIONS concurrent connections..."

    local test_results="$RESULTS_DIR/connection_exhaustion_$TIMESTAMP.log"

    # Test increasing connection counts
    for num_conns in 10 25 40 50 75 100; do
        log_info "Testing $num_conns concurrent connections..."

        if [ -f "$PROJECT_ROOT/scripts/test_pool_capacity.py" ]; then
            python3 "$PROJECT_ROOT/scripts/test_pool_capacity.py" "$num_conns" >> "$test_results" 2>&1

            if [ $? -eq 0 ]; then
                log_info "  ✓ $num_conns connections: PASS"
            else
                log_warn "  ✗ $num_conns connections: FAIL"
            fi
        else
            log_warn "  Pool capacity test script not found"
        fi

        sleep 2
    done

    log_info "Connection exhaustion test complete. Results: $test_results"
}

test_sustained_load() {
    log_info "Test 2: Sustained Load ($STRESS_DURATION seconds)"

    local test_results="$RESULTS_DIR/sustained_load_$TIMESTAMP.log"

    # Initialize pgbench schema if needed
    pgbench -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -i -s 10 "$DB_NAME" >/dev/null 2>&1 || true

    log_info "Running pgbench with multiple clients..."

    # Run pgbench with varying client counts
    for clients in 10 25 50; do
        log_info "  Testing with $clients clients..."

        pgbench -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
                -c "$clients" -j 4 -T "$STRESS_DURATION" \
                -r -P 10 \
                "$DB_NAME" >> "$test_results" 2>&1

        log_info "  ✓ Completed $clients clients"
        sleep 5
    done

    log_info "Sustained load test complete. Results: $test_results"
}

test_rapid_connections() {
    log_info "Test 3: Rapid Connection Churn"

    local test_results="$RESULTS_DIR/rapid_connections_$TIMESTAMP.log"
    local duration=30
    local count=0
    local errors=0
    local start_time=$(date +%s)

    log_info "Opening and closing connections rapidly for ${duration}s..."

    while [ $(($(date +%s) - start_time)) -lt $duration ]; do
        if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1" >/dev/null 2>&1; then
            ((count++))
        else
            ((errors++))
        fi
    done

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    local rate=$((count / elapsed))

    echo "Rapid Connection Test Results" > "$test_results"
    echo "=============================" >> "$test_results"
    echo "Duration: ${elapsed}s" >> "$test_results"
    echo "Successful connections: $count" >> "$test_results"
    echo "Failed connections: $errors" >> "$test_results"
    echo "Rate: ${rate} connections/sec" >> "$test_results"

    log_info "✓ Rapid connection test complete"
    log_info "  Connections: $count ($rate/sec)"
    log_info "  Errors: $errors"
}

test_vector_operations_stress() {
    log_info "Test 4: Vector Operations Stress Test"

    local test_results="$RESULTS_DIR/vector_stress_$TIMESTAMP.log"

    log_info "Generating test vectors and performing similarity searches..."

    python3 - <<EOF >> "$test_results" 2>&1
import psycopg2
import random
import time
import os
from concurrent.futures import ThreadPoolExecutor, as_completed

db_config = {
    'host': '$DB_HOST',
    'port': int('$DB_PORT'),
    'database': '$DB_NAME',
    'user': '$DB_USER',
    'password': '$DB_USER${RUVECTOR_PASSWORD:-dpg_cluster_2026}',
}

def get_connection():
    return psycopg2.connect(**db_config)

def insert_vector():
    try:
        conn = get_connection()
        cur = conn.cursor()
        vector = [random.random() for _ in range(384)]
        cur.execute("""
            INSERT INTO claude_flow.embeddings (text, embedding, metadata, namespace)
            VALUES (%s, %s::ruvector, %s::jsonb, %s)
            ON CONFLICT DO NOTHING
        """, (f"stress_{random.randint(1, 1000000)}", vector, '{"stress_test": true}', 'stress_test'))
        conn.commit()
        conn.close()
        return True
    except Exception as e:
        print(f"Insert error: {e}")
        return False

def search_vector():
    try:
        conn = get_connection()
        cur = conn.cursor()
        query = [random.random() for _ in range(384)]
        cur.execute("""
            SELECT text, embedding <=> %s::ruvector AS distance
            FROM claude_flow.embeddings
            WHERE namespace = 'stress_test'
            ORDER BY distance
            LIMIT 10
        """, (query,))
        results = cur.fetchall()
        conn.close()
        return len(results) > 0
    except Exception as e:
        print(f"Search error: {e}")
        return False

# Insert test vectors
print("Inserting 1000 test vectors...")
start = time.time()
insert_success = 0
with ThreadPoolExecutor(max_workers=20) as executor:
    futures = [executor.submit(insert_vector) for _ in range(1000)]
    for future in as_completed(futures):
        if future.result():
            insert_success += 1

insert_duration = time.time() - start
print(f"Inserted {insert_success}/1000 vectors in {insert_duration:.2f}s")

# Perform searches
print("Performing 500 similarity searches...")
start = time.time()
search_success = 0
with ThreadPoolExecutor(max_workers=20) as executor:
    futures = [executor.submit(search_vector) for _ in range(500)]
    for future in as_completed(futures):
        if future.result():
            search_success += 1

search_duration = time.time() - start
print(f"Completed {search_success}/500 searches in {search_duration:.2f}s")

# Cleanup
print("Cleaning up test data...")
conn = get_connection()
cur = conn.cursor()
cur.execute("DELETE FROM claude_flow.embeddings WHERE namespace = 'stress_test'")
conn.commit()
conn.close()

print(f"\nVector stress test complete")
print(f"Insert rate: {insert_success/insert_duration:.2f} ops/sec")
print(f"Search rate: {search_success/search_duration:.2f} ops/sec")
EOF

    log_info "✓ Vector operations stress test complete. Results: $test_results"
}

test_failover_scenario() {
    if [ "$FAILOVER_TEST" != "true" ]; then
        log_info "Test 5: Failover Scenario (SKIPPED - requires FAILOVER_TEST=true)"
        return
    fi

    log_info "Test 5: Failover Scenario"
    log_warn "This test requires Patroni HA setup"

    local test_results="$RESULTS_DIR/failover_$TIMESTAMP.log"

    # Check if Patroni is available
    if ! command -v patronictl >/dev/null 2>&1; then
        log_warn "Patroni not found - skipping failover test"
        return
    fi

    log_info "Triggering controlled failover..."

    # Get current primary
    local primary=$(patronictl list -f json | jq -r '.[] | select(.Role == "Leader") | .Member')

    if [ -z "$primary" ]; then
        log_error "Could not determine current primary"
        return
    fi

    log_info "Current primary: $primary"

    # Start background load
    log_info "Starting background load..."
    pgbench -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
            -c 20 -j 4 -T 120 -n \
            "$DB_NAME" > "$test_results" 2>&1 &
    local pgbench_pid=$!

    sleep 10

    # Trigger failover
    log_info "Triggering failover..."
    patronictl failover --master "$primary" --force >> "$test_results" 2>&1

    # Wait for failover to complete
    sleep 20

    # Check new primary
    local new_primary=$(patronictl list -f json | jq -r '.[] | select(.Role == "Leader") | .Member')
    log_info "New primary: $new_primary"

    # Wait for background load to complete
    wait $pgbench_pid

    log_info "✓ Failover test complete. Results: $test_results"
}

generate_summary_report() {
    log_info "Generating summary report..."

    local summary="$RESULTS_DIR/stress_test_summary_$TIMESTAMP.md"

    cat > "$summary" <<EOF
# Stress Test Summary

**Timestamp:** $(date -d "@$TIMESTAMP" 2>/dev/null || date)

**Configuration:**
- Database: $DB_NAME @ $DB_HOST:$DB_PORT
- Max Connections Tested: $MAX_CONNECTIONS
- Stress Duration: ${STRESS_DURATION}s
- Failover Test: $FAILOVER_TEST

## Database Statistics

**Before Tests:**
\`\`\`json
$(get_db_stats)
\`\`\`

## Test Results

### 1. Connection Exhaustion
See: \`connection_exhaustion_$TIMESTAMP.log\`

### 2. Sustained Load
See: \`sustained_load_$TIMESTAMP.log\`

### 3. Rapid Connection Churn
See: \`rapid_connections_$TIMESTAMP.log\`

### 4. Vector Operations Stress
See: \`vector_stress_$TIMESTAMP.log\`

### 5. Failover Scenario
See: \`failover_$TIMESTAMP.log\`

## Conclusions

EOF

    # Check for failures in logs
    local failures=0
    for log in "$RESULTS_DIR"/*_"$TIMESTAMP".log; do
        if [ -f "$log" ]; then
            if grep -q -i "error\|fail\|exception" "$log"; then
                ((failures++))
                echo "⚠️ Errors found in $(basename "$log")" >> "$summary"
            fi
        fi
    done

    if [ $failures -eq 0 ]; then
        echo "✅ All stress tests completed successfully" >> "$summary"
    else
        echo "⚠️ $failures test(s) reported errors - review logs for details" >> "$summary"
    fi

    echo "" >> "$summary"
    echo "**After Tests:**" >> "$summary"
    echo "\`\`\`json" >> "$summary"
    get_db_stats >> "$summary"
    echo "\`\`\`" >> "$summary"

    log_info "✓ Summary report: $summary"

    # Display summary
    cat "$summary"
}

main() {
    echo "======================================================================"
    echo "  Distributed PostgreSQL Cluster - Stress Test Suite"
    echo "======================================================================"
    echo ""

    check_dependencies
    check_database || exit 1

    log_info "Starting stress tests at $(date)"
    log_info "Results will be saved to: $RESULTS_DIR"
    echo ""

    # Run all tests
    test_connection_exhaustion
    echo ""

    test_sustained_load
    echo ""

    test_rapid_connections
    echo ""

    test_vector_operations_stress
    echo ""

    test_failover_scenario
    echo ""

    # Generate summary
    generate_summary_report

    echo ""
    echo "======================================================================"
    echo "  Stress Test Suite Complete"
    echo "======================================================================"
    log_info "All results saved to: $RESULTS_DIR"
}

# Run main function
main "$@"
