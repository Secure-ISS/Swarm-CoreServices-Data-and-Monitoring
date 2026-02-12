#!/bin/bash
#
# Backup Manager for Distributed PostgreSQL Cluster
# Supports: Full backups, incremental WAL archiving, RuVector indexes
# Cloud storage: S3, GCS, Azure Blob
# Features: Compression, encryption, retention policies, monitoring
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
RETENTION_DAYS="${RETENTION_DAYS:-7}"
RETENTION_WEEKS="${RETENTION_WEEKS:-4}"
RETENTION_MONTHS="${RETENTION_MONTHS:-6}"
COMPRESSION="${COMPRESSION:-gzip}"
ENCRYPTION="${ENCRYPTION:-false}"
ENCRYPTION_KEY="${ENCRYPTION_KEY:-}"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"
EMAIL_NOTIFICATIONS="${EMAIL_NOTIFICATIONS:-false}"
EMAIL_TO="${EMAIL_TO:-}"
CLOUD_PROVIDER="${CLOUD_PROVIDER:-none}"
CLOUD_BUCKET="${CLOUD_BUCKET:-}"
VERIFY_BACKUP="${VERIFY_BACKUP:-true}"
DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-single-node}"

# Load environment
if [[ -f "$CONFIG_FILE" ]]; then
    set -a
    source "$CONFIG_FILE"
    set +a
fi

# Logging
LOG_FILE="${BACKUP_DIR}/logs/backup-$(date +%Y%m%d-%H%M%S).log"
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

# Email notification
send_notification() {
    local subject="$1"
    local message="$2"

    if [[ "$EMAIL_NOTIFICATIONS" == "true" ]] && [[ -n "$EMAIL_TO" ]]; then
        echo "$message" | mail -s "$subject" "$EMAIL_TO" || true
    fi
}

# Create backup directories
init_backup_dirs() {
    log "Initializing backup directories..."

    mkdir -p "$BACKUP_DIR"/{full,incremental,config,indexes,logs}
    mkdir -p "$WAL_ARCHIVE_DIR"

    chmod 700 "$BACKUP_DIR"
    chmod 700 "$WAL_ARCHIVE_DIR"

    log_success "Backup directories initialized"
}

# Full database backup using pg_dump
backup_full() {
    local backup_type="${1:-manual}"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_name="full-${backup_type}-${timestamp}"
    local backup_file="${BACKUP_DIR}/full/${backup_name}.sql"

    log "Starting full backup: $backup_name"

    case "$DEPLOYMENT_MODE" in
        single-node)
            backup_full_single "$backup_file"
            ;;
        citus)
            backup_full_citus "$backup_file"
            ;;
        patroni)
            backup_full_patroni "$backup_file"
            ;;
        *)
            log_error "Unknown deployment mode: $DEPLOYMENT_MODE"
            return 1
            ;;
    esac

    # Compress backup
    if [[ "$COMPRESSION" != "none" ]]; then
        compress_backup "$backup_file"
        backup_file="${backup_file}.gz"
    fi

    # Encrypt backup
    if [[ "$ENCRYPTION" == "true" ]]; then
        encrypt_backup "$backup_file"
        backup_file="${backup_file}.enc"
    fi

    # Verify backup
    if [[ "$VERIFY_BACKUP" == "true" ]]; then
        verify_backup "$backup_file"
    fi

    # Upload to cloud
    if [[ "$CLOUD_PROVIDER" != "none" ]]; then
        upload_to_cloud "$backup_file" "full/"
    fi

    log_success "Full backup completed: $backup_file"
    echo "$backup_file"
}

# Single-node full backup
backup_full_single() {
    local backup_file="$1"

    log "Performing single-node full backup..."

    pg_dump \
        -h "${PGHOST:-localhost}" \
        -p "${PGPORT:-5432}" \
        -U "${PGUSER:-postgres}" \
        -d "${PGDATABASE:-postgres}" \
        -F p \
        -f "$backup_file" \
        --verbose \
        --no-owner \
        --no-acl \
        2>> "$LOG_FILE"

    log_success "Single-node backup completed"
}

