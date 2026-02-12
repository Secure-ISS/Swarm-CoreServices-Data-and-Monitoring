#!/bin/bash
# Migration Script: Single-Node to Citus Distributed Cluster
# Converts existing single-node PostgreSQL database to Citus distributed setup
# Version: 1.0.0

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SOURCE_HOST="${SOURCE_HOST:-localhost}"
SOURCE_PORT="${SOURCE_PORT:-5432}"
SOURCE_USER="${SOURCE_USER:-dpg_cluster}"
SOURCE_DB="${SOURCE_DB:-distributed_postgres_cluster}"

CITUS_COORDINATOR_HOST="${CITUS_COORDINATOR_HOST:-citus-coordinator}"
CITUS_COORDINATOR_PORT="${CITUS_COORDINATOR_PORT:-5432}"

BACKUP_DIR="${BACKUP_DIR:-./backups/migration-$(date +%Y%m%d_%H%M%S)}"

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to create backup directory
create_backup_dir() {
    log_info "Creating backup directory: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    log_success "Backup directory created"
}

# Function to backup source database
backup_source_database() {
    log_info "Backing up source database..."

    local backup_file="$BACKUP_DIR/pre-migration-backup.sql"

    PGPASSWORD="$POSTGRES_PASSWORD" pg_dump \
        -h "$SOURCE_HOST" \
        -p "$SOURCE_PORT" \
        -U "$SOURCE_USER" \
        -d "$SOURCE_DB" \
        --no-owner \
        --no-privileges \
        -f "$backup_file"

    if [ $? -eq 0 ]; then
        log_success "Database backup created: $backup_file"
        log_info "Backup size: $(du -h "$backup_file" | cut -f1)"
    else
        log_error "Failed to create database backup"
        exit 1
    fi
}

# Function to analyze tables for distribution strategy
analyze_tables() {
    log_info "Analyzing tables for optimal distribution strategy..."

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" \
        -U "$SOURCE_USER" -d "$SOURCE_DB" > "$BACKUP_DIR/table-analysis.txt" <<-EOSQL
        \echo 'Table Sizes and Row Counts:'
        SELECT
            schemaname,
            tablename,
            pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size,
            n_live_tup as estimated_rows,
            CASE
                WHEN pg_total_relation_size(schemaname||'.'||tablename) > 10737418240 THEN 'LARGE (>10GB) - Hash distribute'
                WHEN pg_total_relation_size(schemaname||'.'||tablename) > 1073741824 THEN 'MEDIUM (>1GB) - Hash distribute'
                WHEN pg_total_relation_size(schemaname||'.'||tablename) > 104857600 THEN 'SMALL (>100MB) - Hash or reference'
                ELSE 'TINY (<100MB) - Reference table'
            END as recommendation
        FROM pg_stat_user_tables
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
        ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;

        \echo ''
        \echo 'Foreign Key Relationships (for co-location):'
        SELECT
            tc.table_schema,
            tc.table_name,
            kcu.column_name,
            ccu.table_name AS foreign_table_name,
            ccu.column_name AS foreign_column_name
        FROM information_schema.table_constraints AS tc
        JOIN information_schema.key_column_usage AS kcu
            ON tc.constraint_name = kcu.constraint_name
        JOIN information_schema.constraint_column_usage AS ccu
            ON ccu.constraint_name = tc.constraint_name
        WHERE tc.constraint_type = 'FOREIGN KEY'
            AND tc.table_schema NOT IN ('pg_catalog', 'information_schema')
        ORDER BY tc.table_name;

        \echo ''
        \echo 'Indexes to recreate:'
        SELECT
            schemaname,
            tablename,
            indexname,
            indexdef
        FROM pg_indexes
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
        ORDER BY tablename, indexname;
EOSQL

    log_success "Table analysis saved to: $BACKUP_DIR/table-analysis.txt"
    log_info "Review this file to plan distribution strategy"
}

