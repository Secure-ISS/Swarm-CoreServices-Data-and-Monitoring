#!/bin/bash
#
# PostgreSQL Security Audit Script
# ==================================
# Comprehensive security assessment of distributed PostgreSQL cluster
#
# Usage: ./audit-security.sh [--output report.html]
#

set -euo pipefail

# Configuration
POSTGRES_HOST="${POSTGRES_HOST:-pg-coordinator}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-distributed_postgres_cluster}"
POSTGRES_USER="${POSTGRES_USER:-cluster_admin}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-text}"
REPORT_FILE="${REPORT_FILE:-security-audit-$(date +%Y%m%d-%H%M%S).txt}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Scoring
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

# Functions
print_header() {
    echo ""
    echo "============================================"
    echo "$1"
    echo "============================================"
}

check_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASSED_CHECKS++))
    ((TOTAL_CHECKS++))
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    ((FAILED_CHECKS++))
    ((TOTAL_CHECKS++))
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
    ((WARNING_CHECKS++))
    ((TOTAL_CHECKS++))
}

run_query() {
    PGPASSWORD="$PGPASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c "$1" 2>/dev/null || echo ""
}

# Start audit
print_header "PostgreSQL Security Audit Report"
echo "Timestamp: $(date)"
echo "Target: $POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB"
echo ""

# ============================================================================
# 1. CONNECTION SECURITY
# ============================================================================
print_header "1. Connection Security"

# Check SSL is enabled
ssl_enabled=$(run_query "SHOW ssl;")
if [[ "$ssl_enabled" == "on" ]]; then
    check_pass "SSL/TLS is enabled"
else
    check_fail "SSL/TLS is disabled (CRITICAL)"
fi

# Check TLS version
ssl_min_version=$(run_query "SHOW ssl_min_protocol_version;")
if [[ "$ssl_min_version" == "TLSv1.3" ]]; then
    check_pass "TLS 1.3 is enforced"
elif [[ "$ssl_min_version" == "TLSv1.2" ]]; then
    check_warn "TLS 1.2 is minimum (upgrade to TLS 1.3 recommended)"
else
    check_fail "Outdated TLS version: $ssl_min_version"
fi

# Check for unencrypted connections
unencrypted_conns=$(run_query "SELECT COUNT(*) FROM pg_stat_ssl WHERE NOT ssl;")
if [[ "$unencrypted_conns" -eq 0 ]]; then
    check_pass "No unencrypted connections detected"
else
    check_fail "$unencrypted_conns unencrypted connections found"
fi

# Check password encryption
password_encryption=$(run_query "SHOW password_encryption;")
if [[ "$password_encryption" == "scram-sha-256" ]]; then
    check_pass "SCRAM-SHA-256 password encryption is enabled"
elif [[ "$password_encryption" == "md5" ]]; then
    check_fail "MD5 password encryption is weak (upgrade to scram-sha-256)"
else
    check_warn "Unknown password encryption: $password_encryption"
fi

# ============================================================================
# 2. AUTHENTICATION & AUTHORIZATION
# ============================================================================
print_header "2. Authentication & Authorization"

# Check for weak passwords (password == username)
weak_passwords=$(run_query "SELECT usename FROM pg_shadow WHERE passwd IS NULL;")
if [[ -z "$weak_passwords" ]]; then
    check_pass "No users with NULL passwords"
else
    check_fail "Users with NULL passwords: $weak_passwords"
fi

# Check for superusers
superusers=$(run_query "SELECT COUNT(*) FROM pg_user WHERE usesuper;")
if [[ "$superusers" -le 2 ]]; then
    check_pass "Superuser count is reasonable ($superusers)"
else
    check_warn "$superusers superusers detected (minimize superuser accounts)"
fi

# Check for users with BYPASSRLS
bypassrls_users=$(run_query "SELECT usename FROM pg_user WHERE rolbypassrls AND usename != 'postgres';")
if [[ -z "$bypassrls_users" ]]; then
    check_pass "No users bypass row-level security"
else
    check_warn "Users with BYPASSRLS: $bypassrls_users"
fi

# Check public schema permissions
public_create=$(run_query "SELECT has_schema_privilege('public', 'public', 'CREATE');")
if [[ "$public_create" == "f" ]]; then
    check_pass "PUBLIC cannot create in public schema"
