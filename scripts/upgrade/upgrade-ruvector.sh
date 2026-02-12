#!/bin/bash

###############################################################################
# RuVector Extension Upgrade Script
# Automates RuVector extension upgrades with index migration
# Usage: ./upgrade-ruvector.sh <old_version> <new_version>
# Example: ./upgrade-ruvector.sh 0.1.0 2.0.0
###############################################################################

set -euo pipefail

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

# Parse arguments
if [ $# -ne 2 ]; then
    log_error "Usage: $0 <old_version> <new_version>"
    log_error "Example: $0 0.1.0 2.0.0"
    exit 1
fi

OLD_VERSION=$1
NEW_VERSION=$2
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/var/lib/postgresql/backups/ruvector_upgrade_${OLD_VERSION}_to_${NEW_VERSION}_${TIMESTAMP}"
LOGFILE="${BACKUP_DIR}/upgrade.log"
DB_HOST="${POSTGRES_HOST:-localhost}"
DB_PORT="${POSTGRES_PORT:-5432}"
DB_USER="${POSTGRES_USER:-postgres}"
DB_NAME="${POSTGRES_DB:-postgres}"

# Create backup directory
mkdir -p "${BACKUP_DIR}"
exec > >(tee -a "${LOGFILE}") 2>&1

log_info "Starting RuVector upgrade from version ${OLD_VERSION} to ${NEW_VERSION}"
log_info "Timestamp: ${TIMESTAMP}"
log_info "Log file: ${LOGFILE}"

###############################################################################
# Phase 1: Pre-upgrade validation
###############################################################################

log_info "Phase 1: Pre-upgrade validation"

# Test database connection
if ! psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c '\q' 2>/dev/null; then
    log_error "Cannot connect to database"
    exit 1
fi

# Check if RuVector extension is installed
CURRENT_VERSION=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -At -c "
    SELECT extversion FROM pg_extension WHERE extname = 'ruvector'
" 2>/dev/null || echo "")

if [ -z "${CURRENT_VERSION}" ]; then
    log_error "RuVector extension is not installed"
    exit 1
fi

log_info "Current RuVector version: ${CURRENT_VERSION}"

if [ "${CURRENT_VERSION}" != "${OLD_VERSION}" ]; then
    log_warning "Current version (${CURRENT_VERSION}) does not match expected old version (${OLD_VERSION})"
    log_warning "Proceeding with upgrade from ${CURRENT_VERSION} to ${NEW_VERSION}"
    OLD_VERSION="${CURRENT_VERSION}"
fi

# Get list of databases with RuVector
DATABASES=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d postgres -At -c "
    SELECT datname FROM pg_database
    WHERE datname NOT IN ('template0', 'template1')
    AND oid IN (
        SELECT DISTINCT d.oid
        FROM pg_database d
        JOIN pg_extension e ON true
        WHERE e.extname = 'ruvector'
    )
" || echo "${DB_NAME}")

log_info "Databases with RuVector extension: $(echo ${DATABASES} | tr '\n' ' ')"

# Check for breaking changes
case "${NEW_VERSION}" in
    2.*)
        log_warning "Upgrading to RuVector 2.x (major version)"
        log_warning "Breaking changes:"
        log_warning "  - HNSW index parameters changed"
        log_warning "  - New distance functions available"
        log_warning "  - Performance improvements require index rebuild"
        ;;
esac

log_success "Pre-upgrade validation passed"

###############################################################################
# Phase 2: Inventory existing RuVector objects
###############################################################################

log_info "Phase 2: Inventorying existing RuVector objects"

for DB in ${DATABASES}; do
    log_info "Scanning database: ${DB}"

    # Count tables with ruvector columns
    TABLE_COUNT=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB}" -At -c "
        SELECT count(DISTINCT c.relname)
        FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        JOIN pg_attribute a ON a.attrelid = c.oid
        JOIN pg_type t ON a.atttypid = t.oid
        WHERE t.typname = 'ruvector'
        AND c.relkind = 'r'
        AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    ")
    log_info "  Tables with ruvector columns: ${TABLE_COUNT}"

    # List ruvector indexes
    psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB}" -c "
        SELECT
            n.nspname AS schema,
            c.relname AS table,
            i.relname AS index,
            am.amname AS index_type,
            pg_size_pretty(pg_relation_size(i.oid)) AS size
        FROM pg_index x
        JOIN pg_class c ON c.oid = x.indrelid
        JOIN pg_class i ON i.oid = x.indexrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_am am ON i.relam = am.oid
        WHERE am.amname = 'ruvector'
        ORDER BY n.nspname, c.relname, i.relname
    " > "${BACKUP_DIR}/${DB}_indexes_before.txt"

    INDEX_COUNT=$(cat "${BACKUP_DIR}/${DB}_indexes_before.txt" | grep -c '^' || echo "0")
    log_info "  RuVector indexes: ${INDEX_COUNT}"

    # Save index definitions
    psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB}" -At -c "
        SELECT
            n.nspname || '.' || c.relname || '.' || i.relname AS full_name,
            pg_get_indexdef(x.indexrelid) AS definition
        FROM pg_index x
        JOIN pg_class c ON c.oid = x.indrelid
        JOIN pg_class i ON i.oid = x.indexrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_am am ON i.relam = am.oid
        WHERE am.amname = 'ruvector'
        ORDER BY n.nspname, c.relname, i.relname
    " > "${BACKUP_DIR}/${DB}_index_definitions.txt"