# Function to generate migration SQL
generate_migration_sql() {
    log_info "Generating migration SQL script..."

    local migration_sql="$BACKUP_DIR/migration-script.sql"

    cat > "$migration_sql" <<-'EOSQL'
-- Citus Migration Script
-- Generated automatically - review and customize before running

-- Step 1: Create Citus extension
CREATE EXTENSION IF NOT EXISTS citus;
CREATE EXTENSION IF NOT EXISTS ruvector;

-- Step 2: Distribute large tables with hash sharding
-- CUSTOMIZE: Replace 'id' with appropriate distribution column
-- Example: Primary key or foreign key for co-location

-- Large tables (>1GB) - hash distribution
-- SELECT create_distributed_table('schema.large_table', 'id', shard_count => 32);

-- Medium tables (100MB-1GB) - hash distribution
-- SELECT create_distributed_table('schema.medium_table', 'id', shard_count => 16);

-- Small tables (<100MB) - reference tables (replicated)
-- SELECT create_reference_table('schema.small_lookup_table');

-- Step 3: Co-locate related tables for efficient joins
-- Example: Orders and order_items should be co-located by customer_id
-- SELECT create_distributed_table('orders', 'customer_id');
-- SELECT create_distributed_table('order_items', 'customer_id', colocate_with => 'orders');

-- Step 4: Create distributed indexes
-- Citus automatically creates indexes on shards, but you may want to optimize
-- CREATE INDEX CONCURRENTLY idx_name ON distributed_table (column) WHERE condition;

-- Step 5: Verify distribution
SELECT table_name, citus_table_type, distribution_column, shard_count
FROM citus_tables;

-- Step 6: Check shard distribution
SELECT nodename, COUNT(*) as shard_count, pg_size_pretty(SUM(shard_size)) as total_size
FROM citus_shards
GROUP BY nodename;

EOSQL

    log_success "Migration SQL template created: $migration_sql"
    log_warning "IMPORTANT: Review and customize this SQL before running!"
}

# Function to export data for migration
export_table_data() {
    local table=$1
    local schema=${2:-public}

    log_info "Exporting data from $schema.$table..."

    local export_file="$BACKUP_DIR/${schema}_${table}.csv"

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" \
        -U "$SOURCE_USER" -d "$SOURCE_DB" -c \
        "COPY $schema.$table TO STDOUT WITH (FORMAT CSV, HEADER)" > "$export_file"

    if [ $? -eq 0 ]; then
        log_success "Data exported: $export_file ($(du -h "$export_file" | cut -f1))"
    else
        log_error "Failed to export $schema.$table"
        return 1
    fi
}

# Function to import data to Citus
import_table_data() {
    local table=$1
    local schema=${2:-public}

    log_info "Importing data to $schema.$table..."

    local import_file="$BACKUP_DIR/${schema}_${table}.csv"

    if [ ! -f "$import_file" ]; then
        log_error "Import file not found: $import_file"
        return 1
    fi

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$CITUS_COORDINATOR_HOST" -p "$CITUS_COORDINATOR_PORT" \
        -U "$SOURCE_USER" -d "$SOURCE_DB" -c \
        "COPY $schema.$table FROM STDIN WITH (FORMAT CSV, HEADER)" < "$import_file"

    if [ $? -eq 0 ]; then
        log_success "Data imported to $schema.$table"
    else
        log_error "Failed to import to $schema.$table"
        return 1
    fi
}

# Function to verify migration
verify_migration() {
    log_info "Verifying migration..."

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$CITUS_COORDINATOR_HOST" -p "$CITUS_COORDINATOR_PORT" \
        -U "$SOURCE_USER" -d "$SOURCE_DB" <<-EOSQL
        \echo 'Distributed Tables:'
        SELECT table_name, citus_table_type, distribution_column, shard_count
        FROM citus_tables;

        \echo ''
        \echo 'Worker Nodes:'
        SELECT * FROM citus_get_active_worker_nodes();

        \echo ''
        \echo 'Shard Distribution:'
        SELECT nodename, COUNT(*) as shards, pg_size_pretty(SUM(shard_size)) as size
        FROM citus_shards
        GROUP BY nodename;

        \echo ''
        \echo 'Table Row Counts (sampled):'
        SELECT
            table_name,
            (SELECT COUNT(*) FROM distributed.users LIMIT 1) as sample_count
        FROM citus_tables
        LIMIT 5;
EOSQL
}

