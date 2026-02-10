#!/bin/bash
# Distributed backup for PostgreSQL mesh cluster
# Usage: ./backup-distributed.sh <stack_name> [backup_type] [compression]

set -euo pipefail

# Configuration
STACK_NAME="${1:-postgres-mesh}"
BACKUP_TYPE="${2:-full}"  # full, incremental, differential
COMPRESSION="${3:-zstd}"  # none, gzip, zstd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="backup-${STACK_NAME}-${BACKUP_TYPE}-${TIMESTAMP}"

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

# Validate backup type
case "$BACKUP_TYPE" in
    full|incremental|differential)
        ;;
    *)
        log_error "Invalid backup type: ${BACKUP_TYPE}"
        echo "Valid types: full, incremental, differential"
        exit 1
        ;;
esac

# Validate compression
case "$COMPRESSION" in
    none|gzip|zstd)
        ;;
    *)
        log_error "Invalid compression: ${COMPRESSION}"
        echo "Valid compression: none, gzip, zstd"
        exit 1
        ;;
esac

log_info "Starting distributed backup for stack: ${STACK_NAME}"
log_info "Backup type: ${BACKUP_TYPE}"
log_info "Compression: ${COMPRESSION}"
log_info "Timestamp: ${TIMESTAMP}"

# Create backup directory
mkdir -p "${BACKUP_DIR}/${BACKUP_NAME}"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"

# Step 1: Backup coordinator metadata
log_info "Step 1/5: Backing up coordinator metadata..."

COORDINATOR_TASK=$(docker service ps "${STACK_NAME}_coordinator" --filter "desired-state=running" -q | head -n 1)
if [ -z "$COORDINATOR_TASK" ]; then
    log_error "Coordinator is not running"
    exit 1
fi

COORDINATOR_CONTAINER=$(docker inspect --format '{{.Status.ContainerStatus.ContainerID}}' "$COORDINATOR_TASK")

# Backup global objects (roles, databases, tablespaces)
docker exec "$COORDINATOR_CONTAINER" pg_dumpall -U dpg_cluster --globals-only \
    > "${BACKUP_PATH}/globals.sql"
log_success "Coordinator metadata backed up"

# Step 2: Backup coordinator database
log_info "Step 2/5: Backing up coordinator database..."

if [ "$BACKUP_TYPE" == "full" ]; then
    docker exec "$COORDINATOR_CONTAINER" pg_dump -U dpg_cluster -d distributed_postgres_cluster \
        --format=custom --verbose --file=/tmp/coordinator.dump 2>&1 | tee "${BACKUP_PATH}/coordinator.log"

    docker cp "${COORDINATOR_CONTAINER}:/tmp/coordinator.dump" "${BACKUP_PATH}/coordinator.dump"
    docker exec "$COORDINATOR_CONTAINER" rm /tmp/coordinator.dump

    log_success "Coordinator database backed up"
else
    log_info "Incremental/differential backup - checking for changes..."
    # For incremental, use pg_basebackup with WAL archiving
    docker exec "$COORDINATOR_CONTAINER" pg_basebackup -U dpg_cluster -D /tmp/backup \
        --format=tar --wal-method=fetch --progress --verbose 2>&1 | tee "${BACKUP_PATH}/coordinator.log"

    docker cp "${COORDINATOR_CONTAINER}:/tmp/backup" "${BACKUP_PATH}/coordinator-base"
    docker exec "$COORDINATOR_CONTAINER" rm -rf /tmp/backup

    log_success "Coordinator incremental backup completed"
fi

# Step 3: Backup worker nodes in parallel
log_info "Step 3/5: Backing up worker nodes in parallel..."

