#!/bin/bash
#
# Restore Manager for Distributed PostgreSQL Cluster
# Supports: Full restore, PITR, partial restore, validation
# Features: RuVector index rebuilding, automated testing
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
WAL_ARCHIVE_DIR="${WAL_ARCHIVE_DIR:-/var/backups/postgresql/wal}"
RESTORE_DIR="${RESTORE_DIR:-/var/restore/postgresql}"
DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-single-node}"
ENCRYPTION="${ENCRYPTION:-false}"
ENCRYPTION_KEY="${ENCRYPTION_KEY:-}"
VALIDATE_AFTER_RESTORE="${VALIDATE_AFTER_RESTORE:-true}"
REBUILD_INDEXES="${REBUILD_INDEXES:-true}"

# Load environment
if [[ -f "$CONFIG_FILE" ]]; then
    set -a
    source "$CONFIG_FILE"
    set +a
fi

# Logging
LOG_FILE="${RESTORE_DIR}/logs/restore-$(date +%Y%m%d-%H%M%S).log"
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

# Initialize restore environment
init_restore() {
    log "Initializing restore environment..."

    mkdir -p "$RESTORE_DIR"/{data,logs,temp}
    chmod 700 "$RESTORE_DIR"

    log_success "Restore environment initialized"
}

# List available backups
list_backups() {
    log "Available Backups:"
    echo "===================="

    echo -e "\nFull Backups:"
    ls -lht "$BACKUP_DIR/full" 2>/dev/null | grep -E "\.sql|\.sql\.gz|\.sql\.gz\.enc" | head -10

    echo -e "\nConfig Backups:"
    ls -lht "$BACKUP_DIR/config" 2>/dev/null | head -5

    echo -e "\nIndex Backups:"
    ls -lht "$BACKUP_DIR/indexes" 2>/dev/null | head -5

    echo "===================="
}

# Prepare backup for restore
prepare_backup() {
    local backup_file="$1"
    local temp_file="${RESTORE_DIR}/temp/$(basename "$backup_file")"

    log "Preparing backup: $(basename "$backup_file")"

    # Copy to temp location
    cp "$backup_file" "$temp_file"

    # Decrypt if needed
    if [[ "$temp_file" == *.enc ]]; then
        decrypt_backup "$temp_file"
        temp_file="${temp_file%.enc}"
    fi

    # Decompress if needed
    if [[ "$temp_file" == *.gz ]]; then
        log "Decompressing backup..."
        gunzip "$temp_file"
        temp_file="${temp_file%.gz}"
    elif [[ "$temp_file" == *.bz2 ]]; then
        log "Decompressing backup..."
        bunzip2 "$temp_file"
        temp_file="${temp_file%.bz2}"
    elif [[ "$temp_file" == *.xz ]]; then
        log "Decompressing backup..."
        unxz "$temp_file"
        temp_file="${temp_file%.xz}"
    elif [[ "$temp_file" == *.zst ]]; then
        log "Decompressing backup..."
        unzstd "$temp_file"
        temp_file="${temp_file%.zst}"
    fi

    log_success "Backup prepared: $temp_file"
    echo "$temp_file"
}

# Decrypt backup
decrypt_backup() {
    local file="$1"

    if [[ -z "$ENCRYPTION_KEY" ]]; then
        log_error "Encryption key not provided"
        exit 1
    fi

    log "Decrypting backup..."

    openssl enc -aes-256-cbc -d -pbkdf2 -in "$file" -out "${file%.enc}" -k "$ENCRYPTION_KEY"
    rm -f "$file"

    log_success "Decryption completed"
}

# Full restore
restore_full() {
    local backup_file="$1"
    local target_db="${2:-${PGDATABASE:-postgres}}"

    log "Starting full restore from: $(basename "$backup_file")"

    # Prepare backup
    local prepared_file=$(prepare_backup "$backup_file")

    # Confirm restore
    log_warning "This will DROP and recreate database: $target_db"
    read -p "Continue? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log "Restore cancelled"
        exit 0
    fi

    case "$DEPLOYMENT_MODE" in
        single-node)
            restore_full_single "$prepared_file" "$target_db"
            ;;
        citus)
            restore_full_citus "$prepared_file" "$target_db"
            ;;
        patroni)
            restore_full_patroni "$prepared_file" "$target_db"
            ;;
        *)
            log_error "Unknown deployment mode: $DEPLOYMENT_MODE"
            exit 1
            ;;
    esac

    # Rebuild indexes
    if [[ "$REBUILD_INDEXES" == "true" ]]; then
        rebuild_indexes "$target_db"
    fi

    # Validate restore
    if [[ "$VALIDATE_AFTER_RESTORE" == "true" ]]; then
        validate_restore "$target_db"
    fi

    # Cleanup
    rm -f "$prepared_file"

    log_success "Full restore completed"
}

