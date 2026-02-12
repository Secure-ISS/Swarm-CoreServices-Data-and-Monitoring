# Migration Paths for PostgreSQL Distributed Cluster

## Overview

This document provides detailed migration paths for upgrading PostgreSQL, RuVector, and transitioning between cluster architectures.

## PostgreSQL Version Migrations

### PostgreSQL 16 → 17 → 18

#### 16 → 17 Migration

**Duration**: 30-120 minutes (depending on database size)

**Breaking Changes**:
- `pg_stat_statements` extension schema changes
- `pg_repack` extension requires update
- Some GUC parameter defaults changed

**Migration Steps**:

```bash
# 1. Pre-migration checks
psql -U postgres -c "SELECT version()"
psql -U postgres -c "SELECT * FROM pg_prepared_xacts"  # Must be empty
psql -U postgres -c "SELECT * FROM pg_extension WHERE extname IN ('pg_stat_statements', 'pg_repack')"

# 2. Backup
pg_dumpall -U postgres > backup_pg16_$(date +%Y%m%d).sql
tar -czf /backup/pg16_data.tar.gz /var/lib/postgresql/16/main/

# 3. Install PostgreSQL 17
sudo apt-get install postgresql-17 postgresql-server-dev-17

# 4. Stop old cluster
sudo systemctl stop postgresql@16-main

# 5. Run pg_upgrade
sudo -u postgres /usr/lib/postgresql/17/bin/pg_upgrade \
    --old-bindir=/usr/lib/postgresql/16/bin \
    --new-bindir=/usr/lib/postgresql/17/bin \
    --old-datadir=/var/lib/postgresql/16/main \
    --new-datadir=/var/lib/postgresql/17/main \
    --check

sudo -u postgres /usr/lib/postgresql/17/bin/pg_upgrade \
    --old-bindir=/usr/lib/postgresql/16/bin \
    --new-bindir=/usr/lib/postgresql/17/bin \
    --old-datadir=/var/lib/postgresql/16/main \
    --new-datadir=/var/lib/postgresql/17/main \
    --link

# 6. Start new cluster
sudo systemctl start postgresql@17-main

# 7. Update statistics
./analyze_new_cluster.sh
vacuumdb -U postgres --all --analyze-only -j$(nproc)

# 8. Update extensions
psql -U postgres -c "ALTER EXTENSION pg_stat_statements UPDATE"
psql -U postgres -c "ALTER EXTENSION pg_repack UPDATE"
```

**Post-Migration Validation**:

```sql
-- Check version
SELECT version();

-- Check extensions
SELECT extname, extversion FROM pg_extension ORDER BY extname;

-- Check replication
SELECT * FROM pg_stat_replication;

-- Performance test
EXPLAIN ANALYZE SELECT count(*) FROM large_table;
```

#### 17 → 18 Migration

**Duration**: 30-120 minutes (depending on database size)

**Breaking Changes**:
- Replication protocol changes (requires 18.0.1+)
- New parallel query defaults
- Changes to `pg_stat_*` views
- `pg_hba.conf` authentication method changes

**Migration Steps**:

```bash
# 1. Pre-migration checks
psql -U postgres -c "SELECT version()"
psql -U postgres -c "SELECT * FROM pg_prepared_xacts"
psql -U postgres -c "SELECT slot_name, plugin, active FROM pg_replication_slots"

# 2. Review breaking changes
psql -U postgres -c "SHOW max_parallel_workers"  # Default changed to 16
psql -U postgres -c "SHOW maintenance_work_mem"  # Calculation changed

# 3. Backup
pg_dumpall -U postgres > backup_pg17_$(date +%Y%m%d).sql

# 4. Install PostgreSQL 18
sudo apt-get install postgresql-18 postgresql-server-dev-18

# 5. Run upgrade script
sudo -u postgres ./scripts/upgrade/upgrade-postgresql.sh 17 18

# 6. Update configuration
cat >> /etc/postgresql/18/main/postgresql.conf <<EOF
# Adjusted for PostgreSQL 18
max_parallel_workers = 8  # Keep conservative initially
maintenance_work_mem = 256MB  # Keep previous value
EOF

# 7. Restart and validate
sudo systemctl restart postgresql@18-main
psql -U postgres -c "SELECT version()"
```

**Post-Migration Tasks**:

