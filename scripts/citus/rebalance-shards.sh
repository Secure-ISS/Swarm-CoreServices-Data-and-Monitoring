#!/bin/bash
# Citus Shard Rebalancing Script
# Rebalances shards across worker nodes for optimal distribution
# Version: 1.0.0

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
COORDINATOR_HOST="${CITUS_COORDINATOR_HOST:-citus-coordinator}"
COORDINATOR_PORT="${CITUS_COORDINATOR_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-dpg_cluster}"
POSTGRES_DB="${POSTGRES_DB:-distributed_postgres_cluster}"

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to show current shard distribution
show_shard_distribution() {
    log_info "Current shard distribution:"

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
        SELECT
            nodename,
            nodeport,
            COUNT(*) as shard_count,
            pg_size_pretty(SUM(shard_size)) as total_size,
            ROUND(AVG(shard_size::numeric) / 1024 / 1024, 2) as avg_shard_size_mb
        FROM citus_shards
        GROUP BY nodename, nodeport
        ORDER BY nodename;

        \echo ''
        \echo 'Per-table shard distribution:'
        SELECT
            table_name::text,
            nodename,
            COUNT(*) as shard_count,
            pg_size_pretty(SUM(shard_size)) as total_size
        FROM citus_shards
        GROUP BY table_name, nodename
        ORDER BY table_name, nodename;
EOSQL
}

# Function to calculate shard distribution imbalance
calculate_imbalance() {
    log_info "Calculating shard distribution imbalance..."

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A <<-EOSQL
        WITH shard_counts AS (
            SELECT
                nodename,
                COUNT(*) as shard_count
            FROM citus_shards
            GROUP BY nodename
        ),
        stats AS (
            SELECT
                AVG(shard_count) as avg_count,
                STDDEV(shard_count) as stddev_count,
                MAX(shard_count) as max_count,
                MIN(shard_count) as min_count
            FROM shard_counts
        )
        SELECT
            CASE
                WHEN stddev_count IS NULL THEN 'BALANCED'
                WHEN stddev_count / NULLIF(avg_count, 0) < 0.1 THEN 'BALANCED'
                WHEN stddev_count / NULLIF(avg_count, 0) < 0.2 THEN 'SLIGHTLY_IMBALANCED'
                WHEN stddev_count / NULLIF(avg_count, 0) < 0.3 THEN 'IMBALANCED'
                ELSE 'SEVERELY_IMBALANCED'
            END as status,
            ROUND((max_count - min_count)::numeric / NULLIF(avg_count, 0) * 100, 2) as imbalance_percentage
        FROM stats;
EOSQL
}

