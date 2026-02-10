#!/bin/bash
# Restore PostgreSQL mesh cluster from distributed backup
# Usage: ./restore-distributed.sh <stack_name> <backup_path> [restore_mode]

set -euo pipefail

# Configuration
STACK_NAME="${1:-postgres-mesh}"
BACKUP_PATH="${2}"
RESTORE_MODE="${3:-full}"  # full or point-in-time
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Validate inputs
if [ -z "$BACKUP_PATH" ]; then
    log_error "Backup path is required"
    echo "Usage: $0 <stack_name> <backup_path> [restore_mode]"
    exit 1
fi

# Check if backup exists
if [ ! -d "$BACKUP_PATH" ] && [ ! -f "$BACKUP_PATH" ]; then
    log_error "Backup path does not exist: ${BACKUP_PATH}"
    exit 1
fi

log_warning "=== RESTORE OPERATION ==="
log_warning "This will OVERWRITE existing data in stack: ${STACK_NAME}"
log_warning "Backup source: ${BACKUP_PATH}"
log_warning "Restore mode: ${RESTORE_MODE}"
echo ""
read -p "Are you sure you want to proceed? (yes/no): " -r
if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
    log_info "Restore cancelled"
    exit 0
fi

# Extract backup if compressed
EXTRACTED_BACKUP=""
if [ -f "$BACKUP_PATH" ]; then
    log_info "Extracting compressed backup..."
    EXTRACTED_BACKUP="/tmp/restore-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$EXTRACTED_BACKUP"

    if [[ "$BACKUP_PATH" == *.tar.gz ]]; then
        tar xzf "$BACKUP_PATH" -C "$EXTRACTED_BACKUP" --strip-components=1
    elif [[ "$BACKUP_PATH" == *.tar.zst ]]; then
        zstd -d "$BACKUP_PATH" -c | tar xf - -C "$EXTRACTED_BACKUP" --strip-components=1
    else
        log_error "Unknown compression format"
        exit 1
    fi

    BACKUP_PATH="$EXTRACTED_BACKUP"
    log_success "Backup extracted to: ${BACKUP_PATH}"
fi

# Load backup manifest
if [ ! -f "${BACKUP_PATH}/manifest.json" ]; then
    log_error "Backup manifest not found. Invalid backup."
    exit 1
fi

log_info "Loading backup manifest..."
BACKUP_TYPE=$(jq -r '.backup_type' "${BACKUP_PATH}/manifest.json")
WORKER_COUNT=$(jq -r '.workers.count' "${BACKUP_PATH}/manifest.json")
BACKUP_TIMESTAMP=$(jq -r '.timestamp' "${BACKUP_PATH}/manifest.json")

log_info "Backup type: ${BACKUP_TYPE}"
log_info "Workers in backup: ${WORKER_COUNT}"
log_info "Backup timestamp: ${BACKUP_TIMESTAMP}"

# Step 1: Stop cluster services (but keep containers running)
log_info "Step 1/6: Preparing cluster for restore..."
log_warning "Stopping write operations..."

# Get coordinator container
COORDINATOR_TASK=$(docker service ps "${STACK_NAME}_coordinator" --filter "desired-state=running" -q | head -n 1)
if [ -z "$COORDINATOR_TASK" ]; then
    log_error "Coordinator is not running. Start the cluster first."
    exit 1
fi

COORDINATOR_CONTAINER=$(docker inspect --format '{{.Status.ContainerStatus.ContainerID}}' "$COORDINATOR_TASK")

# Terminate all active connections
log_info "Terminating active connections..."
docker exec "$COORDINATOR_CONTAINER" psql -U dpg_cluster -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'distributed_postgres_cluster' AND pid <> pg_backend_pid();" \
    || log_warning "Could not terminate all connections"

log_success "Cluster prepared for restore"

# Step 2: Restore global objects (roles, etc.)
log_info "Step 2/6: Restoring global objects..."

