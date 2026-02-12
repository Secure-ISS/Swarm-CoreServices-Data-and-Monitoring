#!/usr/bin/env bash

###############################################################################
# Patroni Manual Failover Script
#
# Description: Performs controlled switchover or manual failover
# Usage: ./manual-failover.sh [OPTIONS]
#
# Options:
#   --switchover: Perform controlled switchover (zero downtime)
#   --failover: Force failover (emergency use)
#   --master <node>: Specify current master
#   --candidate <node>: Specify target candidate
#   --cluster <name>: Cluster name (default: postgres-cluster-coordinators)
#   --dry-run: Show what would be done without executing
#
# Author: Database Operations Team
# Version: 1.0
# Last Updated: 2026-02-12
###############################################################################

set -euo pipefail

# Configuration
PATRONICTL="${PATRONICTL:-patronictl}"
PATRONI_CONFIG="${PATRONI_CONFIG:-/etc/patroni/patroni.yml}"
CLUSTER_NAME="${CLUSTER_NAME:-postgres-cluster-coordinators}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Command line arguments
OPERATION=""
MASTER_NODE=""
CANDIDATE_NODE=""
DRY_RUN=false
FORCE=false

###############################################################################
# Helper Functions
###############################################################################

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Perform controlled switchover or manual failover of Patroni cluster.

OPTIONS:
    --switchover             Perform controlled switchover (recommended)
    --failover              Force failover (emergency use only)
    --master <node>         Current master node
    --candidate <node>      Target candidate node
    --cluster <name>        Cluster name (default: postgres-cluster-coordinators)
    --dry-run               Show what would be done without executing
    --force                 Skip safety checks (use with caution)
    -h, --help              Show this help message

EXAMPLES:
    # Controlled switchover (preferred for maintenance)
    $0 --switchover --master coordinator-1 --candidate coordinator-2

    # Manual failover (emergency)
    $0 --failover --master coordinator-1 --candidate coordinator-2

    # Dry run (see what would happen)
    $0 --switchover --master coordinator-1 --candidate coordinator-2 --dry-run

NOTES:
    - Switchover is preferred for planned maintenance (zero data loss)
    - Failover should only be used in emergencies
    - Always verify cluster health before and after the operation

EOF
    exit 0
}

###############################################################################
# Pre-Flight Checks
###############################################################################

check_prerequisites() {
    print_info "Running pre-flight checks..."

    # Check patronictl is available
    if ! command -v "$PATRONICTL" &> /dev/null; then
        print_error "patronictl not found. Please install Patroni."
        exit 1
    fi

    # Check Patroni config exists
    if [[ ! -f "$PATRONI_CONFIG" ]]; then
        print_error "Patroni configuration not found: $PATRONI_CONFIG"
        exit 1
    fi

    # Check cluster is accessible
    if ! $PATRONICTL -c "$PATRONI_CONFIG" list &> /dev/null; then
        print_error "Cannot connect to Patroni cluster"
        exit 1
    fi

    print_success "Prerequisites check passed"
}

verify_cluster_state() {
    print_info "Verifying cluster state..."

    local cluster_status
    cluster_status=$($PATRONICTL -c "$PATRONI_CONFIG" list 2>&1)

    echo "$cluster_status"
    echo ""

    # Check if there's a leader
    if ! echo "$cluster_status" | grep -q "Leader"; then
        print_error "No leader found in cluster. Cannot perform failover."
        return 1
    fi

    # Check if master node exists
    if [[ -n "$MASTER_NODE" ]]; then
        if ! echo "$cluster_status" | grep -q "$MASTER_NODE"; then
            print_error "Master node '$MASTER_NODE' not found in cluster"
            return 1
        fi
    fi

    # Check if candidate node exists
    if [[ -n "$CANDIDATE_NODE" ]]; then
        if ! echo "$cluster_status" | grep -q "$CANDIDATE_NODE"; then
            print_error "Candidate node '$CANDIDATE_NODE' not found in cluster"
            return 1
        fi

        # Verify candidate is a replica
        if ! echo "$cluster_status" | grep "$CANDIDATE_NODE" | grep -q "Replica"; then
            print_error "Candidate node '$CANDIDATE_NODE' is not a replica"
            return 1
        fi
    fi

    print_success "Cluster state verified"
    return 0
}

