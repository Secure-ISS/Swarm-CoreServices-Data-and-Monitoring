#!/usr/bin/env bash

###############################################################################
# Patroni Cluster Backup Script
#
# Description: Create physical backups of Patroni cluster using pg_basebackup
# Usage: ./backup-cluster.sh [OPTIONS]
#
# Options:
#   --cluster <name>: Cluster to backup (coordinator/worker-1/worker-2/worker-3)
#   --node <name>: Specific node to backup from (default: replica)
#   --backup-dir <path>: Backup destination directory
#   --compress: Enable compression (gzip)
#   --retention-days <n>: Delete backups older than N days (default: 7)
#
# Author: Database Operations Team
# Version: 1.0
# Last Updated: 2026-02-12
###############################################################################

set -euo pipefail

# Configuration
BACKUP_BASE_DIR="${BACKUP_DIR:-/backups/patroni}"
POSTGRES_USER="${POSTGRES_USER:-admin}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
RETENTION_DAYS=7
COMPRESS=false
CLUSTER_NAME=""
NODE_NAME=""

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

Create physical backup of Patroni PostgreSQL cluster.

OPTIONS:
    --cluster <name>        Cluster to backup (coordinator, worker-1, worker-2, worker-3)
    --node <name>           Specific node to backup from (default: use replica)
    --backup-dir <path>     Backup destination (default: /backups/patroni)
    --compress              Enable gzip compression
    --retention-days <n>    Delete backups older than N days (default: 7)
    -h, --help              Show this help message

EXAMPLES:
    # Backup coordinator cluster from replica
    $0 --cluster coordinator --compress

    # Backup specific node
    $0 --cluster coordinator --node coordinator-2

    # Backup with custom destination and retention
    $0 --cluster worker-1 --backup-dir /mnt/backups --retention-days 30

NOTES:
    - Backups are taken from replica nodes to avoid load on leader
    - pg_basebackup is used for physical backups (full cluster)
    - Compression is recommended for large databases
    - Set POSTGRES_PASSWORD environment variable

EOF
    exit 0
}

###############################################################################
# Backup Functions
###############################################################################

select_backup_node() {
    local cluster="$1"

    print_info "Selecting backup source node..."

    # Get cluster members
    local members
    members=$(patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -E "postgres-cluster-$cluster" || echo "")

    if [[ -z "$members" ]]; then
        print_error "No members found for cluster: $cluster"
        exit 1
    fi

    # Prefer replica over leader (to avoid load)
    local replica_node
    replica_node=$(echo "$members" | grep "Replica" | grep "streaming" | head -n 1 | awk '{print $2}' || echo "")

    if [[ -n "$replica_node" ]]; then
        print_success "Selected replica node: $replica_node"
        echo "$replica_node"
        return 0
    fi

    # If no replica, use leader (not recommended for production)
    local leader_node
    leader_node=$(echo "$members" | grep "Leader" | head -n 1 | awk '{print $2}' || echo "")

    if [[ -n "$leader_node" ]]; then
        print_warning "No replica available, using leader node: $leader_node"
        echo "$leader_node"
        return 0
    fi

    print_error "No suitable node found for backup"
    exit 1
}

create_backup() {
    local node="$1"
    local backup_dir="$2"

    print_info "Creating backup from node: $node"
    print_info "Backup directory: $backup_dir"

    # Create backup directory
    if ! mkdir -p "$backup_dir"; then
        print_error "Failed to create backup directory: $backup_dir"
        exit 1
    fi

    # Build pg_basebackup command
    local backup_cmd="PGPASSWORD='$POSTGRES_PASSWORD' pg_basebackup"
    backup_cmd+=" -h $node"
    backup_cmd+=" -U $POSTGRES_USER"
    backup_cmd+=" -D $backup_dir"
    backup_cmd+=" -Ft"  # tar format
    backup_cmd+=" -P"   # progress
    backup_cmd+=" --wal-method=stream"  # include WAL

    if [[ "$COMPRESS" == "true" ]]; then
        backup_cmd+=" -z"  # gzip compression
        print_info "Compression enabled (gzip)"
    fi

    # Execute backup
    print_info "Starting backup (this may take several minutes)..."

    if eval "$backup_cmd"; then
        print_success "Backup completed successfully!"

        # Display backup size
        local backup_size
        backup_size=$(du -sh "$backup_dir" | awk '{print $1}')
        print_info "Backup size: $backup_size"

        # Create metadata file
        create_backup_metadata "$backup_dir" "$node"

        return 0
    else
        print_error "Backup failed!"
        return 1
    fi
}

create_backup_metadata() {
    local backup_dir="$1"
    local node="$2"

    local metadata_file="$backup_dir/backup_metadata.txt"

    cat > "$metadata_file" << EOF
Backup Metadata
===============
Timestamp: $(date '+%Y-%m-%d %H:%M:%S %Z')
Source Node: $node
Cluster: $CLUSTER_NAME
PostgreSQL Version: $(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$node" -U "$POSTGRES_USER" -d postgres -t -c "SELECT version();" 2>/dev/null || echo "Unknown")
Backup Method: pg_basebackup
Compression: $([ "$COMPRESS" == "true" ] && echo "Yes (gzip)" || echo "No")
Backup Directory: $backup_dir
Created By: $(whoami)@$(hostname)
EOF

    print_success "Metadata file created: $metadata_file"
}

cleanup_old_backups() {
    local base_dir="$1"
    local retention="$2"

    print_info "Cleaning up backups older than $retention days..."

    local old_backups
    old_backups=$(find "$base_dir" -maxdepth 1 -type d -name "${CLUSTER_NAME}_*" -mtime +$retention 2>/dev/null || echo "")

    if [[ -z "$old_backups" ]]; then
        print_info "No old backups to clean up"
        return 0
    fi

    local count
    count=$(echo "$old_backups" | wc -l)

    print_warning "Found $count old backup(s) to delete"

    echo "$old_backups" | while IFS= read -r old_backup; do
        print_info "Deleting: $old_backup"
        rm -rf "$old_backup"
    done

    print_success "Cleanup completed"
}

###############################################################################
# Main
###############################################################################

main() {
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${BOLD}PATRONI CLUSTER BACKUP${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Validate arguments
    if [[ -z "$CLUSTER_NAME" ]]; then
        print_error "Cluster name not specified. Use --cluster <name>"
        echo ""
        usage
    fi

    if [[ -z "$POSTGRES_PASSWORD" ]]; then
        print_error "POSTGRES_PASSWORD environment variable not set"
        exit 1
    fi

    # Select backup node if not specified
    if [[ -z "$NODE_NAME" ]]; then
        NODE_NAME=$(select_backup_node "$CLUSTER_NAME")
    fi
    echo ""

    # Create backup directory with timestamp
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_dir="${BACKUP_BASE_DIR}/${CLUSTER_NAME}_${timestamp}"

    # Perform backup
    if create_backup "$NODE_NAME" "$backup_dir"; then
        echo ""
        print_success "Backup saved to: $backup_dir"

        # Cleanup old backups
        echo ""
        cleanup_old_backups "$BACKUP_BASE_DIR" "$RETENTION_DAYS"

        echo ""
        print_success "Backup process completed successfully!"
        exit 0
    else
        print_error "Backup process failed!"
        exit 1
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --cluster)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --node)
            NODE_NAME="$2"
            shift 2
            ;;
        --backup-dir)
            BACKUP_BASE_DIR="$2"
            shift 2
            ;;
        --compress)
            COMPRESS=true
            shift
            ;;
        --retention-days)
            RETENTION_DAYS="$2"
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