# Function to rebalance all distributed tables
rebalance_all_tables() {
    log_info "Starting shard rebalancing for all distributed tables..."

    # Get list of distributed tables
    local tables=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c \
        "SELECT table_name FROM citus_tables WHERE citus_table_type = 'distributed';")

    if [ -z "$tables" ]; then
        log_warning "No distributed tables found to rebalance"
        return 0
    fi

    local table_count=0
    local success_count=0
    local fail_count=0

    while IFS= read -r table; do
        if [ -n "$table" ]; then
            table_count=$((table_count + 1))
            log_info "Rebalancing table: $table"

            if rebalance_table "$table"; then
                success_count=$((success_count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
        fi
    done <<< "$tables"

    echo ""
    log_info "Rebalancing summary:"
    echo "  Total tables: $table_count"
    echo "  Successful:   $success_count"
    echo "  Failed:       $fail_count"
}

# Function to rebalance a specific table
rebalance_table() {
    local table=$1

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL 2>&1
        SELECT rebalance_table_shards('$table', threshold => 0.1);
EOSQL

    if [ $? -eq 0 ]; then
        log_success "Table $table rebalanced successfully"
        return 0
    else
        log_error "Failed to rebalance table $table"
        return 1
    fi
}

# Function to drain a specific worker node
drain_worker() {
    local worker_host=$1
    local worker_port=$2

    log_info "Draining worker node: $worker_host:$worker_port"
    log_warning "This will move all shards from this worker to other workers"

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
        -- Mark node as draining (shouldhaveshards = false)
        SELECT citus_set_node_property('$worker_host', $worker_port, 'shouldhaveshards', false);

        -- Rebalance all tables to move shards away
        SELECT rebalance_table_shards(table_name::text)
        FROM citus_tables
        WHERE citus_table_type = 'distributed';

        -- Show remaining shards on the drained node
        SELECT COUNT(*) as remaining_shards
        FROM citus_shards
        WHERE nodename = '$worker_host' AND nodeport = $worker_port;
EOSQL

    if [ $? -eq 0 ]; then
        log_success "Worker node drained successfully"
    else
        log_error "Failed to drain worker node"
        return 1
    fi
}

# Function to add a new worker to the cluster
add_worker() {
    local worker_host=$1
    local worker_port=$2

    log_info "Adding new worker node: $worker_host:$worker_port"

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
        -- Add the worker node
        SELECT citus_add_node('$worker_host', $worker_port);

        -- Verify it was added
        SELECT * FROM citus_get_active_worker_nodes() WHERE nodename = '$worker_host';
EOSQL

    if [ $? -eq 0 ]; then
        log_success "Worker node added successfully"
        log_info "Run rebalance to distribute shards to the new worker"
    else
        log_error "Failed to add worker node"
        return 1
    fi
}

# Function to remove a worker from the cluster
remove_worker() {
    local worker_host=$1
    local worker_port=$2

    log_info "Removing worker node: $worker_host:$worker_port"
    log_warning "Draining shards first..."

    # First drain the worker
    drain_worker "$worker_host" "$worker_port" || return 1

    # Then remove it
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
        -- Remove the worker node
        SELECT citus_remove_node('$worker_host', $worker_port);

        -- Verify it was removed
        SELECT * FROM citus_get_active_worker_nodes();
EOSQL

    if [ $? -eq 0 ]; then
        log_success "Worker node removed successfully"
    else
        log_error "Failed to remove worker node"
        return 1
    fi
}

# Function to show rebalancing recommendations
show_recommendations() {
    log_info "Analyzing cluster and providing recommendations..."

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
        \echo 'Worker Node Status:'
        SELECT
            nodename,
            nodeport,
            isactive,
            shouldhaveshards,
            nodecluster
        FROM pg_dist_node
        ORDER BY nodename;

        \echo ''
        \echo 'Shard Distribution Balance:'
        WITH shard_counts AS (
            SELECT
                nodename,
                COUNT(*) as shard_count,
                SUM(shard_size) as total_size
            FROM citus_shards
            GROUP BY nodename
        ),
        stats AS (
            SELECT
                AVG(shard_count) as avg_shards,
                MAX(shard_count) as max_shards,
                MIN(shard_count) as min_shards
            FROM shard_counts
        )
        SELECT
            sc.nodename,
            sc.shard_count,
            ROUND((sc.shard_count - s.avg_shards) / s.avg_shards * 100, 2) as deviation_pct,
            pg_size_pretty(sc.total_size) as total_size,
            CASE
                WHEN sc.shard_count < s.avg_shards * 0.9 THEN 'UNDERUTILIZED'
                WHEN sc.shard_count > s.avg_shards * 1.1 THEN 'OVERUTILIZED'
                ELSE 'BALANCED'
            END as status
        FROM shard_counts sc, stats s
        ORDER BY sc.shard_count DESC;

        \echo ''
        \echo 'Tables that might benefit from rebalancing:'
        SELECT
            table_name::text,
            MAX(shard_count) - MIN(shard_count) as shard_imbalance,
            COUNT(DISTINCT nodename) as nodes_used
        FROM (
            SELECT
                table_name,
                nodename,
                COUNT(*) as shard_count
            FROM citus_shards
            GROUP BY table_name, nodename
        ) t
        GROUP BY table_name
        HAVING MAX(shard_count) - MIN(shard_count) > 2
        ORDER BY shard_imbalance DESC;
EOSQL
}

# Main function
main() {
    local command=${1:-status}

    case "$command" in
        status)
            show_shard_distribution
            ;;
        analyze)
            show_recommendations
            ;;
        rebalance)
            local table=$2
            if [ -n "$table" ]; then
                log_info "Rebalancing specific table: $table"
                rebalance_table "$table"
            else
                log_info "Rebalancing all distributed tables"
                rebalance_all_tables
            fi
            echo ""
            show_shard_distribution
            ;;
        drain)
            if [ -z "$2" ] || [ -z "$3" ]; then
                log_error "Usage: $0 drain <host> <port>"
                exit 1
            fi
            drain_worker "$2" "$3"
            ;;
        add)
            if [ -z "$2" ] || [ -z "$3" ]; then
                log_error "Usage: $0 add <host> <port>"
                exit 1
            fi
            add_worker "$2" "$3"
            ;;
        remove)
            if [ -z "$2" ] || [ -z "$3" ]; then
                log_error "Usage: $0 remove <host> <port>"
                exit 1
            fi
            remove_worker "$2" "$3"
            ;;
        *)
            echo "Usage: $0 <command> [options]"
            echo ""
            echo "Commands:"
            echo "  status              Show current shard distribution"
            echo "  analyze             Show rebalancing recommendations"
            echo "  rebalance [table]   Rebalance all tables or specific table"
            echo "  drain <host> <port> Drain shards from a worker node"
            echo "  add <host> <port>   Add a new worker to the cluster"
            echo "  remove <host> <port> Remove a worker from the cluster"
            echo ""
            echo "Examples:"
            echo "  $0 status"
            echo "  $0 rebalance"
            echo "  $0 rebalance distributed.users"
            echo "  $0 drain citus-worker-1 5432"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