# Single-node full restore
restore_full_single() {
    local backup_file="$1"
    local target_db="$2"

    log "Performing single-node restore..."

    # Drop and recreate database
    log "Dropping database: $target_db"
    psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d postgres <<-EOF
		DROP DATABASE IF EXISTS ${target_db};
		CREATE DATABASE ${target_db};
	EOF

    # Restore backup
    log "Restoring from backup..."
    psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d "$target_db" \
        < "$backup_file" 2>> "$LOG_FILE"

    log_success "Single-node restore completed"
}

# Citus cluster full restore
restore_full_citus() {
    local backup_file="$1"
    local target_db="$2"

    log "Performing Citus cluster restore..."

    # Restore coordinator
    log "Restoring coordinator node..."
    restore_full_single "$backup_file" "$target_db"

    # Rebalance shards if needed
    log "Checking shard distribution..."
    psql -h "${CITUS_COORDINATOR_HOST:-localhost}" -p "${CITUS_COORDINATOR_PORT:-5432}" \
        -U "${PGUSER:-postgres}" -d "$target_db" <<-EOF
		SELECT citus_rebalance_start();
	EOF

    log_success "Citus cluster restore completed"
}

# Patroni cluster full restore
restore_full_patroni() {
    local backup_file="$1"
    local target_db="$2"

    log "Performing Patroni cluster restore..."

    # Get primary node
    local primary_host=$(curl -s "http://${PATRONI_HOST:-localhost}:${PATRONI_PORT:-8008}/primary" | jq -r '.host // "localhost"')

    log "Restoring to primary node: $primary_host"

    # Stop Patroni temporarily
    log_warning "Stopping Patroni cluster..."
    curl -s -X DELETE "http://${PATRONI_HOST:-localhost}:${PATRONI_PORT:-8008}/config" -d '{"pause":true}'

    # Restore
    PGHOST="$primary_host" restore_full_single "$backup_file" "$target_db"

    # Resume Patroni
    log "Resuming Patroni cluster..."
    curl -s -X DELETE "http://${PATRONI_HOST:-localhost}:${PATRONI_PORT:-8008}/config" -d '{"pause":false}'

    log_success "Patroni cluster restore completed"
}

# Point-in-time recovery (PITR)
restore_pitr() {
    local backup_file="$1"
    local target_time="$2"
    local target_db="${3:-${PGDATABASE:-postgres}}"

    log "Starting PITR to: $target_time"

    # Prepare backup
    local prepared_file=$(prepare_backup "$backup_file")

    # Create recovery configuration
    local recovery_conf="${RESTORE_DIR}/temp/recovery.conf"
    cat > "$recovery_conf" <<-EOF
		restore_command = 'cp ${WAL_ARCHIVE_DIR}/%f %p'
		recovery_target_time = '$target_time'
		recovery_target_action = 'promote'
	EOF

    log "Recovery configuration created"

    # Restore base backup
    restore_full_single "$prepared_file" "$target_db"

    # Apply WAL files up to target time
    log "Applying WAL files..."

    # For PostgreSQL 12+, use recovery.signal
    local pg_data="/var/lib/postgresql/data"
    touch "${pg_data}/recovery.signal"
    cp "$recovery_conf" "${pg_data}/postgresql.auto.conf"

    # Restart PostgreSQL
    log "Restarting PostgreSQL for recovery..."
    systemctl restart postgresql || docker restart ruvector-db || true

    # Wait for recovery
    log "Waiting for recovery to complete..."
    for i in {1..60}; do
        if psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d "$target_db" \
            -c "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q "f"; then
            log_success "Recovery completed"
            break
        fi
        sleep 5
    done

    # Cleanup
    rm -f "$prepared_file" "$recovery_conf"

    log_success "PITR completed"
}

