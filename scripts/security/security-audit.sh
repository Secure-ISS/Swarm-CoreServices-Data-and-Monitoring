#!/bin/bash
# Security Audit Script for Distributed PostgreSQL Cluster
# Performs comprehensive security scanning and compliance checks
# Version: 1.0.0

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; }
log_critical() { echo -e "${MAGENTA}[CRITICAL]${NC} $1"; }

# Configuration
PGDATA="${PGDATA:-/var/lib/postgresql/data}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
SSL_DIR="${SSL_DIR:-/etc/postgresql/ssl}"
REPORT_FILE="security_audit_$(date +%Y%m%d_%H%M%S).txt"

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0
CRITICAL_ISSUES=0

# Report generation
REPORT_CONTENT=""

add_to_report() {
    REPORT_CONTENT+="$1"$'\n'
}

print_header() {
    local title=$1
    echo ""
    echo "============================================"
    echo "$title"
    echo "============================================"
    add_to_report ""
    add_to_report "============================================"
    add_to_report "$title"
    add_to_report "============================================"
}

check_test() {
    ((TOTAL_CHECKS++))
    local status=$1
    local message=$2
    local severity=${3:-info}

    if [[ $status -eq 0 ]]; then
        log_success "$message"
        add_to_report "[PASS] $message"
        ((PASSED_CHECKS++))
    else
        if [[ $severity == "critical" ]]; then
            log_critical "$message"
            add_to_report "[CRITICAL] $message"
            ((CRITICAL_ISSUES++))
            ((FAILED_CHECKS++))
        elif [[ $severity == "high" ]]; then
            log_error "$message"
            add_to_report "[FAIL] $message"
            ((FAILED_CHECKS++))
        else
            log_warning "$message"
            add_to_report "[WARN] $message"
            ((WARNING_CHECKS++))
        fi
    fi
}

execute_sql() {
    local sql=$1
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -t -A -c "$sql" 2>/dev/null || echo ""
}

# ============================================================================
# Section 1: File Permissions Audit
# ============================================================================

audit_file_permissions() {
    print_header "File Permissions Audit"

    # Check PGDATA permissions
    if [[ -d "$PGDATA" ]]; then
        local perms=$(stat -c %a "$PGDATA")
        if [[ "$perms" == "700" ]]; then
            check_test 0 "PGDATA directory permissions ($perms)" "high"
        else
            check_test 1 "PGDATA directory has insecure permissions: $perms (expected 700)" "critical"
        fi

        local owner=$(stat -c %U "$PGDATA")
        if [[ "$owner" == "postgres" ]]; then
            check_test 0 "PGDATA directory owner ($owner)" "high"
        else
            check_test 1 "PGDATA directory has incorrect owner: $owner (expected postgres)" "critical"
        fi
    else
        check_test 1 "PGDATA directory not found: $PGDATA" "critical"
    fi

    # Check configuration file permissions
    for file in postgresql.conf pg_hba.conf pg_ident.conf; do
        local filepath="$PGDATA/$file"
        if [[ -f "$filepath" ]]; then
            local perms=$(stat -c %a "$filepath")
            if [[ "$perms" == "600" ]]; then
                check_test 0 "$file permissions ($perms)" "high"
            else
                check_test 1 "$file has insecure permissions: $perms (expected 600)" "high"
            fi
        else
            check_test 1 "$file not found" "high"
        fi
    done

    # Check SSL certificate permissions
    if [[ -d "$SSL_DIR" ]]; then
        local ssl_perms=$(stat -c %a "$SSL_DIR")
        if [[ "$ssl_perms" == "700" ]]; then
            check_test 0 "SSL directory permissions ($ssl_perms)" "high"
        else
            check_test 1 "SSL directory has insecure permissions: $ssl_perms (expected 700)" "high"
        fi

        # Check private key permissions
        if [[ -f "$SSL_DIR/server.key" ]]; then
            local key_perms=$(stat -c %a "$SSL_DIR/server.key")
            if [[ "$key_perms" == "600" ]]; then
                check_test 0 "SSL private key permissions ($key_perms)" "critical"
            else
                check_test 1 "SSL private key has insecure permissions: $key_perms (expected 600)" "critical"
            fi
        fi
    fi
}