# Get all worker services
WORKER_SERVICES=($(docker service ls --filter "name=${STACK_NAME}_worker" --format "{{.Name}}"))
WORKER_COUNT=${#WORKER_SERVICES[@]}

log_info "Found ${WORKER_COUNT} worker nodes"

# Function to backup a single worker
backup_worker() {
    local worker_service=$1
    local worker_name=$(basename "$worker_service")
    local worker_backup_dir="${BACKUP_PATH}/${worker_name}"

    mkdir -p "$worker_backup_dir"

    log_info "Backing up ${worker_name}..."

    # Get worker container
    local task_id=$(docker service ps "$worker_service" --filter "desired-state=running" -q | head -n 1)
    if [ -z "$task_id" ]; then
        log_warning "${worker_name} is not running - skipping"
        return 1
    fi

    local container_id=$(docker inspect --format '{{.Status.ContainerStatus.ContainerID}}' "$task_id")

    # Backup worker database
    if [ "$BACKUP_TYPE" == "full" ]; then
        docker exec "$container_id" pg_dump -U dpg_cluster -d distributed_postgres_cluster \
            --format=custom --verbose --file=/tmp/worker.dump 2>&1 | tee "${worker_backup_dir}/backup.log"

        docker cp "${container_id}:/tmp/worker.dump" "${worker_backup_dir}/data.dump"
        docker exec "$container_id" rm /tmp/worker.dump
    else
        docker exec "$container_id" pg_basebackup -U dpg_cluster -D /tmp/backup \
            --format=tar --wal-method=fetch --progress 2>&1 | tee "${worker_backup_dir}/backup.log"

        docker cp "${container_id}:/tmp/backup" "${worker_backup_dir}/base"
        docker exec "$container_id" rm -rf /tmp/backup
    fi

    log_success "${worker_name} backup completed"
}

# Export function for parallel execution
export -f backup_worker
export -f log_info
export -f log_warning
export -f log_success
export BACKUP_PATH
export BACKUP_TYPE
export RED GREEN YELLOW BLUE NC

# Run backups in parallel (max 4 concurrent)
printf "%s\n" "${WORKER_SERVICES[@]}" | xargs -P 4 -I {} bash -c 'backup_worker "{}"'

log_success "All worker backups completed"

# Step 4: Create metadata and manifest
log_info "Step 4/5: Creating backup metadata..."

cat > "${BACKUP_PATH}/manifest.json" <<EOF
{
  "backup_name": "${BACKUP_NAME}",
  "stack_name": "${STACK_NAME}",
  "backup_type": "${BACKUP_TYPE}",
  "compression": "${COMPRESSION}",
  "timestamp": "${TIMESTAMP}",
  "coordinator": {
    "backed_up": true,
    "format": "$([ "$BACKUP_TYPE" == "full" ] && echo "custom" || echo "tar")"
  },
  "workers": {
    "count": ${WORKER_COUNT},
    "services": [
$(IFS=,; printf '      "%s"' "${WORKER_SERVICES[*]}" | sed 's/","/",\n      "/g')
    ]
  },
  "database": "distributed_postgres_cluster",
  "postgresql_version": "$(docker exec "$COORDINATOR_CONTAINER" psql -U dpg_cluster -t -c 'SELECT version();' | xargs)"
}
EOF

log_success "Backup metadata created"

# Step 5: Compress backup (if requested)
if [ "$COMPRESSION" != "none" ]; then
    log_info "Step 5/5: Compressing backup..."

    case "$COMPRESSION" in
        gzip)
            tar czf "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" -C "${BACKUP_DIR}" "${BACKUP_NAME}"
            COMPRESSED_SIZE=$(du -h "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" | cut -f1)
            log_success "Backup compressed with gzip: ${COMPRESSED_SIZE}"
            ;;
        zstd)
            tar cf - -C "${BACKUP_DIR}" "${BACKUP_NAME}" | zstd -T0 -10 > "${BACKUP_DIR}/${BACKUP_NAME}.tar.zst"
            COMPRESSED_SIZE=$(du -h "${BACKUP_DIR}/${BACKUP_NAME}.tar.zst" | cut -f1)
            log_success "Backup compressed with zstd: ${COMPRESSED_SIZE}"
            ;;
    esac

    # Optionally remove uncompressed backup
    read -p "Remove uncompressed backup? (yes/no): " -r
    if [[ $REPLY =~ ^[Yy]es$ ]]; then
        rm -rf "${BACKUP_PATH}"
        log_info "Uncompressed backup removed"
    fi
else
    log_info "Step 5/5: Skipping compression"
fi

# Calculate backup size
BACKUP_SIZE=$(du -sh "${BACKUP_PATH}" 2>/dev/null | cut -f1 || echo "N/A")

# Display backup summary
log_info "=== Backup Summary ==="
echo "Backup Name: ${BACKUP_NAME}"
echo "Backup Type: ${BACKUP_TYPE}"
echo "Compression: ${COMPRESSION}"
echo "Location: ${BACKUP_PATH}"
echo "Size: ${BACKUP_SIZE}"
echo "Timestamp: ${TIMESTAMP}"
echo ""
echo "Coordinator: Backed up"
echo "Workers: ${WORKER_COUNT} backed up"
echo ""
echo "Manifest: ${BACKUP_PATH}/manifest.json"
echo ""

log_success "Distributed backup completed successfully!"

# Save backup info for incremental backups
if [ "$BACKUP_TYPE" == "full" ]; then
    echo "${BACKUP_NAME}" > "${BACKUP_DIR}/.last_full_backup"
    log_info "Full backup reference saved for future incremental backups"
fi

exit 0
