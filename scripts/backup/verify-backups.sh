#!/bin/bash
#
# Backup Verification Script
# Tests backup integrity, automated restore testing, monitoring
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/.env"

# Default configuration
BACKUP_DIR="${BACKUP_DIR:-/var/backups/postgresql}"
TEST_DB_PREFIX="backup_verify_test"
PARALLEL_TESTS="${PARALLEL_TESTS:-2}"
EMAIL_NOTIFICATIONS="${EMAIL_NOTIFICATIONS:-false}"
EMAIL_TO="${EMAIL_TO:-}"

# Load environment
if [[ -f "$CONFIG_FILE" ]]; then
    set -a
    source "$CONFIG_FILE"
    set +a
fi

# Logging
LOG_FILE="${BACKUP_DIR}/logs/verify-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✓${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ✗${NC} $*" | tee -a "$LOG_FILE" >&2
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠${NC} $*" | tee -a "$LOG_FILE"
}

# Test results
declare -A test_results
test_count=0
pass_count=0
fail_count=0

# Record test result
record_test() {
    local test_name="$1"
    local result="$2"

    test_results["$test_name"]="$result"
    ((test_count++))

    if [[ "$result" == "PASS" ]]; then
        ((pass_count++))
        log_success "Test passed: $test_name"
    else
        ((fail_count++))
        log_error "Test failed: $test_name"
    fi
}

# Verify file integrity
verify_file_integrity() {
    local backup_file="$1"
    local test_name="File Integrity: $(basename "$backup_file")"

    log "Verifying file integrity..."

    # Check file exists
    if [[ ! -f "$backup_file" ]]; then
        record_test "$test_name" "FAIL"
        return 1
    fi

    # Check file size
    local file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null)
    if [[ "$file_size" -eq 0 ]]; then
        log_error "File is empty"
        record_test "$test_name" "FAIL"
        return 1
    fi

    # Check compression integrity
    if [[ "$backup_file" == *.gz ]]; then
        if gzip -t "$backup_file" 2>/dev/null; then
            log "Gzip integrity OK"
        else
            log_error "Gzip integrity check failed"
            record_test "$test_name" "FAIL"
            return 1
        fi
    elif [[ "$backup_file" == *.bz2 ]]; then
        if bzip2 -t "$backup_file" 2>/dev/null; then
            log "Bzip2 integrity OK"
        else
            log_error "Bzip2 integrity check failed"
            record_test "$test_name" "FAIL"
            return 1
        fi
    elif [[ "$backup_file" == *.xz ]]; then
        if xz -t "$backup_file" 2>/dev/null; then
            log "XZ integrity OK"
        else
            log_error "XZ integrity check failed"
            record_test "$test_name" "FAIL"
            return 1
        fi
    fi

    # Check SQL syntax (for uncompressed files)
    if [[ "$backup_file" == *.sql ]]; then
        if grep -q "PostgreSQL database dump" "$backup_file"; then
            log "SQL header verified"
        else
            log_warning "SQL header not found"
        fi
    fi

    record_test "$test_name" "PASS"
}

