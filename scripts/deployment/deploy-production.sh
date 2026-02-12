#!/bin/bash
set -euo pipefail

################################################################################
# Production Deployment Automation Script
#
# This script automates the deployment of the Distributed PostgreSQL Cluster
# to a Docker Swarm environment with comprehensive validation and error handling.
#
# Usage: ./deploy-production.sh [--skip-validation] [--rollback]
#
# Prerequisites:
# - Docker Swarm initialized
# - Node labels configured
# - Storage directories created
# - SSL certificates generated
################################################################################

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_FILE="$PROJECT_ROOT/docker/production/docker-compose.yml"
STACK_NAME="postgres-prod"
LOG_FILE="/var/log/postgres-deployment-$(date +%Y%m%d_%H%M%S).log"

# Deployment configuration
SKIP_VALIDATION=false
ROLLBACK_MODE=false
DEPLOYMENT_TIMEOUT=600  # 10 minutes

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-validation)
            SKIP_VALIDATION=true
            shift
            ;;
        --rollback)
            ROLLBACK_MODE=true
            shift
            ;;
        --help)
            echo "Usage: $0 [--skip-validation] [--rollback]"
            echo ""
            echo "Options:"
            echo "  --skip-validation  Skip pre-deployment validation checks"
            echo "  --rollback        Rollback to previous deployment"
            echo "  --help            Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

################################################################################
# Logging Functions
################################################################################

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "$timestamp [$level] $message" | tee -a "$LOG_FILE"
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

################################################################################
# Utility Functions
################################################################################

check_command() {
    local cmd=$1
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Required command not found: $cmd"
        return 1
    fi
    return 0
}

wait_for_service() {
    local service_name=$1
    local timeout=${2:-300}
    local interval=5
    local elapsed=0

    log_info "Waiting for service $service_name to be ready..."

    while [ $elapsed -lt $timeout ]; do
        local replicas=$(docker service ls --filter "name=$service_name" --format "{{.Replicas}}" | head -1)
        if [ -n "$replicas" ]; then
            local running=$(echo "$replicas" | cut -d'/' -f1)
            local desired=$(echo "$replicas" | cut -d'/' -f2)

            if [ "$running" = "$desired" ] && [ "$running" != "0" ]; then
                log_success "Service $service_name is ready ($replicas)"
                return 0
            fi
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log_error "Service $service_name did not become ready within $timeout seconds"
    return 1
}

check_service_health() {
    local service_name=$1
    local container_id=$(docker ps -q -f "name=$service_name" | head -1)

    if [ -z "$container_id" ]; then
        log_error "No container found for service $service_name"
        return 1
    fi

    local health=$(docker inspect --format='{{.State.Health.Status}}' "$container_id" 2>/dev/null || echo "unknown")

    if [ "$health" = "healthy" ]; then
        log_success "Service $service_name is healthy"
        return 0
    else
        log_warning "Service $service_name health status: $health"
        return 1
    fi
}

################################################################################
# Validation Functions
################################################################################

validate_docker_swarm() {
    log_info "Validating Docker Swarm..."

    if ! docker info --format '{{.Swarm.LocalNodeState}}' | grep -q "active"; then
        log_error "Docker Swarm is not initialized"
        log_info "Run: docker swarm init"
        return 1
    fi

    local manager_count=$(docker node ls --filter "role=manager" --format "{{.Hostname}}" | wc -l)
    if [ "$manager_count" -lt 3 ]; then
        log_warning "Less than 3 manager nodes detected ($manager_count). Recommended: 3+"
    fi

    local worker_count=$(docker node ls --filter "role=worker" --format "{{.Hostname}}" | wc -l)
    if [ "$worker_count" -lt 3 ]; then
        log_warning "Less than 3 worker nodes detected ($worker_count). Recommended: 3+"
    fi

    log_success "Docker Swarm validation passed"
    return 0
}

validate_node_labels() {
    log_info "Validating node labels..."

    local required_labels=(
        "postgres.etcd=etcd-1"
        "postgres.etcd=etcd-2"
        "postgres.etcd=etcd-3"
        "postgres.role=patroni"
        "postgres.patroni-id=1"
        "postgres.patroni-id=2"
        "postgres.patroni-id=3"
    )

    for label in "${required_labels[@]}"; do
        local count=$(docker node ls --filter "node.label=$label" --format "{{.Hostname}}" | wc -l)
        if [ "$count" -eq 0 ]; then
            log_error "No nodes found with label: $label"
            log_info "Run: docker node update --label-add $label <node-name>"
            return 1
        fi
    done

    log_success "Node labels validation passed"
    return 0
}

