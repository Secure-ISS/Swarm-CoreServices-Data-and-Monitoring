#!/bin/bash
# Citus Cluster Setup Script
# Initializes Citus extension and registers worker nodes with coordinator
# Version: 1.0.0

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
COORDINATOR_HOST="${CITUS_COORDINATOR_HOST:-citus-coordinator}"
COORDINATOR_PORT="${CITUS_COORDINATOR_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-dpg_cluster}"
POSTGRES_DB="${POSTGRES_DB:-distributed_postgres_cluster}"

WORKER_1_HOST="${CITUS_WORKER_1_HOST:-citus-worker-1}"
WORKER_1_PORT="${CITUS_WORKER_1_PORT:-5432}"

WORKER_2_HOST="${CITUS_WORKER_2_HOST:-citus-worker-2}"
WORKER_2_PORT="${CITUS_WORKER_2_PORT:-5432}"

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

# Function to wait for PostgreSQL to be ready
wait_for_postgres() {
    local host=$1
    local port=$2
    local max_attempts=30
    local attempt=1

    log_info "Waiting for PostgreSQL at $host:$port to be ready..."

    while [ $attempt -le $max_attempts ]; do
        if pg_isready -h "$host" -p "$port" -U "$POSTGRES_USER" > /dev/null 2>&1; then
            log_success "PostgreSQL at $host:$port is ready"
            return 0
        fi

        log_warning "Attempt $attempt/$max_attempts: PostgreSQL not ready yet..."
        sleep 2
        attempt=$((attempt + 1))
    done

    log_error "PostgreSQL at $host:$port failed to become ready"
    return 1
}

# Function to create Citus extension
create_citus_extension() {
    local host=$1
    local port=$2
    local node_type=$3

    log_info "Creating Citus extension on $node_type ($host:$port)..."

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$host" -p "$port" -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
        -- Create Citus extension
        CREATE EXTENSION IF NOT EXISTS citus;

        -- Create RuVector extension
        CREATE EXTENSION IF NOT EXISTS ruvector;

        -- Create additional useful extensions
        CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
        CREATE EXTENSION IF NOT EXISTS pgcrypto;

        -- Show installed extensions
        SELECT extname, extversion FROM pg_extension WHERE extname IN ('citus', 'ruvector', 'pg_stat_statements');
EOSQL

    if [ $? -eq 0 ]; then
        log_success "Extensions created on $node_type"
    else
        log_error "Failed to create extensions on $node_type"
        return 1
    fi
}

# Function to register worker nodes with coordinator
register_workers() {
    log_info "Registering worker nodes with coordinator..."

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
        -- Add worker nodes to the cluster
        SELECT citus_add_node('$WORKER_1_HOST', $WORKER_1_PORT);
        SELECT citus_add_node('$WORKER_2_HOST', $WORKER_2_PORT);

        -- Verify worker nodes are registered
        SELECT * FROM citus_get_active_worker_nodes();
EOSQL

    if [ $? -eq 0 ]; then
        log_success "Worker nodes registered successfully"
    else
        log_error "Failed to register worker nodes"
        return 1
    fi
}

# Function to create and distribute demo tables
create_distributed_tables() {
    log_info "Creating distributed tables..."

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
        -- Create schema for distributed tables
        CREATE SCHEMA IF NOT EXISTS distributed;

        -- Create distributed user table (hash distribution)
        CREATE TABLE IF NOT EXISTS distributed.users (
            user_id BIGSERIAL,
            username VARCHAR(255) NOT NULL,
            email VARCHAR(255) NOT NULL,
            created_at TIMESTAMP DEFAULT NOW(),
            metadata JSONB,
            PRIMARY KEY (user_id)
        );

        -- Distribute users table by user_id (hash sharding)
        SELECT create_distributed_table('distributed.users', 'user_id');

        -- Create distributed events table (co-located with users)
        CREATE TABLE IF NOT EXISTS distributed.events (
            event_id BIGSERIAL,
            user_id BIGINT NOT NULL,
            event_type VARCHAR(100) NOT NULL,
            event_data JSONB,
            timestamp TIMESTAMP DEFAULT NOW(),
            PRIMARY KEY (event_id, user_id)
        );

        -- Distribute events table co-located with users
        SELECT create_distributed_table('distributed.events', 'user_id', colocate_with => 'distributed.users');

        -- Create distributed embeddings table (for RuVector)
        CREATE TABLE IF NOT EXISTS distributed.embeddings (
            embedding_id BIGSERIAL,
            user_id BIGINT NOT NULL,
            content TEXT,
            embedding ruvector(1536),
            created_at TIMESTAMP DEFAULT NOW(),
            PRIMARY KEY (embedding_id, user_id)
        );

        -- Distribute embeddings table
        SELECT create_distributed_table('distributed.embeddings', 'user_id', colocate_with => 'distributed.users');

        -- Create HNSW index on embeddings
        CREATE INDEX IF NOT EXISTS idx_embeddings_hnsw
        ON distributed.embeddings
        USING hnsw (embedding ruvector_cosine_ops)
        WITH (m = 16, ef_construction = 100);

        -- Create reference table (replicated to all nodes)
        CREATE TABLE IF NOT EXISTS distributed.config (
            key VARCHAR(255) PRIMARY KEY,
            value TEXT,
            updated_at TIMESTAMP DEFAULT NOW()
        );

        -- Make config a reference table (replicated)
        SELECT create_reference_table('distributed.config');

        -- Show distributed tables
        SELECT * FROM citus_tables;
EOSQL

    if [ $? -eq 0 ]; then
        log_success "Distributed tables created successfully"
    else
        log_error "Failed to create distributed tables"
        return 1
    fi
}

