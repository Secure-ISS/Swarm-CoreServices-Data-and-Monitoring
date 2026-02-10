#!/bin/bash
# Initialize Docker Swarm PostgreSQL Mesh Cluster
# Usage: ./initialize-cluster.sh [stack_name] [worker_count]

set -euo pipefail

# Configuration
STACK_NAME="${1:-postgres-mesh}"
WORKER_COUNT="${2:-3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../../deployment/docker-swarm" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        exit 1
    fi

    # Check Docker Swarm
    if ! docker info --format '{{.Swarm.LocalNodeState}}' | grep -q "active"; then
        log_warning "Docker Swarm is not initialized. Initializing..."
        docker swarm init --advertise-addr $(hostname -I | awk '{print $1}')
    fi

    log_success "Prerequisites check passed"
}

# Create Docker secrets
create_secrets() {
    log_info "Creating Docker secrets..."

    # Generate random passwords
    POSTGRES_PASSWORD=$(openssl rand -base64 32)
    REPLICATION_PASSWORD=$(openssl rand -base64 32)
    PGBOUNCER_PASSWORD=$(openssl rand -base64 32)

    # Create secrets if they don't exist
    if ! docker secret ls | grep -q postgres_password; then
        echo "$POSTGRES_PASSWORD" | docker secret create postgres_password -
        log_success "Created postgres_password secret"
    else
        log_info "postgres_password secret already exists"
    fi

    if ! docker secret ls | grep -q replication_password; then
        echo "$REPLICATION_PASSWORD" | docker secret create replication_password -
        log_success "Created replication_password secret"
    else
        log_info "replication_password secret already exists"
    fi

    if ! docker secret ls | grep -q pgbouncer_auth; then
        echo "\"dpg_cluster\" \"md5$(echo -n "${PGBOUNCER_PASSWORD}dpg_cluster" | md5sum | awk '{print $1}')\"" | \
            docker secret create pgbouncer_auth -
        log_success "Created pgbouncer_auth secret"
    else
        log_info "pgbouncer_auth secret already exists"
    fi

    # Save passwords to secure file (for reference)
    cat > "${DEPLOY_DIR}/.secrets" <<EOF
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
REPLICATION_PASSWORD=${REPLICATION_PASSWORD}
PGBOUNCER_PASSWORD=${PGBOUNCER_PASSWORD}
EOF
    chmod 600 "${DEPLOY_DIR}/.secrets"
    log_success "Secrets saved to ${DEPLOY_DIR}/.secrets (keep this file secure!)"
}

# Label nodes for placement
label_nodes() {
    log_info "Labeling nodes for service placement..."

    # Get manager node
    MANAGER_NODE=$(docker node ls --filter role=manager -q | head -n 1)
    docker node update --label-add postgres.role=coordinator "$MANAGER_NODE"
    log_success "Labeled manager node as coordinator"

    # Label worker nodes
    WORKER_NODES=($(docker node ls --filter role=worker -q))
    for node in "${WORKER_NODES[@]}"; do
        docker node update --label-add postgres.role=worker "$node"
    done
    log_success "Labeled ${#WORKER_NODES[@]} worker nodes"
}

# Create necessary directories
create_directories() {
    log_info "Creating necessary directories..."

    mkdir -p "${DEPLOY_DIR}/init-scripts"
    mkdir -p "${DEPLOY_DIR}/scripts"
    mkdir -p "${DEPLOY_DIR}/logs"
    mkdir -p "${DEPLOY_DIR}/backups"

    log_success "Directories created"
}

# Copy initialization scripts
copy_init_scripts() {
    log_info "Copying initialization scripts..."

    # Copy RuVector init script
    if [ -f "${SCRIPT_DIR}/../sql/init-ruvector.sql" ]; then
        cp "${SCRIPT_DIR}/../sql/init-ruvector.sql" "${DEPLOY_DIR}/init-scripts/"
        log_success "Copied init-ruvector.sql"
    fi

    # Copy Python scripts
    for script in health-monitor.py; do
        if [ -f "${SCRIPT_DIR}/${script}" ]; then
            cp "${SCRIPT_DIR}/${script}" "${DEPLOY_DIR}/scripts/"
            chmod +x "${DEPLOY_DIR}/scripts/${script}"
        fi
    done

    log_success "Initialization scripts copied"
}