```sql
-- Update statistics
ANALYZE;

-- Check parallel query settings
SHOW max_parallel_workers;
SHOW max_parallel_workers_per_gather;

-- Test query performance
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM large_table WHERE condition;

-- Monitor replication
SELECT * FROM pg_stat_replication;
```

### Step Migration: 15 → 16 → 17 → 18

**Total Duration**: 2-5 hours

For PostgreSQL 15 clusters, step-wise migration is required:

```bash
# Phase 1: 15 → 16
./scripts/upgrade/upgrade-postgresql.sh 15 16
# Validate and test for 24 hours

# Phase 2: 16 → 17
./scripts/upgrade/upgrade-postgresql.sh 16 17
# Validate and test for 24 hours

# Phase 3: 17 → 18
./scripts/upgrade/upgrade-postgresql.sh 17 18
# Validate and test
```

**Alternative: Direct Migration with pg_dump**

For databases < 100GB, consider direct migration:

```bash
# 1. Create PostgreSQL 18 cluster
initdb -D /var/lib/postgresql/18/main

# 2. Export from PostgreSQL 15
pg_dumpall -U postgres -h old_server > full_dump.sql

# 3. Import to PostgreSQL 18
psql -U postgres -h new_server -f full_dump.sql

# 4. Validate
psql -U postgres -h new_server -c "SELECT count(*) FROM important_table"
```

## RuVector Extension Migrations

### RuVector 0.1.0 → 2.0.0

**Duration**: 10-30 minutes per database

**Breaking Changes**:

| Change | 0.1.0 | 2.0.0 |
|--------|-------|-------|
| Distance functions | `ruvector_*_distance()` | `cosine_distance()`, `l2_distance()` |
| HNSW parameters | `m`, `ef_construction` | Enhanced parameters |
| Index type | `ruvector_hnsw` | `ruvector` with ops class |

**Migration Steps**:

```bash
# 1. Check current version
psql -U postgres -d distributed_postgres_cluster -c "
    SELECT extversion FROM pg_extension WHERE extname = 'ruvector'
"

# 2. Backup vector data
pg_dump -U postgres -d distributed_postgres_cluster \
    --table=claude_flow.embeddings \
    --table=claude_flow.hyperbolic_embeddings \
    > ruvector_data_backup.sql

# 3. Run upgrade script
./scripts/upgrade/upgrade-ruvector.sh 0.1.0 2.0.0

# 4. Validate indexes
psql -U postgres -d distributed_postgres_cluster -c "
    SELECT schemaname, tablename, indexname, pg_size_pretty(pg_relation_size(indexname::regclass))
    FROM pg_indexes
    WHERE indexdef LIKE '%ruvector%'
"

# 5. Update queries in application
# Old syntax:
# SELECT id, ruvector_cosine_distance(embedding, query) AS dist
# New syntax:
# SELECT id, embedding <=> query AS dist
```

**Application Code Updates**:

```python
# Before (RuVector 0.1.0)
query = """
    SELECT id, ruvector_cosine_distance(embedding, %s::ruvector) AS distance
    FROM embeddings
    ORDER BY distance
    LIMIT 10
"""

# After (RuVector 2.0.0)
query = """
    SELECT id, embedding <=> %s::ruvector AS distance
    FROM embeddings
    ORDER BY distance
    LIMIT 10
"""
```

### Index Rebuilding

RuVector 2.0.0 indexes are rebuilt automatically, but you can optimize them:

```sql
-- Check index parameters
SELECT
    schemaname,
    tablename,
    indexname,
    pg_get_indexdef(indexname::regclass) AS definition
FROM pg_indexes
WHERE indexdef LIKE '%ruvector%';

-- Drop and recreate with optimized parameters
DROP INDEX IF EXISTS claude_flow.idx_embeddings_vector;

CREATE INDEX idx_embeddings_vector
ON claude_flow.embeddings
USING ruvector (embedding ruvector_cosine_ops)
WITH (m = 32, ef_construction = 200);

-- Analyze table
ANALYZE claude_flow.embeddings;
```

## Architecture Migrations

### Single-Node → Citus Cluster

**Duration**: 2-4 hours

**Prerequisites**:
- PostgreSQL 16+ installed on all nodes
- Citus extension installed
- Network connectivity between nodes

