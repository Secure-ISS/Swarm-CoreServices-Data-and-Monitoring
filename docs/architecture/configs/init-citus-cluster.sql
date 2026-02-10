-- Citus Cluster Initialization Script
-- Run this on the coordinator after all nodes are up

-- ============================================================
-- 1. Enable Extensions
-- ============================================================
CREATE EXTENSION IF NOT EXISTS citus;
CREATE EXTENSION IF NOT EXISTS ruvector;

\echo 'Extensions enabled'

-- ============================================================
-- 2. Add Worker Nodes to Citus Cluster
-- ============================================================

-- Shard 1 workers
SELECT citus_add_node('worker-1-1', 5432);
SELECT citus_add_node('worker-1-2', 5432);

-- Shard 2 workers
SELECT citus_add_node('worker-2-1', 5432);
SELECT citus_add_node('worker-2-2', 5432);

-- Shard 3 workers
SELECT citus_add_node('worker-3-1', 5432);
SELECT citus_add_node('worker-3-2', 5432);

\echo 'Worker nodes added'

-- ============================================================
-- 3. Configure Citus Parameters
-- ============================================================

-- Set shard count (must be done before creating distributed tables)
-- Choose shard count based on: 2 * number_of_workers (for rebalancing flexibility)
SET citus.shard_count = 32;

-- Enable multi-shard queries
SET citus.multi_shard_commit_protocol = '2pc';

-- Enable repartition joins
SET citus.enable_repartition_joins = true;

-- Connection settings
SET citus.max_cached_conns_per_worker = 10;
SET citus.node_connection_timeout = 5000;  -- 5 seconds

\echo 'Citus parameters configured'

-- ============================================================
-- 4. Create Application Database Tables
-- ============================================================

-- Switch to application database
\c distributed_postgres_cluster

-- Enable extensions in application database
CREATE EXTENSION IF NOT EXISTS citus;
CREATE EXTENSION IF NOT EXISTS ruvector;

-- ============================================================
-- 5. Create Tables (from init-ruvector.sql)
-- ============================================================

-- Main memory entries table with vector embeddings
CREATE TABLE IF NOT EXISTS memory_entries (
    id SERIAL PRIMARY KEY,
    namespace VARCHAR(255) NOT NULL,
    key VARCHAR(255) NOT NULL,
    value TEXT,
    embedding ruvector(384),
    metadata JSONB DEFAULT '{}',
    tags TEXT[],
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    expires_at TIMESTAMP,
    UNIQUE(namespace, key)
);

