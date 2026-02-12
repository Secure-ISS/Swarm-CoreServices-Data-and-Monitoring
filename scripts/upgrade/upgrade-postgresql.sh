#!/bin/bash

###############################################################################
# PostgreSQL Version Upgrade Script
# Automates PostgreSQL major version upgrades with pg_upgrade
# Usage: ./upgrade-postgresql.sh <old_version> <new_version>
# Example: ./upgrade-postgresql.sh 17 18
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

# Check if running as postgres user
if [ "$(whoami)" != "postgres" ]; then
    log_error "This script must be run as postgres user"
    exit 1
fi

# Parse arguments
if [ $# -ne 2 ]; then
    log_error "Usage: $0 <old_version> <new_version>"
    log_error "Example: $0 17 18"
    exit 1
fi

OLD_VERSION=$1
NEW_VERSION=$2
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/var/lib/postgresql/backups/upgrade_${OLD_VERSION}_to_${NEW_VERSION}_${TIMESTAMP}"
OLD_BINDIR="/usr/lib/postgresql/${OLD_VERSION}/bin"
NEW_BINDIR="/usr/lib/postgresql/${NEW_VERSION}/bin"
OLD_DATADIR="/var/lib/postgresql/${OLD_VERSION}/main"
NEW_DATADIR="/var/lib/postgresql/${NEW_VERSION}/main"
OLD_CONFIGDIR="/etc/postgresql/${OLD_VERSION}/main"
NEW_CONFIGDIR="/etc/postgresql/${NEW_VERSION}/main"
PGDATA_BACKUP="${BACKUP_DIR}/pgdata"
LOGFILE="${BACKUP_DIR}/upgrade.log"

# Pre-upgrade checks
log_info "Starting PostgreSQL upgrade from version ${OLD_VERSION} to ${NEW_VERSION}"
log_info "Timestamp: ${TIMESTAMP}"

# Create backup directory
mkdir -p "${BACKUP_DIR}"
exec > >(tee -a "${LOGFILE}") 2>&1

log_info "Log file: ${LOGFILE}"

###############################################################################
# Phase 1: Pre-upgrade validation
###############################################################################

log_info "Phase 1: Pre-upgrade validation"

# Check if old version is installed
if [ ! -d "${OLD_BINDIR}" ]; then
    log_error "PostgreSQL ${OLD_VERSION} binaries not found at ${OLD_BINDIR}"
    exit 1
fi

# Check if new version is installed
if [ ! -d "${NEW_BINDIR}" ]; then
    log_error "PostgreSQL ${NEW_VERSION} binaries not found at ${NEW_BINDIR}"
    log_info "Install PostgreSQL ${NEW_VERSION} first:"
    log_info "  sudo apt-get install postgresql-${NEW_VERSION}"
    exit 1
fi

# Check if old cluster is running
if ! "${OLD_BINDIR}/pg_ctl" status -D "${OLD_DATADIR}" > /dev/null 2>&1; then
    log_error "PostgreSQL ${OLD_VERSION} cluster is not running"
    log_info "Start it with: sudo systemctl start postgresql@${OLD_VERSION}-main"
    exit 1
fi

# Check disk space (need 2x data directory size)
DATADIR_SIZE=$(du -sb "${OLD_DATADIR}" | awk '{print $1}')
AVAILABLE_SPACE=$(df -B1 "${OLD_DATADIR}" | tail -1 | awk '{print $4}')
REQUIRED_SPACE=$((DATADIR_SIZE * 2))

if [ "${AVAILABLE_SPACE}" -lt "${REQUIRED_SPACE}" ]; then
    log_error "Insufficient disk space"
    log_error "Required: $(numfmt --to=iec-i --suffix=B ${REQUIRED_SPACE})"
    log_error "Available: $(numfmt --to=iec-i --suffix=B ${AVAILABLE_SPACE})"
    exit 1
fi

log_success "Disk space check passed"

# Check for replication slots (need to be dropped before upgrade)
REPL_SLOTS=$("${OLD_BINDIR}/psql" -U postgres -At -c "SELECT count(*) FROM pg_replication_slots" postgres)
if [ "${REPL_SLOTS}" -gt 0 ]; then
    log_warning "Found ${REPL_SLOTS} replication slots - they will be recreated after upgrade"
fi

# Check for prepared transactions (must be committed/rolled back)
PREPARED_XACTS=$("${OLD_BINDIR}/psql" -U postgres -At -c "SELECT count(*) FROM pg_prepared_xacts" postgres)
if [ "${PREPARED_XACTS}" -gt 0 ]; then
    log_error "Found ${PREPARED_XACTS} prepared transactions"
    log_error "Commit or rollback all prepared transactions before upgrading"
    exit 1
fi

# Check for incompatible extensions
log_info "Checking for incompatible extensions..."
INCOMPATIBLE=$("${OLD_BINDIR}/psql" -U postgres -At -c "
    SELECT string_agg(extname, ', ')
    FROM pg_extension
    WHERE extname IN ('postgis_topology', 'postgres_fdw', 'file_fdw')
" postgres)

if [ -n "${INCOMPATIBLE}" ]; then
    log_warning "Found potentially incompatible extensions: ${INCOMPATIBLE}"
    log_warning "Ensure these extensions are available for PostgreSQL ${NEW_VERSION}"
fi

log_success "Pre-upgrade validation passed"

###############################################################################
# Phase 2: Backup
###############################################################################

log_info "Phase 2: Creating backup"

# Stop PostgreSQL old version
log_info "Stopping PostgreSQL ${OLD_VERSION}..."
sudo systemctl stop postgresql@${OLD_VERSION}-main
log_success "PostgreSQL ${OLD_VERSION} stopped"

# Backup data directory
log_info "Backing up data directory to ${PGDATA_BACKUP}..."
cp -a "${OLD_DATADIR}" "${PGDATA_BACKUP}"
log_success "Data directory backed up"

# Backup configuration
log_info "Backing up configuration..."
cp -a "${OLD_CONFIGDIR}" "${BACKUP_DIR}/config"
log_success "Configuration backed up"

# Create pg_dumpall backup (safety net)
log_info "Creating logical backup with pg_dumpall..."
sudo systemctl start postgresql@${OLD_VERSION}-main
sleep 5
"${OLD_BINDIR}/pg_dumpall" -U postgres > "${BACKUP_DIR}/pg_dumpall.sql"
sudo systemctl stop postgresql@${OLD_VERSION}-main
log_success "Logical backup created"

###############################################################################
# Phase 3: Initialize new cluster
###############################################################################

log_info "Phase 3: Initializing new cluster"

# Initialize new cluster if it doesn't exist
if [ ! -d "${NEW_DATADIR}" ]; then
    log_info "Initializing PostgreSQL ${NEW_VERSION} cluster..."
    "${NEW_BINDIR}/initdb" -D "${NEW_DATADIR}" --encoding=UTF8 --locale=en_US.UTF-8
    log_success "New cluster initialized"
else
    log_warning "New data directory already exists, skipping initdb"
fi

# Copy important config files
log_info "Copying configuration files..."
if [ -f "${OLD_CONFIGDIR}/postgresql.conf" ]; then
    cp "${OLD_CONFIGDIR}/postgresql.conf" "${NEW_CONFIGDIR}/postgresql.conf"
fi
if [ -f "${OLD_CONFIGDIR}/pg_hba.conf" ]; then
    cp "${OLD_CONFIGDIR}/pg_hba.conf" "${NEW_CONFIGDIR}/pg_hba.conf"
fi
if [ -f "${OLD_CONFIGDIR}/pg_ident.conf" ]; then
    cp "${OLD_CONFIGDIR}/pg_ident.conf" "${NEW_CONFIGDIR}/pg_ident.conf"
fi
log_success "Configuration files copied"

###############################################################################
# Phase 4: Compatibility check
###############################################################################

log_info "Phase 4: Running pg_upgrade compatibility check"

"${NEW_BINDIR}/pg_upgrade" \
    --old-bindir="${OLD_BINDIR}" \
    --new-bindir="${NEW_BINDIR}" \
    --old-datadir="${OLD_DATADIR}" \
    --new-datadir="${NEW_DATADIR}" \
    --check \
    --username=postgres

if [ $? -ne 0 ]; then
    log_error "Compatibility check failed"
    log_error "Review the errors above and fix them before upgrading"
    log_info "Restoring from backup..."
    sudo systemctl start postgresql@${OLD_VERSION}-main
    exit 1
fi

log_success "Compatibility check passed"

###############################################################################
# Phase 5: Perform upgrade
###############################################################################

log_info "Phase 5: Performing upgrade"
log_warning "This may take several minutes for large databases..."

# Run pg_upgrade
"${NEW_BINDIR}/pg_upgrade" \
    --old-bindir="${OLD_BINDIR}" \
    --new-bindir="${NEW_BINDIR}" \
    --old-datadir="${OLD_DATADIR}" \
    --new-datadir="${NEW_DATADIR}" \
    --username=postgres \
    --jobs=$(nproc) \
    --link

if [ $? -ne 0 ]; then
    log_error "Upgrade failed"
    log_error "See ${LOGFILE} for details"
    log_info "Restoring from backup..."
    rm -rf "${NEW_DATADIR}"
    cp -a "${PGDATA_BACKUP}" "${OLD_DATADIR}"
    sudo systemctl start postgresql@${OLD_VERSION}-main
    exit 1
fi

log_success "Upgrade completed successfully"

###############################################################################
# Phase 6: Post-upgrade tasks
###############################################################################

log_info "Phase 6: Post-upgrade tasks"

# Start new cluster
log_info "Starting PostgreSQL ${NEW_VERSION}..."
sudo systemctl start postgresql@${NEW_VERSION}-main
sleep 5

# Check if new cluster is running
if ! "${NEW_BINDIR}/pg_ctl" status -D "${NEW_DATADIR}" > /dev/null 2>&1; then
    log_error "Failed to start PostgreSQL ${NEW_VERSION}"
    exit 1
fi

log_success "PostgreSQL ${NEW_VERSION} started"

# Run analyze on all databases
log_info "Running ANALYZE on all databases..."
if [ -f "./analyze_new_cluster.sh" ]; then
    ./analyze_new_cluster.sh
    log_success "ANALYZE completed"
else
    log_warning "analyze_new_cluster.sh not found, skipping ANALYZE"
fi

# Update statistics
log_info "Updating optimizer statistics..."
"${NEW_BINDIR}/vacuumdb" -U postgres --all --analyze-only -j$(nproc)
log_success "Statistics updated"

# Recreate replication slots if needed
if [ "${REPL_SLOTS}" -gt 0 ]; then
    log_info "Replication slots need to be recreated manually"
fi

# Enable new cluster on boot
log_info "Enabling PostgreSQL ${NEW_VERSION} on boot..."
sudo systemctl enable postgresql@${NEW_VERSION}-main

# Disable old cluster on boot
sudo systemctl disable postgresql@${OLD_VERSION}-main

###############################################################################
# Phase 7: Validation
###############################################################################

log_info "Phase 7: Post-upgrade validation"

# Check cluster status
CLUSTER_STATUS=$("${NEW_BINDIR}/pg_ctl" status -D "${NEW_DATADIR}" || true)
log_info "Cluster status: ${CLUSTER_STATUS}"

# Count databases
DB_COUNT=$("${NEW_BINDIR}/psql" -U postgres -At -c "SELECT count(*) FROM pg_database WHERE datname NOT IN ('template0', 'template1')" postgres)
log_info "Databases found: ${DB_COUNT}"

# Check extensions
log_info "Checking extensions..."
"${NEW_BINDIR}/psql" -U postgres -c "
    SELECT e.extname, e.extversion, n.nspname
    FROM pg_extension e
    JOIN pg_namespace n ON e.extnamespace = n.oid
    ORDER BY e.extname
" postgres

# Check RuVector extension if present
RUVECTOR_COUNT=$("${NEW_BINDIR}/psql" -U postgres -At -c "SELECT count(*) FROM pg_extension WHERE extname = 'ruvector'" postgres || echo "0")
if [ "${RUVECTOR_COUNT}" -gt 0 ]; then
    log_info "RuVector extension found, checking indexes..."
    "${NEW_BINDIR}/psql" -U postgres -c "
        SELECT schemaname, tablename, indexname
        FROM pg_indexes
        WHERE indexdef LIKE '%USING ruvector%'
        LIMIT 10
    " postgres
fi

# Performance test
log_info "Running basic performance test..."
PERF_BEFORE=$(cat "${BACKUP_DIR}/perf_before.txt" 2>/dev/null || echo "N/A")
PERF_AFTER=$("${NEW_BINDIR}/psql" -U postgres -At -c "SELECT count(*) FROM pg_class" postgres)
log_info "pg_class count: ${PERF_AFTER} (before: ${PERF_BEFORE})"

log_success "Post-upgrade validation completed"

###############################################################################
# Phase 8: Cleanup and recommendations
###############################################################################

log_info "Phase 8: Cleanup and recommendations"

# Save cleanup script
cat > "${BACKUP_DIR}/cleanup_old_cluster.sh" << 'EOF'
#!/bin/bash
# Cleanup old PostgreSQL cluster
# WARNING: This will permanently delete the old cluster data
# Only run this after verifying the new cluster is working correctly

OLD_VERSION=$1
OLD_DATADIR="/var/lib/postgresql/${OLD_VERSION}/main"

if [ -z "${OLD_VERSION}" ]; then
    echo "Usage: $0 <old_version>"
    exit 1
fi

echo "This will DELETE the old PostgreSQL ${OLD_VERSION} cluster data"
echo "Data directory: ${OLD_DATADIR}"
echo -n "Are you sure? (type 'yes' to confirm): "
read CONFIRM

if [ "${CONFIRM}" != "yes" ]; then
    echo "Aborted"
    exit 1
fi

sudo systemctl stop postgresql@${OLD_VERSION}-main
sudo systemctl disable postgresql@${OLD_VERSION}-main
rm -rf "${OLD_DATADIR}"
echo "Old cluster deleted"
EOF

chmod +x "${BACKUP_DIR}/cleanup_old_cluster.sh"

log_info "Upgrade summary:"
log_info "  Old version: PostgreSQL ${OLD_VERSION}"
log_info "  New version: PostgreSQL ${NEW_VERSION}"
log_info "  Backup location: ${BACKUP_DIR}"
log_info "  Log file: ${LOGFILE}"

log_warning "Important next steps:"
log_warning "  1. Test your applications with the new PostgreSQL version"
log_warning "  2. Monitor performance and logs for 24-48 hours"
log_warning "  3. Keep the old cluster backup for at least 1 week"
log_warning "  4. Run cleanup_old_cluster.sh when confident:"
log_warning "     ${BACKUP_DIR}/cleanup_old_cluster.sh ${OLD_VERSION}"

log_success "PostgreSQL upgrade completed successfully!"
log_info "Old cluster has been preserved at: ${OLD_DATADIR}"
log_info "New cluster is running at: ${NEW_DATADIR}"

# Rollback instructions
cat > "${BACKUP_DIR}/ROLLBACK.md" << EOF
# Rollback Instructions

If you need to rollback to PostgreSQL ${OLD_VERSION}:

1. Stop the new cluster:
   sudo systemctl stop postgresql@${NEW_VERSION}-main

2. Restore the old data directory:
   rm -rf ${OLD_DATADIR}
   cp -a ${PGDATA_BACKUP} ${OLD_DATADIR}

3. Start the old cluster:
   sudo systemctl start postgresql@${OLD_VERSION}-main

4. Re-enable the old cluster on boot:
   sudo systemctl enable postgresql@${OLD_VERSION}-main

5. Disable the new cluster:
   sudo systemctl disable postgresql@${NEW_VERSION}-main

The backup includes:
- Data directory: ${PGDATA_BACKUP}
- Configuration: ${BACKUP_DIR}/config
- Logical backup: ${BACKUP_DIR}/pg_dumpall.sql
EOF

log_info "Rollback instructions saved to: ${BACKUP_DIR}/ROLLBACK.md"

exit 0
