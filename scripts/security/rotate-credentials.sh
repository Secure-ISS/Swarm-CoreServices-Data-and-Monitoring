#!/bin/bash
#
# Credential Rotation Script
# ===========================
# Automates password rotation for PostgreSQL users
# Schedule: Run every 90 days (quarterly)
#
# Usage: ./rotate-credentials.sh [--dry-run]
#

set -euo pipefail

# Configuration
POSTGRES_HOST="${POSTGRES_HOST:-pg-coordinator}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-distributed_postgres_cluster}"
ADMIN_USER="${ADMIN_USER:-cluster_admin}"
LOG_FILE="/var/log/credential-rotation.log"

# Users to rotate (exclude postgres superuser)
USERS_TO_ROTATE=(
    "dpg_cluster"
    "replicator"
    "app_writer"
    "app_reader"
    "backup_agent"
    "monitor"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Logging functions
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

# Generate strong password
generate_password() {
    # 24-character password with upper, lower, digits, special chars
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-24
}

# Rotate password for a single user
rotate_user_password() {
    local username=$1
    local dry_run=$2

    log_info "Rotating password for user: $username"

    # Generate new password
    local new_password
    new_password=$(generate_password)

    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY RUN] Would rotate password for $username"
        return 0
    fi

    # Update password in PostgreSQL
    PGPASSWORD="$ADMIN_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
        -U "$ADMIN_USER" -d "$POSTGRES_DB" -c \
        "ALTER USER $username WITH PASSWORD '$new_password';" 2>&1 | tee -a "$LOG_FILE"

    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        log_info "Password updated in PostgreSQL"

        # Update Docker secret (if using Docker Swarm)
        if docker info 2>/dev/null | grep -q "Swarm: active"; then
            log_info "Updating Docker secret: ${username}_password"

            # Remove old secret
            docker secret rm "${username}_password" 2>/dev/null || true

            # Create new secret
            echo "$new_password" | docker secret create "${username}_password" -

            # Update services using this secret
            for service in $(docker service ls --format '{{.Name}}'); do
                if docker service inspect "$service" 2>/dev/null | grep -q "${username}_password"; then
                    log_info "Updating service: $service"
                    docker service update --secret-rm "${username}_password" "$service"
                    docker service update --secret-add "${username}_password" "$service"
                fi
            done

            log_info "Docker secrets updated"
        fi

        # Store in secure vault (optional - integrate with HashiCorp Vault, AWS Secrets Manager, etc.)
        # store_in_vault "$username" "$new_password"

        # Send notification (optional - integrate with Slack, email, etc.)
        # send_notification "Password rotated for $username"

        log_info "Password rotation complete for $username"
        return 0
    else
        log_error "Failed to rotate password for $username"
        return 1
    fi
}

# Main rotation logic
main() {
    local dry_run=false

    # Parse arguments
    if [[ "$*" == *"--dry-run"* ]]; then
        dry_run=true
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    log_info "========================================="
    log_info "Starting credential rotation"
    log_info "========================================="

    # Check if admin password is set
    if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
        log_error "ADMIN_PASSWORD environment variable not set"
        log_error "Set it with: export ADMIN_PASSWORD='your_admin_password'"
        exit 1
    fi

    # Test database connection
    log_info "Testing database connection..."
    if ! PGPASSWORD="$ADMIN_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
        -U "$ADMIN_USER" -d "$POSTGRES_DB" -c "SELECT 1;" > /dev/null 2>&1; then
        log_error "Cannot connect to PostgreSQL"
        exit 1
    fi
    log_info "Database connection successful"

    # Rotate passwords for each user
    local success_count=0
    local failure_count=0

    for user in "${USERS_TO_ROTATE[@]}"; do
        if rotate_user_password "$user" "$dry_run"; then
            ((success_count++))
        else
            ((failure_count++))
        fi
        echo ""
    done

    # Summary
    log_info "========================================="
    log_info "Credential rotation complete"
    log_info "Successful: $success_count"
    log_info "Failed: $failure_count"
    log_info "========================================="

    # Force clients to reconnect (optional)
    if [[ "$dry_run" == "false" ]] && [[ "$failure_count" -eq 0 ]]; then
        log_warn "Terminating existing connections to force credential refresh..."
        PGPASSWORD="$ADMIN_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
            -U "$ADMIN_USER" -d "$POSTGRES_DB" -c \
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename != 'postgres';" \
            2>&1 | tee -a "$LOG_FILE"
    fi

    # Exit with failure if any rotation failed
    if [[ "$failure_count" -gt 0 ]]; then
        exit 1
    fi
}

# Trap errors
trap 'log_error "Script failed on line $LINENO"' ERR

# Run main function
main "$@"
