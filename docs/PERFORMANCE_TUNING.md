# Performance Tuning Guide

Comprehensive guide to optimizing the Distributed PostgreSQL Cluster with RuVector for maximum performance.

## Table of Contents

1. [Quick Start](#quick-start)
2. [PostgreSQL Configuration](#postgresql-configuration)
3. [RuVector Optimization](#ruvector-optimization)
4. [Query Optimization](#query-optimization)
5. [Index Strategies](#index-strategies)
6. [Connection Pooling](#connection-pooling)
7. [Hardware Recommendations](#hardware-recommendations)
8. [Capacity Planning](#capacity-planning)
9. [Monitoring and Metrics](#monitoring-and-metrics)
10. [Common Bottlenecks](#common-bottlenecks)

---

## Quick Start

### Run All Optimization Tools

```bash
# 1. Auto-tune PostgreSQL parameters
./scripts/performance/tune-postgresql.sh analyze

# 2. Analyze slow queries
./scripts/performance/analyze-slow-queries.sh setup
docker restart ruvector-db  # Required for pg_stat_statements
./scripts/performance/analyze-slow-queries.sh report

# 3. Optimize RuVector indexes
./scripts/performance/optimize-ruvector.sh analyze

# 4. Run performance benchmark
./scripts/performance/benchmark-cluster.sh run
```

### Establish Performance Baseline

```bash
# Create baseline for future comparisons
./scripts/performance/benchmark-cluster.sh baseline

# Compare after optimizations
./scripts/performance/benchmark-cluster.sh run
```

---

## PostgreSQL Configuration

### Memory Configuration

PostgreSQL memory parameters significantly impact performance:

| Parameter | Formula | Example (16GB RAM) | Purpose |
|-----------|---------|-------------------|---------|
| `shared_buffers` | 25% of RAM (up to 8GB) | 4GB | Main cache for data pages |
| `effective_cache_size` | 50-75% of RAM | 10GB | Query planner hint for OS cache |
| `maintenance_work_mem` | RAM / 16 (up to 2GB) | 1GB | Maintenance operations (VACUUM, CREATE INDEX) |
| `work_mem` | (RAM - shared_buffers) / (max_connections * 3) | 32MB | Per-query operation memory |

#### Configuration by Workload Type

**Read-Heavy Workload**
```sql
ALTER SYSTEM SET shared_buffers = '4GB';
ALTER SYSTEM SET effective_cache_size = '12GB';
ALTER SYSTEM SET work_mem = '64MB';
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_io_concurrency = 200;
```

**Write-Heavy Workload**
```sql
ALTER SYSTEM SET shared_buffers = '4GB';
ALTER SYSTEM SET wal_buffers = '16MB';
ALTER SYSTEM SET checkpoint_completion_target = 0.9;
ALTER SYSTEM SET max_wal_size = '4GB';
ALTER SYSTEM SET random_page_cost = 1.5;
```

**Mixed Workload**
```sql
ALTER SYSTEM SET shared_buffers = '4GB';
ALTER SYSTEM SET effective_cache_size = '10GB';
ALTER SYSTEM SET work_mem = '32MB';
ALTER SYSTEM SET random_page_cost = 1.3;
ALTER SYSTEM SET effective_io_concurrency = 150;
```

### WAL (Write-Ahead Log) Configuration

Optimize WAL for write performance:

```sql
-- WAL buffers (-1 = auto-tune to 3% of shared_buffers)
ALTER SYSTEM SET wal_buffers = '-1';

-- Checkpoint configuration
ALTER SYSTEM SET checkpoint_completion_target = 0.9;
ALTER SYSTEM SET max_wal_size = '2GB';
ALTER SYSTEM SET min_wal_size = '512MB';

-- WAL compression (PostgreSQL 14+)
ALTER SYSTEM SET wal_compression = on;
```

### Parallel Query Configuration

Leverage multiple CPU cores:

```sql
-- Number of CPU cores
ALTER SYSTEM SET max_parallel_workers_per_gather = 4;
ALTER SYSTEM SET max_parallel_workers = 4;
ALTER SYSTEM SET max_worker_processes = 8;

-- Parallel query thresholds
ALTER SYSTEM SET parallel_tuple_cost = 0.1;
ALTER SYSTEM SET parallel_setup_cost = 1000.0;
ALTER SYSTEM SET min_parallel_table_scan_size = '8MB';
```

### Autovacuum Tuning

Prevent table bloat and maintain statistics:

```sql
-- Enable and configure autovacuum
ALTER SYSTEM SET autovacuum = on;
ALTER SYSTEM SET autovacuum_max_workers = 3;
ALTER SYSTEM SET autovacuum_naptime = '10s';

-- Aggressive settings for write-heavy workloads
ALTER SYSTEM SET autovacuum_vacuum_scale_factor = 0.1;
ALTER SYSTEM SET autovacuum_analyze_scale_factor = 0.05;
```

### Automated Tuning Script

```bash
# Auto-detect workload and tune parameters
./scripts/performance/tune-postgresql.sh analyze

# Force specific workload profile
./scripts/performance/tune-postgresql.sh analyze read-heavy
./scripts/performance/tune-postgresql.sh analyze write-heavy
./scripts/performance/tune-postgresql.sh analyze mixed

# Run VACUUM ANALYZE on all tables
./scripts/performance/tune-postgresql.sh vacuum

# Analyze index usage
./scripts/performance/tune-postgresql.sh indexes
```

---

## RuVector Optimization

### HNSW Index Parameters

RuVector uses HNSW (Hierarchical Navigable Small World) indexes for approximate nearest neighbor search.

#### Parameter Reference

| Parameter | Default | Range | Impact |
|-----------|---------|-------|--------|
| `m` | 16 | 4-64 | Connectivity, affects recall and index size |
| `ef_construction` | 100 | 10-1000 | Build quality, affects accuracy and build time |
| `ef_search` | 100 | 10-1000 | Query quality, set at query time |

#### Parameter Tuning Guidelines

**Development / Testing**
```sql
CREATE INDEX idx_embeddings_hnsw ON table_name
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 16, ef_construction = 100);
```

**Production**
```sql
CREATE INDEX idx_embeddings_hnsw ON table_name
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 16, ef_construction = 200);
```

**High Accuracy**
```sql
CREATE INDEX idx_embeddings_hnsw ON table_name
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 32, ef_construction = 200);
```

**Fast Build (lower accuracy)**
```sql
CREATE INDEX idx_embeddings_hnsw ON table_name
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 8, ef_construction = 50);
```

#### Query-Time Optimization

Adjust search quality dynamically:

```sql
-- Higher accuracy (slower)
SET hnsw.ef_search = 200;
SELECT * FROM table_name
ORDER BY embedding <=> query_vector
LIMIT 10;

-- Faster search (lower accuracy)
SET hnsw.ef_search = 50;
SELECT * FROM table_name
ORDER BY embedding <=> query_vector
LIMIT 10;

-- Reset to default
RESET hnsw.ef_search;
```

### Batch Operations

**ALWAYS use batch operations for vectors:**

```sql
-- ✓ GOOD: Batch insert
INSERT INTO embeddings (text, embedding)
SELECT text, embedding
FROM unnest($1::text[], $2::ruvector[]) AS t(text, embedding);

-- ✗ BAD: Single inserts in loop
FOR i IN 1..N LOOP
    INSERT INTO embeddings (text, embedding)
    VALUES ($1, $2);
END LOOP;
```

Batch operations are **10-50x faster** than single inserts.

### Vector Memory Configuration

For vector-heavy workloads:

```sql
-- Increase memory for vector operations
ALTER SYSTEM SET shared_buffers = '8GB';
ALTER SYSTEM SET work_mem = '256MB';
ALTER SYSTEM SET maintenance_work_mem = '2GB';

-- For HNSW index builds
ALTER SYSTEM SET max_parallel_maintenance_workers = 4;
```

### Optimization Scripts

```bash
# Analyze current HNSW indexes
./scripts/performance/optimize-ruvector.sh analyze

# Benchmark HNSW parameters
./scripts/performance/optimize-ruvector.sh benchmark

# Optimize existing indexes
./scripts/performance/optimize-ruvector.sh tune

# Profile vector operations
./scripts/performance/optimize-ruvector.sh profile

# Quick benchmark
./scripts/performance/optimize-ruvector.sh quick

# Show recommendations
./scripts/performance/optimize-ruvector.sh recommendations
```

---

## Query Optimization

### Slow Query Analysis

#### Setup pg_stat_statements

```bash
# Enable extension and configure
./scripts/performance/analyze-slow-queries.sh setup

# Restart PostgreSQL
docker restart ruvector-db

# Generate slow query report
./scripts/performance/analyze-slow-queries.sh report
```

#### Analyzing Queries with EXPLAIN

```sql
-- Show query plan
EXPLAIN SELECT * FROM table_name WHERE condition;

-- Show actual execution statistics
EXPLAIN ANALYZE SELECT * FROM table_name WHERE condition;

-- Show buffers and timing
EXPLAIN (ANALYZE, BUFFERS, TIMING) SELECT * FROM table_name WHERE condition;

-- JSON output for tooling
EXPLAIN (FORMAT JSON) SELECT * FROM table_name WHERE condition;
```

#### Query Optimization Techniques

**1. Index Selection**
```sql
-- Check if indexes are being used
SELECT
    schemaname,
    tablename,
    indexname,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_user_indexes
WHERE idx_scan > 0
ORDER BY idx_scan DESC;
```

**2. Avoid Sequential Scans on Large Tables**
```sql
-- Find tables with high sequential scan counts
SELECT
    schemaname || '.' || tablename AS table_name,
    seq_scan,
    seq_tup_read,
    idx_scan,
    n_live_tup AS row_count
FROM pg_stat_user_tables
WHERE seq_scan > 100
    AND n_live_tup > 1000
ORDER BY seq_scan DESC;
```

**3. Optimize JOIN Operations**
```sql
-- Use explicit JOIN syntax
SELECT * FROM t1
INNER JOIN t2 ON t1.id = t2.t1_id  -- ✓ Good
WHERE t1.status = 'active';

-- Avoid implicit joins
SELECT * FROM t1, t2
WHERE t1.id = t2.t1_id  -- ✗ Bad
    AND t1.status = 'active';
```

**4. Use Covering Indexes**
```sql
-- Include frequently accessed columns
CREATE INDEX idx_users_email_name ON users (email) INCLUDE (name, created_at);

-- Now this query uses index-only scan
SELECT name, created_at FROM users WHERE email = 'user@example.com';
```

**5. Partial Indexes**
```sql
-- Index only active records
CREATE INDEX idx_active_users ON users (email) WHERE status = 'active';

-- Query benefits from smaller index
SELECT * FROM users WHERE email = 'user@example.com' AND status = 'active';
```

### Common Query Patterns

#### Pagination

**Efficient offset-based pagination:**
```sql
-- ✓ Good: Use index on id
SELECT * FROM items
WHERE id > $last_id
ORDER BY id
LIMIT 20;

-- ✗ Bad: Large offset
SELECT * FROM items
ORDER BY id
LIMIT 20 OFFSET 10000;  -- Slow for large offsets
```

#### Full-Text Search

```sql
-- Create GIN index for text search
CREATE INDEX idx_documents_search ON documents
USING gin(to_tsvector('english', content));

-- Use index
SELECT * FROM documents
WHERE to_tsvector('english', content) @@ to_tsquery('search & terms');
```

#### Aggregations

```sql
-- Use materialized views for expensive aggregations
CREATE MATERIALIZED VIEW daily_stats AS
SELECT
    DATE(created_at) AS date,
    COUNT(*) AS count,
    AVG(value) AS avg_value
FROM events
GROUP BY DATE(created_at);

-- Refresh periodically
REFRESH MATERIALIZED VIEW CONCURRENTLY daily_stats;
```

---

## Index Strategies

### Index Types

| Index Type | Use Case | Example |
|-----------|----------|---------|
| B-tree | Equality, range queries | `CREATE INDEX idx_name ON table (column);` |
| HNSW | Vector similarity search | `CREATE INDEX idx_vec ON table USING hnsw (embedding);` |
| GIN | Full-text search, arrays | `CREATE INDEX idx_gin ON table USING gin (column);` |
| Hash | Equality only | `CREATE INDEX idx_hash ON table USING hash (column);` |
| BRIN | Large tables, sequential data | `CREATE INDEX idx_brin ON table USING brin (timestamp);` |

### Index Creation Best Practices

**1. Use CONCURRENTLY for Production**
```sql
-- Non-blocking index creation
CREATE INDEX CONCURRENTLY idx_name ON table_name (column_name);

-- If it fails, clean up invalid index
DROP INDEX CONCURRENTLY idx_name;
```

**2. Multi-Column Indexes**
```sql
-- Order matters! Most selective column first
CREATE INDEX idx_users_status_created ON users (status, created_at);

-- This query uses the index
SELECT * FROM users WHERE status = 'active' AND created_at > '2024-01-01';

-- This query also uses the index (first column only)
SELECT * FROM users WHERE status = 'active';

-- This query does NOT use the index (second column only)
SELECT * FROM users WHERE created_at > '2024-01-01';
```

**3. Covering Indexes**
```sql
-- Include columns for index-only scans
CREATE INDEX idx_orders_customer_total ON orders (customer_id)
INCLUDE (total_amount, order_date);

-- Index-only scan (faster)
SELECT total_amount, order_date
FROM orders
WHERE customer_id = 123;
```

**4. Partial Indexes**
```sql
-- Index only relevant subset
CREATE INDEX idx_active_orders ON orders (created_at)
WHERE status = 'active';

-- Smaller index, faster queries
SELECT * FROM orders
WHERE status = 'active' AND created_at > '2024-01-01';
```

### Index Maintenance

**Monitor Index Usage**
```sql
-- Unused indexes
SELECT
    schemaname || '.' || tablename AS table_name,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
    AND indexname NOT LIKE '%_pkey'
ORDER BY pg_relation_size(indexrelid) DESC;
```

**Rebuild Bloated Indexes**
```sql
-- Concurrent rebuild
REINDEX INDEX CONCURRENTLY idx_name;

-- Or recreate
DROP INDEX CONCURRENTLY idx_name;
CREATE INDEX CONCURRENTLY idx_name ON table_name (column_name);
```

**Update Statistics**
```sql
-- Single table
ANALYZE table_name;

-- All tables
ANALYZE;

-- Increase statistics detail
ALTER TABLE table_name ALTER COLUMN column_name SET STATISTICS 500;
ANALYZE table_name;
```

---

## Connection Pooling

### Current Configuration

- **Project pool**: 40 max connections
- **Shared pool**: 15 max connections
- **Total capacity**: 55 connections
- **PostgreSQL max_connections**: 100

### Connection Pool Sizing

**Formula:**
```
pool_size = (CPU_cores * 2) + disk_drives
```

**Example (4 cores, 1 SSD):**
```
pool_size = (4 * 2) + 1 = 9
```

### PgBouncer Configuration

For very high concurrency:

```ini
[databases]
distributed_postgres_cluster = host=localhost port=5432 dbname=distributed_postgres_cluster

[pgbouncer]
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
reserve_pool_size = 5
reserve_pool_timeout = 3
```

**Pool Modes:**
- `session`: Connection per session (safest, lowest concurrency)
- `transaction`: Connection per transaction (recommended)
- `statement`: Connection per statement (highest concurrency, most restrictive)

### Monitoring Connections

```sql
-- Active connections
SELECT count(*) FROM pg_stat_activity
WHERE datname = 'distributed_postgres_cluster';

-- Long-running queries
SELECT
    pid,
    now() - query_start AS duration,
    query
FROM pg_stat_activity
WHERE state = 'active'
    AND query_start < now() - interval '1 minute'
ORDER BY duration DESC;

-- Kill long-running query
SELECT pg_terminate_backend(pid);
```

---

## Hardware Recommendations

### Minimum Requirements

| Component | Minimum | Recommended | High Performance |
|-----------|---------|-------------|------------------|
| CPU | 2 cores | 4-8 cores | 16+ cores |
| RAM | 4GB | 16GB | 32-64GB |
| Storage | 50GB SSD | 500GB NVMe | 1TB+ NVMe RAID |
| Network | 1 Gbps | 10 Gbps | 25+ Gbps |

### Storage Configuration

**SSD vs HDD**
- **SSD**: Required for production workloads
- **NVMe**: 3-5x faster than SATA SSD
- **RAID 10**: Best for databases (performance + redundancy)

**File System**
- **ext4**: Reliable, well-tested
- **XFS**: Better for large files and parallel I/O
- **ZFS**: Advanced features but overhead

**Mount Options**
```bash
# ext4 with optimizations
/dev/sda1 /var/lib/postgresql ext4 noatime,nodiratime,discard 0 0
```

### CPU Considerations

- **Single-thread performance** > core count for most queries
- **Parallel queries** benefit from more cores
- **Intel vs AMD**: Both work well, prefer higher clock speeds

### Network

- **Latency**: Keep < 1ms for distributed queries
- **Bandwidth**: 10 Gbps minimum for distributed clusters
- **Jumbo Frames**: Enable for better throughput (MTU 9000)

---

## Capacity Planning

### Growth Projections

**Data Growth**
```
Year 1: 100GB
Year 2: 300GB (+200%)
Year 3: 700GB (+133%)
```

**Connection Growth**
```
Year 1: 50 concurrent
Year 2: 150 concurrent (+200%)
Year 3: 400 concurrent (+167%)
```

### Scaling Strategies

**Vertical Scaling (Scale Up)**
- Add RAM (easiest, most effective)
- Upgrade to faster storage (NVMe)
- More CPU cores

**Horizontal Scaling (Scale Out)**
- Read replicas for read-heavy workloads
- Sharding for write-heavy workloads
- Citus for distributed PostgreSQL

### Storage Estimation

**Database Size Formula:**
```
Total Size = (Table Size + Index Size) * 1.3 (overhead)
```

**Vector Storage:**
- 1536-dim float32 vector = 6144 bytes
- 1M vectors ≈ 6GB data
- HNSW index ≈ 1-2x data size
- Total: ~18GB for 1M vectors

**Example Calculation:**
```
1M entries:
- Vectors: 6GB
- HNSW indexes: 12GB
- Metadata: 2GB
- Overhead: 6GB (30%)
Total: 26GB

10M entries: 260GB
100M entries: 2.6TB
```

---

## Monitoring and Metrics

### Key Performance Indicators

| Metric | Target | Warning | Critical |
|--------|--------|---------|----------|
| Query latency (p99) | < 50ms | > 100ms | > 500ms |
| Cache hit ratio | > 95% | < 90% | < 85% |
| Connection usage | < 50% | > 70% | > 90% |
| Disk I/O wait | < 5% | > 10% | > 20% |
| Replication lag | < 1s | > 5s | > 30s |

### Monitoring Tools

**Built-in Views**
```sql
-- Current activity
SELECT * FROM pg_stat_activity;

-- Table statistics
SELECT * FROM pg_stat_user_tables;

-- Index usage
SELECT * FROM pg_stat_user_indexes;

-- Database size
SELECT pg_size_pretty(pg_database_size(current_database()));
```

**pg_stat_statements**
```sql
-- Top 10 slowest queries
SELECT
    mean_exec_time,
    calls,
    query
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;
```

**External Tools**
- **pgAdmin**: Web-based administration
- **Datadog**: Comprehensive monitoring
- **Prometheus + Grafana**: Open-source monitoring
- **pgbadger**: Log analyzer

### Benchmark Scripts

```bash
# Run comprehensive benchmark
./scripts/performance/benchmark-cluster.sh run

# Set baseline for comparisons
./scripts/performance/benchmark-cluster.sh baseline

# Compare with baseline
./scripts/performance/benchmark-cluster.sh compare results.json

# Generate HTML report
./scripts/performance/benchmark-cluster.sh report
```

---

## Common Bottlenecks

### 1. Insufficient Memory

**Symptoms:**
- High disk I/O
- Slow query performance
- Frequent swapping

**Solutions:**
```sql
-- Increase shared_buffers
ALTER SYSTEM SET shared_buffers = '8GB';

-- Increase work_mem for complex queries
ALTER SYSTEM SET work_mem = '64MB';
```

### 2. Slow Queries

**Symptoms:**
- High query latency
- pg_stat_statements shows slow queries

**Solutions:**
```bash
# Analyze slow queries
./scripts/performance/analyze-slow-queries.sh report

# Add missing indexes
CREATE INDEX CONCURRENTLY idx_name ON table_name (column_name);

# Update statistics
ANALYZE table_name;
```

### 3. Connection Exhaustion

**Symptoms:**
- "Too many connections" errors
- High connection pool usage

**Solutions:**
```sql
-- Increase max_connections
ALTER SYSTEM SET max_connections = 200;

-- Implement connection pooling (PgBouncer)
-- Or increase application pool size
```

### 4. Table Bloat

**Symptoms:**
- Growing table/index sizes
- Degrading performance over time

**Solutions:**
```bash
# Run VACUUM
./scripts/performance/tune-postgresql.sh vacuum

# Manual VACUUM FULL (requires downtime)
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster \
  -c "VACUUM FULL table_name;"
```

### 5. Lock Contention

**Symptoms:**
- Queries waiting for locks
- log_lock_waits messages

**Solutions:**
```sql
-- Find blocking queries
SELECT
    blocked.pid AS blocked_pid,
    blocking.pid AS blocking_pid,
    blocked.query AS blocked_query,
    blocking.query AS blocking_query
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking ON blocking.pid = ANY(pg_blocking_pids(blocked.pid));

-- Kill blocking query if needed
SELECT pg_terminate_backend(blocking_pid);
```

### 6. Poor Vector Search Performance

**Symptoms:**
- Slow vector similarity queries
- High HNSW index scan times

**Solutions:**
```bash
# Optimize HNSW indexes
./scripts/performance/optimize-ruvector.sh tune

# Adjust query-time parameters
SET hnsw.ef_search = 100;

# Use batch operations
-- Insert vectors in batches of 100-1000
```

---

## Performance Tuning Checklist

### Initial Setup
- [ ] Run auto-tuning script: `./scripts/performance/tune-postgresql.sh analyze`
- [ ] Set baseline: `./scripts/performance/benchmark-cluster.sh baseline`
- [ ] Enable pg_stat_statements: `./scripts/performance/analyze-slow-queries.sh setup`
- [ ] Configure monitoring

### Weekly Maintenance
- [ ] Run VACUUM ANALYZE: `./scripts/performance/tune-postgresql.sh vacuum`
- [ ] Review slow queries: `./scripts/performance/analyze-slow-queries.sh report`
- [ ] Check index usage: `./scripts/performance/tune-postgresql.sh indexes`
- [ ] Monitor cache hit ratio

### Monthly Maintenance
- [ ] Review and update statistics: `ANALYZE;`
- [ ] Rebuild bloated indexes: `REINDEX INDEX CONCURRENTLY`
- [ ] Review and drop unused indexes
- [ ] Run full benchmark and compare: `./scripts/performance/benchmark-cluster.sh run`

### Quarterly Maintenance
- [ ] Review capacity and plan scaling
- [ ] Update hardware if needed
- [ ] Review and optimize connection pooling
- [ ] Audit slow queries and optimize

---

## Performance Testing

### Load Testing

**pgbench (built-in PostgreSQL benchmark):**
```bash
# Initialize test data
docker exec ruvector-db pgbench -i -s 50 distributed_postgres_cluster

# Run benchmark (10 clients, 2 threads, 60 seconds)
docker exec ruvector-db pgbench -c 10 -j 2 -T 60 distributed_postgres_cluster
```

**Custom Load Test:**
```python
import asyncio
import asyncpg
from time import time

async def load_test():
    pool = await asyncpg.create_pool(
        host='localhost',
        port=5432,
        user='dpg_cluster',
        password='dpg_cluster_2026',
        database='distributed_postgres_cluster',
        min_size=10,
        max_size=40
    )

    async def query():
        async with pool.acquire() as conn:
            await conn.fetch('SELECT 1')

    start = time()
    tasks = [query() for _ in range(1000)]
    await asyncio.gather(*tasks)
    duration = time() - start

    print(f"1000 queries in {duration:.2f}s")
    print(f"QPS: {1000/duration:.2f}")

asyncio.run(load_test())
```

---

## Additional Resources

### Documentation
- [PostgreSQL Performance Tips](https://wiki.postgresql.org/wiki/Performance_Optimization)
- [PostgreSQL Tuning Guide](https://www.postgresql.org/docs/current/runtime-config.html)
- [RuVector Documentation](https://github.com/ruvnet/ruvector)

### Tools
- [explain.depesz.com](https://explain.depesz.com/) - EXPLAIN visualizer
- [pgMustard](https://www.pgmustard.com/) - Query plan analyzer
- [pgtune](https://pgtune.leopard.in.ua/) - Configuration generator

### Scripts Reference
- `/scripts/performance/tune-postgresql.sh` - Auto-tune PostgreSQL
- `/scripts/performance/analyze-slow-queries.sh` - Slow query analysis
- `/scripts/performance/optimize-ruvector.sh` - RuVector optimization
- `/scripts/performance/benchmark-cluster.sh` - Performance benchmarking

---

**Last Updated:** 2026-02-12
**Version:** 1.0.0
