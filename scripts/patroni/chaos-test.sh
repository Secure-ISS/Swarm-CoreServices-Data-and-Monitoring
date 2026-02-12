#!/bin/bash
# Chaos Testing Script for Patroni HA
# Simulates various failure scenarios to test HA resilience

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
PATRONI_NODES=("patroni-node-1" "patroni-node-2" "patroni-node-3")
ETCD_NODES=("etcd-node-1" "etcd-node-2" "etcd-node-3")
TEST_DURATION=300  # 5 minutes
LOG_DIR="./logs/chaos-tests"

# Create log directory
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/chaos_test_$TIMESTAMP.log"

# Logging function
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${GREEN}$*${NC}" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}$*${NC}" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}$*${NC}" | tee -a "$LOG_FILE"
}

# Check if container is running
is_container_running() {
    local container=$1
    docker ps --format '{{.Names}}' | grep -q "^${container}$"
}

# Get primary Patroni node
get_primary_node() {
    for node in "${PATRONI_NODES[@]}"; do
        if is_container_running "$node"; then
            local is_leader=$(docker exec "$node" patronictl list -f json 2>/dev/null | \
                             jq -r ".[] | select(.Member == \"$node\") | .Role" 2>/dev/null)
            if [ "$is_leader" = "Leader" ]; then
                echo "$node"
                return 0
            fi
        fi
    done
    return 1
}