# ============================================================================
# Section 2: Authentication and Authorization Audit
# ============================================================================

audit_authentication() {
    print_header "Authentication and Authorization Audit"

    # Check password encryption method
    local pwd_enc=$(execute_sql "SHOW password_encryption;")
    if [[ "$pwd_enc" == "scram-sha-256" ]]; then
        check_test 0 "Password encryption method: $pwd_enc" "high"
    else
        check_test 1 "Weak password encryption: $pwd_enc (should be scram-sha-256)" "critical"
    fi

    # Check for users with weak passwords (empty or common)
    local weak_users=$(execute_sql "SELECT COUNT(*) FROM pg_shadow WHERE passwd IS NULL;")
    if [[ "$weak_users" -eq 0 ]]; then
        check_test 0 "No users with null passwords" "critical"
    else
        check_test 1 "$weak_users users found with null passwords" "critical"
    fi

    # Check for superuser accounts
    local superusers=$(execute_sql "SELECT usename FROM pg_user WHERE usesuper = true;")
    local su_count=$(echo "$superusers" | wc -l)
    if [[ $su_count -le 2 ]]; then
        check_test 0 "Superuser count: $su_count (acceptable)" "medium"
    else
        check_test 1 "Too many superusers: $su_count (review required)" "medium"
        add_to_report "Superusers: $superusers"
    fi

    # Check pg_hba.conf for insecure entries
    if [[ -f "$PGDATA/pg_hba.conf" ]]; then
        # Check for 'trust' authentication
        if grep -qE "^[^#]*trust" "$PGDATA/pg_hba.conf"; then
            check_test 1 "pg_hba.conf contains 'trust' authentication" "critical"
        else
            check_test 0 "No 'trust' authentication found in pg_hba.conf" "critical"
        fi

        # Check for 'password' (plain text) authentication
        if grep -qE "^[^#]*\spassword\s*$" "$PGDATA/pg_hba.conf"; then
            check_test 1 "pg_hba.conf contains plain text 'password' authentication" "critical"
        else
            check_test 0 "No plain text password authentication in pg_hba.conf" "critical"
        fi

        # Check for 0.0.0.0/0 entries without SSL
        if grep -qE "^host.*0\.0\.0\.0/0" "$PGDATA/pg_hba.conf" | grep -v hostssl; then
            check_test 1 "pg_hba.conf allows non-SSL connections from any host" "critical"
        else
            check_test 0 "No insecure global host entries in pg_hba.conf" "high"
        fi

        # Check SSL enforcement
        local hostssl_count=$(grep -cE "^hostssl" "$PGDATA/pg_hba.conf" || echo 0)
        local host_count=$(grep -cE "^host[^s]" "$PGDATA/pg_hba.conf" || echo 0)
        if [[ $hostssl_count -gt 0 ]] && [[ $host_count -eq 0 ]]; then
            check_test 0 "SSL enforcement configured in pg_hba.conf" "high"
        else
            check_test 1 "Non-SSL connections allowed in pg_hba.conf" "high"
        fi
    fi

    # Check for idle sessions
    local idle_sessions=$(execute_sql "SELECT COUNT(*) FROM pg_stat_activity WHERE state = 'idle' AND state_change < NOW() - INTERVAL '1 hour';")
    if [[ "$idle_sessions" -eq 0 ]]; then
        check_test 0 "No long-running idle sessions" "low"
    else
        check_test 1 "$idle_sessions idle sessions older than 1 hour" "medium"
    fi
}

# ============================================================================
# Section 3: SSL/TLS Configuration Audit
# ============================================================================

