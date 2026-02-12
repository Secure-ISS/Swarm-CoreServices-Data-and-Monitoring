#!/bin/bash
# Security Hardening Script for Distributed PostgreSQL Cluster
# Implements CIS PostgreSQL Benchmark and security best practices
# Version: 1.0.0

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration
PGDATA="${PGDATA:-/var/lib/postgresql/data}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
SSL_DIR="${SSL_DIR:-/etc/postgresql/ssl}"
AUDIT_LOG_DIR="${AUDIT_LOG_DIR:-/var/log/postgresql/audit}"
BACKUP_DIR="/tmp/pg_backup_$(date +%Y%m%d_%H%M%S)"

# Ensure running as postgres user or root
if [[ $EUID -ne 0 ]] && [[ "$(whoami)" != "postgres" ]]; then
    log_error "This script must be run as root or postgres user"
    exit 1
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"
log_info "Backup directory: $BACKUP_DIR"

# Function to backup configuration file
backup_config() {
    local file=$1
    if [[ -f "$file" ]]; then
        cp "$file" "$BACKUP_DIR/$(basename "$file").backup"
        log_success "Backed up $file"
    fi
}

# Function to execute SQL safely
execute_sql() {
    local sql=$1
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -c "$sql" || {
        log_error "Failed to execute: $sql"
        return 1
    }
}

# ============================================================================
# CIS Benchmark Section 1: Installation and Patches
# ============================================================================

section_1_installation() {
    log_info "=== Section 1: Installation and Patches ==="

    # 1.1 Ensure latest PostgreSQL version is used
    log_info "Checking PostgreSQL version..."
    PG_VERSION=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -t -c "SELECT version();" | head -n1)
    log_info "Current version: $PG_VERSION"

    # 1.2 Ensure systemd service files are secured (if using systemd)
    if command -v systemctl &> /dev/null; then
        log_info "Checking systemd service file permissions..."
        SERVICE_FILE="/etc/systemd/system/postgresql*.service"
        if ls $SERVICE_FILE 2>/dev/null; then
            chmod 644 $SERVICE_FILE
            log_success "Service file permissions set to 644"
        fi
    fi
}

# ============================================================================
# CIS Benchmark Section 2: Directory and File Permissions
# ============================================================================

section_2_file_permissions() {
    log_info "=== Section 2: Directory and File Permissions ==="

    # 2.1 Ensure PGDATA directory has appropriate permissions (700)
    log_info "Setting PGDATA directory permissions..."
    if [[ -d "$PGDATA" ]]; then
        chmod 700 "$PGDATA"
        chown postgres:postgres "$PGDATA"
        log_success "PGDATA permissions set to 700"
    else
        log_error "PGDATA directory not found: $PGDATA"
    fi

    # 2.2 Ensure configuration files have appropriate permissions
    for file in postgresql.conf pg_hba.conf pg_ident.conf; do
        filepath="$PGDATA/$file"
        if [[ -f "$filepath" ]]; then
            backup_config "$filepath"
            chmod 600 "$filepath"
            chown postgres:postgres "$filepath"
            log_success "$file permissions set to 600"
        fi
    done

    # 2.3 Ensure SSL certificates have appropriate permissions
    if [[ -d "$SSL_DIR" ]]; then
        chmod 700 "$SSL_DIR"
        chown postgres:postgres "$SSL_DIR"
        find "$SSL_DIR" -type f -name "*.key" -exec chmod 600 {} \;
        find "$SSL_DIR" -type f -name "*.crt" -exec chmod 644 {} \;
        log_success "SSL certificate permissions configured"
    fi
}

# ============================================================================
# CIS Benchmark Section 3: Logging and Auditing
# ============================================================================

