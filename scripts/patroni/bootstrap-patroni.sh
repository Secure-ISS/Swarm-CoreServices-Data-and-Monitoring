#!/bin/bash
# Patroni Cluster Bootstrap Script
# Version: 1.0.0
# Description: Initialize and bootstrap a Patroni HA cluster with etcd

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_DIR="$PROJECT_ROOT/config/patroni"

# Configuration
ETCD_CLUSTER_SIZE=${ETCD_CLUSTER_SIZE:-3}
PATRONI_NODE_COUNT=${PATRONI_NODE_COUNT:-3}
CLUSTER_NAME=${CLUSTER_NAME:-postgres-ha-cluster}

# Logging
LOG_FILE="${LOG_FILE:-/var/log/patroni/bootstrap.log}"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info() {
    log "INFO" "${BLUE}$*${NC}"
}

log_success() {
    log "SUCCESS" "${GREEN}$*${NC}"
}

log_warning() {
    log "WARNING" "${YELLOW}$*${NC}"
}

log_error() {
    log "ERROR" "${RED}$*${NC}"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    local required_commands=("docker" "docker-compose" "etcdctl")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done

    if [ ! -f "$CONFIG_DIR/patroni.yml.template" ]; then
        log_error "Patroni configuration template not found: $CONFIG_DIR/patroni.yml.template"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

# Initialize etcd cluster
initialize_etcd() {
    log_info "Initializing etcd cluster with $ETCD_CLUSTER_SIZE nodes..."

    cd "$PROJECT_ROOT"

    # Generate docker-compose for etcd
    cat > docker-compose.etcd.yml <<EOF
version: '3.8'

services:
EOF

    for i in $(seq 1 $ETCD_CLUSTER_SIZE); do
        local node_name="etcd-$i"
        local client_port=$((2378 + i))
        local peer_port=$((2379 + i))

        cat >> docker-compose.etcd.yml <<EOF
  $node_name:
    image: quay.io/coreos/etcd:v3.5.11
    container_name: $node_name
    command:
      - /usr/local/bin/etcd
      - --name=$node_name
      - --data-dir=/etcd-data
      - --initial-advertise-peer-urls=http://$node_name:$peer_port
      - --listen-peer-urls=http://0.0.0.0:$peer_port
      - --advertise-client-urls=http://$node_name:$client_port
      - --listen-client-urls=http://0.0.0.0:$client_port
      - --initial-cluster=$(for j in $(seq 1 $ETCD_CLUSTER_SIZE); do echo -n "etcd-$j=http://etcd-$j:$((2379 + j))"; [ $j -lt $ETCD_CLUSTER_SIZE ] && echo -n ","; done)
      - --initial-cluster-state=new
      - --initial-cluster-token=etcd-cluster-token
    networks:
      - patroni-net
    volumes:
      - etcd-data-$i:/etcd-data
    healthcheck:
      test: ["CMD", "etcdctl", "endpoint", "health"]
      interval: 10s
      timeout: 5s
      retries: 5

EOF
    done

    cat >> docker-compose.etcd.yml <<EOF
networks:
  patroni-net:
    driver: bridge

volumes:
EOF

    for i in $(seq 1 $ETCD_CLUSTER_SIZE); do
        echo "  etcd-data-$i:" >> docker-compose.etcd.yml
    done

    # Start etcd cluster
    log_info "Starting etcd cluster..."
    docker-compose -f docker-compose.etcd.yml up -d

    # Wait for etcd to be healthy
    log_info "Waiting for etcd cluster to be healthy..."
    local max_attempts=30
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if docker exec etcd-1 etcdctl endpoint health 2>/dev/null | grep -q "is healthy"; then
            log_success "etcd cluster is healthy"
            break
        fi
        log_info "Attempt $attempt/$max_attempts - waiting for etcd..."
        sleep 5
        ((attempt++))
    done

    if [ $attempt -gt $max_attempts ]; then
        log_error "etcd cluster failed to become healthy"
        exit 1
    fi
}

# Generate Patroni configuration for a node
generate_patroni_config() {
    local node_id=$1
    local node_name="patroni-node-$node_id"
    local node_ip="patroni-node-$node_id"
    local config_file="$CONFIG_DIR/patroni-node-$node_id.yml"

    log_info "Generating configuration for $node_name..."

    # Build etcd hosts string
    local etcd_hosts=""
    for i in $(seq 1 $ETCD_CLUSTER_SIZE); do
        etcd_hosts="${etcd_hosts}etcd-$i:$((2378 + i))"
        [ $i -lt $ETCD_CLUSTER_SIZE ] && etcd_hosts="${etcd_hosts},"
    done

    # Generate configuration from template
    export PATRONI_NODE_NAME="$node_name"
    export PATRONI_HOST_IP="$node_ip"
    export ETCD_HOSTS="$etcd_hosts"
    export PATRONI_API_PASSWORD="${PATRONI_API_PASSWORD:-patroni_api_pass}"
    export REPLICATION_PASSWORD="${REPLICATION_PASSWORD:-replication_pass}"
    export ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin_pass}"
    export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres_pass}"

    envsubst < "$CONFIG_DIR/patroni.yml.template" > "$config_file"

    log_success "Configuration generated: $config_file"
}