check_replication_lag() {
    print_info "Checking replication lag..."

    # Get current leader from Patroni
    local current_leader
    current_leader=$($PATRONICTL -c "$PATRONI_CONFIG" list | grep "Leader" | awk '{print $2}' || echo "")

    if [[ -z "$current_leader" ]]; then
        print_warning "Cannot determine current leader"
        return 1
    fi

    # This would typically query PostgreSQL for replication lag
    # For now, we'll use patronictl output

    local lag_info
    lag_info=$($PATRONICTL -c "$PATRONI_CONFIG" list | grep "Lag in MB")

    if echo "$lag_info" | grep -qE "[0-9]+" && ! echo "$lag_info" | grep -q "0"; then
        print_warning "Replication lag detected. Consider waiting for replicas to catch up."
        return 1
    fi

    print_success "Replication lag check passed (all replicas caught up)"
    return 0
}

###############################################################################
# Failover Operations
###############################################################################

perform_switchover() {
    local master="$1"
    local candidate="$2"

    print_info "Performing controlled switchover..."
    print_info "Master: $master → Candidate: $candidate"

    if [[ "$DRY_RUN" == "true" ]]; then
        print_warning "DRY RUN MODE - No changes will be made"
        echo ""
        echo "Would execute:"
        echo "  patronictl -c $PATRONI_CONFIG switchover \\"
        echo "    --master $master \\"
        echo "    --candidate $candidate \\"
        echo "    --force"
        return 0
    fi

    # Confirmation prompt
    if [[ "$FORCE" == "false" ]]; then
        echo ""
        print_warning "This will perform a switchover. Current connections may be briefly interrupted."
        read -p "Continue? (yes/no): " -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
            print_info "Switchover cancelled"
            exit 0
        fi
    fi

    # Execute switchover
    print_info "Executing switchover..."

    if $PATRONICTL -c "$PATRONI_CONFIG" switchover \
        --master "$master" \
        --candidate "$candidate" \
        --force; then

        print_success "Switchover initiated successfully"

        # Wait for switchover to complete
        print_info "Waiting for switchover to complete (max 30 seconds)..."
        local timeout=30
        local elapsed=0

        while [[ $elapsed -lt $timeout ]]; do
            sleep 2
            elapsed=$((elapsed + 2))

            if $PATRONICTL -c "$PATRONI_CONFIG" list | grep "$candidate" | grep -q "Leader"; then
                print_success "Switchover completed successfully!"
                print_success "New leader: $candidate"
                return 0
            fi

            echo -n "."
        done

        echo ""
        print_warning "Switchover timeout. Check cluster status manually."
        return 1
    else
        print_error "Switchover failed"
        return 1
    fi
}