section_3_logging() {
    log_info "=== Section 3: Logging and Auditing ==="

    # Create audit log directory
    mkdir -p "$AUDIT_LOG_DIR"
    chown postgres:postgres "$AUDIT_LOG_DIR"
    chmod 700 "$AUDIT_LOG_DIR"

    # 3.1 Enable logging
    log_info "Configuring logging parameters..."

    cat >> "$PGDATA/postgresql.conf" <<EOF

# ============================================================================
# SECURITY HARDENING - LOGGING CONFIGURATION
# ============================================================================

# Enable logging
logging_collector = on
log_destination = 'stderr'
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1d
log_rotation_size = 100MB
log_truncate_on_rotation = off

# What to log
log_connections = on
log_disconnections = on
log_duration = off
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
log_lock_waits = on
log_statement = 'ddl'
log_temp_files = 0
log_timezone = 'UTC'

# Log levels
log_min_messages = warning
log_min_error_statement = error
log_min_duration_statement = 1000

# Authentication logging
log_checkpoints = on
log_autovacuum_min_duration = 0

# Slow query logging
log_duration = off
log_statement = 'none'

EOF

    log_success "Logging configuration applied"

    # 3.2 Install and configure pgaudit extension
    log_info "Installing pgaudit extension..."
    execute_sql "CREATE EXTENSION IF NOT EXISTS pgaudit;" || log_warning "pgaudit extension not available"

    if psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -t -c "\dx pgaudit" | grep -q pgaudit; then
        cat >> "$PGDATA/postgresql.conf" <<EOF

# pgaudit configuration
shared_preload_libraries = 'pgaudit'
pgaudit.log = 'all'
pgaudit.log_catalog = on
pgaudit.log_parameter = on
pgaudit.log_relation = on
pgaudit.log_statement_once = off

EOF
        log_success "pgaudit extension configured"
    fi
}

# ============================================================================
# CIS Benchmark Section 4: Authentication and Authorization
# ============================================================================

section_4_authentication() {
    log_info "=== Section 4: Authentication and Authorization ==="

    # 4.1 Configure SCRAM-SHA-256 authentication
    log_info "Setting password encryption to SCRAM-SHA-256..."

    cat >> "$PGDATA/postgresql.conf" <<EOF

# ============================================================================
# SECURITY HARDENING - AUTHENTICATION CONFIGURATION
# ============================================================================

# Password encryption
password_encryption = 'scram-sha-256'

# SSL/TLS Configuration
ssl = on
ssl_cert_file = '$SSL_DIR/server.crt'
ssl_key_file = '$SSL_DIR/server.key'
ssl_ca_file = '$SSL_DIR/root.crt'
ssl_crl_file = ''
ssl_ciphers = 'HIGH:MEDIUM:+3DES:!aNULL:!eNULL:!MD5:!PSK'
ssl_prefer_server_ciphers = on
ssl_min_protocol_version = 'TLSv1.2'

EOF

    log_success "Password encryption configured"

    # 4.2 Configure pg_hba.conf with least privilege
    log_info "Configuring pg_hba.conf..."

    backup_config "$PGDATA/pg_hba.conf"

    cat > "$PGDATA/pg_hba.conf" <<EOF
# ============================================================================
# SECURITY HARDENED pg_hba.conf
# TYPE  DATABASE        USER            ADDRESS                 METHOD
# ============================================================================

# Local connections (Unix domain socket)
local   all             postgres                                peer
local   all             all                                     scram-sha-256

# IPv4 local connections - require SSL
hostssl all             all             127.0.0.1/32            scram-sha-256
hostssl all             all             10.0.0.0/8              scram-sha-256 clientcert=verify-ca
hostssl all             all             172.16.0.0/12           scram-sha-256 clientcert=verify-ca
hostssl all             all             192.168.0.0/16          scram-sha-256 clientcert=verify-ca

# IPv6 local connections - require SSL
hostssl all             all             ::1/128                 scram-sha-256

# Replication connections
hostssl replication     replication     10.0.0.0/8              scram-sha-256 clientcert=verify-ca

# Reject all non-SSL connections
host    all             all             0.0.0.0/0               reject
host    all             all             ::/0                    reject

EOF

    log_success "pg_hba.conf configured with SSL enforcement"

    # 4.3 Configure password policies
    log_info "Configuring password policies..."

    execute_sql "ALTER SYSTEM SET password_encryption = 'scram-sha-256';"

    # Create password check function
    execute_sql "
    CREATE OR REPLACE FUNCTION check_password_strength(username text, password text)
    RETURNS boolean AS \$\$
    BEGIN
        -- Minimum length check
        IF length(password) < 12 THEN
            RAISE EXCEPTION 'Password must be at least 12 characters long';
        END IF;

        -- Complexity check (must contain uppercase, lowercase, digit, special char)
        IF NOT (password ~ '[A-Z]' AND password ~ '[a-z]' AND password ~ '[0-9]' AND password ~ '[^A-Za-z0-9]') THEN
            RAISE EXCEPTION 'Password must contain uppercase, lowercase, digit, and special character';
        END IF;

        -- Username check
        IF lower(password) LIKE '%' || lower(username) || '%' THEN
            RAISE EXCEPTION 'Password must not contain username';
        END IF;

        RETURN true;
    END;
    \$\$ LANGUAGE plpgsql;
    " || log_warning "Password strength function creation failed"
}