**Migration Steps**:

```bash
# 1. Install Citus on all nodes
sudo apt-get install postgresql-16-citus-12.0

# 2. Configure coordinator node
cat >> /etc/postgresql/16/main/postgresql.conf <<EOF
shared_preload_libraries = 'citus'
citus.node_conninfo = 'sslmode=prefer'
EOF

sudo systemctl restart postgresql@16-main

# 3. Create Citus extension
psql -U postgres -c "CREATE EXTENSION citus"

# 4. Add worker nodes
psql -U postgres -c "SELECT citus_add_node('worker1', 5432)"
psql -U postgres -c "SELECT citus_add_node('worker2', 5432)"

# 5. Distribute existing tables
psql -U postgres <<EOF
SELECT create_distributed_table('users', 'user_id');
SELECT create_distributed_table('orders', 'user_id');
SELECT create_distributed_table('products', 'product_id');
EOF

# 6. Validate distribution
psql -U postgres -c "SELECT * FROM citus_tables"
```

### Citus → Patroni HA Cluster

**Duration**: 4-8 hours

**Prerequisites**:
- 3+ nodes for HA cluster
- etcd cluster running (3 nodes minimum)
- Patroni installed on all nodes

**Migration Steps**:

```bash
# 1. Setup etcd cluster
# On each etcd node:
./scripts/setup/setup-etcd.sh --cluster-name pg-cluster

# 2. Install Patroni on all nodes
pip install patroni[etcd]

# 3. Configure Patroni on primary (current Citus coordinator)
cat > /etc/patroni.yml <<EOF
scope: postgres-cluster
namespace: /service/
name: node1

restapi:
  listen: 0.0.0.0:8008
  connect_address: node1:8008

etcd:
  hosts: etcd1:2379,etcd2:2379,etcd3:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576

postgresql:
  listen: 0.0.0.0:5432
  connect_address: node1:5432
  data_dir: /var/lib/postgresql/16/main
  parameters:
    shared_preload_libraries: 'citus'
    max_connections: 100
    shared_buffers: 8GB
EOF

# 4. Initialize Patroni on primary
patronictl -c /etc/patroni.yml reinit postgres-cluster node1

# 5. Add replicas
# On each replica node:
cat > /etc/patroni.yml <<EOF
scope: postgres-cluster
namespace: /service/
name: node2  # node3, node4, etc.

restapi:
  listen: 0.0.0.0:8008
  connect_address: node2:8008

etcd:
  hosts: etcd1:2379,etcd2:2379,etcd3:2379

postgresql:
  listen: 0.0.0.0:5432
  connect_address: node2:5432
  data_dir: /var/lib/postgresql/16/main
EOF

patronictl -c /etc/patroni.yml add postgres-cluster node2

# 6. Validate cluster
patronictl -c /etc/patroni.yml list
```

### Single-Node → Patroni HA (Direct)

**Duration**: 3-6 hours

**Migration Steps**:

```bash
# 1. Backup current database
pg_basebackup -U postgres -D /backup/pg_backup -Fp -Xs -P

# 2. Setup etcd cluster
./scripts/setup/setup-etcd.sh --cluster-name pg-cluster

# 3. Convert primary to Patroni
# Stop PostgreSQL
sudo systemctl stop postgresql@16-main

# Configure Patroni
cat > /etc/patroni.yml <<EOF
# ... (Patroni configuration)
EOF

# Start Patroni
patroni /etc/patroni.yml

# 4. Add replicas
# On replica nodes:
patroni /etc/patroni.yml  # Patroni will handle replication setup

# 5. Validate
patronictl -c /etc/patroni.yml list
psql -h node1 -U postgres -c "SELECT * FROM pg_stat_replication"
```

## Breaking Changes Checklist

### PostgreSQL 17 → 18

- [ ] Review `pg_hba.conf` for authentication method changes
- [ ] Update `max_parallel_workers` configuration
- [ ] Test `pg_stat_*` view queries
- [ ] Verify replication protocol compatibility (use 18.0.1+)
- [ ] Check query plans for parallel query changes
- [ ] Update monitoring queries for new view columns
- [ ] Review application connection pooling settings

### RuVector 0.1 → 2.0

