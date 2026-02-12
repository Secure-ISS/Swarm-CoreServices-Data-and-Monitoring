# Sprint 6-10 Implementation Guide
## Weeks 7-12: Distribution → Performance Optimization

---

## PHASE 1: Citus Setup (Week 7)

### 1.1 Start Citus Cluster

```bash
# Navigate to project root
cd /home/matt/projects/Distributed-Postgress-Cluster

# Start 3-node cluster (1 coordinator + 2 workers)
docker compose -f docker/citus/docker-compose.yml up -d

# Verify all nodes running
docker compose -f docker/citus/docker-compose.yml ps
docker compose -f docker/citus/docker-compose.yml logs -f citus-coordinator

# Wait for readiness (~30 seconds)
sleep 35
```

### 1.2 Initialize Citus Cluster

```bash
# Run setup script - creates extensions + registers workers
./scripts/citus/setup-citus.sh

# Expected: "All worker nodes registered successfully"
# Logs: Extensions created, demo tables distributed
```

### 1.3 Verify Coordinator Connection

```bash
# Via psql
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster

# Via Docker
docker exec -it citus-coordinator psql -U dpg_cluster -d distributed_postgres_cluster

# Inside psql - check nodes
\d citus_get_active_worker_nodes
SELECT * FROM citus_get_active_worker_nodes();
```

---

## PHASE 2: Shard Creation & Distribution (Week 8)

### 2.1 Create Hash-Distributed Tables

```sql
-- Session: Citus Coordinator

-- Create users table (hash distribution)
CREATE TABLE distributed.users (
    user_id BIGSERIAL PRIMARY KEY,
    username VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL,
    metadata JSONB,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Distribute by user_id
SELECT create_distributed_table('distributed.users', 'user_id', colocate_with => 'none');

-- Create events table (hash distribution, colocated with users)
CREATE TABLE distributed.events (
    event_id BIGSERIAL,
    user_id BIGINT NOT NULL REFERENCES distributed.users(user_id),
    event_type VARCHAR(100),
    event_data JSONB,
    timestamp TIMESTAMP DEFAULT NOW(),
    PRIMARY KEY (event_id, user_id)
);

-- Distribute colocated with users
SELECT create_distributed_table('distributed.events', 'user_id', colocate_with => 'distributed.users');
```

### 2.2 Create Reference Tables

```sql
-- Create reference table (replicated on all workers)
CREATE TABLE reference.country_codes (
    code VARCHAR(2) PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Mark as reference table
SELECT create_reference_table('reference.country_codes');

-- Create regions reference table
CREATE TABLE reference.regions (
    region_id INT PRIMARY KEY,
    region_name VARCHAR(100) NOT NULL,
    country_code VARCHAR(2) REFERENCES reference.country_codes(code)
);

SELECT create_reference_table('reference.regions');
```

### 2.3 Create Local Tables (Coordinator-only)

```sql
-- Create local table on coordinator (not distributed)
CREATE TABLE local.system_config (
    config_key VARCHAR(255) PRIMARY KEY,
    config_value TEXT,
    updated_by VARCHAR(100),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Insert configuration
INSERT INTO local.system_config (config_key, config_value, updated_by)
VALUES
    ('cluster_name', 'dpg-cluster-01', 'admin'),
    ('max_connections', '100', 'admin'),
    ('shard_count', '32', 'admin');
```

### 2.4 Verify Shard Distribution

```sql
-- View all distributed tables
SELECT * FROM citus_tables;

-- View shard metadata
SELECT nodename, shardid, shardstate, shardlength
FROM citus_shards
ORDER BY nodename, shardid;

-- Check shard distribution balance
SELECT nodename, COUNT(*) as shard_count,
       pg_size_pretty(SUM(shard_size)) as total_size
FROM citus_shards
GROUP BY nodename
ORDER BY nodename;
```

---

## PHASE 3: Data Insertion & Load Testing (Week 8-9)