# Create Docker configs
create_configs() {
    log_info "Creating Docker configs..."

    # Remove existing configs if they exist
    docker config rm coordinator_config 2>/dev/null || true
    docker config rm worker_config 2>/dev/null || true
    docker config rm pgbouncer_config 2>/dev/null || true

    # Create new configs
    docker config create coordinator_config "${DEPLOY_DIR}/configs/coordinator.conf"
    docker config create worker_config "${DEPLOY_DIR}/configs/worker.conf"
    docker config create pgbouncer_config "${DEPLOY_DIR}/configs/pgbouncer.ini"

    log_success "Docker configs created"
}

# Deploy the stack
deploy_stack() {
    log_info "Deploying PostgreSQL mesh stack: ${STACK_NAME}..."

    cd "${DEPLOY_DIR}"
    docker stack deploy -c stack.yml "${STACK_NAME}"

    log_success "Stack deployed: ${STACK_NAME}"
}

# Wait for services to be ready
wait_for_services() {
    log_info "Waiting for services to be ready (this may take a few minutes)..."

    local max_wait=300  # 5 minutes
    local elapsed=0

    while [ $elapsed -lt $max_wait ]; do
        local ready_services=$(docker stack services "${STACK_NAME}" --filter "desired-state=running" --format "{{.Replicas}}" | grep -c "^[1-9]")
        local total_services=$(docker stack services "${STACK_NAME}" --format "{{.Name}}" | wc -l)

        if [ "$ready_services" -eq "$total_services" ]; then
            log_success "All services are ready!"
            return 0
        fi

        log_info "Services ready: ${ready_services}/${total_services}"
        sleep 10
        elapsed=$((elapsed + 10))
    done

    log_warning "Timeout waiting for services. Check status manually with: docker stack services ${STACK_NAME}"
}

# Verify cluster health
verify_cluster() {
    log_info "Verifying cluster health..."

    # Wait a bit for services to stabilize
    sleep 20

    # Check coordinator
    log_info "Checking coordinator..."
    COORDINATOR_TASK=$(docker service ps "${STACK_NAME}_coordinator" --filter "desired-state=running" -q | head -n 1)
    if [ -n "$COORDINATOR_TASK" ]; then
        COORDINATOR_NODE=$(docker inspect --format '{{.NodeID}}' "$COORDINATOR_TASK")
        log_success "Coordinator is running on node: $COORDINATOR_NODE"
    else
        log_error "Coordinator is not running!"
    fi

    # Check workers
    log_info "Checking workers..."
    for i in $(seq 1 "$WORKER_COUNT"); do
        WORKER_REPLICAS=$(docker service ls --filter "name=${STACK_NAME}_worker-${i}" --format "{{.Replicas}}")
        log_info "Worker-${i}: ${WORKER_REPLICAS}"
    done

    # Check pooler
    log_info "Checking connection pooler..."
    POOLER_REPLICAS=$(docker service ls --filter "name=${STACK_NAME}_pgbouncer" --format "{{.Replicas}}")
    log_info "PgBouncer: ${POOLER_REPLICAS}"

    log_success "Cluster verification complete"
}

# Display connection information
display_connection_info() {
    log_info "=== Connection Information ==="
    echo ""
    echo "PostgreSQL Coordinator (Direct):"
    echo "  Host: localhost"
    echo "  Port: 5432"
    echo "  Database: distributed_postgres_cluster"
    echo "  User: dpg_cluster"
    echo ""
    echo "PgBouncer (Connection Pool):"
    echo "  Host: localhost"
    echo "  Port: 6432"
    echo "  Database: distributed_postgres_cluster"
    echo "  User: dpg_cluster"
    echo ""
    echo "Passwords are stored in: ${DEPLOY_DIR}/.secrets"
    echo ""
    log_info "=== Useful Commands ==="
    echo ""
    echo "View stack services:"
    echo "  docker stack services ${STACK_NAME}"
    echo ""
    echo "View service logs:"
    echo "  docker service logs ${STACK_NAME}_coordinator"
    echo "  docker service logs ${STACK_NAME}_worker-1"
    echo "  docker service logs ${STACK_NAME}_pgbouncer"
    echo ""
    echo "Scale workers:"
    echo "  docker service scale ${STACK_NAME}_worker-1=2"
    echo ""
    echo "Remove stack:"
    echo "  docker stack rm ${STACK_NAME}"
    echo ""
}

# Main execution
main() {
    log_info "Starting PostgreSQL Mesh Cluster Initialization..."
    log_info "Stack Name: ${STACK_NAME}"
    log_info "Worker Count: ${WORKER_COUNT}"
    echo ""

    check_prerequisites
    create_directories
    create_secrets
    label_nodes
    copy_init_scripts
    create_configs
    deploy_stack
    wait_for_services
    verify_cluster
    display_connection_info

    log_success "Cluster initialization complete!"
}

# Run main function
main "$@"