else
    check_fail "PUBLIC has CREATE privilege on public schema (revoke recommended)"
fi

# ============================================================================
# 3. NETWORK SECURITY
# ============================================================================
print_header "3. Network Security"

# Check listen_addresses
listen_addresses=$(run_query "SHOW listen_addresses;")
if [[ "$listen_addresses" == "localhost" ]]; then
    check_pass "PostgreSQL only listens on localhost (use with caution in distributed setup)"
elif [[ "$listen_addresses" == "*" ]]; then
    check_warn "PostgreSQL listens on all interfaces (ensure firewall is configured)"
else
    check_pass "PostgreSQL listens on: $listen_addresses"
fi

# Check max_connections
max_connections=$(run_query "SHOW max_connections;")
if [[ "$max_connections" -lt 1000 ]]; then
    check_pass "max_connections is reasonable ($max_connections)"
else
    check_warn "max_connections is very high ($max_connections) - consider connection pooling"
fi

# Check for pg_hba.conf with 'trust' authentication
if docker exec ruvector-db cat /var/lib/postgresql/data/pg_hba.conf 2>/dev/null | grep -q "trust"; then
    check_fail "pg_hba.conf contains 'trust' authentication (insecure)"
else
    check_pass "No 'trust' authentication in pg_hba.conf"
fi

# Check for pg_hba.conf with 'password' (plaintext)
if docker exec ruvector-db cat /var/lib/postgresql/data/pg_hba.conf 2>/dev/null | grep -q "password"; then
    check_fail "pg_hba.conf uses plaintext passwords (use scram-sha-256)"
else
    check_pass "No plaintext password authentication"
fi

# ============================================================================
# 4. DATA PROTECTION
# ============================================================================
print_header "4. Data Protection"

# Check for pgcrypto extension
pgcrypto_installed=$(run_query "SELECT COUNT(*) FROM pg_extension WHERE extname = 'pgcrypto';")
if [[ "$pgcrypto_installed" -gt 0 ]]; then
    check_pass "pgcrypto extension is installed (column-level encryption available)"
else
    check_warn "pgcrypto not installed (column-level encryption unavailable)"
fi

# Check for tables with RLS enabled
rls_tables=$(run_query "SELECT COUNT(*) FROM pg_tables WHERE rowsecurity;")
if [[ "$rls_tables" -gt 0 ]]; then
    check_pass "$rls_tables tables have row-level security enabled"
else
    check_warn "No tables have row-level security enabled (consider enabling RLS)"
fi

# Check for backup encryption
if [[ -f "/backups/backup_*.gpg" ]]; then
    check_pass "Encrypted backups detected"
else
    check_warn "No encrypted backups found (implement encrypted backups)"
fi

# ============================================================================
# 5. AUDIT LOGGING
# ============================================================================
print_header "5. Audit Logging"

# Check if pgaudit is installed
pgaudit_installed=$(run_query "SELECT COUNT(*) FROM pg_extension WHERE extname = 'pgaudit';")
if [[ "$pgaudit_installed" -gt 0 ]]; then
    check_pass "pgaudit extension is installed"
else
    check_warn "pgaudit not installed (advanced audit logging unavailable)"
fi

# Check log_connections
log_connections=$(run_query "SHOW log_connections;")
if [[ "$log_connections" == "on" ]]; then
    check_pass "Connection logging is enabled"
else
    check_fail "Connection logging is disabled"
fi

# Check log_disconnections
log_disconnections=$(run_query "SHOW log_disconnections;")
if [[ "$log_disconnections" == "on" ]]; then
    check_pass "Disconnection logging is enabled"
else
    check_fail "Disconnection logging is disabled"
fi

# Check log_statement
log_statement=$(run_query "SHOW log_statement;")
if [[ "$log_statement" == "ddl" ]] || [[ "$log_statement" == "all" ]]; then
    check_pass "DDL statement logging is enabled ($log_statement)"
else
    check_warn "Limited statement logging ($log_statement) - consider 'ddl' or 'all'"
fi

# ============================================================================
# 6. VULNERABILITY CHECKS
# ============================================================================
print_header "6. Vulnerability Checks"

# Check PostgreSQL version
pg_version=$(run_query "SHOW server_version;")
pg_major=$(echo "$pg_version" | cut -d. -f1)
if [[ "$pg_major" -ge 15 ]]; then
    check_pass "PostgreSQL version is up-to-date ($pg_version)"
