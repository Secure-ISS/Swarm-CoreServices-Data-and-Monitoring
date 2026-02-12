#!/bin/bash
# Patroni High Availability Validation Script
# Version: 1.0.0
# Description: Comprehensive validation of HA setup and failover capabilities

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Configuration
PATRONI_PRIMARY=${PATRONI_PRIMARY:-patroni-node-1}
CLUSTER_NAME=${CLUSTER_NAME:-postgres-ha-cluster}
LOG_FILE="${LOG_FILE:-/var/log/patroni/ha-validation.log}"
TEST_DATABASE=${TEST_DATABASE:-distributed_postgres_cluster}

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "${BLUE}$*${NC}"; }
log_success() { log "SUCCESS" "${GREEN}$*${NC}"; }
log_warning() { log "WARNING" "${YELLOW}$*${NC}"; }
log_error() { log "ERROR" "${RED}$*${NC}"; }
log_test() { log "TEST" "${MAGENTA}$*${NC}"; }

# Test framework
run_test() {
    local test_name="$1"
    local test_function="$2"

    ((TESTS_TOTAL++))
    log_test "Running test: $test_name"

    if $test_function; then
        ((TESTS_PASSED++))
        log_success "PASSED: $test_name"
        return 0
    else
        ((TESTS_FAILED++))
        log_error "FAILED: $test_name"
        return 1
    fi
}

# Test 1: Cluster status check
test_cluster_status() {
    log_info "Checking cluster status..."

    local output=$(docker exec "$PATRONI_PRIMARY" patronictl -c /etc/patroni/patroni.yml list 2>&1)

    if echo "$output" | grep -q "Leader"; then
        log_info "Leader found in cluster"
        echo "$output" | tee -a "$LOG_FILE"
        return 0
    else
        log_error "No leader found in cluster"
        return 1
    fi
}