### 3.1 Bulk Load Data

```bash
# Load sample data via Python script
python3 scripts/benchmark/quick_benchmark.py --mode load --rows 100000

# Via SQL script
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster < scripts/citus/test-distribution.sh
```

### 3.2 Insert Test Data

```sql
-- Insert users (10k test records)
INSERT INTO distributed.users (username, email, metadata)
SELECT
    'user_' || i::TEXT,
    'user_' || i::TEXT || '@example.com',
    jsonb_build_object('source', 'test', 'created_batch', 1)
FROM generate_series(1, 10000) AS i;

-- Insert events (50k records)
INSERT INTO distributed.events (user_id, event_type, event_data)
SELECT
    (random() * 10000 + 1)::BIGINT,
    CASE (random() * 4)::INT
        WHEN 0 THEN 'login'
        WHEN 1 THEN 'logout'
        WHEN 2 THEN 'purchase'
        ELSE 'view'
    END,
    jsonb_build_object('session_id', gen_random_uuid())
FROM generate_series(1, 50000);
```

### 3.3 Verify Distribution

```sql
-- Check row counts per shard
SELECT nodename, COUNT(*) as rows_per_shard
FROM citus_shards
WHERE table_name = 'distributed.users'::regclass
GROUP BY nodename;

-- Verify data is distributed
SELECT
    get_shard_id_for_distribution_column('distributed.users', user_id) as shard_id,
    COUNT(*) as row_count
FROM distributed.users
GROUP BY shard_id
ORDER BY shard_id;
```

---

## PHASE 4: Performance Tuning (Week 9-10)

### 4.1 PostgreSQL Configuration Auto-Tuning

```bash
# Detect workload and auto-tune (reads workload patterns)
./scripts/performance/tune-postgresql.sh auto

# Tune for read-heavy workload (analytics, OLAP)
./scripts/performance/tune-postgresql.sh read-heavy

# Tune for write-heavy workload (transactions, OLTP)
./scripts/performance/tune-postgresql.sh write-heavy

# Tune for mixed workload
./scripts/performance/tune-postgresql.sh mixed
```

### 4.2 Apply Manual Performance Settings

```sql
-- Memory and cache optimization
ALTER SYSTEM SET shared_buffers = '4GB';
ALTER SYSTEM SET effective_cache_size = '12GB';
ALTER SYSTEM SET work_mem = '50MB';
ALTER SYSTEM SET maintenance_work_mem = '1GB';

-- Parallel execution
ALTER SYSTEM SET max_parallel_workers = 8;
ALTER SYSTEM SET max_parallel_workers_per_gather = 4;
ALTER SYSTEM SET max_worker_processes = 8;

-- Query planning
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_io_concurrency = 200;

-- Connection pool
ALTER SYSTEM SET max_connections = 200;

-- Restart PostgreSQL to apply
SELECT pg_ctl(pg_config_bindir() || '/pg_ctl', 'restart');

-- Or via Docker
docker restart citus-coordinator citus-worker-1 citus-worker-2
```

### 4.3 Create Performance Indexes

```sql
-- HNSW indexes for vector search (RuVector)
CREATE INDEX idx_users_metadata ON distributed.users
USING ruvector_cosine (metadata) WITH (m=16, ef_construction=200);

-- B-tree indexes for equality + range queries
CREATE INDEX idx_events_user_timestamp ON distributed.events
(user_id, timestamp DESC);

CREATE INDEX idx_events_type ON distributed.events (event_type);

-- BRIN indexes for large sequential tables
CREATE INDEX idx_users_created_at ON distributed.users
USING BRIN (created_at) WITH (pages_per_range=128);

-- Verify indexes were created
SELECT indexname, tablename FROM pg_indexes
WHERE tablename IN ('users', 'events')
ORDER BY tablename, indexname;
```

### 4.4 Citus-Specific Optimization

