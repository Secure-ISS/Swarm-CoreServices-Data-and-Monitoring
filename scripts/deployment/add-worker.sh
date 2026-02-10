#!/bin/bash
# Add a new worker node to the PostgreSQL mesh cluster
# Usage: ./add-worker.sh <stack_name> <worker_id> [node_constraint]

set -euo pipefail

# Configuration
STACK_NAME="${1:-postgres-mesh}"
WORKER_ID="${2}"
NODE_CONSTRAINT="${3:-}"
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
    echo "Usage: $0 <stack_name> <worker_id> [node_constraint]"
    exit 1
fi

# Validate worker ID format
if ! [[ "$WORKER_ID" =~ ^worker-[0-9]+$ ]]; then
    log_error "Worker ID must be in format 'worker-N' (e.g., worker-4)"
    exit 1
fi

# Check if worker already exists
if docker service ls --filter "name=${STACK_NAME}_${WORKER_ID}" --format "{{.Name}}" | grep -q "${WORKER_ID}"; then
    log_error "Worker ${WORKER_ID} already exists in stack ${STACK_NAME}"
    exit 1
fi

log_info "Adding new worker node: ${WORKER_ID} to stack: ${STACK_NAME}"

# Get coordinator host
COORDINATOR_HOST="${STACK_NAME}_coordinator"

# Build placement constraints
PLACEMENT_CONSTRAINTS="[node.role==worker,node.labels.postgres.role==worker]"
if [ -n "$NODE_CONSTRAINT" ]; then
    PLACEMENT_CONSTRAINTS="[${NODE_CONSTRAINT}]"
    log_info "Using custom node constraint: ${NODE_CONSTRAINT}"
fi

# Create the worker service
log_info "Creating worker service..."

docker service create \
    --name "${STACK_NAME}_${WORKER_ID}" \
    --hostname "pg-${WORKER_ID}" \
    --network "${STACK_NAME}_postgres_mesh" \
    --network-alias "postgres-${WORKER_ID}" \
    --mount type=volume,source="${STACK_NAME}_${WORKER_ID}_data",target=/var/lib/postgresql/data \
    --secret postgres_password \
    --secret replication_password \
    --config source=worker_config,target=/etc/postgresql/postgresql.conf \
    --env POSTGRES_DB=distributed_postgres_cluster \
    --env POSTGRES_USER=dpg_cluster \
    --env POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
    --env PGDATA=/var/lib/postgresql/data/pgdata \
    --env POSTGRES_ROLE=worker \
    --env POSTGRES_COORDINATOR_HOST=pg-coordinator \
    --env POSTGRES_COORDINATOR_PORT=5432 \
    --env POSTGRES_MAX_CONNECTIONS=200 \
    --env POSTGRES_SHARED_BUFFERS=2GB \
    --env POSTGRES_EFFECTIVE_CACHE_SIZE=6GB \
    --env POSTGRES_WORK_MEM=32MB \
    --env POSTGRES_MAINTENANCE_WORK_MEM=512MB \
    --env POSTGRES_REPLICATION_USER=replicator \
    --env POSTGRES_REPLICATION_PASSWORD_FILE=/run/secrets/replication_password \
    --constraint "$PLACEMENT_CONSTRAINTS" \
    --limit-cpu 2 \
    --limit-memory 4G \
    --reserve-cpu 1 \
    --reserve-memory 2G \
    --replicas 1 \
    --restart-condition on-failure \
    --restart-delay 10s \
    --restart-max-attempts 5 \
    --restart-window 120s \
    --update-parallelism 1 \
    --update-delay 30s \
    --update-failure-action rollback \
    --update-order start-first \
    --label "com.distributed-postgres.role=worker" \
    --label "com.distributed-postgres.cluster=main" \
    --label "com.distributed-postgres.worker-id=${WORKER_ID#worker-}" \
    --health-cmd "pg_isready -U dpg_cluster -d distributed_postgres_cluster" \
    --health-interval 15s \
    --health-timeout 5s \
    --health-retries 3 \
    --health-start-period 60s \
    ruvnet/ruvector-postgres:latest

log_success "Worker service ${WORKER_ID} created"

# Wait for the worker to be healthy
log_info "Waiting for worker to be healthy..."
max_wait=120
elapsed=0

while [ $elapsed -lt $max_wait ]; do
    health_status=$(docker service ps "${STACK_NAME}_${WORKER_ID}" --filter "desired-state=running" --format "{{.CurrentState}}" | head -n 1)

    if echo "$health_status" | grep -q "Running"; then
        log_success "Worker ${WORKER_ID} is running!"
        break
    fi

    log_info "Current status: ${health_status}"
    sleep 5
    elapsed=$((elapsed + 5))
done

if [ $elapsed -ge $max_wait ]; then
    log_warning "Worker did not become healthy within ${max_wait} seconds"
    log_info "Check logs with: docker service logs ${STACK_NAME}_${WORKER_ID}"
    exit 1
fi

# Verify connectivity
log_info "Verifying worker connectivity..."

# Get the task ID
TASK_ID=$(docker service ps "${STACK_NAME}_${WORKER_ID}" --filter "desired-state=running" -q | head -n 1)

if [ -n "$TASK_ID" ]; then
    CONTAINER_ID=$(docker inspect --format '{{.Status.ContainerStatus.ContainerID}}' "$TASK_ID")

    if [ -n "$CONTAINER_ID" ]; then
        # Test database connectivity
        if docker exec "$CONTAINER_ID" pg_isready -U dpg_cluster -d distributed_postgres_cluster > /dev/null 2>&1; then
            log_success "Worker ${WORKER_ID} is responding to database connections"
        else
            log_warning "Worker ${WORKER_ID} is not yet responding to connections"
        fi
    fi
fi

# Display worker information
log_info "=== Worker ${WORKER_ID} Information ==="
docker service ps "${STACK_NAME}_${WORKER_ID}" --no-trunc
echo ""

log_info "=== Useful Commands ==="
echo "View worker logs:"
echo "  docker service logs ${STACK_NAME}_${WORKER_ID}"
echo ""
echo "Check worker status:"
echo "  docker service ps ${STACK_NAME}_${WORKER_ID}"
echo ""
echo "Scale worker replicas:"
echo "  docker service scale ${STACK_NAME}_${WORKER_ID}=2"
echo ""
echo "Remove worker:"
echo "  ./remove-worker.sh ${STACK_NAME} ${WORKER_ID}"
echo ""

log_success "Worker ${WORKER_ID} successfully added to cluster!"
