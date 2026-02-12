# Migration Guide: Single-Node to Citus Distributed Cluster

## Overview

This guide walks through migrating an existing single-node PostgreSQL database to a Citus distributed cluster with minimal downtime.

## Prerequisites

- Existing PostgreSQL database (single-node)
- Docker and Docker Compose installed
- Sufficient disk space for backup (2x current database size)
- Network connectivity between source and target

## Migration Strategies

### Strategy 1: Offline Migration (Full Downtime)

**Best for:**
- Small databases (<100GB)
- Can afford 1-4 hours downtime
- Simple data structure

**Steps:**
1. Stop application
2. Backup source database
3. Start Citus cluster
4. Restore to coordinator
5. Distribute tables
6. Test and verify
7. Start application

**Downtime:** 1-4 hours depending on database size

### Strategy 2: Online Migration (Minimal Downtime)

**Best for:**
- Large databases (>100GB)
- Cannot afford extended downtime
- Complex data structure

**Steps:**
1. Start Citus cluster alongside source
2. Create distributed tables (empty)
3. Copy data table-by-table
4. Set up logical replication
5. Switch application to Citus
6. Decommission source

**Downtime:** 5-15 minutes for cutover

### Strategy 3: Hybrid Migration (Per-Table)

**Best for:**
- Very large databases (>1TB)
- Gradual migration needed
- Different tables have different requirements

**Steps:**
1. Start Citus cluster
2. Migrate tables one-by-one
3. Update application to use both databases
4. Gradually move all tables
5. Decommission source

**Downtime:** None (requires application changes)

## Step-by-Step: Offline Migration

### Step 1: Preparation

```bash
# Set environment variables
export SOURCE_HOST=localhost
export SOURCE_PORT=5432
export SOURCE_USER=dpg_cluster
export SOURCE_DB=distributed_postgres_cluster
export POSTGRES_PASSWORD=your_password

# Run preparation script
cd /home/matt/projects/Distributed-Postgress-Cluster
./scripts/citus/migrate-to-citus.sh all
```

This creates:
- `backups/migration-TIMESTAMP/pre-migration-backup.sql` - Full database backup
- `backups/migration-TIMESTAMP/table-analysis.txt` - Table size analysis
- `backups/migration-TIMESTAMP/migration-script.sql` - SQL template
- `backups/migration-TIMESTAMP/rollback.sh` - Emergency rollback

### Step 2: Analyze Tables

```bash
# Review table analysis
cat backups/migration-*/table-analysis.txt
```

Decision matrix:
- **Large tables (>1GB)**: Hash distribution by primary/foreign key
- **Medium tables (100MB-1GB)**: Hash distribution or reference
- **Small tables (<100MB)**: Reference tables (replicated)
- **Related tables**: Co-locate by common foreign key

Example analysis output:
```
users              5.2 GB   10M rows   → Hash by user_id
orders             3.8 GB   8M rows    → Hash by user_id (co-locate)
products           150 MB   50K rows   → Reference table
order_items        2.1 GB   15M rows   → Hash by user_id (co-locate)
categories         5 MB     100 rows   → Reference table
```

### Step 3: Customize Migration SQL

Edit `backups/migration-*/migration-script.sql`:

```sql
-- Large tables with hash distribution
SELECT create_distributed_table('users', 'user_id', shard_count => 32);
SELECT create_distributed_table('orders', 'user_id', colocate_with => 'users');
SELECT create_distributed_table('order_items', 'user_id', colocate_with => 'users');

-- Small reference tables
SELECT create_reference_table('products');
SELECT create_reference_table('categories');

-- Vector embeddings (co-located with users)
SELECT create_distributed_table('user_embeddings', 'user_id', colocate_with => 'users');
CREATE INDEX idx_embeddings_hnsw ON user_embeddings
USING hnsw (embedding ruvector_cosine_ops) WITH (m = 16);
```

### Step 4: Stop Application

```bash
# Stop your application to prevent writes
systemctl stop your-app
# or
docker-compose down
```