- [ ] Update distance function calls in application code
- [ ] Review HNSW index parameters
- [ ] Test vector search query performance
- [ ] Update vector dimension validation logic
- [ ] Review index size and adjust parameters
- [ ] Update monitoring dashboards for new metrics
- [ ] Test bulk insert performance

### Patroni 3.1 → 3.2

- [ ] Review DCS configuration changes
- [ ] Update Patroni configuration files
- [ ] Test failover and switchover procedures
- [ ] Verify etcd connection settings
- [ ] Check REST API authentication changes
- [ ] Update monitoring scripts
- [ ] Test backup and restore procedures

### Citus 11 → 12

- [ ] Review distributed table design
- [ ] Test shard rebalancing
- [ ] Update coordinator connection settings
- [ ] Verify worker node connectivity
- [ ] Test distributed queries
- [ ] Update application connection strings
- [ ] Review partitioning strategy

## Data Validation After Migration

### Comprehensive Validation Script

```sql
-- 1. Row count validation
WITH pre_migration AS (
    SELECT 'users' AS table_name, 1000000 AS expected_count
    UNION ALL
    SELECT 'orders', 5000000
    UNION ALL
    SELECT 'products', 50000
)
SELECT
    p.table_name,
    p.expected_count,
    (SELECT count(*) FROM users) AS actual_count,  -- Adjust per table
    CASE
        WHEN p.expected_count = (SELECT count(*) FROM users) THEN 'PASS'
        ELSE 'FAIL'
    END AS validation
FROM pre_migration p;

-- 2. Index validation
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexname::regclass)) AS size
FROM pg_indexes
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_relation_size(indexname::regclass) DESC;

-- 3. Extension validation
SELECT extname, extversion FROM pg_extension ORDER BY extname;

-- 4. Replication validation
SELECT
    client_addr,
    state,
    sync_state,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;

-- 5. Performance validation
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM large_table WHERE indexed_column = 'test' LIMIT 100;
```

## Rollback Procedures

### PostgreSQL Version Rollback

```bash
# Quick rollback (< 30 minutes after upgrade)
sudo systemctl stop postgresql@18-main
cd /var/lib/postgresql/backups/upgrade_17_to_18_*/
./rollback.sh
sudo systemctl start postgresql@17-main

# Full rollback (> 30 minutes after upgrade)
sudo systemctl stop postgresql@18-main
rm -rf /var/lib/postgresql/18/main
tar -xzf /backup/pg17_data.tar.gz -C /
sudo systemctl start postgresql@17-main
```

### RuVector Rollback

```bash
# Rollback to 0.1.0
cd /var/lib/postgresql/backups/ruvector_upgrade_*/
./rollback.sh
```

### Architecture Rollback

**Citus → Single-Node**:

```bash
# 1. Stop Citus workers
ssh worker1 "sudo systemctl stop postgresql@16-main"
ssh worker2 "sudo systemctl stop postgresql@16-main"

# 2. Reconfigure coordinator as standalone
sed -i "s/shared_preload_libraries = 'citus'/# shared_preload_libraries = 'citus'/" \
    /etc/postgresql/16/main/postgresql.conf

sudo systemctl restart postgresql@16-main

# 3. Drop Citus extension
psql -U postgres -c "DROP EXTENSION IF EXISTS citus CASCADE"
```

## Performance Comparison

### Before and After Migration

Use these benchmarks to compare performance:

```bash
# 1. pgbench (OLTP workload)
pgbench -i -s 100 postgres  # Initialize
pgbench -c 10 -j 4 -T 60 postgres  # Run for 60 seconds

# 2. Vector search (if using RuVector)
psql -U postgres -c "
    EXPLAIN (ANALYZE, BUFFERS)
    SELECT id, embedding <=> '[0.1,0.2,0.3]'::ruvector AS distance
    FROM embeddings
    ORDER BY distance
    LIMIT 10
"

# 3. Replication lag
psql -U postgres -c "
    SELECT
        client_addr,
        pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes,
        replay_lag
    FROM pg_stat_replication
"
```

## Support Resources

- PostgreSQL Upgrade Documentation: https://www.postgresql.org/docs/current/upgrading.html
- Patroni Documentation: https://patroni.readthedocs.io/
- Citus Upgrade Guide: https://docs.citusdata.com/en/stable/admin_guide/upgrading_citus.html
- Project Issues: `/docs/TROUBLESHOOTING.md`