# Test 2: Verify leader election
test_leader_election() {
    log_info "Verifying leader election..."

    local leader=$(docker exec "$PATRONI_PRIMARY" patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')

    if [ -n "$leader" ]; then
        log_info "Current leader: $leader"

        # Verify leader can accept writes
        if docker exec "$leader" psql -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
            log_success "Leader is accepting connections"
            return 0
        else
            log_error "Leader is not accepting connections"
            return 1
        fi
    else
        log_error "No leader elected"
        return 1
    fi
}

# Test 3: Verify replication
test_replication() {
    log_info "Verifying replication..."

    local leader=$(docker exec "$PATRONI_PRIMARY" patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')
    local replica_count=$(docker exec "$leader" psql -U postgres -t -c "SELECT count(*) FROM pg_stat_replication;" | xargs)

    log_info "Number of replicas: $replica_count"

    if [ "$replica_count" -gt 0 ]; then
        # Check replication lag
        docker exec "$leader" psql -U postgres -c "
            SELECT
                application_name,
                state,
                sync_state,
                replay_lag
            FROM pg_stat_replication;
        " | tee -a "$LOG_FILE"
        return 0
    else
        log_error "No replicas found"
        return 1
    fi
}

# Test 4: Verify synchronous replication
test_synchronous_replication() {
    log_info "Verifying synchronous replication..."

    local leader=$(docker exec "$PATRONI_PRIMARY" patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')
    local sync_count=$(docker exec "$leader" psql -U postgres -t -c "SELECT count(*) FROM pg_stat_replication WHERE sync_state IN ('sync', 'potential');" | xargs)

    if [ "$sync_count" -gt 0 ]; then
        log_info "Synchronous replicas: $sync_count"
        return 0
    else
        log_error "No synchronous replicas found"
        return 1
    fi
}

# Test 5: Test data consistency
test_data_consistency() {
    log_info "Testing data consistency across nodes..."

    local leader=$(docker exec "$PATRONI_PRIMARY" patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')
    local test_value=$(date +%s)

    # Insert test data on leader
    docker exec "$leader" psql -U postgres -d "$TEST_DATABASE" -c "
        CREATE TABLE IF NOT EXISTS ha_test (id SERIAL PRIMARY KEY, value TEXT, created_at TIMESTAMP);
        INSERT INTO ha_test (value, created_at) VALUES ('test-$test_value', now());
    " > /dev/null 2>&1

    # Wait for replication
    sleep 2

    # Check on replicas
    local replicas=$(docker exec "$PATRONI_PRIMARY" patronictl -c /etc/patroni/patroni.yml list | grep Replica | awk '{print $2}')

    for replica in $replicas; do
        local replica_value=$(docker exec "$replica" psql -U postgres -d "$TEST_DATABASE" -t -c "SELECT value FROM ha_test WHERE value = 'test-$test_value';" | xargs)

        if [ "$replica_value" = "test-$test_value" ]; then
            log_info "Data replicated to $replica"
        else
            log_error "Data not replicated to $replica"
            return 1
        fi
    done

    # Cleanup
    docker exec "$leader" psql -U postgres -d "$TEST_DATABASE" -c "DELETE FROM ha_test WHERE value = 'test-$test_value';" > /dev/null 2>&1

    return 0
}

# Test 6: Verify replication lag
test_replication_lag() {
    log_info "Checking replication lag..."

    local leader=$(docker exec "$PATRONI_PRIMARY" patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')

    local max_lag=$(docker exec "$leader" psql -U postgres -t -c "
        SELECT COALESCE(MAX(EXTRACT(EPOCH FROM replay_lag)), 0)
        FROM pg_stat_replication;
    " | xargs)

    log_info "Maximum replication lag: ${max_lag}s"

    # Acceptable lag: 5 seconds
    if (( $(echo "$max_lag < 5" | bc -l) )); then
        log_success "Replication lag is acceptable"
        return 0
    else
        log_warning "Replication lag is high: ${max_lag}s"
        return 1
    fi
}

# Test 7: Verify automatic failover capability
test_failover_capability() {
    log_info "Verifying automatic failover capability..."

    # Check DCS configuration
    local dcs_check=$(docker exec "$PATRONI_PRIMARY" etcdctl get /db/$CLUSTER_NAME/config 2>&1)

    if echo "$dcs_check" | grep -q "ttl"; then
        log_info "DCS configuration found"

        # Check failover settings
        local ttl=$(echo "$dcs_check" | grep -oP 'ttl":\K\d+' || echo "0")
        local loop_wait=$(echo "$dcs_check" | grep -oP 'loop_wait":\K\d+' || echo "0")

        log_info "TTL: ${ttl}s, Loop Wait: ${loop_wait}s"

        if [ "$ttl" -gt 0 ] && [ "$loop_wait" -gt 0 ]; then
            return 0
        fi
    fi

    log_error "Failover configuration not found or invalid"
    return 1
}

# Test 8: Simulate failover (optional - requires user confirmation)
test_simulate_failover() {
    log_warning "Failover simulation requires manual confirmation"
    log_info "To manually test failover, run:"
    log_info "  docker exec $PATRONI_PRIMARY patronictl -c /etc/patroni/patroni.yml failover"
    return 0
}

# Test 9: Verify watchdog configuration
test_watchdog() {
    log_info "Verifying watchdog configuration..."

    local leader=$(docker exec "$PATRONI_PRIMARY" patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')

    if docker exec "$leader" test -e /dev/watchdog; then
        log_success "Watchdog device exists"
        return 0
    else
        log_warning "Watchdog device not found (optional)"
        return 0
    fi
}

# Test 10: Verify REST API
test_rest_api() {
    log_info "Verifying Patroni REST API..."

    local leader=$(docker exec "$PATRONI_PRIMARY" patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')

    if docker exec "$leader" curl -s http://localhost:8008/health | grep -q "running"; then
        log_success "REST API is responding"
        return 0
    else
        log_error "REST API is not responding"
        return 1
    fi
}

# Test 11: Verify RuVector extension
test_ruvector_extension() {
    log_info "Verifying RuVector extension..."

    local leader=$(docker exec "$PATRONI_PRIMARY" patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')

    if docker exec "$leader" psql -U postgres -d "$TEST_DATABASE" -c "SELECT * FROM pg_extension WHERE extname = 'ruvector';" | grep -q "ruvector"; then
        log_success "RuVector extension is installed"
        return 0
    else
        log_error "RuVector extension not found"
        return 1
    fi
}

# Print test summary
print_summary() {
    echo ""
    log_info "========================================"
    log_info "HA Validation Test Summary"
    log_info "========================================"
    log_info "Total Tests: $TESTS_TOTAL"
    log_success "Passed: $TESTS_PASSED"
    log_error "Failed: $TESTS_FAILED"
    log_info "========================================"

    local pass_rate=$(echo "scale=2; $TESTS_PASSED * 100 / $TESTS_TOTAL" | bc)
    log_info "Pass Rate: ${pass_rate}%"

    if [ "$TESTS_FAILED" -eq 0 ]; then
        log_success "All tests passed! HA cluster is healthy."
        return 0
    else
        log_error "Some tests failed. Review the log for details."
        return 1
    fi
}

# Main execution
main() {
    log_info "Starting HA validation tests..."
    log_info "Cluster: $CLUSTER_NAME"
    log_info "Primary node: $PATRONI_PRIMARY"
    log_info "Test database: $TEST_DATABASE"
    echo ""

    run_test "Cluster Status Check" test_cluster_status
    run_test "Leader Election Verification" test_leader_election
    run_test "Replication Verification" test_replication
    run_test "Synchronous Replication" test_synchronous_replication
    run_test "Data Consistency" test_data_consistency
    run_test "Replication Lag Check" test_replication_lag
    run_test "Failover Capability" test_failover_capability
    run_test "Watchdog Configuration" test_watchdog
    run_test "REST API Health" test_rest_api
    run_test "RuVector Extension" test_ruvector_extension

    print_summary
}

main "$@"