# Function to create rollback script
create_rollback_script() {
    log_info "Creating rollback script..."

    local rollback_script="$BACKUP_DIR/rollback.sh"

    cat > "$rollback_script" <<-'EOROLLBACK'
#!/bin/bash
# Rollback script for Citus migration
# Restores database from pre-migration backup

set -e

BACKUP_FILE="pre-migration-backup.sql"
TARGET_HOST="${RESTORE_HOST:-localhost}"
TARGET_PORT="${RESTORE_PORT:-5432}"
TARGET_USER="${RESTORE_USER:-dpg_cluster}"
TARGET_DB="${RESTORE_DB:-distributed_postgres_cluster}"

echo "WARNING: This will DROP and recreate the database!"
echo "Target: $TARGET_USER@$TARGET_HOST:$TARGET_PORT/$TARGET_DB"
read -p "Continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Rollback cancelled"
    exit 0
fi

# Drop and recreate database
PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$TARGET_HOST" -p "$TARGET_PORT" \
    -U "$TARGET_USER" -d postgres <<-EOSQL
    DROP DATABASE IF EXISTS $TARGET_DB;
    CREATE DATABASE $TARGET_DB;
EOSQL

# Restore from backup
PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$TARGET_HOST" -p "$TARGET_PORT" \
    -U "$TARGET_USER" -d "$TARGET_DB" < "$BACKUP_FILE"

echo "Rollback completed successfully"
EOROLLBACK

    chmod +x "$rollback_script"
    log_success "Rollback script created: $rollback_script"
}

# Main migration workflow
main() {
    local phase=${1:-all}

    log_info "Starting Citus migration process..."
    echo ""

    case "$phase" in
        backup)
            create_backup_dir
            backup_source_database
            analyze_tables
            generate_migration_sql
            create_rollback_script
            ;;
        analyze)
            analyze_tables
            ;;
        generate)
            generate_migration_sql
            ;;
        export)
            if [ -z "$2" ] || [ -z "$3" ]; then
                log_error "Usage: $0 export <schema> <table>"
                exit 1
            fi
            export_table_data "$3" "$2"
            ;;
        import)
            if [ -z "$2" ] || [ -z "$3" ]; then
                log_error "Usage: $0 import <schema> <table>"
                exit 1
            fi
            import_table_data "$3" "$2"
            ;;
        verify)
            verify_migration
            ;;
        all)
            create_backup_dir
            backup_source_database
            analyze_tables
            generate_migration_sql
            create_rollback_script
            echo ""
            log_success "Migration preparation completed!"
            echo ""
            log_info "Next steps:"
            echo "  1. Review table analysis: $BACKUP_DIR/table-analysis.txt"
            echo "  2. Customize migration SQL: $BACKUP_DIR/migration-script.sql"
            echo "  3. Start Citus cluster: docker compose -f docker/citus/docker-compose.yml up -d"
            echo "  4. Run setup script: scripts/citus/setup-citus.sh"
            echo "  5. Apply migration SQL to Citus coordinator"
            echo "  6. Export/import data for each table"
            echo "  7. Verify migration: $0 verify"
            echo "  8. If issues occur, rollback: $BACKUP_DIR/rollback.sh"
            ;;
        *)
            echo "Usage: $0 <command> [options]"
            echo ""
            echo "Commands:"
            echo "  all              Complete migration preparation (backup + analyze + generate)"
            echo "  backup           Backup source database only"
            echo "  analyze          Analyze tables for distribution strategy"
            echo "  generate         Generate migration SQL template"
            echo "  export <schema> <table>   Export table data to CSV"
            echo "  import <schema> <table>   Import table data from CSV"
            echo "  verify           Verify migration completeness"
            echo ""
            echo "Environment Variables:"
            echo "  SOURCE_HOST      Source PostgreSQL host (default: localhost)"
            echo "  SOURCE_PORT      Source PostgreSQL port (default: 5432)"
            echo "  SOURCE_USER      Source PostgreSQL user (default: dpg_cluster)"
            echo "  SOURCE_DB        Source database name"
            echo "  POSTGRES_PASSWORD PostgreSQL password"
            echo "  CITUS_COORDINATOR_HOST  Citus coordinator host"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