# Test restore functionality
test_restore() {
    local backup_file="$1"
    local test_name="Restore Test: $(basename "$backup_file")"
    local test_db="${TEST_DB_PREFIX}_$(date +%s)_$$"

    log "Testing restore: $(basename "$backup_file")"

    # Create test database
    if ! psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d postgres \
        -c "CREATE DATABASE ${test_db};" 2>> "$LOG_FILE"; then
        log_error "Failed to create test database"
        record_test "$test_name" "FAIL"
        return 1
    fi

    # Prepare backup
    local prepared_file="$backup_file"

    # Decompress if needed
    if [[ "$backup_file" == *.gz ]]; then
        prepared_file="/tmp/$(basename "${backup_file%.gz}")"
        gunzip -c "$backup_file" > "$prepared_file"
    fi

    # Restore
    if psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d "$test_db" \
        < "$prepared_file" 2>> "$LOG_FILE"; then
        log "Restore successful"

        # Verify data
        local table_count=$(psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d "$test_db" \
            -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';")

        log "Tables restored: $table_count"

        if [[ "$table_count" -gt 0 ]]; then
            record_test "$test_name" "PASS"
        else
            log_error "No tables found after restore"
            record_test "$test_name" "FAIL"
        fi
    else
        log_error "Restore failed"
        record_test "$test_name" "FAIL"
    fi

    # Cleanup
    psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d postgres \
        -c "DROP DATABASE IF EXISTS ${test_db};" 2>> "$LOG_FILE" || true

    if [[ "$prepared_file" != "$backup_file" ]]; then
        rm -f "$prepared_file"
    fi
}

# Test RuVector indexes
test_ruvector_indexes() {
    local backup_file="$1"
    local test_name="RuVector Indexes: $(basename "$backup_file")"
    local test_db="${TEST_DB_PREFIX}_ruvector_$(date +%s)"

    log "Testing RuVector indexes..."

    # Create test database
    psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d postgres \
        -c "CREATE DATABASE ${test_db};" 2>> "$LOG_FILE"

    # Prepare and restore backup
    local prepared_file="$backup_file"
    if [[ "$backup_file" == *.gz ]]; then
        prepared_file="/tmp/$(basename "${backup_file%.gz}")"
        gunzip -c "$backup_file" > "$prepared_file"
    fi

    psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d "$test_db" \
        < "$prepared_file" 2>> "$LOG_FILE"

    # Check RuVector extension
    local has_ruvector=$(psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d "$test_db" \
        -tAc "SELECT COUNT(*) FROM pg_extension WHERE extname='ruvector';")

    if [[ "$has_ruvector" -gt 0 ]]; then
        # Check RuVector indexes
        local index_count=$(psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d "$test_db" \
            -tAc "SELECT COUNT(*) FROM pg_indexes WHERE indexdef LIKE '%ruvector%';")

        log "RuVector indexes found: $index_count"

        if [[ "$index_count" -gt 0 ]]; then
            # Test index query
            psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d "$test_db" \
                -c "SELECT indexname, indexdef FROM pg_indexes WHERE indexdef LIKE '%ruvector%' LIMIT 1;" \
                >> "$LOG_FILE" 2>&1

            record_test "$test_name" "PASS"
        else
            log_warning "No RuVector indexes found"
            record_test "$test_name" "PASS"
        fi
    else
        log_warning "RuVector extension not installed"
        record_test "$test_name" "PASS"
    fi

    # Cleanup
    psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d postgres \
        -c "DROP DATABASE IF EXISTS ${test_db};" 2>> "$LOG_FILE" || true

    if [[ "$prepared_file" != "$backup_file" ]]; then
        rm -f "$prepared_file"
    fi
}

# Monitor backup sizes
monitor_backup_sizes() {
    log "Monitoring backup sizes..."

    echo -e "\nBackup Size Analysis:"
    echo "===================="

    # Full backups
    local full_total=$(du -sh "$BACKUP_DIR/full" 2>/dev/null | cut -f1)
    local full_count=$(find "$BACKUP_DIR/full" -type f 2>/dev/null | wc -l)
    echo "Full Backups: $full_count files, $full_total"

    # WAL archives
    local wal_total=$(du -sh "$WAL_ARCHIVE_DIR" 2>/dev/null | cut -f1)
    local wal_count=$(find "$WAL_ARCHIVE_DIR" -type f 2>/dev/null | wc -l)
    echo "WAL Archives: $wal_count files, $wal_total"

    # Config backups
    local config_total=$(du -sh "$BACKUP_DIR/config" 2>/dev/null | cut -f1)
    local config_count=$(find "$BACKUP_DIR/config" -type f 2>/dev/null | wc -l)
    echo "Config Backups: $config_count files, $config_total"

    # Index backups
    local index_total=$(du -sh "$BACKUP_DIR/indexes" 2>/dev/null | cut -f1)
    local index_count=$(find "$BACKUP_DIR/indexes" -type f 2>/dev/null | wc -l)
    echo "Index Backups: $index_count files, $index_total"

    # Total
    local total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    echo -e "\nTotal Backup Size: $total_size"
    echo "===================="

    # Growth rate (compare with 24h ago)
    local size_file="${BACKUP_DIR}/logs/size-history.log"
    local current_size=$(du -sb "$BACKUP_DIR" 2>/dev/null | cut -f1)

    if [[ -f "$size_file" ]]; then
        local prev_size=$(tail -1 "$size_file" | cut -d' ' -f1)
        local growth=$((current_size - prev_size))
        local growth_percent=$(awk "BEGIN {printf \"%.2f\", ($growth / $prev_size) * 100}")

        echo -e "\n24h Growth: $(numfmt --to=iec $growth) ($growth_percent%)"
    fi

    # Record current size
    echo "$current_size $(date +%s)" >> "$size_file"
}

# Storage capacity planning
check_storage_capacity() {
    log "Checking storage capacity..."

    local backup_disk=$(df -h "$BACKUP_DIR" | tail -1)
    local used_percent=$(echo "$backup_disk" | awk '{print $5}' | sed 's/%//')

    echo -e "\nStorage Capacity:"
    echo "===================="
    echo "$backup_disk"
    echo "===================="

    if [[ "$used_percent" -gt 90 ]]; then
        log_error "Storage usage critical: ${used_percent}%"
        return 1
    elif [[ "$used_percent" -gt 80 ]]; then
        log_warning "Storage usage high: ${used_percent}%"
        return 0
    else
        log_success "Storage usage OK: ${used_percent}%"
        return 0
    fi
}

# Verify all recent backups
verify_all_backups() {
    log "Verifying all recent backups..."

    # Find recent full backups (last 7 days)
    local recent_backups=$(find "$BACKUP_DIR/full" -type f -mtime -7 2>/dev/null)

    if [[ -z "$recent_backups" ]]; then
        log_warning "No recent backups found"
        return 1
    fi

    # Verify each backup
    echo "$recent_backups" | while read -r backup_file; do
        log "Verifying: $(basename "$backup_file")"

        # File integrity check
        verify_file_integrity "$backup_file"

        # Restore test (only for daily backups to avoid too many tests)
        if [[ "$(basename "$backup_file")" =~ daily ]]; then
            test_restore "$backup_file"
            test_ruvector_indexes "$backup_file"
        fi
    done
}

# Generate report
generate_report() {
    log "Generating verification report..."

    local report_file="${BACKUP_DIR}/logs/verify-report-$(date +%Y%m%d-%H%M%S).txt"

    cat > "$report_file" <<-EOF
		PostgreSQL Backup Verification Report
		Generated: $(date)

		Summary:
		========
		Total Tests: $test_count
		Passed: $pass_count
		Failed: $fail_count
		Success Rate: $(awk "BEGIN {printf \"%.2f\", ($pass_count / $test_count) * 100}")%

		Test Results:
		=============
	EOF

    for test_name in "${!test_results[@]}"; do
        echo "$test_name: ${test_results[$test_name]}" >> "$report_file"
    done

    echo "" >> "$report_file"

    # Add storage info
    monitor_backup_sizes >> "$report_file"
    check_storage_capacity >> "$report_file"

    log_success "Report generated: $report_file"

    # Send email notification
    if [[ "$EMAIL_NOTIFICATIONS" == "true" ]] && [[ -n "$EMAIL_TO" ]]; then
        local subject="Backup Verification Report - $(date +%Y-%m-%d)"
        mail -s "$subject" "$EMAIL_TO" < "$report_file"
    fi

    # Display summary
    cat "$report_file"
}

# Usage information
usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  all                          Verify all recent backups
  file <backup-file>           Verify file integrity
  restore <backup-file>        Test restore
  indexes <backup-file>        Test RuVector indexes
  sizes                        Monitor backup sizes
  capacity                     Check storage capacity
  report                       Generate verification report

Environment Variables:
  BACKUP_DIR              Backup directory (default: /var/backups/postgresql)
  TEST_DB_PREFIX          Test database prefix (default: backup_verify_test)
  PARALLEL_TESTS          Parallel test count (default: 2)
  EMAIL_NOTIFICATIONS     Send email notifications: true|false (default: false)
  EMAIL_TO                Email address for notifications

Examples:
  $0 all
  $0 file /var/backups/postgresql/full/full-daily-20260212.sql.gz
  $0 restore /var/backups/postgresql/full/full-daily-20260212.sql.gz
  $0 sizes
  $0 report

EOF
}

# Main execution
main() {
    local command="${1:-}"

    case "$command" in
        all)
            verify_all_backups
            generate_report
            ;;
        file)
            if [[ -z "${2:-}" ]]; then
                log_error "Backup file required"
                usage
                exit 1
            fi
            verify_file_integrity "$2"
            ;;
        restore)
            if [[ -z "${2:-}" ]]; then
                log_error "Backup file required"
                usage
                exit 1
            fi
            test_restore "$2"
            ;;
        indexes)
            if [[ -z "${2:-}" ]]; then
                log_error "Backup file required"
                usage
                exit 1
            fi
            test_ruvector_indexes "$2"
            ;;
        sizes)
            monitor_backup_sizes
            ;;
        capacity)
            check_storage_capacity
            ;;
        report)
            generate_report
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