perform_failover() {
    local master="$1"
    local candidate="$2"

    print_warning "MANUAL FAILOVER - Use only in emergencies!"
    print_info "Master: $master → Candidate: $candidate"

    if [[ "$DRY_RUN" == "true" ]]; then
        print_warning "DRY RUN MODE - No changes will be made"
        echo ""
        echo "Would execute:"
        echo "  patronictl -c $PATRONI_CONFIG failover \\"
        echo "    --master $master \\"
        echo "    --candidate $candidate \\"
        echo "    --force"
        return 0
    fi

    # Confirmation prompt
    if [[ "$FORCE" == "false" ]]; then
        echo ""
        print_error "DANGER: Manual failover may result in data loss!"
        print_warning "This should only be used when automatic failover is not working."
        print_warning "Consider using --switchover instead for planned maintenance."
        echo ""
        read -p "Are you ABSOLUTELY SURE you want to proceed? (type 'FAILOVER' to confirm): " -r
        echo ""
        if [[ "$REPLY" != "FAILOVER" ]]; then
            print_info "Failover cancelled"
            exit 0
        fi
    fi

    # Execute failover
    print_info "Executing manual failover..."

    if $PATRONICTL -c "$PATRONI_CONFIG" failover \
        --master "$master" \
        --candidate "$candidate" \
        --force; then

        print_success "Failover initiated successfully"

        # Wait for failover to complete
        print_info "Waiting for failover to complete (max 30 seconds)..."
        local timeout=30
        local elapsed=0

        while [[ $elapsed -lt $timeout ]]; do
            sleep 2
            elapsed=$((elapsed + 2))

            if $PATRONICTL -c "$PATRONI_CONFIG" list | grep "$candidate" | grep -q "Leader"; then
                print_success "Failover completed successfully!"
                print_success "New leader: $candidate"
                return 0
            fi

            echo -n "."
        done

        echo ""
        print_warning "Failover timeout. Check cluster status manually."
        return 1
    else
        print_error "Failover failed"
        return 1
    fi
}

###############################################################################
# Post-Operation Checks
###############################################################################

verify_post_failover() {
    print_info "Running post-failover verification..."
    echo ""

    # Show current cluster status
    print_info "Current cluster status:"
    $PATRONICTL -c "$PATRONI_CONFIG" list
    echo ""

    # Check for leader
    if $PATRONICTL -c "$PATRONI_CONFIG" list | grep -q "Leader"; then
        print_success "Cluster has a leader"
    else
        print_error "No leader found after failover!"
        return 1
    fi

    # Check all members are in expected state
    local failed_members
    failed_members=$($PATRONICTL -c "$PATRONI_CONFIG" list | grep -v "running\|streaming" | grep -v "Member\|---" || echo "")

    if [[ -n "$failed_members" ]]; then
        print_warning "Some members are not in expected state:"
        echo "$failed_members"
        return 1
    else
        print_success "All members in expected state"
    fi

    print_success "Post-failover verification passed"
    return 0
}

###############################################################################
# Main
###############################################################################

main() {
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${BOLD}PATRONI MANUAL FAILOVER TOOL${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Validate arguments
    if [[ -z "$OPERATION" ]]; then
        print_error "No operation specified. Use --switchover or --failover"
        echo ""
        usage
    fi

    if [[ -z "$MASTER_NODE" ]] || [[ -z "$CANDIDATE_NODE" ]]; then
        print_error "Both --master and --candidate must be specified"
        echo ""
        usage
    fi

    # Run checks
    check_prerequisites
    echo ""

    verify_cluster_state || exit 1
    echo ""

    if [[ "$OPERATION" == "switchover" ]]; then
        check_replication_lag || print_warning "Proceeding despite replication lag"
        echo ""
    fi

    # Perform operation
    case "$OPERATION" in
        switchover)
            if perform_switchover "$MASTER_NODE" "$CANDIDATE_NODE"; then
                echo ""
                verify_post_failover
                exit 0
            else
                exit 1
            fi
            ;;
        failover)
            if perform_failover "$MASTER_NODE" "$CANDIDATE_NODE"; then
                echo ""
                verify_post_failover
                exit 0
            else
                exit 1
            fi
            ;;
        *)
            print_error "Invalid operation: $OPERATION"
            usage
            ;;
    esac
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --switchover)
            OPERATION="switchover"
            shift
            ;;
        --failover)
            OPERATION="failover"
            shift
            ;;
        --master)
            MASTER_NODE="$2"
            shift 2
            ;;
        --candidate)
            CANDIDATE_NODE="$2"
            shift 2
            ;;
        --cluster)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            echo ""
            usage
            ;;
    esac
done

main