# Partial restore (single table/schema)
restore_partial() {
    local backup_file="$1"
    local object_type="$2"  # table or schema
    local object_name="$3"
    local target_db="${4:-${PGDATABASE:-postgres}}"

    log "Starting partial restore: $object_type $object_name"

    # Prepare backup
    local prepared_file=$(prepare_backup "$backup_file")

    case "$object_type" in
        table)
            restore_table "$prepared_file" "$object_name" "$target_db"
            ;;
        schema)
            restore_schema "$prepared_file" "$object_name" "$target_db"
            ;;
        *)
            log_error "Unknown object type: $object_type"
            exit 1
            ;;
    esac

    # Cleanup
    rm -f "$prepared_file"

    log_success "Partial restore completed"
}

# Restore single table
restore_table() {
    local backup_file="$1"
    local table_name="$2"
    local target_db="$3"

    log "Restoring table: $table_name"

    # Extract table from backup
    local temp_file="${RESTORE_DIR}/temp/${table_name}.sql"

    # Use pg_restore or grep depending on backup format
    if [[ "$backup_file" == *.sql ]]; then
        # Plain SQL backup
        awk "/CREATE TABLE ${table_name}/,/COPY ${table_name}/; /COPY ${table_name}/,/^\\\\./;" \
            "$backup_file" > "$temp_file"
    else
        log_error "Unsupported backup format for partial restore"
        exit 1
    fi

    # Restore table
    psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d "$target_db" \
        < "$temp_file" 2>> "$LOG_FILE"

    rm -f "$temp_file"

    log_success "Table restored: $table_name"
}

# Restore schema
restore_schema() {
    local backup_file="$1"
    local schema_name="$2"
    local target_db="$3"

    log "Restoring schema: $schema_name"

    # Extract schema from backup
    local temp_file="${RESTORE_DIR}/temp/${schema_name}.sql"

    grep -A 999999 "CREATE SCHEMA ${schema_name}" "$backup_file" | \
        grep -B 999999 "^--" | \
        head -n -1 > "$temp_file"

    # Restore schema
    psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d "$target_db" \
        < "$temp_file" 2>> "$LOG_FILE"

    rm -f "$temp_file"

    log_success "Schema restored: $schema_name"
}

# Rebuild RuVector indexes
rebuild_indexes() {
    local target_db="$1"

    log "Rebuilding RuVector indexes..."

    # Get latest index backup
    local index_backup=$(ls -t "$BACKUP_DIR/indexes"/ruvector-indexes-*.sql* 2>/dev/null | head -1)

    if [[ -z "$index_backup" ]]; then
        log_warning "No index backup found, skipping index rebuild"
        return 0
    fi

    # Prepare index backup
    local prepared_file=$(prepare_backup "$index_backup")

    # Rebuild indexes
    psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d "$target_db" <<-EOF
		-- Drop existing RuVector indexes
		SELECT 'DROP INDEX IF EXISTS ' || schemaname || '.' || indexname || ';'
		FROM pg_indexes
		WHERE indexdef LIKE '%ruvector%';

		-- Recreate indexes from backup
		\i $prepared_file
	EOF

    # Reindex
    log "Reindexing RuVector tables..."
    psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d "$target_db" <<-EOF
		REINDEX DATABASE ${target_db};
	EOF

    rm -f "$prepared_file"

    log_success "Indexes rebuilt"
}

# Validate restore
validate_restore() {
    local target_db="$1"

    log "Validating restore..."

    # Check database exists
    if ! psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -lqt | cut -d \| -f 1 | grep -qw "$target_db"; then
        log_error "Database not found: $target_db"
        return 1
    fi

    # Check RuVector extension
    local has_ruvector=$(psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d "$target_db" \
        -tAc "SELECT COUNT(*) FROM pg_extension WHERE extname='ruvector';")

    if [[ "$has_ruvector" -eq 0 ]]; then
        log_warning "RuVector extension not installed"
    else
        log_success "RuVector extension verified"
    fi

    # Check table count
    local table_count=$(psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d "$target_db" \
        -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema');")

    log "Tables found: $table_count"

    # Check index count
    local index_count=$(psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d "$target_db" \
        -tAc "SELECT COUNT(*) FROM pg_indexes WHERE schemaname NOT IN ('pg_catalog', 'information_schema');")

    log "Indexes found: $index_count"

    # Run test queries
    log "Running test queries..."

    psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d "$target_db" <<-EOF
		-- Test basic query
		SELECT version();

		-- Test RuVector query if available
		DO \$\$
		BEGIN
		    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname='ruvector') THEN
		        PERFORM count(*) FROM pg_indexes WHERE indexdef LIKE '%ruvector%';
		    END IF;
		END \$\$;
	EOF

    log_success "Validation completed"
}

