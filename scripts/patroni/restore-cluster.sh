#!/usr/bin/env bash

###############################################################################
# Patroni Cluster Restore Script
#
# Description: Restore Patroni cluster from pg_basebackup
# Usage: ./restore-cluster.sh [OPTIONS]
#
# Options:
#   --backup <path>: Path to backup directory
#   --node <name>: Node to restore to
#   --cluster <name>: Cluster name
#   --pitr <timestamp>: Point-in-time recovery (optional)
#
# Author: Database Operations Team
# Version: 1.0
# Last Updated: 2026-02-12
#
# WARNING: This script will DESTROY existing data on the target node!
###############################################################################

set -euo pipefail

# Configuration
PATRONICTL="${PATRONICTL:-patronictl}"
PATRONI_CONFIG="${PATRONI_CONFIG:-/etc/patroni/patroni.yml}"
DATA_DIR="${DATA_DIR:-/var/lib/postgresql/data}"
BACKUP_PATH=""
NODE_NAME=""
CLUSTER_NAME=""
PITR_TARGET=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

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

Restore Patroni PostgreSQL cluster from backup.

OPTIONS:
    --backup <path>         Path to backup directory (required)
    --node <name>           Node to restore to (required)
    --cluster <name>        Cluster name (required)
    --pitr <timestamp>      Point-in-time recovery timestamp (optional)
                            Format: 'YYYY-MM-DD HH:MM:SS'
    -h, --help              Show this help message

EXAMPLES:
    # Basic restore
    $0 --backup /backups/patroni/coordinator_20260212_103000 \\
       --node coordinator-1 \\
       --cluster coordinator

    # Point-in-time recovery
    $0 --backup /backups/patroni/coordinator_20260212_103000 \\
       --node coordinator-1 \\
       --cluster coordinator \\
       --pitr '2026-02-12 10:45:00'

WARNINGS:
    - This will DESTROY all data on the target node
    - The node will be removed from Patroni cluster during restore
    - Point-in-time recovery requires WAL archives to be available
    - Always verify backup before restoring

EOF
    exit 0
}

###############################################################################
# Validation Functions
###############################################################################

validate_prerequisites() {
    print_info "Validating prerequisites..."

    # Check if backup exists
    if [[ ! -d "$BACKUP_PATH" ]]; then
        print_error "Backup directory not found: $BACKUP_PATH"
        exit 1
    fi

    # Check if backup contains base.tar.gz
    if [[ ! -f "$BACKUP_PATH/base.tar.gz" ]] && [[ ! -f "$BACKUP_PATH/base.tar" ]]; then
        print_error "Invalid backup: base.tar.gz or base.tar not found"
        exit 1
    fi

    # Check if Patroni is available
    if ! command -v "$PATRONICTL" &> /dev/null; then
        print_error "patronictl not found. Please install Patroni."
        exit 1
    fi

    # Check if node exists in cluster
    if ! $PATRONICTL -c "$PATRONI_CONFIG" list | grep -q "$NODE_NAME"; then
        print_error "Node '$NODE_NAME' not found in Patroni cluster"
        exit 1
    fi

    print_success "Prerequisites validated"
}

display_backup_info() {
    print_info "Backup Information:"
    echo ""

    local metadata_file="$BACKUP_PATH/backup_metadata.txt"

    if [[ -f "$metadata_file" ]]; then
        cat "$metadata_file"
    else
        print_warning "No metadata file found"
        print_info "Backup directory: $BACKUP_PATH"
        print_info "Size: $(du -sh "$BACKUP_PATH" | awk '{print $1}')"
    fi

    echo ""
}

###############################################################################
# Restore Functions
###############################################################################

stop_patroni_node() {
    local node="$1"

    print_warning "Stopping Patroni on node: $node"

    # Stop Patroni service
    if systemctl is-active --quiet patroni; then
        systemctl stop patroni
        print_success "Patroni stopped"
    else
        print_info "Patroni not running"
    fi

    # Verify PostgreSQL is stopped
    if pgrep -x postgres > /dev/null; then
        print_warning "PostgreSQL still running, force stopping..."
        sudo -u postgres pg_ctl stop -D "$DATA_DIR" -m fast || true
    fi
}

backup_existing_data() {
    local data_dir="$1"

    if [[ ! -d "$data_dir" ]]; then
        print_info "No existing data directory"
        return 0
    fi

    local backup_old="${data_dir}.backup_$(date +%Y%m%d_%H%M%S)"

    print_warning "Backing up existing data to: $backup_old"

    if mv "$data_dir" "$backup_old"; then
        print_success "Existing data backed up"
        print_info "To remove: rm -rf $backup_old"
    else
        print_error "Failed to backup existing data"
        return 1
    fi
}

