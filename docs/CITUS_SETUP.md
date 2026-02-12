# Citus Distributed PostgreSQL Cluster Setup Guide

## Overview

Citus transforms PostgreSQL into a distributed database by horizontally sharding data across multiple nodes. This guide covers setup, configuration, and management of a Citus cluster with RuVector extension support.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                 Client Applications                  │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│              Citus Coordinator Node                  │
│  - Query planning and routing                        │
│  - Metadata management                               │
│  - Result aggregation                                │
│  - RuVector extension                                │
└──────────┬────────────┬──────────────────────────────┘
           │            │
           ▼            ▼
┌──────────────┐ ┌──────────────┐
│  Worker 1    │ │  Worker 2    │
│  - Shards    │ │  - Shards    │
│  - Storage   │ │  - Storage   │
│  - RuVector  │ │  - RuVector  │
└──────────────┘ └──────────────┘
```

## Quick Start

### 1. Start Citus Cluster

```bash
# Start coordinator + 2 workers (3 nodes total)
cd /home/matt/projects/Distributed-Postgress-Cluster
docker compose -f docker/citus/docker-compose.yml up -d

# Verify all nodes are running
docker compose -f docker/citus/docker-compose.yml ps

# Check logs
docker compose -f docker/citus/docker-compose.yml logs -f citus-coordinator
```

### 2. Initialize Citus Cluster

```bash
# Run setup script (waits for nodes, creates extensions, registers workers)
./scripts/citus/setup-citus.sh

# Expected output:
# - All nodes ready (3 total: 1 coordinator + 2 workers)
# - Extensions created (citus, ruvector, pg_stat_statements)
# - 2 worker nodes registered
# - Demo distributed tables created
```

### 3. Connect to Coordinator

```bash
# Using psql
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster

# Using Docker
docker exec -it citus-coordinator psql -U dpg_cluster -d distributed_postgres_cluster
```

### 4. Verify Cluster Status

```sql
-- View worker nodes
SELECT * FROM citus_get_active_worker_nodes();

-- View distributed tables
SELECT * FROM citus_tables;

-- View shard distribution
SELECT nodename, COUNT(*) as shards, pg_size_pretty(SUM(shard_size)) as size
FROM citus_shards
GROUP BY nodename;
```

## Distribution Strategies

### Hash Distribution (Default)

Best for large tables with uniform access patterns.

```sql
-- Create hash-distributed table
CREATE TABLE users (
    user_id BIGSERIAL PRIMARY KEY,
    username VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Distribute by user_id (default: 32 shards)
SELECT create_distributed_table('users', 'user_id');

-- Custom shard count
SELECT create_distributed_table('users', 'user_id', shard_count => 64);
```

**Pros:**
- Even data distribution
- Good for large tables
- Supports co-location

**Cons:**
- Can't easily rebalance without redistributing
- Distribution column must be in all queries

### Co-location

Co-locate related tables for efficient joins.

```sql
-- Base table
CREATE TABLE customers (
    customer_id BIGSERIAL PRIMARY KEY,
    name VARCHAR(255)
);
SELECT create_distributed_table('customers', 'customer_id');

-- Co-located table (same distribution column)
CREATE TABLE orders (
    order_id BIGSERIAL PRIMARY KEY,
    customer_id BIGINT NOT NULL,
    total DECIMAL(10,2)
);
SELECT create_distributed_table('orders', 'customer_id', colocate_with => 'customers');

-- Now joins on customer_id are local to each shard!
SELECT c.name, COUNT(o.order_id)
FROM customers c
JOIN orders o ON c.customer_id = o.customer_id
GROUP BY c.name;
```

### Reference Tables

Small lookup tables replicated to all nodes.

```sql
-- Create reference table
CREATE TABLE countries (
    country_code CHAR(2) PRIMARY KEY,
    country_name VARCHAR(100)
);

-- Replicate to all nodes
SELECT create_reference_table('countries');

-- Reference tables can join with any distributed table efficiently
SELECT u.username, c.country_name
FROM users u
JOIN countries c ON u.country_code = c.country_code;
```

**Use reference tables for:**
- Small tables (<100MB)
- Frequently joined dimension tables
- Configuration/lookup tables
- Tables updated infrequently

### Range Distribution

For time-series or sequential data.

```sql
-- Create range-distributed table
CREATE TABLE events (
    event_id BIGSERIAL,
    event_time TIMESTAMP NOT NULL,
    event_data JSONB,
    PRIMARY KEY (event_time, event_id)
);

-- Distribute by time range
SELECT create_distributed_table('events', 'event_time', 'range');

-- Define ranges manually
SELECT master_create_empty_shard('events') AS shard_id;
UPDATE pg_dist_shard SET shardminvalue = '2024-01-01', shardmaxvalue = '2024-02-01'
WHERE shardid = <shard_id>;
```

**Best for:**
- Time-series data
- Log tables
- Append-only workloads

## RuVector Integration

Citus works seamlessly with RuVector for distributed vector similarity search.

```sql
-- Create distributed embeddings table
CREATE TABLE document_embeddings (
    doc_id BIGSERIAL,
    user_id BIGINT NOT NULL,
    content TEXT,
    embedding ruvector(1536),
    created_at TIMESTAMP DEFAULT NOW(),
    PRIMARY KEY (doc_id, user_id)
);

-- Distribute by user_id
SELECT create_distributed_table('document_embeddings', 'user_id', colocate_with => 'users');

-- Create HNSW index on each shard
CREATE INDEX idx_embeddings_hnsw
ON document_embeddings
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 16, ef_construction = 100);