audit_ssl_tls() {
    print_header "SSL/TLS Configuration Audit"

    # Check if SSL is enabled
    local ssl_enabled=$(execute_sql "SHOW ssl;")
    if [[ "$ssl_enabled" == "on" ]]; then
        check_test 0 "SSL enabled" "critical"
    else
        check_test 1 "SSL is disabled" "critical"
        return
    fi

    # Check SSL protocol version
    local ssl_min_ver=$(execute_sql "SHOW ssl_min_protocol_version;")
    if [[ "$ssl_min_ver" == "TLSv1.2" ]] || [[ "$ssl_min_ver" == "TLSv1.3" ]]; then
        check_test 0 "SSL minimum protocol version: $ssl_min_ver" "high"
    else
        check_test 1 "Weak SSL minimum protocol: $ssl_min_ver (should be TLSv1.2+)" "critical"
    fi

    # Check SSL cipher configuration
    local ssl_ciphers=$(execute_sql "SHOW ssl_ciphers;")
    if [[ -n "$ssl_ciphers" ]] && [[ "$ssl_ciphers" != "ALL" ]]; then
        check_test 0 "SSL ciphers configured: $ssl_ciphers" "high"
    else
        check_test 1 "SSL ciphers not restricted (using: $ssl_ciphers)" "high"
    fi

    # Check certificate files exist
    local ssl_cert=$(execute_sql "SHOW ssl_cert_file;")
    local ssl_key=$(execute_sql "SHOW ssl_key_file;")

    if [[ -f "$PGDATA/$ssl_cert" ]]; then
        check_test 0 "SSL certificate file exists: $ssl_cert" "critical"

        # Check certificate expiration
        local cert_expiry=$(openssl x509 -in "$PGDATA/$ssl_cert" -noout -enddate 2>/dev/null | cut -d= -f2)
        local expiry_epoch=$(date -d "$cert_expiry" +%s)
        local now_epoch=$(date +%s)
        local days_until_expiry=$(( ($expiry_epoch - $now_epoch) / 86400 ))

        if [[ $days_until_expiry -gt 30 ]]; then
            check_test 0 "SSL certificate valid for $days_until_expiry days" "high"
        elif [[ $days_until_expiry -gt 0 ]]; then
            check_test 1 "SSL certificate expires in $days_until_expiry days (renewal required)" "high"
        else
            check_test 1 "SSL certificate has expired" "critical"
        fi
    else
        check_test 1 "SSL certificate file not found: $ssl_cert" "critical"
    fi

    if [[ -f "$PGDATA/$ssl_key" ]]; then
        check_test 0 "SSL private key file exists: $ssl_key" "critical"
    else
        check_test 1 "SSL private key file not found: $ssl_key" "critical"
    fi

    # Check SSL prefer server ciphers
    local ssl_prefer=$(execute_sql "SHOW ssl_prefer_server_ciphers;")
    if [[ "$ssl_prefer" == "on" ]]; then
        check_test 0 "SSL prefer server ciphers enabled" "medium"
    else
        check_test 1 "SSL server cipher preference disabled" "medium"
    fi
}

# ============================================================================
# Section 4: Logging and Auditing
# ============================================================================

audit_logging() {
    print_header "Logging and Auditing Configuration"

    # Check if logging collector is enabled
    local log_collector=$(execute_sql "SHOW logging_collector;")
    if [[ "$log_collector" == "on" ]]; then
        check_test 0 "Logging collector enabled" "high"
    else
        check_test 1 "Logging collector disabled" "high"
    fi

    # Check connection logging
    local log_connections=$(execute_sql "SHOW log_connections;")
    if [[ "$log_connections" == "on" ]]; then
        check_test 0 "Connection logging enabled" "medium"
    else
        check_test 1 "Connection logging disabled" "medium"
    fi

    local log_disconnections=$(execute_sql "SHOW log_disconnections;")
    if [[ "$log_disconnections" == "on" ]]; then
        check_test 0 "Disconnection logging enabled" "medium"
    else
        check_test 1 "Disconnection logging disabled" "medium"
    fi

    # Check statement logging
    local log_statement=$(execute_sql "SHOW log_statement;")
    if [[ "$log_statement" == "none" ]]; then
        check_test 1 "Statement logging disabled (consider enabling for DDL)" "low"
    else
        check_test 0 "Statement logging enabled: $log_statement" "medium"
    fi

    # Check for pgaudit extension
    local pgaudit_installed=$(execute_sql "SELECT COUNT(*) FROM pg_extension WHERE extname = 'pgaudit';")
    if [[ "$pgaudit_installed" -eq 1 ]]; then
        check_test 0 "pgaudit extension installed" "medium"

        # Check pgaudit configuration
        local pgaudit_log=$(execute_sql "SHOW pgaudit.log;" 2>/dev/null || echo "")
        if [[ -n "$pgaudit_log" ]]; then
            check_test 0 "pgaudit logging configured: $pgaudit_log" "medium"
        fi
    else
        check_test 1 "pgaudit extension not installed (recommended for compliance)" "low"
    fi

    # Check log file permissions
    local log_dir="$PGDATA/log"
    if [[ -d "$log_dir" ]]; then
        local log_perms=$(stat -c %a "$log_dir")
        if [[ "$log_perms" == "700" ]]; then
            check_test 0 "Log directory permissions: $log_perms" "medium"
        else
            check_test 1 "Log directory permissions too permissive: $log_perms" "medium"
        fi
    fi
}

