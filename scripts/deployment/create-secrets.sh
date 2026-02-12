#!/bin/bash
set -euo pipefail

################################################################################
# Docker Secrets Creation Script
#
# This script generates secure passwords and creates Docker secrets required
# for the production PostgreSQL deployment.
#
# Usage: ./create-secrets.sh
################################################################################

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

generate_password() {
    openssl rand -base64 32 | tr -d '/+=' | cut -c1-32
}

create_secret() {
    local secret_name=$1
    local secret_value=$2

    # Check if secret already exists
    if docker secret ls --format "{{.Name}}" | grep -q "^${secret_name}$"; then
        log_warning "Secret $secret_name already exists - skipping"
        return 0
    fi

    # Create secret
    if echo "$secret_value" | docker secret create "$secret_name" - > /dev/null 2>&1; then
        log_success "Created secret: $secret_name"
        return 0
    else
        log_error "Failed to create secret: $secret_name"
        return 1
    fi
}

create_file_secret() {
    local secret_name=$1
    local file_path=$2

    if [ ! -f "$file_path" ]; then
        log_error "File not found: $file_path"
        return 1
    fi

    # Check if secret already exists
    if docker secret ls --format "{{.Name}}" | grep -q "^${secret_name}$"; then
        log_warning "Secret $secret_name already exists - skipping"
        return 0
    fi

    # Create secret from file
    if docker secret create "$secret_name" "$file_path" > /dev/null 2>&1; then
        log_success "Created secret: $secret_name (from file)"
        return 0
    else
        log_error "Failed to create secret: $secret_name"
        return 1
    fi
}

main() {
    log_info "=========================================="
    log_info "Docker Secrets Creation"
    log_info "=========================================="

    # Check if Docker Swarm is initialized
    if ! docker info --format '{{.Swarm.LocalNodeState}}' | grep -q "active"; then
        log_error "Docker Swarm is not initialized"
        log_info "Run: docker swarm init"
        exit 1
    fi

    log_info "Generating secure passwords..."

    # Generate passwords
    POSTGRES_PASSWORD=$(generate_password)
    REPLICATION_PASSWORD=$(generate_password)
    POSTGRES_MCP_PASSWORD=$(generate_password)
    REDIS_PASSWORD=$(generate_password)
    GRAFANA_ADMIN_PASSWORD=$(generate_password)

    log_info "Creating password secrets..."

    # Create password secrets
    create_secret "postgres_password" "$POSTGRES_PASSWORD"
    create_secret "replication_password" "$REPLICATION_PASSWORD"
    create_secret "postgres_mcp_password" "$POSTGRES_MCP_PASSWORD"
    create_secret "redis_password" "$REDIS_PASSWORD"
    create_secret "grafana_admin_password" "$GRAFANA_ADMIN_PASSWORD"

    # SSL certificates
    log_info "Creating SSL certificate secrets..."

    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(cd "$script_dir/../.." && pwd)"
    local ssl_dir="$project_root/config/security/ssl"

    # Check if SSL certificates exist
    if [ -f "$ssl_dir/server-cert.pem" ]; then
        create_file_secret "postgres_ssl_cert" "$ssl_dir/server-cert.pem"
        create_file_secret "postgres_ssl_key" "$ssl_dir/server-key.pem"
        create_file_secret "postgres_ssl_ca" "$ssl_dir/ca-cert.pem"
    else
        log_warning "SSL certificates not found in $ssl_dir"
        log_info "Generating SSL certificates..."

        # Generate SSL certificates
        mkdir -p "$ssl_dir"
        cd "$ssl_dir"

        # Generate CA certificate
        if [ ! -f "ca-key.pem" ]; then
            openssl genrsa -out ca-key.pem 4096
            openssl req -new -x509 -days 3650 -key ca-key.pem -out ca-cert.pem \
                -subj "/CN=PostgreSQL-CA/O=Distributed-PostgreSQL-Cluster/C=US"
        fi

        # Generate server certificate
        if [ ! -f "server-key.pem" ]; then
            openssl genrsa -out server-key.pem 4096
            openssl req -new -key server-key.pem -out server-req.pem \
                -subj "/CN=*.postgres-prod/O=Distributed-PostgreSQL-Cluster/C=US"
            openssl x509 -req -days 365 -in server-req.pem \
                -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial \
                -out server-cert.pem
            rm server-req.pem
        fi

        # Generate client certificate
        if [ ! -f "client-key.pem" ]; then
            openssl genrsa -out client-key.pem 4096
            openssl req -new -key client-key.pem -out client-req.pem \
                -subj "/CN=postgres/O=Distributed-PostgreSQL-Cluster/C=US"
            openssl x509 -req -days 365 -in client-req.pem \
                -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial \
                -out client-cert.pem
            rm client-req.pem
        fi

        # Set permissions
        chmod 600 *-key.pem
        chmod 644 *-cert.pem

        log_success "SSL certificates generated in: $ssl_dir"

        # Create secrets
        create_file_secret "postgres_ssl_cert" "$ssl_dir/server-cert.pem"
        create_file_secret "postgres_ssl_key" "$ssl_dir/server-key.pem"
        create_file_secret "postgres_ssl_ca" "$ssl_dir/ca-cert.pem"
    fi

    # Save passwords to secure file
    local password_file="$project_root/config/security/.passwords"
    log_info "Saving passwords to: $password_file"

    cat > "$password_file" <<EOF
# PostgreSQL Production Passwords
# Generated: $(date)
# WARNING: Keep this file secure and do not commit to version control

POSTGRES_PASSWORD=$POSTGRES_PASSWORD
REPLICATION_PASSWORD=$REPLICATION_PASSWORD
POSTGRES_MCP_PASSWORD=$POSTGRES_MCP_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD
GRAFANA_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD

# Access Information:
# PostgreSQL: psql -h haproxy -U postgres -d distributed_postgres_cluster
# PgBouncer: psql -h pgbouncer -p 6432 -U postgres -d distributed_postgres_cluster
# Redis: redis-cli -h redis-master -a \$REDIS_PASSWORD
# Grafana: http://manager:3001 (admin / \$GRAFANA_ADMIN_PASSWORD)
EOF

    chmod 600 "$password_file"

    # Summary
    log_success "=========================================="
    log_success "Secrets Created Successfully!"
    log_success "=========================================="
    log_info ""
    log_info "Created secrets:"
    log_info "  - postgres_password"
    log_info "  - replication_password"
    log_info "  - postgres_mcp_password"
    log_info "  - redis_password"
    log_info "  - grafana_admin_password"
    log_info "  - postgres_ssl_cert"
    log_info "  - postgres_ssl_key"
    log_info "  - postgres_ssl_ca"
    log_info ""
    log_info "Passwords saved to: $password_file"
    log_info "SSL certificates saved to: $ssl_dir"
    log_info ""
    log_warning "IMPORTANT:"
    log_warning "  1. Keep $password_file secure"
    log_warning "  2. Add to .gitignore if not already"
    log_warning "  3. Consider using a password manager"
    log_warning "  4. Rotate passwords regularly"
    log_info ""
    log_info "Verify secrets:"
    log_info "  docker secret ls"
    log_info ""
    log_info "Next step:"
    log_info "  ./scripts/deployment/deploy-production.sh"
}

main