restore_base_backup() {
    local backup_path="$1"
    local data_dir="$2"

    print_info "Restoring base backup..."

    # Create new data directory
    mkdir -p "$data_dir"
    chown postgres:postgres "$data_dir"
    chmod 700 "$data_dir"

    # Extract base backup
    local base_tar
    if [[ -f "$backup_path/base.tar.gz" ]]; then
        base_tar="$backup_path/base.tar.gz"
        print_info "Extracting compressed backup..."
        tar -xzf "$base_tar" -C "$data_dir"
    elif [[ -f "$backup_path/base.tar" ]]; then
        base_tar="$backup_path/base.tar"
        print_info "Extracting backup..."
        tar -xf "$base_tar" -C "$data_dir"
    else
        print_error "Base backup file not found"
        return 1
    fi

    # Extract WAL archive if exists
    if [[ -f "$backup_path/pg_wal.tar.gz" ]]; then
        print_info "Extracting WAL archive..."
        tar -xzf "$backup_path/pg_wal.tar.gz" -C "$data_dir/pg_wal"
    elif [[ -f "$backup_path/pg_wal.tar" ]]; then
        tar -xf "$backup_path/pg_wal.tar" -C "$data_dir/pg_wal"
    fi

    # Fix permissions
    chown -R postgres:postgres "$data_dir"

    print_success "Base backup restored"
}

configure_recovery() {
    local data_dir="$1"
    local pitr_target="$2"

    print_info "Configuring recovery..."

    # Create recovery.signal file
    touch "$data_dir/recovery.signal"
    chown postgres:postgres "$data_dir/recovery.signal"

    # Configure recovery settings
    local recovery_conf="$data_dir/postgresql.auto.conf"

    cat >> "$recovery_conf" << EOF

# Recovery Configuration (added by restore script)
restore_command = 'cp /wal_archive/%f %p'
recovery_target_action = 'promote'
EOF

    if [[ -n "$pitr_target" ]]; then
        print_info "Configuring point-in-time recovery to: $pitr_target"
        echo "recovery_target_time = '$pitr_target'" >> "$recovery_conf"
    fi

    chown postgres:postgres "$recovery_conf"

    print_success "Recovery configured"
}

start_recovery() {
    local data_dir="$1"

    print_info "Starting PostgreSQL for recovery..."

    # Start PostgreSQL manually for recovery
    sudo -u postgres pg_ctl start -D "$data_dir" -l "$data_dir/recovery.log"

    # Wait for recovery to complete
    print_info "Waiting for recovery to complete (this may take several minutes)..."

    local timeout=300
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if sudo -u postgres pg_isready -q; then
            if [[ ! -f "$data_dir/recovery.signal" ]]; then
                print_success "Recovery completed!"
                return 0
            fi
        fi

        sleep 5
        elapsed=$((elapsed + 5))
        echo -n "."
    done

    echo ""
    print_error "Recovery timeout"
    return 1
}

reinitialize_patroni() {
    local node="$1"
    local cluster="$2"

    print_info "Reinitializing Patroni..."

    # Stop PostgreSQL
    sudo -u postgres pg_ctl stop -D "$DATA_DIR" -m fast || true

    # Restart Patroni
    systemctl start patroni

    # Wait for node to rejoin cluster
    print_info "Waiting for node to rejoin cluster..."

    local timeout=60
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if $PATRONICTL -c "$PATRONI_CONFIG" list | grep "$node" | grep -qE "running|streaming"; then
            print_success "Node rejoined cluster successfully!"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
        echo -n "."
    done

    echo ""
    print_warning "Node did not rejoin cluster within timeout. Check logs."
    return 1
}

###############################################################################
# Main
###############################################################################

main() {
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${BOLD}PATRONI CLUSTER RESTORE${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Validate arguments
    if [[ -z "$BACKUP_PATH" ]] || [[ -z "$NODE_NAME" ]] || [[ -z "$CLUSTER_NAME" ]]; then
        print_error "Missing required arguments"
        echo ""
        usage
    fi

    # Display backup info
    display_backup_info

    # Validate prerequisites
    validate_prerequisites
    echo ""

    # Final confirmation
    print_error "WARNING: This will DESTROY all data on node: $NODE_NAME"
    print_warning "Backup path: $BACKUP_PATH"
    if [[ -n "$PITR_TARGET" ]]; then
        print_warning "Point-in-time recovery: $PITR_TARGET"
    fi
    echo ""
    read -p "Are you ABSOLUTELY SURE you want to proceed? (type 'RESTORE' to confirm): " -r
    echo ""

    if [[ "$REPLY" != "RESTORE" ]]; then
        print_info "Restore cancelled"
        exit 0
    fi

    # Execute restore
    print_info "Starting restore process..."
    echo ""

    stop_patroni_node "$NODE_NAME" || exit 1
    echo ""

    backup_existing_data "$DATA_DIR" || exit 1
    echo ""

    restore_base_backup "$BACKUP_PATH" "$DATA_DIR" || exit 1
    echo ""

    if [[ -n "$PITR_TARGET" ]]; then
        configure_recovery "$DATA_DIR" "$PITR_TARGET" || exit 1
        echo ""

        start_recovery "$DATA_DIR" || exit 1
        echo ""
    fi

    reinitialize_patroni "$NODE_NAME" "$CLUSTER_NAME" || exit 1
    echo ""

    print_success "Restore completed successfully!"
    echo ""
    print_info "Next steps:"
    print_info "1. Verify cluster status: patronictl list"
    print_info "2. Check replication: SELECT * FROM pg_stat_replication;"
    print_info "3. Validate data integrity"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --backup)
            BACKUP_PATH="$2"
            shift 2
            ;;
        --node)
            NODE_NAME="$2"
            shift 2
            ;;
        --cluster)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --pitr)
            PITR_TARGET="$2"
            shift 2
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