validate_storage() {
    log_info "Validating storage directories..."

    local required_dirs=(
        "/mnt/postgres-cluster/patroni-1"
        "/mnt/postgres-cluster/patroni-2"
        "/mnt/postgres-cluster/patroni-3"
        "/mnt/postgres-cluster/etcd-1"
        "/mnt/postgres-cluster/etcd-2"
        "/mnt/postgres-cluster/etcd-3"
        "/mnt/postgres-cluster/backups"
        "/mnt/postgres-cluster/archives"
    )

    for dir in "${required_dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            log_error "Required directory not found: $dir"
            log_info "Run: mkdir -p $dir && chown -R 999:999 $dir && chmod 700 $dir"
            return 1
        fi

        # Check write permissions
        if [ ! -w "$dir" ]; then
            log_error "Directory not writable: $dir"
            return 1
        fi

        # Check available space (require at least 50GB)
        local available=$(df -BG "$dir" | awk 'NR==2 {print $4}' | sed 's/G//')
        if [ "$available" -lt 50 ]; then
            log_warning "Low disk space in $dir: ${available}GB available (recommended: 50GB+)"
        fi
    done

    log_success "Storage validation passed"
    return 0
}

validate_secrets() {
    log_info "Validating Docker secrets..."

    local required_secrets=(
        "postgres_password"
        "replication_password"
        "redis_password"
        "grafana_admin_password"
        "postgres_ssl_cert"
        "postgres_ssl_key"
        "postgres_ssl_ca"
    )

    for secret in "${required_secrets[@]}"; do
        if ! docker secret ls --format "{{.Name}}" | grep -q "^${secret}$"; then
            log_error "Required secret not found: $secret"
            log_info "Run: scripts/deployment/create-secrets.sh"
            return 1
        fi
    done

    log_success "Secrets validation passed"
    return 0
}

validate_compose_file() {
    log_info "Validating Docker Compose file..."

    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "Compose file not found: $COMPOSE_FILE"
        return 1
    fi

    if ! docker-compose -f "$COMPOSE_FILE" config > /dev/null 2>&1; then
        log_error "Invalid Docker Compose file"
        return 1
    fi

    log_success "Compose file validation passed"
    return 0
}

validate_prerequisites() {
    log_info "Starting pre-deployment validation..."

    local validation_failed=false

    check_command docker || validation_failed=true
    check_command docker-compose || validation_failed=true
    check_command jq || validation_failed=true
    check_command curl || validation_failed=true

    validate_docker_swarm || validation_failed=true
    validate_node_labels || validation_failed=true
    validate_storage || validation_failed=true
    validate_secrets || validation_failed=true
    validate_compose_file || validation_failed=true

    if [ "$validation_failed" = true ]; then
        log_error "Pre-deployment validation failed"
        return 1
    fi

    log_success "All pre-deployment validations passed"
    return 0
}

################################################################################
# Deployment Functions
################################################################################

backup_current_state() {
    log_info "Backing up current deployment state..."

    local backup_dir="/var/backups/postgres-deployment"
    local backup_timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="$backup_dir/state-$backup_timestamp.tar.gz"

    mkdir -p "$backup_dir"

    # Save current stack configuration
    if docker stack ls | grep -q "$STACK_NAME"; then
        docker stack ps "$STACK_NAME" --format json > "$backup_dir/stack-ps-$backup_timestamp.json"
        docker service ls --filter "label=com.distributed-postgres.cluster=main" --format json > "$backup_dir/services-$backup_timestamp.json"

        # Create tarball
        tar -czf "$backup_path" -C "$backup_dir" \
            "stack-ps-$backup_timestamp.json" \
            "services-$backup_timestamp.json"

        log_success "Deployment state backed up to: $backup_path"
    else
        log_warning "No existing stack found to backup"
    fi
}

deploy_stack() {
    log_info "Deploying stack: $STACK_NAME"

    if ! docker stack deploy -c "$COMPOSE_FILE" "$STACK_NAME"; then
        log_error "Stack deployment failed"
        return 1
    fi

    log_success "Stack deployment initiated"
    return 0
}