### Step 5: Start Citus Cluster

```bash
# Start Citus cluster
docker compose -f docker/citus/docker-compose.yml up -d

# Wait for all nodes to be healthy (may take 30-60 seconds)
docker compose -f docker/citus/docker-compose.yml ps

# Initialize Citus (creates extensions, registers workers)
./scripts/citus/setup-citus.sh
```

### Step 6: Create Schema and Distribute Tables

```bash
# Connect to coordinator
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster

# Create schema structure (without data)
\i backups/migration-*/migration-script.sql

# Verify distribution
SELECT * FROM citus_tables;
```

### Step 7: Load Data

Option A: Direct restore (faster for small databases):
```bash
# Restore full backup
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster \
  < backups/migration-*/pre-migration-backup.sql
```

Option B: Table-by-table (better for large databases):
```bash
# Export from source
pg_dump -h $SOURCE_HOST -U $SOURCE_USER -d $SOURCE_DB -t users --data-only \
  | psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster

# Repeat for each table
```

### Step 8: Verify Data

```sql
-- Check row counts match source
SELECT
    schemaname,
    tablename,
    n_live_tup as row_count
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY n_live_tup DESC;

-- Verify shard distribution
SELECT
    table_name,
    COUNT(*) as shard_count,
    pg_size_pretty(SUM(shard_size)) as total_size
FROM citus_shards
GROUP BY table_name;

-- Test queries
SELECT COUNT(*) FROM users;
SELECT COUNT(*) FROM orders WHERE user_id = 123;
```

### Step 9: Update Application

Update connection string:
```
# Old (single-node)
DATABASE_URL=postgresql://user:pass@localhost:5432/db

# New (Citus coordinator)
DATABASE_URL=postgresql://user:pass@localhost:5432/db
```

Application code changes:
```python
# Always include distribution column in queries
# BAD: Full table scan across all shards
User.objects.filter(email='test@example.com')

# GOOD: Prunes to single shard
User.objects.filter(user_id=123, email='test@example.com')

# For queries without distribution column, use EXISTS
# Instead of: SELECT * FROM users WHERE email = ?
# Use: SELECT * FROM users WHERE user_id IN (
#        SELECT user_id FROM users WHERE email = ?
#      )
```

### Step 10: Start Application

```bash
# Update environment variables
export DATABASE_HOST=localhost
export DATABASE_PORT=5432

# Start application
systemctl start your-app
# or
docker-compose up -d
```

### Step 11: Monitor

```bash
# Real-time monitoring
./scripts/citus/monitor-citus.sh watch

# Check for issues
./scripts/citus/monitor-citus.sh alerts

# Export metrics
./scripts/citus/monitor-citus.sh export
```

## Step-by-Step: Online Migration

### Step 1-5: Same as Offline

Follow steps 1-5 from offline migration.

### Step 6: Set Up Logical Replication

On source database:
```sql
-- Enable logical replication
ALTER SYSTEM SET wal_level = logical;
ALTER SYSTEM SET max_replication_slots = 10;
ALTER SYSTEM SET max_wal_senders = 10;

-- Restart PostgreSQL
-- systemctl restart postgresql

-- Create publication
CREATE PUBLICATION citus_migration FOR ALL TABLES;
```

On Citus coordinator:
```sql
-- Create subscription
CREATE SUBSCRIPTION citus_migration_sub
CONNECTION 'host=source_host port=5432 dbname=db user=user password=pass'
PUBLICATION citus_migration;

-- Monitor replication
SELECT * FROM pg_stat_subscription;
```

### Step 7: Wait for Sync

```sql
-- Check replication lag
SELECT
    application_name,
    state,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as lag_bytes
FROM pg_stat_replication;

-- Should be <1KB for cutover
```

### Step 8: Cutover

```bash
# 1. Enable read-only mode on source
# 2. Wait for replication to catch up (lag = 0)
# 3. Update application connection string
# 4. Restart application
# 5. Verify queries work on Citus
# 6. Drop replication
```