# Citus cluster full backup
backup_full_citus() {
    local backup_file="$1"

    log "Performing Citus cluster full backup..."

    # Backup coordinator
    log "Backing up coordinator node..."
    pg_dump \
        -h "${CITUS_COORDINATOR_HOST:-localhost}" \
        -p "${CITUS_COORDINATOR_PORT:-5432}" \
        -U "${PGUSER:-postgres}" \
        -d "${PGDATABASE:-postgres}" \
        -F p \
        -f "${backup_file}.coordinator" \
        --verbose \
        --no-owner \
        --no-acl \
        2>> "$LOG_FILE"

    # Backup workers (metadata only, distributed tables are on coordinator)
    if [[ -n "${CITUS_WORKER_HOSTS:-}" ]]; then
        IFS=',' read -ra WORKERS <<< "$CITUS_WORKER_HOSTS"
        for i in "${!WORKERS[@]}"; do
            log "Backing up worker node $((i+1))..."
            pg_dump \
                -h "${WORKERS[$i]}" \
                -p "${CITUS_WORKER_PORT:-5432}" \
                -U "${PGUSER:-postgres}" \
                -d "${PGDATABASE:-postgres}" \
                -F p \
                -f "${backup_file}.worker-$((i+1))" \
                --verbose \
                --no-owner \
                --no-acl \
                --schema-only \
                2>> "$LOG_FILE" || log_warning "Worker $((i+1)) backup failed"
        done
    fi

    # Combine backups
    cat "${backup_file}.coordinator" > "$backup_file"
    echo -e "\n\n-- Worker Nodes Metadata --\n" >> "$backup_file"
    cat "${backup_file}".worker-* >> "$backup_file" 2>/dev/null || true

    # Cleanup
    rm -f "${backup_file}".coordinator "${backup_file}".worker-*

    log_success "Citus cluster backup completed"
}

# Patroni cluster full backup
backup_full_patroni() {
    local backup_file="$1"

    log "Performing Patroni cluster full backup..."

    # Get primary node from Patroni API
    local primary_host=$(curl -s "http://${PATRONI_HOST:-localhost}:${PATRONI_PORT:-8008}/primary" | jq -r '.host // "localhost"')

    log "Backing up from primary node: $primary_host"

    pg_dump \
        -h "$primary_host" \
        -p "${PGPORT:-5432}" \
        -U "${PGUSER:-postgres}" \
        -d "${PGDATABASE:-postgres}" \
        -F p \
        -f "$backup_file" \
        --verbose \
        --no-owner \
        --no-acl \
        2>> "$LOG_FILE"

    log_success "Patroni cluster backup completed"
}

# WAL archiving (incremental backup)
backup_wal() {
    local wal_file="$1"
    local archive_file="${WAL_ARCHIVE_DIR}/$(basename "$wal_file")"

    log "Archiving WAL file: $(basename "$wal_file")"

    # Copy WAL file
    cp "$wal_file" "$archive_file"

    # Compress
    if [[ "$COMPRESSION" != "none" ]]; then
        gzip -f "$archive_file"
        archive_file="${archive_file}.gz"
    fi

    # Encrypt
    if [[ "$ENCRYPTION" == "true" ]]; then
        encrypt_backup "$archive_file"
        archive_file="${archive_file}.enc"
    fi

    # Upload to cloud
    if [[ "$CLOUD_PROVIDER" != "none" ]]; then
        upload_to_cloud "$archive_file" "wal/"
    fi

    log_success "WAL archived: $(basename "$archive_file")"
}

# Backup RuVector indexes
backup_ruvector_indexes() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="${BACKUP_DIR}/indexes/ruvector-indexes-${timestamp}.sql"

    log "Backing up RuVector indexes..."

    # Export index definitions and data
    psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" -d "${PGDATABASE:-postgres}" <<-EOF > "$backup_file"
		-- RuVector Index Backup
		-- Generated: $(date)

		-- Index definitions
		SELECT 'CREATE INDEX IF NOT EXISTS ' || indexname || ' ON ' || schemaname || '.' || tablename || ' USING ' || indexdef || ';'
		FROM pg_indexes
		WHERE indexdef LIKE '%ruvector%';

		-- Index statistics
		\copy (SELECT schemaname, tablename, indexname, idx_scan, idx_tup_read, idx_tup_fetch FROM pg_stat_user_indexes WHERE indexname LIKE '%ruvector%') TO '${backup_file}.stats' WITH CSV HEADER;
	EOF

    # Compress
    if [[ "$COMPRESSION" != "none" ]]; then
        gzip -f "$backup_file"
        gzip -f "${backup_file}.stats"
    fi

    # Upload to cloud
    if [[ "$CLOUD_PROVIDER" != "none" ]]; then
        upload_to_cloud "${backup_file}*" "indexes/"
    fi

    log_success "RuVector indexes backed up"
}