```sql
-- Enable columnar compression for OLAP tables
ALTER TABLE distributed.events SET (columnar = true);

-- Enable shard placement optimization
SET citus.shard_placement_policy = 'round-robin';

-- Set connection cache size
ALTER SYSTEM SET citus.local_shard_join_threshold = '8MB';

-- Optimize coordinator query execution
ALTER SYSTEM SET citus.coordinator_aggregation_strategy = 'adaptive';

-- Set worker query parallelization
ALTER SYSTEM SET citus.max_adaptive_executor_pool_size = 16;
```

---

## PHASE 5: Benchmarking & Validation (Week 10-11)

### 5.1 Run Cluster Benchmark

```bash
# Comprehensive benchmark (distributed queries, joins, aggregations)
./scripts/performance/benchmark-cluster.sh

# Expected output: Throughput (ops/sec), latency (p50/p95/p99), distribution metrics

# Expected targets:
# - Read throughput: >10k ops/sec
# - Write throughput: >5k ops/sec
# - Latency (p50): <10ms
# - Shard skew: <20%
```

### 5.2 Vector Search Benchmark

```bash
# Benchmark RuVector performance
python3 scripts/performance/benchmark_vector_search.py --vectors 100000 --dimension 1536 --queries 1000

# Expected metrics:
# - Search latency: <5ms per query (HNSW index)
# - Throughput: >2000 queries/sec
# - Index size: <2GB for 100k vectors
```

### 5.3 Load Testing with Locust

```bash
# Start load test (100 concurrent users)
python3 scripts/performance/load_test_locust.py --users 100 --duration 300

# Monitor during load test
./scripts/performance/analyze-slow-queries.sh

# Verify no connection pool exhaustion
docker exec citus-coordinator psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT datname, count(*) as connections FROM pg_stat_activity GROUP BY datname;"
```

### 5.4 Query Performance Analysis

```bash
# Analyze slow queries
./scripts/performance/analyze-slow-queries.sh

# Inside psql - top slow queries
SELECT query, calls, total_time, mean_time
FROM pg_stat_statements
ORDER BY total_time DESC
LIMIT 20;

# Distributed query execution plan
EXPLAIN (ANALYZE, DIST)
SELECT user_id, COUNT(*)
FROM distributed.events
WHERE timestamp > NOW() - INTERVAL '7 days'
GROUP BY user_id;
```

### 5.5 Shard Rebalancing (if needed)

```bash
# Monitor shard imbalance
SELECT nodename, COUNT(*) as shards,
       pg_size_pretty(SUM(shard_size)) as size
FROM citus_shards
GROUP BY nodename;

# If >20% skew detected, rebalance
./scripts/citus/rebalance-shards.sh

# Monitor rebalancing progress
SELECT * FROM citus_get_rebalance_progress();
```

---

## PHASE 6: Production Readiness (Week 11-12)

### 6.1 Database Backups

```bash
# Full cluster backup (all shards + coordinator metadata)
./scripts/backup/backup-manager.sh

# Backup options:
# - Physical backups (pg_basebackup)
# - Logical backups (pg_dump distributed)
# - Incremental backups (WAL archiving)

# Verify backups exist
ls -lh /home/matt/projects/Distributed-Postgress-Cluster/backups/
```

### 6.2 Monitoring & Alerting Setup

```bash
# Start monitoring stack (Prometheus + Grafana)
./scripts/start_monitoring.sh

# Verify services
docker ps | grep -E 'prometheus|grafana'

# Access Grafana dashboards
# http://localhost:3000 (admin/admin)

# Metrics collected:
# - QPS, latency, error rates
# - Shard distribution balance
# - Cache hit ratio
# - Replication lag
```

### 6.3 Health Check Validation

```bash
# Run comprehensive health check
python3 scripts/db_health_check.py

# Expected results:
# - Docker container running: PASS
# - Database connectivity: PASS
# - Extensions available: PASS
# - Schemas created: PASS
# - Tables distributed: PASS
# - Worker nodes: 2 PASS
```