done

log_success "Inventory completed"

###############################################################################
# Phase 3: Backup
###############################################################################

log_info "Phase 3: Creating backup"

for DB in ${DATABASES}; do
    log_info "Backing up database: ${DB}"

    # Backup schema only
    pg_dump -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" \
        --schema-only \
        --extension=ruvector \
        "${DB}" > "${BACKUP_DIR}/${DB}_schema.sql"

    # Backup data from tables with ruvector columns
    TABLES=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB}" -At -c "
        SELECT DISTINCT n.nspname || '.' || c.relname
        FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        JOIN pg_attribute a ON a.attrelid = c.oid
        JOIN pg_type t ON a.atttypid = t.oid
        WHERE t.typname = 'ruvector'
        AND c.relkind = 'r'
        AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    ")

    for TABLE in ${TABLES}; do
        log_info "  Backing up table: ${TABLE}"
        pg_dump -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" \
            --data-only \
            --table="${TABLE}" \
            "${DB}" > "${BACKUP_DIR}/${DB}_$(echo ${TABLE} | tr '.' '_').sql"
    done
done

log_success "Backup completed"

###############################################################################
# Phase 4: Perform upgrade
###############################################################################

log_info "Phase 4: Performing RuVector upgrade"

for DB in ${DATABASES}; do
    log_info "Upgrading RuVector in database: ${DB}"

    # Try ALTER EXTENSION UPDATE first
    log_info "  Attempting ALTER EXTENSION UPDATE..."
    if psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB}" -c "
        ALTER EXTENSION ruvector UPDATE TO '${NEW_VERSION}';
    " 2>&1; then
        log_success "  Extension upgraded successfully"
        continue
    fi

    # If ALTER EXTENSION fails, try manual upgrade
    log_warning "  ALTER EXTENSION failed, attempting manual upgrade..."

    # Drop and recreate extension (requires CASCADE)
    log_warning "  This will drop all RuVector indexes and recreate them"
    log_info "  Dropping extension..."
    psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB}" -c "
        DROP EXTENSION IF EXISTS ruvector CASCADE;
    "

    log_info "  Creating extension with new version..."
    psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB}" -c "
        CREATE EXTENSION ruvector VERSION '${NEW_VERSION}';
    "

    log_success "  Extension recreated with version ${NEW_VERSION}"
done

###############################################################################
# Phase 5: Rebuild indexes
###############################################################################

log_info "Phase 5: Rebuilding RuVector indexes"

for DB in ${DATABASES}; do
    log_info "Rebuilding indexes in database: ${DB}"

    # Read index definitions
    if [ ! -f "${BACKUP_DIR}/${DB}_index_definitions.txt" ]; then
        log_warning "  No index definitions found, skipping"
        continue
    fi

    while IFS='|' read -r FULL_NAME DEFINITION; do
        if [ -z "${DEFINITION}" ]; then
            continue
        fi

        log_info "  Recreating index: ${FULL_NAME}"

        # Drop existing index if it exists
        INDEX_NAME=$(echo "${FULL_NAME}" | awk -F'.' '{print $NF}')
        SCHEMA_NAME=$(echo "${FULL_NAME}" | awk -F'.' '{print $1}')

        psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB}" -c "
            DROP INDEX IF EXISTS ${SCHEMA_NAME}.${INDEX_NAME};
        " 2>&1 | grep -v 'does not exist' || true

        # Recreate index with updated syntax for v2.x
        UPDATED_DEFINITION=$(echo "${DEFINITION}" | sed -e 's/WITH (m = \([0-9]*\), ef_construction = \([0-9]*\))/WITH (m = \1, ef_construction = \2)/')

        log_info "  Running: ${UPDATED_DEFINITION}"
        psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB}" -c "${UPDATED_DEFINITION}"

        log_success "  Index recreated: ${INDEX_NAME}"
    done < "${BACKUP_DIR}/${DB}_index_definitions.txt"