# Function to display cluster status
show_cluster_status() {
    log_info "Cluster Status:"

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
        \echo ''
        \echo '=== Active Worker Nodes ==='
        SELECT nodename, nodeport, isactive FROM citus_get_active_worker_nodes();

        \echo ''
        \echo '=== Distributed Tables ==='
        SELECT table_name, citus_table_type, distribution_column, shard_count
        FROM citus_tables;

        \echo ''
        \echo '=== Shard Distribution ==='
        SELECT
            nodename,
            nodeport,
            COUNT(*) as shard_count,
            pg_size_pretty(SUM(shard_size)) as total_size
        FROM citus_shards
        GROUP BY nodename, nodeport
        ORDER BY nodename;

        \echo ''
        \echo '=== Installed Extensions ==='
        SELECT extname, extversion FROM pg_extension
        WHERE extname IN ('citus', 'ruvector', 'pg_stat_statements')
        ORDER BY extname;
EOSQL
}

# Function to test distributed queries
test_distributed_queries() {
    log_info "Testing distributed queries..."

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$COORDINATOR_HOST" -p "$COORDINATOR_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
        -- Insert test data
        INSERT INTO distributed.users (username, email, metadata)
        SELECT
            'user_' || i,
            'user' || i || '@example.com',
            jsonb_build_object('signup_source', 'test', 'number', i)
        FROM generate_series(1, 100) i
        ON CONFLICT (user_id) DO NOTHING;

        -- Insert test events
        INSERT INTO distributed.events (user_id, event_type, event_data)
        SELECT
            (i % 100) + 1,
            'test_event',
            jsonb_build_object('timestamp', NOW(), 'value', i)
        FROM generate_series(1, 1000) i
        ON CONFLICT (event_id, user_id) DO NOTHING;

        -- Test distributed query
        \echo ''
        \echo '=== Test Query: User Event Counts ==='
        SELECT
            u.username,
            COUNT(e.event_id) as event_count
        FROM distributed.users u
        JOIN distributed.events e ON u.user_id = e.user_id
        GROUP BY u.username
        ORDER BY event_count DESC
        LIMIT 10;

        -- Show query distribution
        \echo ''
        \echo '=== Query Execution Plan ==='
        EXPLAIN (ANALYZE, DIST)
        SELECT COUNT(*) FROM distributed.events WHERE user_id BETWEEN 1 AND 50;
EOSQL

    if [ $? -eq 0 ]; then
        log_success "Distributed queries tested successfully"
    else
        log_warning "Some test queries failed"
    fi
}

# Main setup function
main() {
    log_info "Starting Citus cluster setup..."
    echo ""

    # Step 1: Wait for all nodes to be ready
    log_info "Step 1/6: Waiting for all PostgreSQL nodes..."
    wait_for_postgres "$COORDINATOR_HOST" "$COORDINATOR_PORT" || exit 1
    wait_for_postgres "$WORKER_1_HOST" "$WORKER_1_PORT" || exit 1
    wait_for_postgres "$WORKER_2_HOST" "$WORKER_2_PORT" || exit 1
    echo ""

    # Step 2: Create extensions on all nodes
    log_info "Step 2/6: Creating Citus and RuVector extensions..."
    create_citus_extension "$COORDINATOR_HOST" "$COORDINATOR_PORT" "coordinator" || exit 1
    create_citus_extension "$WORKER_1_HOST" "$WORKER_1_PORT" "worker-1" || exit 1
    create_citus_extension "$WORKER_2_HOST" "$WORKER_2_PORT" "worker-2" || exit 1
    echo ""

    # Step 3: Register worker nodes
    log_info "Step 3/6: Registering worker nodes with coordinator..."
    register_workers || exit 1
    echo ""

    # Step 4: Create distributed tables
    log_info "Step 4/6: Creating distributed tables..."
    create_distributed_tables || exit 1
    echo ""

    # Step 5: Show cluster status
    log_info "Step 5/6: Displaying cluster status..."
    show_cluster_status
    echo ""

    # Step 6: Test distributed queries
    log_info "Step 6/6: Testing distributed queries..."
    test_distributed_queries
    echo ""

    log_success "Citus cluster setup completed successfully!"
    echo ""
    log_info "Connection details:"
    echo "  Coordinator: $COORDINATOR_HOST:$COORDINATOR_PORT"
    echo "  Worker 1:    $WORKER_1_HOST:$WORKER_1_PORT"
    echo "  Worker 2:    $WORKER_2_HOST:$WORKER_2_PORT"
    echo ""
    log_info "Cluster size: 3 nodes total (1 coordinator + 2 workers)"
    echo ""
    log_info "Next steps:"
    echo "  1. Connect to coordinator: psql -h $COORDINATOR_HOST -p $COORDINATOR_PORT -U $POSTGRES_USER -d $POSTGRES_DB"
    echo "  2. View worker nodes: SELECT * FROM citus_get_active_worker_nodes();"
    echo "  3. View distributed tables: SELECT * FROM citus_tables;"
    echo "  4. Test shard rebalancing: scripts/citus/rebalance-shards.sh"
}

# Run main function
main "$@"