# Get random standby node
get_random_standby() {
    local primary=$(get_primary_node)
    local standbys=()

    for node in "${PATRONI_NODES[@]}"; do
        if [ "$node" != "$primary" ] && is_container_running "$node"; then
            standbys+=("$node")
        fi
    done

    if [ ${#standbys[@]} -eq 0 ]; then
        return 1
    fi

    echo "${standbys[$RANDOM % ${#standbys[@]}]}"
}

# Stop container
stop_container() {
    local container=$1
    log_info "Stopping container: $container"
    docker stop "$container" >/dev/null 2>&1
}

# Start container
start_container() {
    local container=$1
    log_info "Starting container: $container"
    docker start "$container" >/dev/null 2>&1
}

# Pause container
pause_container() {
    local container=$1
    log_info "Pausing container: $container"
    docker pause "$container" >/dev/null 2>&1
}

# Unpause container
unpause_container() {
    local container=$1
    log_info "Unpausing container: $container"
    docker unpause "$container" >/dev/null 2>&1
}

# Add network delay
add_network_delay() {
    local container=$1
    local delay_ms=${2:-100}
    log_info "Adding ${delay_ms}ms network delay to $container"
    docker exec "$container" tc qdisc add dev eth0 root netem delay "${delay_ms}ms" 2>/dev/null || true
}

# Remove network delay
remove_network_delay() {
    local container=$1
    log_info "Removing network delay from $container"
    docker exec "$container" tc qdisc del dev eth0 root 2>/dev/null || true
}

# Simulate network partition
simulate_network_partition() {
    local container=$1
    log_warn "Simulating network partition for $container"
    docker exec "$container" iptables -A INPUT -j DROP 2>/dev/null || true
    docker exec "$container" iptables -A OUTPUT -j DROP 2>/dev/null || true
}

# Restore network
restore_network() {
    local container=$1
    log_info "Restoring network for $container"
    docker exec "$container" iptables -F 2>/dev/null || true
}

# Simulate disk pressure
simulate_disk_pressure() {
    local container=$1
    log_warn "Simulating disk pressure on $container"
    docker exec "$container" bash -c "dd if=/dev/zero of=/tmp/disk_pressure bs=1M count=100 2>/dev/null" &
}

# Check cluster health
check_cluster_health() {
    log_info "Checking cluster health..."

    # Check Patroni cluster
    local primary=$(get_primary_node)
    if [ -z "$primary" ]; then
        log_error "No primary node found!"
        return 1
    fi
    log_info "Primary node: $primary"

    # Count running standbys
    local standby_count=0
    for node in "${PATRONI_NODES[@]}"; do
        if [ "$node" != "$primary" ] && is_container_running "$node"; then
            ((standby_count++))
        fi
    done
    log_info "Running standbys: $standby_count"

    # Check etcd cluster
    local etcd_healthy=0
    for node in "${ETCD_NODES[@]}"; do
        if is_container_running "$node"; then
            ((etcd_healthy++))
        fi
    done
    log_info "Healthy etcd nodes: $etcd_healthy"

    return 0
}

# Test scenario: Random node failure
test_random_node_failure() {
    log_info "=== Test: Random Node Failure ==="

    local node="${PATRONI_NODES[$RANDOM % ${#PATRONI_NODES[@]}]}"
    log_warn "Stopping random node: $node"
    stop_container "$node"

    sleep 10
    check_cluster_health

    log_info "Restarting node: $node"
    start_container "$node"
    sleep 15
    check_cluster_health
}

# Test scenario: Primary node failure
test_primary_failure() {
    log_info "=== Test: Primary Node Failure ==="

    local primary=$(get_primary_node)
    if [ -z "$primary" ]; then
        log_error "No primary node found"
        return 1
    fi

    log_warn "Stopping primary node: $primary"
    local start_time=$(date +%s)
    stop_container "$primary"

    sleep 5
    local new_primary=$(get_primary_node)
    local end_time=$(date +%s)
    local failover_time=$((end_time - start_time))

    if [ -n "$new_primary" ] && [ "$new_primary" != "$primary" ]; then
        log_info "Failover completed in ${failover_time}s. New primary: $new_primary"
    else
        log_error "Failover failed or incomplete"
    fi

    sleep 10
    log_info "Restarting original primary: $primary"
    start_container "$primary"
    sleep 15
    check_cluster_health
}

# Test scenario: Network partition
test_network_partition() {
    log_info "=== Test: Network Partition ==="

    local node=$(get_random_standby)
    if [ -z "$node" ]; then
        log_error "No standby node available"
        return 1
    fi

    log_warn "Creating network partition for: $node"
    simulate_network_partition "$node"

    sleep 15
    check_cluster_health

    log_info "Restoring network for: $node"
    restore_network "$node"
    sleep 15
    check_cluster_health
}

# Test scenario: Network delay
test_network_delay() {
    log_info "=== Test: Network Delay ==="

    for node in "${PATRONI_NODES[@]}"; do
        if is_container_running "$node"; then
            add_network_delay "$node" 150
        fi
    done

    sleep 20
    check_cluster_health

    for node in "${PATRONI_NODES[@]}"; do
        if is_container_running "$node"; then
            remove_network_delay "$node"
        fi
    done

    sleep 10
    check_cluster_health
}

# Test scenario: Cascading failures
test_cascading_failures() {
    log_info "=== Test: Cascading Failures ==="

    local failures=2
    local stopped_nodes=()

    for ((i=0; i<failures; i++)); do
        local node="${PATRONI_NODES[i]}"
        log_warn "Stopping node $((i+1))/$failures: $node"
        stop_container "$node"
        stopped_nodes+=("$node")
        sleep 5
        check_cluster_health
    done

    sleep 10

    for node in "${stopped_nodes[@]}"; do
        log_info "Restarting node: $node"
        start_container "$node"
        sleep 10
    done

    sleep 15
    check_cluster_health
}

# Test scenario: etcd failure
test_etcd_failure() {
    log_info "=== Test: etcd Node Failure ==="

    local etcd_node="${ETCD_NODES[$RANDOM % ${#ETCD_NODES[@]}]}"
    log_warn "Stopping etcd node: $etcd_node"
    stop_container "$etcd_node"

    sleep 10
    check_cluster_health

    log_info "Restarting etcd node: $etcd_node"
    start_container "$etcd_node"
    sleep 15
    check_cluster_health
}

# Test scenario: Sustained load
test_sustained_load() {
    log_info "=== Test: Sustained Load ==="

    local primary=$(get_primary_node)
    if [ -z "$primary" ]; then
        log_error "No primary node found"
        return 1
    fi

    log_info "Starting load generation on $primary"

    # Run load in background
    (
        for ((i=0; i<100; i++)); do
            docker exec "$primary" psql -U postgres -c \
                "INSERT INTO ha_test_transactions (transaction_id, data) VALUES ('load_$i', 'data_$i')" \
                2>/dev/null || true
            sleep 0.1
        done
    ) &

    local load_pid=$!
    sleep 5

    # Trigger failure during load
    log_warn "Triggering failure during load"
    test_primary_failure

    # Wait for load to complete
    wait $load_pid 2>/dev/null || true

    check_cluster_health
}

# Main chaos test loop
run_chaos_tests() {
    log_info "========================================"
    log_info "Starting Chaos Testing Suite"
    log_info "Duration: $TEST_DURATION seconds"
    log_info "========================================"

    local start_time=$(date +%s)
    local test_count=0

    # Initial health check
    check_cluster_health

    while [ $(($(date +%s) - start_time)) -lt $TEST_DURATION ]; do
        ((test_count++))
        log_info "Chaos test iteration: $test_count"

        # Randomly select test scenario
        local test_type=$((RANDOM % 7))

        case $test_type in
            0) test_random_node_failure ;;
            1) test_primary_failure ;;
            2) test_network_partition ;;
            3) test_network_delay ;;
            4) test_cascading_failures ;;
            5) test_etcd_failure ;;
            6) test_sustained_load ;;
        esac

        # Wait between tests
        local wait_time=$((RANDOM % 20 + 10))
        log_info "Waiting ${wait_time}s before next test"
        sleep $wait_time
    done

    log_info "========================================"
    log_info "Chaos Testing Complete"
    log_info "Total iterations: $test_count"
    log_info "Log file: $LOG_FILE"
    log_info "========================================"
}

# Cleanup function
cleanup() {
    log_info "Cleaning up chaos test environment..."

    # Restore all networks
    for node in "${PATRONI_NODES[@]}"; do
        if is_container_running "$node"; then
            restore_network "$node" 2>/dev/null || true
            remove_network_delay "$node" 2>/dev/null || true
        fi
    done

    # Start all stopped containers
    for node in "${PATRONI_NODES[@]}" "${ETCD_NODES[@]}"; do
        if ! is_container_running "$node"; then
            start_container "$node"
        fi
    done

    sleep 10
    check_cluster_health

    log_info "Cleanup complete"
}

# Trap cleanup on exit
trap cleanup EXIT INT TERM

# Parse command line arguments
case "${1:-run}" in
    run)
        run_chaos_tests
        ;;
    primary-failure)
        check_cluster_health
        test_primary_failure
        ;;
    network-partition)
        check_cluster_health
        test_network_partition
        ;;
    cascading)
        check_cluster_health
        test_cascading_failures
        ;;
    sustained-load)
        check_cluster_health
        test_sustained_load
        ;;
    health)
        check_cluster_health
        ;;
    *)
        echo "Usage: $0 {run|primary-failure|network-partition|cascading|sustained-load|health}"
        exit 1
        ;;
esac