Total downtime: 5-15 minutes

## Troubleshooting

### Issue: "relation does not exist"

**Cause:** Table not distributed yet
**Solution:**
```sql
-- Check distributed tables
SELECT * FROM citus_tables;

-- Distribute missing table
SELECT create_distributed_table('table_name', 'distribution_column');
```

### Issue: "could not connect to worker node"

**Cause:** Worker not registered or network issue
**Solution:**
```bash
# Check worker status
docker ps
docker logs citus-worker-1

# Re-register worker
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT citus_add_node('citus-worker-1', 5432);"
```

### Issue: "distribution column must be in all queries"

**Cause:** Query missing distribution column
**Solution:**
```sql
-- Add distribution column to WHERE clause
-- BAD
SELECT * FROM users WHERE email = 'test@example.com';

-- GOOD
SELECT * FROM users WHERE user_id = 123 AND email = 'test@example.com';

-- For queries without distribution column, use subquery
SELECT * FROM users WHERE user_id IN (
    SELECT user_id FROM users WHERE email = 'test@example.com'
);
```

### Issue: Slow queries after migration

**Cause:** Missing indexes on shards or poor distribution
**Solution:**
```sql
-- Recreate indexes
CREATE INDEX CONCURRENTLY idx_name ON table_name (column);

-- Check query plan
EXPLAIN (ANALYZE, DIST) SELECT ...;

-- Rebalance shards if uneven
SELECT rebalance_table_shards('table_name');
```

### Issue: Uneven shard distribution

**Cause:** Data skew or insufficient shards
**Solution:**
```bash
# Check distribution
./scripts/citus/rebalance-shards.sh status

# Rebalance
./scripts/citus/rebalance-shards.sh rebalance

# If severe skew, recreate with more shards
# (requires data migration)
```

## Rollback Procedure

If migration fails, rollback to source:

```bash
# 1. Stop application
systemctl stop your-app

# 2. Restore source database
cd backups/migration-*
./rollback.sh

# 3. Update application connection to source
export DATABASE_HOST=source_host

# 4. Start application
systemctl start your-app

# 5. Stop Citus cluster
docker compose -f docker/citus/docker-compose.yml down
```

## Post-Migration Checklist

- [ ] All tables migrated and distributed
- [ ] Row counts match source
- [ ] Indexes recreated
- [ ] Foreign keys validated
- [ ] Application queries tested
- [ ] Performance benchmarked
- [ ] Monitoring enabled
- [ ] Backup strategy updated
- [ ] Documentation updated
- [ ] Team trained on Citus operations

## Performance Optimization

### After Migration

1. **Analyze tables**
   ```sql
   ANALYZE;
   ```

2. **Vacuum tables**
   ```sql
   VACUUM ANALYZE;
   ```

3. **Update statistics**
   ```sql
   ALTER TABLE table_name SET STATISTICS 1000;
   ANALYZE table_name;
   ```

4. **Monitor slow queries**
   ```sql
   SELECT query, mean_exec_time
   FROM pg_stat_statements
   ORDER BY mean_exec_time DESC
   LIMIT 10;
   ```

5. **Rebalance shards**
   ```bash
   ./scripts/citus/rebalance-shards.sh rebalance
   ```

## Best Practices

1. **Test migration on staging first**
2. **Keep backups for at least 7 days**
3. **Monitor closely for first 24 hours**
4. **Update queries to include distribution column**
5. **Set up automated backup strategy**
6. **Document distribution decisions**
7. **Train team on Citus operations**

## Resources

- [Citus Migration Documentation](https://docs.citusdata.com/en/stable/admin_guide/cluster_management.html)
- [PostgreSQL Logical Replication](https://www.postgresql.org/docs/current/logical-replication.html)
- [RuVector Integration](https://github.com/ruvnet/ruvector)

## Support

For migration assistance:
- Open an issue on GitHub
- Contact support team
- Review logs: `docker compose logs citus-coordinator`