if [ -f "${BACKUP_PATH}/globals.sql" ]; then
    docker cp "${BACKUP_PATH}/globals.sql" "${COORDINATOR_CONTAINER}:/tmp/globals.sql"
    docker exec "$COORDINATOR_CONTAINER" psql -U dpg_cluster -d postgres -f /tmp/globals.sql \
        2>&1 | tee "${BACKUP_PATH}/restore-globals.log"
    docker exec "$COORDINATOR_CONTAINER" rm /tmp/globals.sql

    log_success "Global objects restored"
else
    log_warning "No globals.sql found - skipping"
fi

# Step 3: Drop and recreate database
log_info "Step 3/6: Recreating database..."

docker exec "$COORDINATOR_CONTAINER" psql -U dpg_cluster -d postgres -c \
    "DROP DATABASE IF EXISTS distributed_postgres_cluster;"

docker exec "$COORDINATOR_CONTAINER" psql -U dpg_cluster -d postgres -c \
    "CREATE DATABASE distributed_postgres_cluster OWNER dpg_cluster;"

log_success "Database recreated"

# Step 4: Restore coordinator data
log_info "Step 4/6: Restoring coordinator data..."

if [ "$BACKUP_TYPE" == "full" ]; then
    if [ -f "${BACKUP_PATH}/coordinator.dump" ]; then
        docker cp "${BACKUP_PATH}/coordinator.dump" "${COORDINATOR_CONTAINER}:/tmp/coordinator.dump"

        docker exec "$COORDINATOR_CONTAINER" pg_restore -U dpg_cluster -d distributed_postgres_cluster \
            --verbose --no-owner --no-acl /tmp/coordinator.dump 2>&1 | tee "${BACKUP_PATH}/restore-coordinator.log"

        docker exec "$COORDINATOR_CONTAINER" rm /tmp/coordinator.dump
        log_success "Coordinator data restored"
    else
        log_error "Coordinator backup file not found"
        exit 1
    fi