-- Vector similarity search (distributed across shards)
SELECT doc_id, content, embedding <=> '[0.1, 0.2, ...]'::ruvector AS distance
FROM document_embeddings
WHERE user_id = 123  -- Prunes to single shard
ORDER BY embedding <=> '[0.1, 0.2, ...]'::ruvector
LIMIT 10;
```

## Shard Management

### View Shard Distribution

```sql
-- Per-node shard counts
SELECT nodename, nodeport, COUNT(*) as shard_count
FROM citus_shards
GROUP BY nodename, nodeport;

-- Per-table distribution
SELECT table_name::text, nodename, COUNT(*) as shard_count
FROM citus_shards
GROUP BY table_name, nodename
ORDER BY table_name, nodename;

-- Shard sizes
SELECT
    table_name::text,
    pg_size_pretty(SUM(shard_size)) as total_size,
    pg_size_pretty(AVG(shard_size)) as avg_shard_size,
    COUNT(*) as shard_count
FROM citus_shards
GROUP BY table_name;
```

### Rebalance Shards

```bash
# Check current distribution
./scripts/citus/rebalance-shards.sh status

# Analyze imbalance
./scripts/citus/rebalance-shards.sh analyze

# Rebalance all tables
./scripts/citus/rebalance-shards.sh rebalance

# Rebalance specific table
./scripts/citus/rebalance-shards.sh rebalance distributed.users
```

### Add Worker Node

```bash
# Add new worker
./scripts/citus/rebalance-shards.sh add citus-worker-4 5432

# Rebalance to distribute shards to new worker
./scripts/citus/rebalance-shards.sh rebalance
```

### Remove Worker Node

```bash
# Drain worker (moves shards to other workers)
./scripts/citus/rebalance-shards.sh drain citus-worker-3 5432

# Remove worker from cluster
./scripts/citus/rebalance-shards.sh remove citus-worker-3 5432
```

## Query Optimization

### Use EXPLAIN (DIST)

```sql
-- See how query is distributed
EXPLAIN (ANALYZE, DIST) SELECT COUNT(*) FROM users WHERE user_id BETWEEN 1 AND 1000;
```

### Push Down Filters

```sql
-- BAD: Full table scan across all shards
SELECT * FROM users WHERE email LIKE '%@gmail.com';

-- GOOD: Filter on distribution column prunes to specific shards
SELECT * FROM users WHERE user_id = 123 AND email LIKE '%@gmail.com';
```

### Parallel Aggregations

```sql
-- Parallel count across all shards
SELECT COUNT(*) FROM users;

-- Parallel aggregation with GROUP BY
SELECT DATE(created_at), COUNT(*)
FROM users
GROUP BY DATE(created_at);
```

### Subqueries

```sql
-- Subqueries are pushed down to workers when possible
SELECT user_id, username
FROM users
WHERE user_id IN (
    SELECT DISTINCT user_id FROM orders WHERE total > 100
);
```

## Monitoring

### Cluster Health

```sql
-- Node status
SELECT nodename, nodeport, isactive, shouldhaveshards
FROM pg_dist_node;

-- Shard health
SELECT COUNT(*) as total_shards,
       COUNT(*) FILTER (WHERE shardstate = 1) as healthy_shards
FROM pg_dist_shard;

-- Active queries across cluster
SELECT * FROM citus_dist_stat_activity;
```

### Performance Metrics

```sql
-- Query statistics
SELECT query, calls, mean_exec_time, stddev_exec_time
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;

-- Shard-level I/O stats
SELECT schemaname, tablename, heap_blks_read, heap_blks_hit
FROM pg_statio_user_tables
ORDER BY heap_blks_read DESC;
```

### Connection Pooling

Citus coordinator can handle many client connections, but limit worker connections:

```
Client → Coordinator (100 connections)
Coordinator → Worker (32 connections per worker)
```

Use PgBouncer in front of coordinator for higher client connection counts.

## Migration from Single-Node

### Step 1: Backup

```bash
# Run migration preparation
./scripts/citus/migrate-to-citus.sh all

# This creates:
# - Full database backup
# - Table analysis
# - Migration SQL template
# - Rollback script
```

### Step 2: Review Analysis

```bash
# Check table sizes and recommendations
cat backups/migration-*/table-analysis.txt
```

### Step 3: Customize Migration

```bash
# Edit migration SQL based on analysis
vim backups/migration-*/migration-script.sql
```

### Step 4: Start Citus Cluster

```bash
docker compose -f docker/citus/docker-compose.yml up -d
./scripts/citus/setup-citus.sh
```

### Step 5: Apply Migration

```bash
# Connect to coordinator
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster

# Run migration SQL
\i backups/migration-*/migration-script.sql
```

### Step 6: Migrate Data

```bash
# Option A: pg_dump/restore (downtime required)
pg_dump -h source -d db | psql -h coordinator -d db

# Option B: Per-table CSV export/import (less downtime)
./scripts/citus/migrate-to-citus.sh export public users
./scripts/citus/migrate-to-citus.sh import public users
```

### Step 7: Verify

```bash
./scripts/citus/migrate-to-citus.sh verify
```

### Step 8: Rollback (if needed)

```bash
cd backups/migration-*
./rollback.sh
```

## Best Practices

### 1. Choose Distribution Column Carefully

- High cardinality (many unique values)
- Used in most queries (WHERE/JOIN)
- Enables co-location of related data
- Usually primary key or foreign key

### 2. Co-locate Related Tables

```sql
-- Co-locate orders with customers
SELECT create_distributed_table('orders', 'customer_id', colocate_with => 'customers');

-- Co-locate order_items with orders
SELECT create_distributed_table('order_items', 'customer_id', colocate_with => 'orders');
```

### 3. Use Reference Tables for Small Lookups

```sql
SELECT create_reference_table('countries');
SELECT create_reference_table('product_categories');
```

### 4. Monitor Shard Balance

```bash
# Check balance regularly
./scripts/citus/rebalance-shards.sh status

# Rebalance when adding/removing workers
./scripts/citus/rebalance-shards.sh rebalance
```

### 5. Tune Shard Count

- Default: 32 shards
- Small clusters (2 workers): 16-32 shards
- Large clusters: 64-128 shards
- Rule of thumb: 2-4x number of CPU cores across cluster
- For testing with 2 workers: 16-24 shards recommended

### 6. Use Appropriate Indexes

```sql
-- Indexes are created on each shard
CREATE INDEX idx_users_email ON users (email);

-- HNSW for vector similarity
CREATE INDEX idx_embeddings ON embeddings USING hnsw (embedding ruvector_cosine_ops);
```

## Troubleshooting

### Workers Not Registered

```sql
-- Check worker nodes (should show 2 workers)
SELECT * FROM citus_get_active_worker_nodes();

-- Manually add worker if missing
SELECT citus_add_node('citus-worker-1', 5432);
SELECT citus_add_node('citus-worker-2', 5432);
```

### Uneven Shard Distribution

```bash
# Check distribution
./scripts/citus/rebalance-shards.sh status

# Rebalance
./scripts/citus/rebalance-shards.sh rebalance
```

### Slow Queries

```sql
-- Use EXPLAIN (DIST) to see execution plan
EXPLAIN (ANALYZE, DIST) SELECT ...;

-- Check if query is using distribution column
-- BAD: Full scan across all shards
SELECT * FROM users WHERE email = 'test@example.com';

-- GOOD: Prunes to single shard
SELECT * FROM users WHERE user_id = 123;
```

### Connection Errors

```bash
# Check connectivity between nodes
docker exec citus-coordinator pg_isready -h citus-worker-1

# Check PostgreSQL logs
docker logs citus-coordinator
docker logs citus-worker-1
```

## Performance Tuning

### Coordinator Settings

```
shared_buffers = 512MB          # 25% of RAM
effective_cache_size = 1536MB   # 75% of RAM
work_mem = 32MB
max_connections = 100
```

### Worker Settings

```
shared_buffers = 2GB            # 25% of RAM
effective_cache_size = 6GB      # 75% of RAM
work_mem = 128MB
max_connections = 200           # Higher for coordinator connections
```

### Connection Pooling

```
citus.max_cached_conns_per_worker = 4
citus.max_adaptive_executor_pool_size = 32
```

## Useful Commands

```bash
# Start cluster
docker compose -f docker/citus/docker-compose.yml up -d

# Stop cluster
docker compose -f docker/citus/docker-compose.yml down

# View logs
docker compose -f docker/citus/docker-compose.yml logs -f

# Clean all data
docker compose -f docker/citus/docker-compose.yml down -v

# Setup Citus
./scripts/citus/setup-citus.sh

# Rebalance shards
./scripts/citus/rebalance-shards.sh rebalance

# Migrate from single-node
./scripts/citus/migrate-to-citus.sh all

# Monitor cluster
./scripts/citus/monitor-citus.sh
```

## Resources

- [Citus Documentation](https://docs.citusdata.com/)
- [Citus Best Practices](https://docs.citusdata.com/en/stable/performance/performance_tuning.html)
- [RuVector Documentation](https://github.com/ruvnet/ruvector)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)

## Support

For issues or questions:
- GitHub Issues: https://github.com/your-repo/issues
- Citus Community: https://www.citusdata.com/community

## License

MIT License - see LICENSE file for details.