# Bootstrap first Patroni node
bootstrap_first_node() {
    log_info "Bootstrapping first Patroni node..."

    generate_patroni_config 1

    # Create docker-compose for first node
    cat > docker-compose.patroni-1.yml <<EOF
version: '3.8'

services:
  patroni-node-1:
    image: ruvnet/ruvector-postgres:latest
    container_name: patroni-node-1
    hostname: patroni-node-1
    environment:
      - PATRONI_SCOPE=$CLUSTER_NAME
      - PATRONI_NAME=patroni-node-1
      - PATRONI_POSTGRESQL_DATA_DIR=/var/lib/postgresql/data
      - PATRONI_POSTGRESQL_LISTEN=0.0.0.0:5432
      - PATRONI_RESTAPI_LISTEN=0.0.0.0:8008
    volumes:
      - $CONFIG_DIR/patroni-node-1.yml:/etc/patroni/patroni.yml
      - patroni-data-1:/var/lib/postgresql/data
      - patroni-logs-1:/var/log/postgresql
    networks:
      - patroni-net
    ports:
      - "5432:5432"
      - "8008:8008"
    command: patroni /etc/patroni/patroni.yml

networks:
  patroni-net:
    external: true

volumes:
  patroni-data-1:
  patroni-logs-1:
EOF

    docker-compose -f docker-compose.patroni-1.yml up -d

    # Wait for first node to be ready
    log_info "Waiting for first node to bootstrap..."
    local max_attempts=60
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if docker exec patroni-node-1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -q "Leader"; then
            log_success "First node bootstrapped successfully"
            break
        fi
        log_info "Attempt $attempt/$max_attempts - waiting for bootstrap..."
        sleep 5
        ((attempt++))
    done

    if [ $attempt -gt $max_attempts ]; then
        log_error "First node bootstrap failed"
        exit 1
    fi
}

# Add standby nodes
add_standby_nodes() {
    log_info "Adding standby nodes..."

    for node_id in $(seq 2 $PATRONI_NODE_COUNT); do
        log_info "Adding standby node $node_id..."

        generate_patroni_config $node_id

        # Create docker-compose for standby node
        local port_offset=$((node_id - 1))
        cat > docker-compose.patroni-$node_id.yml <<EOF
version: '3.8'

services:
  patroni-node-$node_id:
    image: ruvnet/ruvector-postgres:latest
    container_name: patroni-node-$node_id
    hostname: patroni-node-$node_id
    environment:
      - PATRONI_SCOPE=$CLUSTER_NAME
      - PATRONI_NAME=patroni-node-$node_id
      - PATRONI_POSTGRESQL_DATA_DIR=/var/lib/postgresql/data
      - PATRONI_POSTGRESQL_LISTEN=0.0.0.0:5432
      - PATRONI_RESTAPI_LISTEN=0.0.0.0:8008
    volumes:
      - $CONFIG_DIR/patroni-node-$node_id.yml:/etc/patroni/patroni.yml
      - patroni-data-$node_id:/var/lib/postgresql/data
      - patroni-logs-$node_id:/var/log/postgresql
    networks:
      - patroni-net
    ports:
      - "$((5432 + port_offset)):5432"
      - "$((8008 + port_offset)):8008"
    command: patroni /etc/patroni/patroni.yml

networks:
  patroni-net:
    external: true

volumes:
  patroni-data-$node_id:
  patroni-logs-$node_id:
EOF

        docker-compose -f docker-compose.patroni-$node_id.yml up -d

        # Wait for node to join
        sleep 10
    done

    log_success "All standby nodes added"
}

# Verify cluster
verify_cluster() {
    log_info "Verifying cluster status..."

    docker exec patroni-node-1 patronictl -c /etc/patroni/patroni.yml list

    log_info "Verifying replication..."
    docker exec patroni-node-1 psql -U postgres -c "SELECT * FROM pg_stat_replication;"

    log_success "Cluster verification complete"
}

# Create initial databases
create_databases() {
    log_info "Creating initial databases..."

    docker exec patroni-node-1 psql -U postgres <<EOF
-- Create project database
CREATE DATABASE distributed_postgres_cluster;
CREATE USER dpg_cluster WITH PASSWORD 'dpg_cluster_2026';
GRANT ALL PRIVILEGES ON DATABASE distributed_postgres_cluster TO dpg_cluster;

-- Create shared knowledge database
CREATE DATABASE claude_flow_shared;
CREATE USER shared_user WITH PASSWORD 'shared_knowledge_2026';
GRANT ALL PRIVILEGES ON DATABASE claude_flow_shared TO shared_user;

-- Enable RuVector extension
\c distributed_postgres_cluster
CREATE EXTENSION IF NOT EXISTS ruvector;

\c claude_flow_shared
CREATE EXTENSION IF NOT EXISTS ruvector;
EOF

    log_success "Initial databases created"
}

# Main execution
main() {
    log_info "Starting Patroni cluster bootstrap..."
    log_info "Cluster name: $CLUSTER_NAME"
    log_info "etcd nodes: $ETCD_CLUSTER_SIZE"
    log_info "Patroni nodes: $PATRONI_NODE_COUNT"

    check_prerequisites
    initialize_etcd
    bootstrap_first_node
    add_standby_nodes
    verify_cluster
    create_databases

    log_success "Patroni cluster bootstrap completed successfully!"
    log_info "You can check cluster status with: docker exec patroni-node-1 patronictl -c /etc/patroni/patroni.yml list"
}

# Run main function
main "$@"