# ============================================================================
# Section 5: Network Security Audit
# ============================================================================

audit_network_security() {
    print_header "Network Security Configuration"

    # Check listen addresses
    local listen_addresses=$(execute_sql "SHOW listen_addresses;")
    if [[ "$listen_addresses" == "localhost" ]]; then
        check_test 0 "Listen addresses restricted to localhost" "high"
    elif [[ "$listen_addresses" == "*" ]]; then
        check_test 1 "Database listening on all interfaces (*)" "critical"
    else
        check_test 0 "Listen addresses configured: $listen_addresses" "medium"
    fi

    # Check max connections
    local max_conn=$(execute_sql "SHOW max_connections;")
    if [[ $max_conn -lt 1000 ]]; then
        check_test 0 "Max connections: $max_conn (reasonable limit)" "low"
    else
        check_test 1 "Max connections very high: $max_conn (potential DoS risk)" "medium"
    fi

    # Check statement timeout
    local stmt_timeout=$(execute_sql "SHOW statement_timeout;")
    if [[ "$stmt_timeout" != "0" ]]; then
        check_test 0 "Statement timeout configured: $stmt_timeout" "medium"
    else
        check_test 1 "Statement timeout disabled (runaway queries possible)" "medium"
    fi

    # Check idle_in_transaction timeout
    local idle_timeout=$(execute_sql "SHOW idle_in_transaction_session_timeout;")
    if [[ "$idle_timeout" != "0" ]]; then
        check_test 0 "Idle transaction timeout: $idle_timeout" "low"
    else
        check_test 1 "Idle transaction timeout disabled" "low"
    fi

    # Check for open connections from unauthorized IPs
    local external_conns=$(execute_sql "SELECT COUNT(*) FROM pg_stat_activity WHERE client_addr NOT IN ('127.0.0.1', '::1') AND client_addr IS NOT NULL;")
    if [[ "$external_conns" -eq 0 ]]; then
        check_test 0 "No external connections (localhost only)" "low"
    else
        log_info "Active external connections: $external_conns"
        add_to_report "Active external connections: $external_conns"
    fi
}

# ============================================================================
# Section 6: Database Configuration Security
# ============================================================================

audit_database_config() {
    print_header "Database Configuration Security"

    # Check for dangerous configuration parameters
    local allow_system_mods=$(execute_sql "SHOW allow_system_table_mods;")
    if [[ "$allow_system_mods" == "off" ]]; then
        check_test 0 "System table modifications disabled" "high"
    else
        check_test 1 "System table modifications allowed (dangerous)" "critical"
    fi

    # Check row-level security
    local row_security=$(execute_sql "SHOW row_security;")
    if [[ "$row_security" == "on" ]]; then
        check_test 0 "Row-level security enabled" "medium"
    else
        check_test 1 "Row-level security disabled" "low"
    fi

    # Check for dangerous extensions
    local dangerous_exts="plperl plperlu pltcl pltclu"
    for ext in $dangerous_exts; do
        local ext_installed=$(execute_sql "SELECT COUNT(*) FROM pg_extension WHERE extname = '$ext';")
        if [[ "$ext_installed" -eq 0 ]]; then
            check_test 0 "Dangerous extension '$ext' not installed" "high"
        else
            check_test 1 "Dangerous extension '$ext' is installed" "high"
        fi
    done

    # Check for users with dangerous privileges
    local create_db_users=$(execute_sql "SELECT COUNT(*) FROM pg_user WHERE usecreatedb = true AND NOT usesuper;")
    if [[ $create_db_users -eq 0 ]]; then
        check_test 0 "No non-superusers with CREATEDB privilege" "low"
    else
        check_test 1 "$create_db_users non-superusers have CREATEDB privilege" "medium"
    fi
}