wait_for_deployment() {
    log_info "Waiting for deployment to complete..."

    # Wait for critical services in order
    local services=(
        "${STACK_NAME}_etcd-1"
        "${STACK_NAME}_etcd-2"
        "${STACK_NAME}_etcd-3"
        "${STACK_NAME}_patroni-1"
        "${STACK_NAME}_patroni-2"
        "${STACK_NAME}_patroni-3"
        "${STACK_NAME}_haproxy"
        "${STACK_NAME}_pgbouncer"
        "${STACK_NAME}_redis-master"
    )

    for service in "${services[@]}"; do
        if ! wait_for_service "$service" 300; then
            log_error "Service $service failed to start"
            return 1
        fi
    done

    log_success "All critical services are running"
    return 0
}

verify_etcd_cluster() {
    log_info "Verifying etcd cluster health..."

    local etcd_container=$(docker ps -q -f "name=${STACK_NAME}_etcd-1" | head -1)

    if [ -z "$etcd_container" ]; then
        log_error "etcd container not found"
        return 1
    fi

    # Check cluster health
    if docker exec "$etcd_container" etcdctl endpoint health --cluster 2>&1 | grep -q "is healthy"; then
        log_success "etcd cluster is healthy"
        return 0
    else
        log_error "etcd cluster health check failed"
        return 1
    fi
}