else
    # Incremental restore using pg_basebackup
    if [ -d "${BACKUP_PATH}/coordinator-base" ]; then
        log_info "Restoring from base backup..."

        # Stop PostgreSQL temporarily
        docker exec "$COORDINATOR_CONTAINER" pg_ctl stop -D /var/lib/postgresql/data/pgdata -m fast || true

        # Copy base backup
        docker exec "$COORDINATOR_CONTAINER" rm -rf /var/lib/postgresql/data/pgdata/*
        docker cp "${BACKUP_PATH}/coordinator-base/." "${COORDINATOR_CONTAINER}:/var/lib/postgresql/data/pgdata/"

        # Start PostgreSQL
        docker exec -d "$COORDINATOR_CONTAINER" postgres -D /var/lib/postgresql/data/pgdata

        sleep 10
        log_success "Coordinator base backup restored"
    else
        log_error "Coordinator base backup not found"
        exit 1
    fi
fi

# Step 5: Restore worker nodes in parallel
log_info "Step 5/6: Restoring worker nodes in parallel..."

# Get all worker directories in backup
WORKER_BACKUPS=($(find "${BACKUP_PATH}" -maxdepth 1 -type d -name "worker-*" -printf "%f\n"))
BACKUP_WORKER_COUNT=${#WORKER_BACKUPS[@]}

log_info "Found ${BACKUP_WORKER_COUNT} worker backups"

# Function to restore a single worker
restore_worker() {
    local worker_name=$1
    local worker_backup_dir="${BACKUP_PATH}/${worker_name}"
    local worker_service="${STACK_NAME}_${worker_name}"

    log_info "Restoring ${worker_name}..."

    # Get worker container
    local task_id=$(docker service ps "$worker_service" --filter "desired-state=running" -q | head -n 1)
    if [ -z "$task_id" ]; then
        log_warning "${worker_name} service not found - skipping"
        return 1
    fi

    local container_id=$(docker inspect --format '{{.Status.ContainerStatus.ContainerID}}' "$task_id")

    # Terminate connections to this worker
    docker exec "$container_id" psql -U dpg_cluster -d postgres -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'distributed_postgres_cluster' AND pid <> pg_backend_pid();" \
        2>/dev/null || true

    # Drop and recreate database
    docker exec "$container_id" psql -U dpg_cluster -d postgres -c \
        "DROP DATABASE IF EXISTS distributed_postgres_cluster;" 2>/dev/null || true

    docker exec "$container_id" psql -U dpg_cluster -d postgres -c \
        "CREATE DATABASE distributed_postgres_cluster OWNER dpg_cluster;"

    # Restore data
    if [ "$BACKUP_TYPE" == "full" ]; then
        if [ -f "${worker_backup_dir}/data.dump" ]; then
            docker cp "${worker_backup_dir}/data.dump" "${container_id}:/tmp/worker.dump"

            docker exec "$container_id" pg_restore -U dpg_cluster -d distributed_postgres_cluster \
                --verbose --no-owner --no-acl /tmp/worker.dump 2>&1 | tee "${worker_backup_dir}/restore.log"

            docker exec "$container_id" rm /tmp/worker.dump
        fi
    else
        if [ -d "${worker_backup_dir}/base" ]; then
            docker exec "$container_id" pg_ctl stop -D /var/lib/postgresql/data/pgdata -m fast || true
            docker exec "$container_id" rm -rf /var/lib/postgresql/data/pgdata/*
            docker cp "${worker_backup_dir}/base/." "${container_id}:/var/lib/postgresql/data/pgdata/"
            docker exec -d "$container_id" postgres -D /var/lib/postgresql/data/pgdata
        fi
    fi

    log_success "${worker_name} restore completed"
}

# Export function for parallel execution
export -f restore_worker
export -f log_info
export -f log_warning
export -f log_success
export BACKUP_PATH
export BACKUP_TYPE
export STACK_NAME
export RED GREEN YELLOW BLUE NC

# Run restores in parallel (max 4 concurrent)
printf "%s\n" "${WORKER_BACKUPS[@]}" | xargs -P 4 -I {} bash -c 'restore_worker "{}"'

log_success "All worker restores completed"

# Step 6: Verify cluster health
log_info "Step 6/6: Verifying cluster health..."

sleep 10  # Wait for services to stabilize

# Check coordinator
if docker exec "$COORDINATOR_CONTAINER" pg_isready -U dpg_cluster -d distributed_postgres_cluster > /dev/null 2>&1; then
    log_success "Coordinator is healthy"
else
    log_error "Coordinator health check failed"
fi

# Check workers
HEALTHY_WORKERS=0
for worker in "${WORKER_BACKUPS[@]}"; do
    worker_service="${STACK_NAME}_${worker}"
    task_id=$(docker service ps "$worker_service" --filter "desired-state=running" -q | head -n 1)

    if [ -n "$task_id" ]; then
        container_id=$(docker inspect --format '{{.Status.ContainerStatus.ContainerID}}' "$task_id")

        if docker exec "$container_id" pg_isready -U dpg_cluster -d distributed_postgres_cluster > /dev/null 2>&1; then
            HEALTHY_WORKERS=$((HEALTHY_WORKERS + 1))
        fi
    fi
done

log_info "Healthy workers: ${HEALTHY_WORKERS}/${BACKUP_WORKER_COUNT}"

# Cleanup extracted backup if needed
if [ -n "$EXTRACTED_BACKUP" ]; then
    log_info "Cleaning up extracted backup..."
    rm -rf "$EXTRACTED_BACKUP"
fi

# Display summary
log_info "=== Restore Summary ==="
echo "Stack: ${STACK_NAME}"
echo "Backup timestamp: ${BACKUP_TIMESTAMP}"
echo "Restore mode: ${RESTORE_MODE}"
echo "Coordinator: Restored"
echo "Workers restored: ${BACKUP_WORKER_COUNT}"
echo "Workers healthy: ${HEALTHY_WORKERS}"
echo ""

if [ "$HEALTHY_WORKERS" -eq "$BACKUP_WORKER_COUNT" ]; then
    log_success "Cluster restore completed successfully!"
else
    log_warning "Some workers may not be healthy. Check logs for details."
fi

exit 0