# Backup configuration files
backup_config() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="${BACKUP_DIR}/config/config-${timestamp}.tar.gz"

    log "Backing up configuration files..."

    # Create tarball of config files
    tar -czf "$backup_file" \
        -C "$PROJECT_ROOT" \
        .env \
        .claude-flow/config.yaml \
        config/ \
        scripts/sql/ \
        2>> "$LOG_FILE" || true

    # Upload to cloud
    if [[ "$CLOUD_PROVIDER" != "none" ]]; then
        upload_to_cloud "$backup_file" "config/"
    fi

    log_success "Configuration backed up: $backup_file"
}

# Compress backup
compress_backup() {
    local file="$1"

    log "Compressing backup: $(basename "$file")"

    case "$COMPRESSION" in
        gzip)
            gzip -f "$file"
            ;;
        bzip2)
            bzip2 -f "$file"
            ;;
        xz)
            xz -f -T "$PARALLEL_JOBS" "$file"
            ;;
        zstd)
            zstd -f -T"$PARALLEL_JOBS" "$file" && rm -f "$file"
            ;;
        *)
            log_warning "Unknown compression method: $COMPRESSION"
            return 1
            ;;
    esac

    log_success "Compression completed"
}

# Encrypt backup
encrypt_backup() {
    local file="$1"

    if [[ -z "$ENCRYPTION_KEY" ]]; then
        log_error "Encryption key not provided"
        return 1
    fi

    log "Encrypting backup: $(basename "$file")"

    openssl enc -aes-256-cbc -salt -pbkdf2 -in "$file" -out "${file}.enc" -k "$ENCRYPTION_KEY"
    rm -f "$file"

    log_success "Encryption completed"
}

# Verify backup integrity
verify_backup() {
    local file="$1"

    log "Verifying backup: $(basename "$file")"

    # Check file exists and is not empty
    if [[ ! -f "$file" ]] || [[ ! -s "$file" ]]; then
        log_error "Backup file is missing or empty"
        return 1
    fi

    # Verify compression integrity
    if [[ "$file" == *.gz ]]; then
        gzip -t "$file" || {
            log_error "Backup compression integrity check failed"
            return 1
        }
    elif [[ "$file" == *.bz2 ]]; then
        bzip2 -t "$file" || {
            log_error "Backup compression integrity check failed"
            return 1
        }
    fi

    log_success "Backup verification passed"
}

# Upload to cloud storage
upload_to_cloud() {
    local file="$1"
    local prefix="${2:-}"

    log "Uploading to cloud: $CLOUD_PROVIDER"

    case "$CLOUD_PROVIDER" in
        s3)
            aws s3 cp "$file" "s3://${CLOUD_BUCKET}/${prefix}$(basename "$file")" --storage-class STANDARD_IA || {
                log_error "S3 upload failed"
                return 1
            }
            ;;
        gcs)
            gsutil cp "$file" "gs://${CLOUD_BUCKET}/${prefix}$(basename "$file")" || {
                log_error "GCS upload failed"
                return 1
            }
            ;;
        azure)
            az storage blob upload \
                --account-name "${AZURE_STORAGE_ACCOUNT}" \
                --container-name "${CLOUD_BUCKET}" \
                --name "${prefix}$(basename "$file")" \
                --file "$file" \
                --tier Cool || {
                log_error "Azure upload failed"
                return 1
            }
            ;;
        *)
            log_warning "Unknown cloud provider: $CLOUD_PROVIDER"
            return 1
            ;;
    esac

    log_success "Cloud upload completed"
}

# Apply retention policy
apply_retention() {
    log "Applying retention policy..."

    # Daily backups (keep for RETENTION_DAYS)
    find "$BACKUP_DIR/full" -name "full-daily-*.sql*" -mtime +"$RETENTION_DAYS" -delete

    # Weekly backups (keep for RETENTION_WEEKS * 7)
    find "$BACKUP_DIR/full" -name "full-weekly-*.sql*" -mtime +$((RETENTION_WEEKS * 7)) -delete

    # Monthly backups (keep for RETENTION_MONTHS * 30)
    find "$BACKUP_DIR/full" -name "full-monthly-*.sql*" -mtime +$((RETENTION_MONTHS * 30)) -delete

    # WAL archives (keep for RETENTION_DAYS)
    find "$WAL_ARCHIVE_DIR" -type f -mtime +"$RETENTION_DAYS" -delete

    # Config backups (keep last 10)
    ls -t "$BACKUP_DIR/config"/config-*.tar.gz | tail -n +11 | xargs -r rm -f

    # Index backups (keep last 5)
    ls -t "$BACKUP_DIR/indexes"/ruvector-indexes-*.sql* | tail -n +6 | xargs -r rm -f

    log_success "Retention policy applied"
}