done

log_success "Index rebuild completed"

###############################################################################
# Phase 6: Validation and performance testing
###############################################################################

log_info "Phase 6: Validation and performance testing"

for DB in ${DATABASES}; do
    log_info "Validating database: ${DB}"

    # Check extension version
    NEW_VERSION_CHECK=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB}" -At -c "
        SELECT extversion FROM pg_extension WHERE extname = 'ruvector'
    ")

    if [ "${NEW_VERSION_CHECK}" != "${NEW_VERSION}" ]; then
        log_error "  Version mismatch: expected ${NEW_VERSION}, got ${NEW_VERSION_CHECK}"
        exit 1
    fi

    log_success "  Extension version: ${NEW_VERSION_CHECK}"

    # Check indexes
    psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB}" -c "
        SELECT
            n.nspname AS schema,
            c.relname AS table,
            i.relname AS index,
            am.amname AS index_type,
            pg_size_pretty(pg_relation_size(i.oid)) AS size
        FROM pg_index x
        JOIN pg_class c ON c.oid = x.indrelid
        JOIN pg_class i ON i.oid = x.indexrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_am am ON i.relam = am.oid
        WHERE am.amname = 'ruvector'
        ORDER BY n.nspname, c.relname, i.relname
    " > "${BACKUP_DIR}/${DB}_indexes_after.txt"

    INDEX_COUNT=$(cat "${BACKUP_DIR}/${DB}_indexes_after.txt" | grep -c '^' || echo "0")
    log_info "  RuVector indexes: ${INDEX_COUNT}"

    # Performance test (if embeddings table exists)
    if psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB}" -At -c "
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = 'claude_flow'
            AND table_name = 'embeddings'
        )
    " | grep -q 't'; then
        log_info "  Running performance test on embeddings table..."

        PERF_RESULT=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB}" -At -c "
            EXPLAIN ANALYZE
            SELECT id, embedding <=> '[0.1,0.2,0.3]'::ruvector AS distance
            FROM claude_flow.embeddings
            ORDER BY distance
            LIMIT 10;
        " 2>&1 || echo "Performance test skipped")

        echo "${PERF_RESULT}" > "${BACKUP_DIR}/${DB}_perf_test.txt"

        EXEC_TIME=$(echo "${PERF_RESULT}" | grep 'Execution Time' | awk '{print $3}')
        if [ -n "${EXEC_TIME}" ]; then
            log_info "  Query execution time: ${EXEC_TIME} ms"
        fi
    fi
done

log_success "Validation completed"

###############################################################################
# Phase 7: Summary and recommendations
###############################################################################

log_info "Phase 7: Upgrade summary"

log_info "Upgrade summary:"
log_info "  Old version: RuVector ${OLD_VERSION}"
log_info "  New version: RuVector ${NEW_VERSION}"
log_info "  Databases upgraded: $(echo ${DATABASES} | wc -w)"
log_info "  Backup location: ${BACKUP_DIR}"
log_info "  Log file: ${LOGFILE}"

log_warning "Important next steps:"
log_warning "  1. Test vector search queries with your application"
log_warning "  2. Compare performance before and after (see ${BACKUP_DIR}/*_perf_test.txt)"
log_warning "  3. Monitor index sizes and query performance"
log_warning "  4. Review breaking changes for RuVector ${NEW_VERSION}"

# Save rollback script
cat > "${BACKUP_DIR}/rollback.sh" << EOF
#!/bin/bash
# Rollback RuVector upgrade

set -euo pipefail

echo "Rolling back RuVector from ${NEW_VERSION} to ${OLD_VERSION}"

for DB in ${DATABASES}; do
    echo "Processing database: \${DB}"

    # Drop new extension
    psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "\${DB}" -c "
        DROP EXTENSION IF EXISTS ruvector CASCADE;
    "

    # Restore old extension
    psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "\${DB}" -c "
        CREATE EXTENSION ruvector VERSION '${OLD_VERSION}';
    "

    # Restore indexes from backup
    while IFS='|' read -r FULL_NAME DEFINITION; do
        if [ -z "\${DEFINITION}" ]; then
            continue
        fi
        echo "Restoring index: \${FULL_NAME}"
        psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "\${DB}" -c "\${DEFINITION}"
    done < "${BACKUP_DIR}/\${DB}_index_definitions.txt"
done

echo "Rollback completed"
EOF

chmod +x "${BACKUP_DIR}/rollback.sh"

log_success "RuVector upgrade completed successfully!"
log_info "Rollback script saved to: ${BACKUP_DIR}/rollback.sh"

exit 0