### 6.4 Disaster Recovery Drill

```bash
# Simulate worker node failure
docker stop citus-worker-1

# Verify cluster handles gracefully
SELECT * FROM citus_get_active_worker_nodes();

# Restart worker
docker start citus-worker-1

# Rebalance after recovery
./scripts/citus/rebalance-shards.sh
```

### 6.5 Documentation & Runbooks

```bash
# Generate cluster documentation
cat docs/CITUS_SETUP.md
cat docs/CITUS_IMPLEMENTATION_SUMMARY.md

# Create runbook for production operations
cp docs/OPERATIONS_GUIDE.md /tmp/ops-runbook.md

# Key runbooks:
# - Emergency failover
# - Shard rebalancing
# - Backup & restore procedures
# - Performance incident response
```

---

## Performance Checklist

```
PERFORMANCE TARGETS (Week 12 Validation)
─────────────────────────────────────────
[ ] Read throughput: >10,000 ops/sec
[ ] Write throughput: >5,000 ops/sec
[ ] Latency (p50): <10ms
[ ] Latency (p95): <50ms
[ ] Latency (p99): <200ms
[ ] Shard skew: <20%
[ ] Vector search: <5ms per query
[ ] Cache hit ratio: >80%
[ ] Replication lag: <1 second
[ ] Connection pool utilization: <80%

DISTRIBUTION TARGETS
─────────────────────
[ ] >95% queries routable to shards
[ ] >90% queries not requiring coordinator
[ ] Colocation efficiency: >85%
[ ] Reference table replication: OK
[ ] No hot shards (skew <20%)

RELIABILITY TARGETS
────────────────────
[ ] Uptime: >99.9%
[ ] Backup success rate: 100%
[ ] Recovery time (RTO): <5 minutes
[ ] Data loss (RPO): <1 minute
[ ] No connection pool exhaustion
[ ] No cascading failures

OPERATIONAL TARGETS
────────────────────
[ ] Monitoring coverage: >95%
[ ] Alert response: <5 minutes
[ ] Documentation complete
[ ] Runbooks validated
[ ] Team training complete
```

---

## Troubleshooting Commands

```bash
# Cluster health
docker compose -f docker/citus/docker-compose.yml ps
docker compose -f docker/citus/docker-compose.yml logs | tail -50

# Connection issues
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster -c "SELECT version();"

# Shard distribution
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT nodename, COUNT(*) FROM citus_shards GROUP BY nodename;"

# Slow queries
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster << EOF
SELECT query, calls, mean_time FROM pg_stat_statements
ORDER BY mean_time DESC LIMIT 10;
EOF

# Worker connectivity
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT * FROM citus_get_active_worker_nodes();"

# Reset performance stats
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster -c "SELECT pg_stat_statements_reset();"
```

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `scripts/citus/setup-citus.sh` | Cluster initialization |
| `scripts/citus/01-init-citus.sql` | Extension + schema creation |
| `scripts/citus/rebalance-shards.sh` | Shard distribution balancing |
| `scripts/performance/tune-postgresql.sh` | Auto-tuning script |
| `scripts/performance/benchmark-cluster.sh` | Performance benchmarks |
| `scripts/performance/benchmark_vector_search.py` | Vector search benchmarks |
| `scripts/performance/load_test_locust.py` | Load testing with Locust |
| `scripts/db_health_check.py` | Health monitoring |
| `docker/citus/docker-compose.yml` | Cluster orchestration |

---

## Timeline Summary

- **Week 7**: Citus cluster online, workers registered
- **Week 8**: Tables distributed, data loaded, shards verified
- **Week 9**: Performance tuning, indexes created, optimization applied
- **Week 10**: Benchmarks passing, vector search <5ms, throughput targets met
- **Week 11**: Monitoring active, backups tested, DR drill completed
- **Week 12**: Production readiness, documentation complete, team trained