-- Pattern learning table
CREATE TABLE IF NOT EXISTS patterns (
    id SERIAL PRIMARY KEY,
    namespace VARCHAR(255) NOT NULL,
    pattern_type VARCHAR(100) NOT NULL,
    pattern_data JSONB NOT NULL,
    embedding ruvector(384),
    confidence FLOAT DEFAULT 0.5,
    success_count INTEGER DEFAULT 0,
    failure_count INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Trajectories for ReasoningBank
CREATE TABLE IF NOT EXISTS trajectories (
    id SERIAL PRIMARY KEY,
    task_description TEXT NOT NULL,
    steps JSONB NOT NULL,
    verdict VARCHAR(50),
    quality_score FLOAT,
    embedding ruvector(384),
    created_at TIMESTAMP DEFAULT NOW()
);

-- Graph nodes for relationships
CREATE TABLE IF NOT EXISTS graph_nodes (
    id SERIAL PRIMARY KEY,
    namespace VARCHAR(255) NOT NULL,
    node_id VARCHAR(255) NOT NULL,
    node_type VARCHAR(100) NOT NULL,
    properties JSONB DEFAULT '{}',
    embedding ruvector(384),
    created_at TIMESTAMP DEFAULT NOW(),
    UNIQUE(namespace, node_id)
);

-- Graph edges for relationships
CREATE TABLE IF NOT EXISTS graph_edges (
    id SERIAL PRIMARY KEY,
    namespace VARCHAR(255) NOT NULL,
    from_node VARCHAR(255) NOT NULL,
    to_node VARCHAR(255) NOT NULL,
    edge_type VARCHAR(100) NOT NULL,
    properties JSONB DEFAULT '{}',
    weight FLOAT DEFAULT 1.0,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Hyperbolic embeddings for hierarchical data
CREATE TABLE IF NOT EXISTS hyperbolic_embeddings (
    id SERIAL PRIMARY KEY,
    namespace VARCHAR(255) NOT NULL,
    entity_id VARCHAR(255) NOT NULL,
    embedding ruvector(384),
    radius FLOAT,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP DEFAULT NOW(),
    UNIQUE(namespace, entity_id)
);

-- Reference tables (small, replicated to all workers)
CREATE TABLE IF NOT EXISTS vector_indexes (
    id SERIAL PRIMARY KEY,
    namespace VARCHAR(255) NOT NULL,
    index_name VARCHAR(255) NOT NULL,
    index_type VARCHAR(50) DEFAULT 'hnsw',
    dimensions INTEGER DEFAULT 384,
    metric VARCHAR(50) DEFAULT 'cosine',
    parameters JSONB DEFAULT '{}',
    created_at TIMESTAMP DEFAULT NOW(),
    UNIQUE(namespace, index_name)
);

CREATE TABLE IF NOT EXISTS sessions (
    id SERIAL PRIMARY KEY,
    session_id VARCHAR(255) UNIQUE NOT NULL,
    data JSONB DEFAULT '{}',
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    expires_at TIMESTAMP
);

CREATE TABLE IF NOT EXISTS metadata (
    key VARCHAR(255) PRIMARY KEY,
    value TEXT,
    updated_at TIMESTAMP DEFAULT NOW()
);

\echo 'Tables created'

-- ============================================================
-- 6. Create Distributed Tables
-- ============================================================

-- Distribute large tables by namespace (co-location)
SELECT create_distributed_table('memory_entries', 'namespace');
SELECT create_distributed_table('patterns', 'namespace');
SELECT create_distributed_table('graph_nodes', 'namespace');
SELECT create_distributed_table('graph_edges', 'namespace');
SELECT create_distributed_table('hyperbolic_embeddings', 'namespace');

-- Distribute trajectories by id (even distribution)
SELECT create_distributed_table('trajectories', 'id');

-- Create reference tables (replicated to all workers)
SELECT create_reference_table('vector_indexes');
SELECT create_reference_table('sessions');
SELECT create_reference_table('metadata');

\echo 'Tables distributed'

-- ============================================================
-- 7. Create Indexes (created on each worker automatically)
-- ============================================================

-- HNSW indexes for fast vector search
CREATE INDEX IF NOT EXISTS idx_memory_embedding_hnsw
    ON memory_entries USING hnsw (embedding ruvector_cosine_ops)
    WITH (m = 16, ef_construction = 200);

CREATE INDEX IF NOT EXISTS idx_patterns_embedding_hnsw
    ON patterns USING hnsw (embedding ruvector_cosine_ops)
    WITH (m = 16, ef_construction = 200);

CREATE INDEX IF NOT EXISTS idx_trajectories_embedding_hnsw
    ON trajectories USING hnsw (embedding ruvector_cosine_ops)
    WITH (m = 16, ef_construction = 200);

CREATE INDEX IF NOT EXISTS idx_graph_nodes_embedding_hnsw
    ON graph_nodes USING hnsw (embedding ruvector_cosine_ops)
    WITH (m = 16, ef_construction = 200);

CREATE INDEX IF NOT EXISTS idx_hyperbolic_embedding_hnsw
    ON hyperbolic_embeddings USING hnsw (embedding ruvector_cosine_ops)
    WITH (m = 16, ef_construction = 200);

-- B-tree indexes for common queries
CREATE INDEX IF NOT EXISTS idx_memory_namespace ON memory_entries(namespace);
CREATE INDEX IF NOT EXISTS idx_memory_key ON memory_entries(key);
CREATE INDEX IF NOT EXISTS idx_memory_created_at ON memory_entries(created_at);

CREATE INDEX IF NOT EXISTS idx_patterns_namespace ON patterns(namespace);
CREATE INDEX IF NOT EXISTS idx_patterns_type ON patterns(pattern_type);
CREATE INDEX IF NOT EXISTS idx_patterns_confidence ON patterns(confidence);

CREATE INDEX IF NOT EXISTS idx_graph_nodes_namespace ON graph_nodes(namespace);
CREATE INDEX IF NOT EXISTS idx_graph_nodes_type ON graph_nodes(node_type);

CREATE INDEX IF NOT EXISTS idx_graph_edges_namespace ON graph_edges(namespace);
CREATE INDEX IF NOT EXISTS idx_graph_edges_from ON graph_edges(from_node);
CREATE INDEX IF NOT EXISTS idx_graph_edges_to ON graph_edges(to_node);

-- GIN indexes for JSONB columns
CREATE INDEX IF NOT EXISTS idx_memory_metadata ON memory_entries USING gin(metadata);
CREATE INDEX IF NOT EXISTS idx_patterns_data ON patterns USING gin(pattern_data);
CREATE INDEX IF NOT EXISTS idx_trajectories_steps ON trajectories USING gin(steps);
CREATE INDEX IF NOT EXISTS idx_graph_nodes_properties ON graph_nodes USING gin(properties);
CREATE INDEX IF NOT EXISTS idx_graph_edges_properties ON graph_edges USING gin(properties);

\echo 'Indexes created'

-- ============================================================
-- 8. Create Users and Permissions
-- ============================================================

-- MCP user (AI agents) - read-only + limited insert
CREATE USER IF NOT EXISTS mcp_user WITH PASSWORD 'mcp_password_change_me';
GRANT CONNECT ON DATABASE distributed_postgres_cluster TO mcp_user;
GRANT USAGE ON SCHEMA public TO mcp_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO mcp_user;
GRANT INSERT ON memory_entries TO mcp_user;
GRANT INSERT ON patterns TO mcp_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO mcp_user;

-- Application user - full CRUD
CREATE USER IF NOT EXISTS app_user WITH PASSWORD 'app_password_change_me';
GRANT CONNECT ON DATABASE distributed_postgres_cluster TO app_user;
GRANT USAGE ON SCHEMA public TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_user;

-- Read-only user (for analytics)
CREATE USER IF NOT EXISTS readonly_user WITH PASSWORD 'readonly_password_change_me';
GRANT CONNECT ON DATABASE distributed_postgres_cluster TO readonly_user;
GRANT USAGE ON SCHEMA public TO readonly_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_user;

\echo 'Users and permissions configured'

-- ============================================================
-- 9. Verify Cluster Setup
-- ============================================================

-- Check worker nodes
SELECT * FROM citus_get_active_worker_nodes();

-- Check shard distribution
SELECT logicalrelid, count(*) as shard_count
FROM pg_dist_shard
GROUP BY logicalrelid
ORDER BY logicalrelid;

-- Check table distribution types
SELECT logicalrelid::regclass as table_name,
       partmethod as distribution_type,
       partkey as distribution_column
FROM pg_dist_partition
ORDER BY logicalrelid;

\echo 'Cluster initialized successfully!'
\echo ''
\echo 'Next steps:'
\echo '1. Update passwords for mcp_user, app_user, readonly_user'
\echo '2. Configure SSL/TLS for secure connections'
\echo '3. Set up monitoring (Prometheus + Grafana)'
\echo '4. Test failover scenarios'
\echo ''
\echo 'Connection strings:'
\echo '  Primary (writes): postgresql://app_user:password@haproxy:5432/distributed_postgres_cluster'
\echo '  Replicas (reads): postgresql://readonly_user:password@haproxy:5433/distributed_postgres_cluster'
\echo '  MCP (AI agents): postgresql://mcp_user:password@haproxy:5432/distributed_postgres_cluster'
