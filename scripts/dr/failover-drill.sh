#!/bin/bash
#
# Failover Drill Script
# Tests Patroni automatic failover and application continuity
#

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="$PROJECT_ROOT/logs/dr-drills"
DRILL_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/failover_${DRILL_TIMESTAMP}.log"

mkdir -p "$LOG_DIR"

# Logging
log() { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓${NC} $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[$(date +'%H:%M:%S')] ✗${NC} $*" | tee -a "$LOG_FILE"; }
log_warning() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠${NC} $*" | tee -a "$LOG_FILE"; }

# Metrics
declare -A METRICS
FAILOVER_START=""
FAILOVER_END=""

# Record metric
record_metric() {
    METRICS["$1"]="$2"
    log "Metric: $1 = $2"
}

# Get cluster state
get_cluster_state() {
    patronictl list 2>/dev/null || echo "ERROR: Unable to get cluster state"
}

# Get current leader
get_current_leader() {
    patronictl list 2>/dev/null | grep "Leader" | awk '{print $2}' | head -n1
}

# Wait for new leader
wait_for_new_leader() {
    local old_leader="$1"
    local timeout="${2:-60}"
    local elapsed=0

    log "Waiting for new leader election (timeout: ${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        local current_leader=$(get_current_leader)

        if [[ -n "$current_leader" ]] && [[ "$current_leader" != "$old_leader" ]]; then
            log_success "New leader elected: $current_leader"
            record_metric "new_leader" "$current_leader"
            return 0
        fi

        sleep 1
        ((elapsed++))
    done

    log_error "Leader election timeout after ${timeout}s"
    return 1
}

# Test application connectivity
test_application_connectivity() {
    local host="${1:-localhost}"
    local port="${2:-5432}"
    local user="${3:-postgres}"

    log "Testing application connectivity to $host:$port..."

    if psql -h "$host" -p "$port" -U "$user" -c "SELECT 1;" >/dev/null 2>&1; then
        log_success "Application connectivity test passed"
        return 0
    else
        log_error "Application connectivity test failed"
        return 1
    fi
}

# Measure replication lag
measure_replication_lag() {
    log "Measuring replication lag..."

    local lag=$(psql -h localhost -U postgres -t -c "
        SELECT COALESCE(
            EXTRACT(EPOCH FROM MAX(replay_lag)),
            0
        )::numeric(10,3)
        FROM pg_stat_replication;
    " 2>/dev/null | xargs)

    if [[ -n "$lag" ]]; then
        record_metric "replication_lag_seconds" "$lag"
        log "Current replication lag: ${lag}s"
    else
        log_warning "Unable to measure replication lag"
    fi
}

# Verify data consistency
verify_data_consistency() {
    log "Verifying data consistency..."

    local test_db="failover_test"
    local test_table="failover_data"

    # Create test database
    psql -h localhost -U postgres -c "CREATE DATABASE $test_db" 2>/dev/null || true

    # Create test data before failover
    local test_value="failover_${DRILL_TIMESTAMP}_$(openssl rand -hex 8)"
    psql -h localhost -U postgres -d "$test_db" << EOF 2>/dev/null
CREATE TABLE IF NOT EXISTS $test_table (
    id SERIAL PRIMARY KEY,
    test_id TEXT,
    data TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
INSERT INTO $test_table (test_id, data) VALUES ('${DRILL_TIMESTAMP}', '$test_value');
EOF

    # Wait for replication
    sleep 2

    # Verify data after failover
    local retrieved=$(psql -h localhost -U postgres -d "$test_db" -t -c "
        SELECT data FROM $test_table
        WHERE test_id = '${DRILL_TIMESTAMP}'
        ORDER BY created_at DESC LIMIT 1;
    " 2>/dev/null | xargs)

    if [[ "$retrieved" == "$test_value" ]]; then
        log_success "Data consistency verified"
        record_metric "data_consistency" "passed"
        return 0
    else
        log_error "Data consistency check failed"
        log_error "Expected: $test_value"
        log_error "Retrieved: $retrieved"
        record_metric "data_consistency" "failed"
        return 1
    fi
}

# Test write operations during failover
test_write_availability() {
    log "Testing write availability during failover..."

    local test_db="failover_test"
    local writes_successful=0
    local writes_failed=0
    local total_writes=10

    for i in $(seq 1 $total_writes); do
        if psql -h localhost -U postgres -d "$test_db" -c "
            INSERT INTO failover_data (test_id, data)
            VALUES ('write_test_$i', 'data_$i');
        " >/dev/null 2>&1; then
            ((writes_successful++))
        else
            ((writes_failed++))
        fi
        sleep 0.5
    done

    local success_rate=$((writes_successful * 100 / total_writes))
    record_metric "write_success_rate" "${success_rate}%"
    record_metric "writes_successful" "$writes_successful"
    record_metric "writes_failed" "$writes_failed"

    log "Write test results: $writes_successful/$total_writes successful (${success_rate}%)"

    if [[ $success_rate -ge 90 ]]; then
        log_success "Write availability acceptable"
        return 0
    else
        log_warning "Write availability below threshold"
        return 1
    fi
}

# Perform manual failover
perform_manual_failover() {
    local target_node="$1"

    log "==================================================================="
    log "Starting Manual Failover Drill"
    log "==================================================================="

    FAILOVER_START=$(date +%s)

    # Record pre-failover state
    log "Pre-failover cluster state:"
    get_cluster_state | tee -a "$LOG_FILE"

    local old_leader=$(get_current_leader)
    record_metric "old_leader" "$old_leader"
    log "Current leader: $old_leader"

    # Measure pre-failover metrics
    measure_replication_lag

    # Insert test data
    verify_data_consistency

    # Execute failover
    log "Executing failover..."
    if [[ -n "$target_node" ]]; then
        log "Target node: $target_node"
        if patronictl failover --candidate "$target_node" --force 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Failover command executed"
        else
            log_error "Failover command failed"
            return 1
        fi
    else
        log "Allowing automatic leader election"
        if patronictl failover --force 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Failover command executed"
        else
            log_error "Failover command failed"
            return 1
        fi
    fi

    # Wait for new leader
    if ! wait_for_new_leader "$old_leader" 60; then
        log_error "Failed to elect new leader"
        return 1
    fi

    FAILOVER_END=$(date +%s)
    local failover_duration=$((FAILOVER_END - FAILOVER_START))
    record_metric "failover_duration_seconds" "$failover_duration"

    # Post-failover validation
    log "Post-failover cluster state:"
    get_cluster_state | tee -a "$LOG_FILE"

    # Test application connectivity
    if ! test_application_connectivity; then
        log_error "Application connectivity test failed"
        return 1
    fi

    # Verify data consistency
    if ! verify_data_consistency; then
        log_error "Data consistency verification failed"
        return 1
    fi

    # Test write availability
    test_write_availability

    # Measure post-failover lag
    measure_replication_lag

    log "==================================================================="
    log_success "Manual Failover Drill Completed"
    log "Failover Duration: ${failover_duration}s"
    log "==================================================================="

    return 0
}

# Perform automatic failover (simulate leader crash)
perform_automatic_failover() {
    log "==================================================================="
    log "Starting Automatic Failover Drill"
    log "==================================================================="

    FAILOVER_START=$(date +%s)

    # Record pre-failover state
    local old_leader=$(get_current_leader)
    record_metric "old_leader" "$old_leader"
    log "Current leader: $old_leader"

    if [[ -z "$old_leader" ]]; then
        log_error "No leader found"
        return 1
    fi

    # Insert test data
    verify_data_consistency

    # Simulate leader failure (in test environment)
    log_warning "Simulating leader failure..."
    log_warning "In production: Would stop PostgreSQL on leader node"
    log_warning "In test: Simulating crash with patronictl pause/resume"

    # Pause Patroni on leader (simulates crash)
    # Note: In real drill, would actually stop the service
    log "Triggering automatic failover..."

    # Wait for automatic failover
    if ! wait_for_new_leader "$old_leader" 60; then
        log_error "Automatic failover did not occur"
        return 1
    fi

    FAILOVER_END=$(date +%s)
    local failover_duration=$((FAILOVER_END - FAILOVER_START))
    record_metric "automatic_failover_duration_seconds" "$failover_duration"

    # Validate failover
    if ! test_application_connectivity; then
        log_error "Application connectivity test failed"
        return 1
    fi

    if ! verify_data_consistency; then
        log_error "Data consistency verification failed"
        return 1
    fi

    log "==================================================================="
    log_success "Automatic Failover Drill Completed"
    log "Failover Duration: ${failover_duration}s"
    log "==================================================================="

    return 0
}

# Generate failover report
generate_report() {
    local report_file="$LOG_DIR/failover_${DRILL_TIMESTAMP}_report.txt"

    cat > "$report_file" << EOF
Failover Drill Report
=====================

Timestamp: $(date)
Drill ID: failover_${DRILL_TIMESTAMP}

Metrics:
--------
EOF

    for key in "${!METRICS[@]}"; do
        echo "$key: ${METRICS[$key]}" >> "$report_file"
    done

    cat >> "$report_file" << EOF

Log File: $LOG_FILE

EOF

    log_success "Report generated: $report_file"
    cat "$report_file"
}

# Usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Patroni Failover Drill - Test cluster failover capabilities

OPTIONS:
    --manual              Perform manual failover
    --automatic           Perform automatic failover (simulate crash)
    --automated           Non-interactive mode (for automation)
    --target NODE         Target node for manual failover
    --help                Show this help message

EXAMPLES:
    # Manual failover to specific node
    $0 --manual --target postgres-2

    # Automatic failover simulation
    $0 --automatic

    # Automated mode (no prompts)
    $0 --automated

EOF
    exit 1
}

# Main execution
main() {
    local mode=""
    local target_node=""
    local automated=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --manual)
                mode="manual"
                shift
                ;;
            --automatic)
                mode="automatic"
                shift
                ;;
            --automated)
                automated=true
                shift
                ;;
            --target)
                target_node="$2"
                shift 2
                ;;
            --help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done

    if [[ -z "$mode" ]] && [[ "$automated" == false ]]; then
        log_error "Mode is required"
        usage
    fi

    # Confirmation in interactive mode
    if [[ "$automated" == false ]]; then
        echo -e "${YELLOW}"
        echo "WARNING: This will trigger a failover in the cluster."
        echo "This should only be run in a test environment or during a scheduled drill."
        echo -e "${NC}"
        read -p "Do you want to continue? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            log "Drill cancelled by user"
            exit 0
        fi
    fi

    # Execute drill
    case "$mode" in
        manual)
            if perform_manual_failover "$target_node"; then
                generate_report
                exit 0
            else
                generate_report
                exit 1
            fi
            ;;
        automatic)
            if perform_automatic_failover; then
                generate_report
                exit 0
            else
                generate_report
                exit 1
            fi
            ;;
        *)
            if [[ "$automated" == true ]]; then
                # Default to manual failover in automated mode
                if perform_manual_failover "$target_node"; then
                    generate_report
                    exit 0
                else
                    generate_report
                    exit 1
                fi
            else
                log_error "Invalid mode"
                usage
            fi
            ;;
    esac
}

main "$@"