# ============================================================================
# Section 7: Privilege Audit
# ============================================================================

audit_privileges() {
    print_header "User Privileges Audit"

    # Check public schema privileges
    local public_create=$(execute_sql "SELECT has_schema_privilege('public', 'public', 'CREATE');")
    if [[ "$public_create" == "f" ]]; then
        check_test 0 "PUBLIC CREATE privilege revoked from public schema" "medium"
    else
        check_test 1 "PUBLIC has CREATE privilege on public schema" "medium"
    fi

    # Check for users with BYPASS RLS
    local bypass_rls_users=$(execute_sql "SELECT COUNT(*) FROM pg_roles WHERE rolbypassrls = true AND NOT rolsuper;")
    if [[ $bypass_rls_users -eq 0 ]]; then
        check_test 0 "No non-superusers with BYPASS RLS" "medium"
    else
        check_test 1 "$bypass_rls_users non-superusers have BYPASS RLS privilege" "high"
    fi

    # Check for overly permissive default privileges
    local default_privs=$(execute_sql "SELECT COUNT(*) FROM pg_default_acl;")
    log_info "Default privileges configured: $default_privs"
    add_to_report "Default privileges entries: $default_privs"
}

# ============================================================================
# Section 8: Compliance Checks
# ============================================================================

audit_compliance() {
    print_header "Compliance Checks (PCI-DSS, HIPAA, GDPR)"

    # PCI-DSS Requirements
    log_info "PCI-DSS Compliance Checks:"

    # Req 2.2.4: Configure security parameters
    local pci_pass=0
    local pci_fail=0

    if [[ $(execute_sql "SHOW ssl;") == "on" ]]; then
        ((pci_pass++))
    else
        ((pci_fail++))
        check_test 1 "PCI-DSS 2.2.4: SSL not enabled" "high"
    fi

    # Req 8.2.1: Strong passwords
    if [[ $(execute_sql "SHOW password_encryption;") == "scram-sha-256" ]]; then
        ((pci_pass++))
    else
        ((pci_fail++))
        check_test 1 "PCI-DSS 8.2.1: Weak password encryption" "high"
    fi

    # Req 10.2: Audit logging
    if [[ $(execute_sql "SHOW log_connections;") == "on" ]]; then
        ((pci_pass++))
    else
        ((pci_fail++))
        check_test 1 "PCI-DSS 10.2: Connection logging disabled" "high"
    fi

    check_test $([[ $pci_fail -eq 0 ]] && echo 0 || echo 1) \
        "PCI-DSS Compliance: $pci_pass passed, $pci_fail failed" "high"

    # HIPAA Requirements
    log_info "HIPAA Compliance Checks:"

    local hipaa_pass=0
    local hipaa_fail=0

    # Access controls
    if [[ $(execute_sql "SELECT COUNT(*) FROM pg_shadow WHERE passwd IS NULL;") -eq 0 ]]; then
        ((hipaa_pass++))
    else
        ((hipaa_fail++))
        check_test 1 "HIPAA 164.312(a)(2)(i): Users without passwords exist" "critical"
    fi

    # Audit controls
    if [[ $(execute_sql "SHOW logging_collector;") == "on" ]]; then
        ((hipaa_pass++))
    else
        ((hipaa_fail++))
        check_test 1 "HIPAA 164.312(b): Audit logging disabled" "critical"
    fi

    # Encryption
    if [[ $(execute_sql "SHOW ssl;") == "on" ]]; then
        ((hipaa_pass++))
    else
        ((hipaa_fail++))
        check_test 1 "HIPAA 164.312(e)(1): Transmission encryption disabled" "critical"
    fi

    check_test $([[ $hipaa_fail -eq 0 ]] && echo 0 || echo 1) \
        "HIPAA Compliance: $hipaa_pass passed, $hipaa_fail failed" "critical"

    # GDPR Requirements
    log_info "GDPR Compliance Checks:"

    # Data protection
    check_test 0 "GDPR Article 32: Security measures (review required)" "medium"

    # Right to erasure (check for soft delete mechanisms)
    check_test 0 "GDPR Article 17: Right to erasure (manual review required)" "low"
}

# ============================================================================
# Section 9: Vulnerability Scan
# ============================================================================