# ============================================================================
# CIS Benchmark Section 5: Connection and Authentication Settings
# ============================================================================

section_5_connection_settings() {
    log_info "=== Section 5: Connection and Authentication Settings ==="

    cat >> "$PGDATA/postgresql.conf" <<EOF

# ============================================================================
# SECURITY HARDENING - CONNECTION SETTINGS
# ============================================================================

# Connection settings
listen_addresses = 'localhost,10.0.0.0/8'
max_connections = 100
superuser_reserved_connections = 3

# Authentication timeout
authentication_timeout = 30s
tcp_keepalives_idle = 300
tcp_keepalives_interval = 30
tcp_keepalives_count = 10

# Statement timeout to prevent runaway queries
statement_timeout = 3600000  # 1 hour
idle_in_transaction_session_timeout = 600000  # 10 minutes

EOF

    log_success "Connection settings configured"
}

# ============================================================================
# CIS Benchmark Section 6: User and Role Management
# ============================================================================

section_6_user_management() {
    log_info "=== Section 6: User and Role Management ==="

    # 6.1 Ensure only necessary users exist
    log_info "Auditing user accounts..."
    execute_sql "SELECT usename, usesuper FROM pg_user;" || true

    # 6.2 Ensure superuser access is restricted
    log_info "Restricting superuser privileges..."
    execute_sql "
    -- Revoke superuser from unnecessary accounts
    -- (Manual review required - this is just a template)
    -- ALTER USER username NOSUPERUSER;
    " || true

    # 6.3 Create security roles
    log_info "Creating security roles..."
    execute_sql "
    -- Read-only role
    CREATE ROLE readonly_role;
    GRANT CONNECT ON DATABASE postgres TO readonly_role;
    GRANT USAGE ON SCHEMA public TO readonly_role;
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_role;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO readonly_role;

    -- Application role
    CREATE ROLE app_role;
    GRANT CONNECT ON DATABASE postgres TO app_role;
    GRANT USAGE ON SCHEMA public TO app_role;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_role;

    -- Replication role
    CREATE ROLE replication_role WITH REPLICATION LOGIN;
    " 2>/dev/null || log_info "Security roles may already exist"

    log_success "User management configured"
}

# ============================================================================
# CIS Benchmark Section 7: Network Configuration
# ============================================================================

section_7_network_security() {
    log_info "=== Section 7: Network Configuration ==="

    # 7.1 Configure firewall rules (iptables example)
    if command -v iptables &> /dev/null; then
        log_info "Configuring firewall rules..."

        # Allow PostgreSQL from internal networks only
        iptables -A INPUT -p tcp --dport "$PGPORT" -s 10.0.0.0/8 -j ACCEPT
        iptables -A INPUT -p tcp --dport "$PGPORT" -s 172.16.0.0/12 -j ACCEPT
        iptables -A INPUT -p tcp --dport "$PGPORT" -s 192.168.0.0/16 -j ACCEPT
        iptables -A INPUT -p tcp --dport "$PGPORT" -j DROP

        # Save iptables rules
        if command -v iptables-save &> /dev/null; then
            iptables-save > /etc/iptables/rules.v4 || true
        fi

        log_success "Firewall rules configured"
    else
        log_warning "iptables not found - manual firewall configuration required"
    fi
}

# ============================================================================
# CIS Benchmark Section 8: Database Configuration
# ============================================================================