verify_patroni_cluster() {
    log_info "Verifying Patroni cluster health..."

    local patroni_container=$(docker ps -q -f "name=${STACK_NAME}_patroni-1" | head -1)

    if [ -z "$patroni_container" ]; then
        log_error "Patroni container not found"
        return 1
    fi

    # Get cluster status via Patroni API
    local cluster_info=$(docker exec "$patroni_container" curl -s http://localhost:8008/cluster)

    if [ -z "$cluster_info" ]; then
        log_error "Failed to retrieve Patroni cluster information"
        return 1
    fi

    # Check for leader
    if echo "$cluster_info" | jq -e '.members[] | select(.role == "leader")' > /dev/null; then
        local leader=$(echo "$cluster_info" | jq -r '.members[] | select(.role == "leader") | .name')
        log_success "Patroni cluster has leader: $leader"
    else
        log_error "No Patroni leader found"
        return 1
    fi

    # Verify replication
    local member_count=$(echo "$cluster_info" | jq '.members | length')
    if [ "$member_count" -ge 3 ]; then
        log_success "Patroni cluster has $member_count members"
    else
        log_warning "Patroni cluster has only $member_count members (expected 3)"
    fi

    return 0
}

verify_postgres_connectivity() {
    log_info "Verifying PostgreSQL connectivity..."

    local max_attempts=10
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if docker run --rm --network ${STACK_NAME}_app-net \
            ruvnet/ruvector-postgres:latest \
            pg_isready -h haproxy -p 5432 -U postgres > /dev/null 2>&1; then
            log_success "PostgreSQL is accepting connections"
            return 0
        fi

        attempt=$((attempt + 1))
        log_info "Waiting for PostgreSQL... (attempt $attempt/$max_attempts)"
        sleep 5
    done

    log_error "PostgreSQL connectivity check failed"
    return 1
}

verify_haproxy() {
    log_info "Verifying HAProxy health..."

    local haproxy_container=$(docker ps -q -f "name=${STACK_NAME}_haproxy" | head -1)

    if [ -z "$haproxy_container" ]; then
        log_error "HAProxy container not found"
        return 1
    fi

    # Check HAProxy stats
    if docker exec "$haproxy_container" nc -z localhost 5432; then
        log_success "HAProxy is healthy"
        return 0
    else
        log_error "HAProxy health check failed"
        return 1
    fi
}

verify_monitoring() {
    log_info "Verifying monitoring stack..."

    # Check Prometheus
    local prometheus_container=$(docker ps -q -f "name=${STACK_NAME}_prometheus" | head -1)
    if [ -n "$prometheus_container" ]; then
        if docker exec "$prometheus_container" wget -q --spider http://localhost:9090/-/healthy; then
            log_success "Prometheus is healthy"
        else
            log_warning "Prometheus health check failed"
        fi
    else
        log_warning "Prometheus container not found"
    fi

    # Check Grafana
    local grafana_container=$(docker ps -q -f "name=${STACK_NAME}_grafana" | head -1)
    if [ -n "$grafana_container" ]; then
        if docker exec "$grafana_container" wget -q --spider http://localhost:3000/api/health; then
            log_success "Grafana is healthy"
        else
            log_warning "Grafana health check failed"
        fi
    else
        log_warning "Grafana container not found"
    fi
}

verify_deployment() {
    log_info "Verifying deployment..."

    local verification_failed=false

    verify_etcd_cluster || verification_failed=true
    verify_patroni_cluster || verification_failed=true
    verify_postgres_connectivity || verification_failed=true
    verify_haproxy || verification_failed=true
    verify_monitoring || verification_failed=true

    if [ "$verification_failed" = true ]; then
        log_error "Deployment verification failed"
        return 1
    fi

    log_success "All deployment verifications passed"
    return 0
}

################################################################################
# Rollback Functions
################################################################################

rollback_deployment() {
    log_warning "Rolling back deployment..."

    # Get previous deployment backup
    local backup_dir="/var/backups/postgres-deployment"
    local latest_backup=$(ls -t "$backup_dir"/state-*.tar.gz 2>/dev/null | head -1)

    if [ -z "$latest_backup" ]; then
        log_error "No backup found for rollback"
        return 1
    fi

    log_info "Rolling back to backup: $latest_backup"

    # Remove current deployment
    if docker stack ls | grep -q "$STACK_NAME"; then
        docker stack rm "$STACK_NAME"
        log_info "Waiting for stack removal..."
        sleep 30
    fi

    # Restore from backup would go here
    # For now, just log the rollback action
    log_warning "Manual rollback required - restore from backup: $latest_backup"

    return 1
}

################################################################################
# Main Deployment Flow
################################################################################

main() {
    log_info "=========================================="
    log_info "Production Deployment Script"
    log_info "Stack: $STACK_NAME"
    log_info "Compose File: $COMPOSE_FILE"
    log_info "=========================================="

    # Handle rollback mode
    if [ "$ROLLBACK_MODE" = true ]; then
        rollback_deployment
        exit $?
    fi

    # Validation phase
    if [ "$SKIP_VALIDATION" = false ]; then
        if ! validate_prerequisites; then
            log_error "Validation failed. Use --skip-validation to bypass (not recommended)"
            exit 1
        fi
    else
        log_warning "Skipping validation checks (--skip-validation)"
    fi

    # Backup current state
    backup_current_state

    # Deploy stack
    if ! deploy_stack; then
        log_error "Deployment failed"
        exit 1
    fi

    # Wait for services to start
    if ! wait_for_deployment; then
        log_error "Deployment timeout or failure"
        log_warning "Consider rolling back with: $0 --rollback"
        exit 1
    fi

    # Verify deployment
    if ! verify_deployment; then
        log_error "Deployment verification failed"
        log_warning "Consider rolling back with: $0 --rollback"
        exit 1
    fi

    # Success!
    log_success "=========================================="
    log_success "Deployment completed successfully!"
    log_success "=========================================="
    log_info ""
    log_info "Access Points:"
    log_info "  PostgreSQL (read-write): haproxy:5432"
    log_info "  PostgreSQL (read-only):  haproxy:5433"
    log_info "  PgBouncer:               pgbouncer:6432"
    log_info "  Redis:                   redis-master:6379"
    log_info "  HAProxy Stats:           http://manager:7000"
    log_info "  Prometheus:              http://manager:9090"
    log_info "  Grafana:                 http://manager:3001"
    log_info ""
    log_info "Next Steps:"
    log_info "  1. Initialize databases and extensions"
    log_info "  2. Configure application connection strings"
    log_info "  3. Set up monitoring alerts"
    log_info "  4. Schedule disaster recovery drills"
    log_info ""
    log_info "Monitoring:"
    log_info "  docker stack ps $STACK_NAME"
    log_info "  docker service ls"
    log_info "  docker service logs ${STACK_NAME}_patroni-1"
    log_info ""
    log_info "Logs saved to: $LOG_FILE"

    exit 0
}

# Trap errors
trap 'log_error "Deployment failed with error on line $LINENO"' ERR

# Run main function
main