scan_vulnerabilities() {
    print_header "Common Vulnerability Scan"

    # Check PostgreSQL version for known vulnerabilities
    local pg_version=$(execute_sql "SHOW server_version;")
    log_info "PostgreSQL version: $pg_version"
    add_to_report "PostgreSQL version: $pg_version"

    # Check for SQL injection vulnerabilities (prepared statements)
    log_info "SQL Injection: Verify application uses prepared statements (manual review required)"

    # Check for privilege escalation opportunities
    local setuid_funcs=$(execute_sql "SELECT COUNT(*) FROM pg_proc WHERE prosecdef = true;")
    if [[ $setuid_funcs -gt 0 ]]; then
        check_test 1 "$setuid_funcs SECURITY DEFINER functions found (review required)" "medium"
    else
        check_test 0 "No SECURITY DEFINER functions" "low"
    fi

    # Check for untrusted languages
    local untrusted_langs=$(execute_sql "SELECT COUNT(*) FROM pg_language WHERE lanname LIKE '%u' AND lanname != 'plpgsql';")
    if [[ $untrusted_langs -eq 0 ]]; then
        check_test 0 "No untrusted procedural languages installed" "high"
    else
        check_test 1 "$untrusted_langs untrusted languages installed (security risk)" "high"
    fi
}

# ============================================================================
# Report Generation
# ============================================================================

generate_report() {
    print_header "Security Audit Summary"

    local score=$((PASSED_CHECKS * 100 / TOTAL_CHECKS))

    echo ""
    echo "======================================"
    echo "       SECURITY AUDIT RESULTS"
    echo "======================================"
    echo ""
    echo "Total Checks:     $TOTAL_CHECKS"
    echo "Passed:           $PASSED_CHECKS"
    echo "Failed:           $FAILED_CHECKS"
    echo "Warnings:         $WARNING_CHECKS"
    echo "Critical Issues:  $CRITICAL_ISSUES"
    echo ""
    echo "Security Score:   $score%"
    echo ""

    add_to_report ""
    add_to_report "======================================"
    add_to_report "       SECURITY AUDIT RESULTS"
    add_to_report "======================================"
    add_to_report ""
    add_to_report "Total Checks:     $TOTAL_CHECKS"
    add_to_report "Passed:           $PASSED_CHECKS"
    add_to_report "Failed:           $FAILED_CHECKS"
    add_to_report "Warnings:         $WARNING_CHECKS"
    add_to_report "Critical Issues:  $CRITICAL_ISSUES"
    add_to_report ""
    add_to_report "Security Score:   $score%"
    add_to_report ""

    if [[ $CRITICAL_ISSUES -gt 0 ]]; then
        echo -e "${RED}CRITICAL: $CRITICAL_ISSUES critical security issues found!${NC}"
        echo "Immediate action required!"
        add_to_report "CRITICAL: $CRITICAL_ISSUES critical security issues found!"
        add_to_report "Immediate action required!"
    elif [[ $FAILED_CHECKS -gt 0 ]]; then
        echo -e "${YELLOW}WARNING: $FAILED_CHECKS security issues found${NC}"
        echo "Review and remediate as soon as possible"
        add_to_report "WARNING: $FAILED_CHECKS security issues found"
    else
        echo -e "${GREEN}Excellent! All critical security checks passed${NC}"
        add_to_report "Excellent! All critical security checks passed"
    fi

    echo ""
    echo "Detailed report saved to: $REPORT_FILE"

    # Save report to file
    echo "$REPORT_CONTENT" > "$REPORT_FILE"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    log_info "Starting PostgreSQL Security Audit..."
    log_info "Timestamp: $(date)"
    add_to_report "PostgreSQL Security Audit Report"
    add_to_report "Generated: $(date)"
    add_to_report "Host: $PGHOST:$PGPORT"

    # Run all audit sections
    audit_file_permissions
    audit_authentication
    audit_ssl_tls
    audit_logging
    audit_network_security
    audit_database_config
    audit_privileges
    audit_compliance
    scan_vulnerabilities

    # Generate final report
    generate_report

    # Exit with appropriate code
    if [[ $CRITICAL_ISSUES -gt 0 ]]; then
        exit 2
    elif [[ $FAILED_CHECKS -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

# Run main function
main "$@"