section_8_database_config() {
    log_info "=== Section 8: Database Configuration ==="

    cat >> "$PGDATA/postgresql.conf" <<EOF

# ============================================================================
# SECURITY HARDENING - DATABASE CONFIGURATION
# ============================================================================

# Disable unnecessary features
allow_system_table_mods = off

# Resource limits
shared_buffers = 256MB
work_mem = 4MB
maintenance_work_mem = 64MB
max_wal_size = 1GB
min_wal_size = 80MB

# Security parameters
row_security = on
ssl_min_protocol_version = 'TLSv1.2'

EOF

    log_success "Database configuration applied"

    # 8.1 Disable unnecessary extensions
    log_info "Removing unnecessary extensions..."
    for ext in plperl plperlu pltcl pltclu; do
        execute_sql "DROP EXTENSION IF EXISTS $ext CASCADE;" 2>/dev/null || true
    done

    # 8.2 Configure database-level security
    execute_sql "
    -- Revoke public schema privileges
    REVOKE CREATE ON SCHEMA public FROM PUBLIC;
    REVOKE ALL ON DATABASE postgres FROM PUBLIC;

    -- Set secure search path
    ALTER DATABASE postgres SET search_path TO '\$user', public;
    " || log_warning "Database security configuration partially applied"
}

# ============================================================================
# SSL/TLS Certificate Generation
# ============================================================================

generate_ssl_certificates() {
    log_info "=== Generating SSL/TLS Certificates ==="

    mkdir -p "$SSL_DIR"
    cd "$SSL_DIR"

    # Generate root CA
    if [[ ! -f root.key ]]; then
        log_info "Generating root CA..."
        openssl genrsa -out root.key 4096
        openssl req -new -x509 -days 3650 -key root.key -out root.crt \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=PostgreSQL-Root-CA"
        log_success "Root CA generated"
    fi

    # Generate server certificate
    if [[ ! -f server.key ]]; then
        log_info "Generating server certificate..."
        openssl genrsa -out server.key 2048
        openssl req -new -key server.key -out server.csr \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=$(hostname)"
        openssl x509 -req -in server.csr -CA root.crt -CAkey root.key \
            -CAcreateserial -out server.crt -days 365
        rm server.csr
        log_success "Server certificate generated"
    fi

    # Set permissions
    chmod 600 root.key server.key
    chmod 644 root.crt server.crt
    chown postgres:postgres root.key root.crt server.key server.crt

    cd - > /dev/null
    log_success "SSL certificates configured in $SSL_DIR"
}

# ============================================================================
# Security Validation
# ============================================================================

validate_security() {
    log_info "=== Validating Security Configuration ==="

    local errors=0

    # Check PGDATA permissions
    if [[ $(stat -c %a "$PGDATA") != "700" ]]; then
        log_error "PGDATA permissions incorrect"
        ((errors++))
    fi

    # Check SSL certificates
    if [[ ! -f "$SSL_DIR/server.crt" ]] || [[ ! -f "$SSL_DIR/server.key" ]]; then
        log_error "SSL certificates missing"
        ((errors++))
    fi

    # Check logging enabled
    if ! grep -q "logging_collector = on" "$PGDATA/postgresql.conf"; then
        log_error "Logging not enabled"
        ((errors++))
    fi

    # Check password encryption
    if ! grep -q "password_encryption = 'scram-sha-256'" "$PGDATA/postgresql.conf"; then
        log_error "SCRAM-SHA-256 not configured"
        ((errors++))
    fi

    if [[ $errors -eq 0 ]]; then
        log_success "All security validations passed"
        return 0
    else
        log_error "Security validation failed with $errors errors"
        return 1
    fi
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    log_info "Starting PostgreSQL Security Hardening..."
    log_info "Timestamp: $(date)"

    # Execute hardening sections
    section_1_installation
    section_2_file_permissions
    generate_ssl_certificates
    section_3_logging
    section_4_authentication
    section_5_connection_settings
    section_6_user_management
    section_7_network_security
    section_8_database_config

    # Validate configuration
    validate_security

    log_info ""
    log_info "============================================"
    log_success "Security hardening completed!"
    log_info "============================================"
    log_info "Backup location: $BACKUP_DIR"
    log_info ""
    log_warning "IMPORTANT: Restart PostgreSQL for changes to take effect:"
    log_warning "  sudo systemctl restart postgresql"
    log_warning "  OR"
    log_warning "  pg_ctl restart -D $PGDATA"
    log_info ""
    log_warning "Review and test configuration before deploying to production"
    log_info "Run security-audit.sh to verify the hardening"
}

# Run main function
main "$@"