# Backup statistics
show_stats() {
    log "Backup Statistics:"
    echo "===================="

    echo -e "\nFull Backups:"
    ls -lh "$BACKUP_DIR/full" 2>/dev/null | tail -n +2 || echo "  No backups found"

    echo -e "\nWAL Archives:"
    du -sh "$WAL_ARCHIVE_DIR" 2>/dev/null || echo "  No archives found"
    find "$WAL_ARCHIVE_DIR" -type f | wc -l | xargs -I {} echo "  {} files"

    echo -e "\nConfig Backups:"
    ls -lh "$BACKUP_DIR/config" 2>/dev/null | tail -n +2 || echo "  No backups found"

    echo -e "\nIndex Backups:"
    ls -lh "$BACKUP_DIR/indexes" 2>/dev/null | tail -n +2 || echo "  No backups found"

    echo -e "\nStorage Usage:"
    du -sh "$BACKUP_DIR" 2>/dev/null || echo "  No data"

    echo "===================="
}

# Schedule backups (generate cron entries)
schedule_backups() {
    log "Generating cron schedule..."

    cat > /tmp/backup-cron.txt <<-EOF
		# PostgreSQL Backup Schedule
		# Daily backup at 2:00 AM
		0 2 * * * $0 full daily

		# Weekly backup on Sunday at 3:00 AM
		0 3 * * 0 $0 full weekly

		# Monthly backup on 1st of month at 4:00 AM
		0 4 1 * * $0 full monthly

		# Config backup daily at 1:00 AM
		0 1 * * * $0 config

		# Index backup daily at 1:30 AM
		30 1 * * * $0 indexes

		# Apply retention daily at 5:00 AM
		0 5 * * * $0 retention
	EOF

    log_success "Cron schedule generated: /tmp/backup-cron.txt"
    echo "To install: crontab -l | cat - /tmp/backup-cron.txt | crontab -"
}

# Usage information
usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  full [daily|weekly|monthly]  Perform full database backup
  wal <wal-file>               Archive WAL file
  indexes                      Backup RuVector indexes
  config                       Backup configuration files
  retention                    Apply retention policy
  schedule                     Generate cron schedule
  stats                        Show backup statistics
  init                         Initialize backup directories

Environment Variables:
  BACKUP_DIR              Backup directory (default: /var/backups/postgresql)
  WAL_ARCHIVE_DIR         WAL archive directory
  RETENTION_DAYS          Daily retention (default: 7)
  RETENTION_WEEKS         Weekly retention (default: 4)
  RETENTION_MONTHS        Monthly retention (default: 6)
  COMPRESSION             Compression method: gzip|bzip2|xz|zstd|none (default: gzip)
  ENCRYPTION              Enable encryption: true|false (default: false)
  ENCRYPTION_KEY          Encryption key (required if ENCRYPTION=true)
  PARALLEL_JOBS           Parallel jobs for compression (default: 4)
  EMAIL_NOTIFICATIONS     Send email notifications: true|false (default: false)
  EMAIL_TO                Email address for notifications
  CLOUD_PROVIDER          Cloud provider: s3|gcs|azure|none (default: none)
  CLOUD_BUCKET            Cloud storage bucket name
  VERIFY_BACKUP           Verify backup integrity: true|false (default: true)
  DEPLOYMENT_MODE         Deployment mode: single-node|citus|patroni (default: single-node)

Examples:
  $0 init
  $0 full daily
  $0 wal /var/lib/postgresql/wal/000000010000000000000001
  $0 indexes
  $0 retention
  $0 stats

EOF
}

# Main execution
main() {
    local command="${1:-}"

    case "$command" in
        init)
            init_backup_dirs
            ;;
        full)
            local backup_type="${2:-manual}"
            backup_full "$backup_type"
            apply_retention
            send_notification "PostgreSQL Backup Success" "Full $backup_type backup completed successfully"
            ;;
        wal)
            local wal_file="${2:-}"
            if [[ -z "$wal_file" ]]; then
                log_error "WAL file path required"
                exit 1
            fi
            backup_wal "$wal_file"
            ;;
        indexes)
            backup_ruvector_indexes
            ;;
        config)
            backup_config
            ;;
        retention)
            apply_retention
            ;;
        schedule)
            schedule_backups
            ;;
        stats)
            show_stats
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