elif [[ "$pg_major" -ge 12 ]]; then
    check_warn "PostgreSQL version is outdated ($pg_version) - upgrade recommended"
else
    check_fail "PostgreSQL version is EOL ($pg_version) - URGENT upgrade required"
fi

# Check for default/demo databases
demo_dbs=$(run_query "SELECT datname FROM pg_database WHERE datname IN ('template0', 'template1', 'postgres');")
# These are system databases, just informational

# Check for excessive privileges on information_schema
info_schema_privs=$(run_query "SELECT COUNT(*) FROM information_schema.table_privileges WHERE grantee = 'PUBLIC' AND table_schema = 'information_schema';")
if [[ "$info_schema_privs" -eq 0 ]]; then
    check_pass "No excessive privileges on information_schema"
else
    check_warn "PUBLIC has privileges on information_schema ($info_schema_privs)"
fi

# ============================================================================
# 7. REPLICATION SECURITY
# ============================================================================
print_header "7. Replication Security"

# Check if replication slots exist
replication_slots=$(run_query "SELECT COUNT(*) FROM pg_replication_slots;")
if [[ "$replication_slots" -gt 0 ]]; then
    check_pass "$replication_slots replication slots configured"

    # Check if replication uses SSL
    replication_ssl=$(run_query "SELECT COUNT(*) FROM pg_stat_replication WHERE NOT ssl;")
    if [[ "$replication_ssl" -eq 0 ]]; then
        check_pass "All replication connections use SSL"
    else
        check_fail "$replication_ssl replication connections without SSL"
    fi
else
    check_warn "No replication configured"
fi

# ============================================================================
# 8. DOCKER SECURITY (if applicable)
# ============================================================================
print_header "8. Container Security"

# Check if running in Docker
if docker ps | grep -q postgres; then
    check_pass "PostgreSQL running in Docker container"

    # Check Docker secrets
    if docker secret ls | grep -q postgres; then
        check_pass "Docker secrets are configured"
    else
        check_warn "No Docker secrets found (use Docker secrets for sensitive data)"
    fi

    # Check container is running as non-root
    container_user=$(docker exec ruvector-db whoami 2>/dev/null || echo "unknown")
    if [[ "$container_user" == "postgres" ]]; then
        check_pass "Container running as postgres user"
    elif [[ "$container_user" == "root" ]]; then
        check_fail "Container running as root (security risk)"
    fi
else
    check_warn "PostgreSQL not running in Docker (manual security checks required)"
fi

# ============================================================================
# SUMMARY
# ============================================================================
print_header "Audit Summary"

echo "Total Checks: $TOTAL_CHECKS"
echo -e "Passed: ${GREEN}$PASSED_CHECKS${NC}"
echo -e "Warnings: ${YELLOW}$WARNING_CHECKS${NC}"
echo -e "Failed: ${RED}$FAILED_CHECKS${NC}"
echo ""

# Calculate security score
SECURITY_SCORE=$(( (PASSED_CHECKS * 100) / TOTAL_CHECKS ))
echo "Security Score: $SECURITY_SCORE/100"

if [[ "$SECURITY_SCORE" -ge 90 ]]; then
    echo -e "${GREEN}Excellent security posture${NC}"
elif [[ "$SECURITY_SCORE" -ge 70 ]]; then
    echo -e "${YELLOW}Good security posture (some improvements needed)${NC}"
elif [[ "$SECURITY_SCORE" -ge 50 ]]; then
    echo -e "${YELLOW}Moderate security posture (several improvements needed)${NC}"
else
    echo -e "${RED}Poor security posture (URGENT action required)${NC}"
fi

echo ""
echo "Report saved to: $REPORT_FILE"

# Save report to file
{
    echo "PostgreSQL Security Audit Report"
    echo "================================="
    echo "Timestamp: $(date)"
    echo "Target: $POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB"
    echo ""
    echo "Security Score: $SECURITY_SCORE/100"
    echo "Passed: $PASSED_CHECKS"
    echo "Warnings: $WARNING_CHECKS"
    echo "Failed: $FAILED_CHECKS"
} > "$REPORT_FILE"

# Exit with failure if critical issues found
if [[ "$FAILED_CHECKS" -gt 0 ]]; then
    exit 1
fi