# Automated restore test
test_restore() {
    local backup_file="$1"
    local test_db="restore_test_$(date +%s)"

    log "Starting automated restore test..."

    # Create test database
    psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d postgres <<-EOF
		CREATE DATABASE ${test_db};
	EOF

    # Restore to test database
    local prepared_file=$(prepare_backup "$backup_file")
    VALIDATE_AFTER_RESTORE=false restore_full_single "$prepared_file" "$test_db"

    # Run validation
    validate_restore "$test_db"

    # Cleanup test database
    log "Cleaning up test database..."
    psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d postgres <<-EOF
		DROP DATABASE IF EXISTS ${test_db};
	EOF

    rm -f "$prepared_file"

    log_success "Restore test completed"
}

# Usage information
usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  list                         List available backups
  full <backup-file> [db]      Full restore from backup
  pitr <backup-file> <time> [db]  Point-in-time recovery
  partial <backup-file> <type> <name> [db]  Partial restore (table/schema)
  indexes [db]                 Rebuild RuVector indexes
  validate [db]                Validate restored database
  test <backup-file>           Automated restore test
  init                         Initialize restore environment

Environment Variables:
  BACKUP_DIR              Backup directory (default: /var/backups/postgresql)
  WAL_ARCHIVE_DIR         WAL archive directory
  RESTORE_DIR             Restore working directory (default: /var/restore/postgresql)
  DEPLOYMENT_MODE         Deployment mode: single-node|citus|patroni (default: single-node)
  ENCRYPTION              Encryption enabled: true|false (default: false)
  ENCRYPTION_KEY          Encryption key (required if ENCRYPTION=true)
  VALIDATE_AFTER_RESTORE  Validate after restore: true|false (default: true)
  REBUILD_INDEXES         Rebuild indexes: true|false (default: true)

Examples:
  # List available backups
  $0 list

  # Full restore
  $0 full /var/backups/postgresql/full/full-daily-20260212.sql.gz my_database

  # Point-in-time recovery
  $0 pitr /var/backups/postgresql/full/full-daily-20260212.sql.gz "2026-02-12 10:30:00" my_database

  # Partial restore (single table)
  $0 partial /var/backups/postgresql/full/full-daily-20260212.sql.gz table users my_database

  # Rebuild indexes
  $0 indexes my_database

  # Test restore
  $0 test /var/backups/postgresql/full/full-daily-20260212.sql.gz

EOF
}

# Main execution
main() {
    local command="${1:-}"

    case "$command" in
        init)
            init_restore
            ;;
        list)
            list_backups
            ;;
        full)
            if [[ -z "${2:-}" ]]; then
                log_error "Backup file required"
                usage
                exit 1
            fi
            restore_full "$2" "${3:-}"
            ;;
        pitr)
            if [[ -z "${2:-}" ]] || [[ -z "${3:-}" ]]; then
                log_error "Backup file and target time required"
                usage
                exit 1
            fi
            restore_pitr "$2" "$3" "${4:-}"
            ;;
        partial)
            if [[ -z "${2:-}" ]] || [[ -z "${3:-}" ]] || [[ -z "${4:-}" ]]; then
                log_error "Backup file, object type, and object name required"
                usage
                exit 1
            fi
            restore_partial "$2" "$3" "$4" "${5:-}"
            ;;
        indexes)
            rebuild_indexes "${2:-${PGDATABASE:-postgres}}"
            ;;
        validate)
            validate_restore "${2:-${PGDATABASE:-postgres}}"
            ;;
        test)
            if [[ -z "${2:-}" ]]; then
                log_error "Backup file required"
                usage
                exit 1
            fi
            test_restore "$2"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
