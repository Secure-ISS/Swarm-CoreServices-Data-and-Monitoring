#!/bin/bash
# Safely remove a worker node from the PostgreSQL mesh cluster
# Usage: ./remove-worker.sh <stack_name> <worker_id> [drain_timeout]

set -euo pipefail

# Configuration
STACK_NAME="${1:-postgres-mesh}"
WORKER_ID="${2}"
DRAIN_TIMEOUT="${3:-300}"
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
if [ -z "$WORKER_ID" ]; then
    log_error "Worker ID is required"
    echo "Usage: $0 <stack_name> <worker_id> [drain_timeout]"
    exit 1
fi

# Validate worker ID format
if ! [[ "$WORKER_ID" =~ ^worker-[0-9]+$ ]]; then
    log_error "Worker ID must be in format 'worker-N' (e.g., worker-4)"
    exit 1
fi

# Check if worker exists
if ! docker service ls --filter "name=${STACK_NAME}_${WORKER_ID}" --format "{{.Name}}" | grep -q "${WORKER_ID}"; then
    log_error "Worker ${WORKER_ID} does not exist in stack ${STACK_NAME}"
    exit 1
fi

log_warning "Preparing to remove worker node: ${WORKER_ID} from stack: ${STACK_NAME}"
log_info "Drain timeout: ${DRAIN_TIMEOUT} seconds"

# Check worker count
WORKER_COUNT=$(docker service ls --filter "name=${STACK_NAME}_worker" --format "{{.Name}}" | wc -l)
if [ "$WORKER_COUNT" -le 2 ]; then
    log_error "Cannot remove worker. Minimum 2 workers required for cluster health."
    log_error "Current worker count: ${WORKER_COUNT}"
    exit 1
fi

# Step 1: Get worker container information
log_info "Step 1/5: Gathering worker information..."
TASK_ID=$(docker service ps "${STACK_NAME}_${WORKER_ID}" --filter "desired-state=running" -q | head -n 1)

if [ -z "$TASK_ID" ]; then
    log_warning "Worker ${WORKER_ID} is not currently running"
else
    CONTAINER_ID=$(docker inspect --format '{{.Status.ContainerStatus.ContainerID}}' "$TASK_ID" 2>/dev/null || echo "")
    log_info "Worker container ID: ${CONTAINER_ID:-N/A}"
fi

# Step 2: Stop accepting new connections
log_info "Step 2/5: Stopping new connections to worker..."

if [ -n "$CONTAINER_ID" ]; then
    # Set the worker to reject new connections
    docker exec "$CONTAINER_ID" psql -U dpg_cluster -d distributed_postgres_cluster -c \
        "ALTER SYSTEM SET max_connections = 0;" 2>/dev/null || log_warning "Could not set max_connections"

    docker exec "$CONTAINER_ID" psql -U dpg_cluster -d distributed_postgres_cluster -c \
        "SELECT pg_reload_conf();" 2>/dev/null || log_warning "Could not reload configuration"

    log_success "Worker configured to reject new connections"
else
    log_warning "Skipping connection rejection (worker not running)"
fi

# Step 3: Wait for existing connections to drain
log_info "Step 3/5: Waiting for existing connections to drain (max ${DRAIN_TIMEOUT}s)..."

if [ -n "$CONTAINER_ID" ]; then
    elapsed=0
    while [ $elapsed -lt $DRAIN_TIMEOUT ]; do
        # Count active connections
        ACTIVE_CONNS=$(docker exec "$CONTAINER_ID" psql -U dpg_cluster -d distributed_postgres_cluster -t -c \
            "SELECT count(*) FROM pg_stat_activity WHERE datname = 'distributed_postgres_cluster' AND pid != pg_backend_pid();" \
            2>/dev/null | xargs || echo "0")

        if [ "$ACTIVE_CONNS" -eq 0 ]; then
            log_success "All connections drained"
            break
        fi

        log_info "Active connections: ${ACTIVE_CONNS}"
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [ $elapsed -ge $DRAIN_TIMEOUT ]; then
        log_warning "Drain timeout reached. ${ACTIVE_CONNS} connections still active."
        read -p "Force removal? (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
            log_error "Worker removal cancelled"
            exit 1
        fi
    fi
else
    log_warning "Skipping connection drain (worker not running)"
fi

# Step 4: Create a backup of worker data (optional but recommended)
log_info "Step 4/5: Creating backup of worker data..."

if [ -n "$CONTAINER_ID" ]; then
    BACKUP_DIR="/tmp/postgres-worker-backup-${WORKER_ID}-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"

    # Backup using pg_dump
    docker exec "$CONTAINER_ID" pg_dumpall -U dpg_cluster > "${BACKUP_DIR}/dump.sql" 2>/dev/null || \
        log_warning "Could not create backup (non-critical)"

    if [ -f "${BACKUP_DIR}/dump.sql" ]; then
        log_success "Backup created at: ${BACKUP_DIR}"
    else
        log_warning "Backup not created (continuing with removal)"
    fi
else
    log_warning "Skipping backup (worker not running)"
fi

# Step 5: Remove the worker service
log_info "Step 5/5: Removing worker service..."

docker service rm "${STACK_NAME}_${WORKER_ID}"
log_success "Worker service ${WORKER_ID} removed"

# Wait for service to be fully removed
log_info "Waiting for service cleanup..."
max_wait=60
elapsed=0

while [ $elapsed -lt $max_wait ]; do
    if ! docker service ls --filter "name=${STACK_NAME}_${WORKER_ID}" --format "{{.Name}}" | grep -q "${WORKER_ID}"; then
        log_success "Service fully removed"
        break
    fi

    sleep 2
    elapsed=$((elapsed + 2))
done

# Clean up volume (optional - prompt user)
log_info "Worker data volume: ${STACK_NAME}_${WORKER_ID}_data"
read -p "Remove worker data volume? (yes/no): " -r
if [[ $REPLY =~ ^[Yy]es$ ]]; then
    if docker volume ls --format "{{.Name}}" | grep -q "${STACK_NAME}_${WORKER_ID}_data"; then
        docker volume rm "${STACK_NAME}_${WORKER_ID}_data"
        log_success "Worker data volume removed"
    else
        log_info "Worker data volume not found (may have already been removed)"
    fi
else
    log_info "Worker data volume preserved at: ${STACK_NAME}_${WORKER_ID}_data"
fi

# Display remaining cluster status
log_info "=== Remaining Cluster Status ==="
docker stack services "${STACK_NAME}" --filter "label=com.distributed-postgres.role=worker"
echo ""

REMAINING_WORKERS=$(docker service ls --filter "name=${STACK_NAME}_worker" --format "{{.Name}}" | wc -l)
log_info "Remaining workers: ${REMAINING_WORKERS}"

if [ "$REMAINING_WORKERS" -lt 2 ]; then
    log_warning "WARNING: Less than 2 workers remaining. Consider adding workers for redundancy."
fi

log_success "Worker ${WORKER_ID} successfully removed from cluster!"
