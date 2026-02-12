# Operations Guide - Distributed PostgreSQL Cluster

**Daily operations handbook for maintaining a production distributed PostgreSQL cluster**

---

## 📋 Table of Contents

1. [Cheat Sheet](#-cheat-sheet) - Quick command reference
2. [Daily Tasks](#-daily-tasks) - Routine operations
3. [Weekly Maintenance](#-weekly-maintenance) - Regular maintenance
4. [Monthly Operations](#-monthly-operations) - Periodic tasks
5. [Backup Procedures](#-backup-procedures) - Data protection
6. [Disaster Recovery](#-disaster-recovery) - Recovery procedures
7. [Troubleshooting](#-troubleshooting) - Problem resolution
8. [FAQ](#-frequently-asked-questions) - Common questions

---

## ⚡ Cheat Sheet

### Quick Commands

```bash
# Cluster Status
docker stack services postgres-mesh                    # All services
patronictl list                                        # HA cluster status
curl http://localhost:8008/health                      # HAProxy health

# Database Access
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster

# Monitoring
curl http://localhost:9090                             # Prometheus
curl http://localhost:3000                             # Grafana
curl http://localhost:8404/stats                       # HAProxy stats

# Failover Operations
patronictl switchover --master coordinator-1 --candidate coordinator-2
patronictl failover --force                            # Emergency failover

# Scaling Operations
SELECT citus_add_node('worker-5', 5432);              # Add worker
SELECT rebalance_table_shards('users');               # Rebalance data

# Backup & Restore
./scripts/backup/full-backup.sh                       # Full backup
./scripts/backup/restore.sh backup-20260212.tar.gz    # Restore

# Health Checks
SELECT * FROM citus_check_cluster_node_health();      # Node health
SELECT * FROM pg_stat_replication;                    # Replication status
SELECT * FROM citus_get_active_worker_nodes();        # Active workers
```

---

## 📅 Daily Tasks

### Morning Health Check (5 minutes)

```bash
#!/bin/bash
# Daily morning health check routine

echo "=== Daily Health Check - $(date) ==="

# 1. Check cluster services
echo "1. Checking Docker services..."
docker stack services postgres-mesh | grep -v "1/1\|3/3\|4/4"
if [ $? -eq 0 ]; then
    echo "⚠️  WARNING: Some services are not fully replicated"
else
    echo "✅ All services healthy"
fi

# 2. Check Patroni cluster
echo -e "\n2. Checking Patroni HA cluster..."
docker exec postgres-coordinator-1 patronictl list

# 3. Check replication lag
echo -e "\n3. Checking replication lag..."
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster -c "
    SELECT
        client_addr,
        state,
        pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes,
        CASE
            WHEN pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) > 10485760 THEN '⚠️  HIGH LAG'
            ELSE '✅ Normal'
        END as status
    FROM pg_stat_replication;
"

# 4. Check connection pool
echo -e "\n4. Checking connection pool..."
psql -h localhost -p 6432 -U dpg_cluster pgbouncer -c "SHOW POOLS" -c "SHOW DATABASES"

# 5. Check disk space
echo -e "\n5. Checking disk space..."
docker exec postgres-coordinator-1 df -h | grep -E 'Filesystem|/var/lib/postgresql'
docker exec postgres-worker-1 df -h | grep -E 'Filesystem|/var/lib/postgresql'

# 6. Check for slow queries
echo -e "\n6. Checking for slow queries (>1s)..."
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster -c "
    SELECT
        pid,
        now() - pg_stat_activity.query_start AS duration,
        query,
        state
    FROM pg_stat_activity
    WHERE (now() - pg_stat_activity.query_start) > interval '1 second'
    AND state = 'active'
    ORDER BY duration DESC;
"

# 7. Check for dead connections
echo -e "\n7. Checking for dead connections..."
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster -c "
    SELECT count(*) as dead_connections
    FROM pg_stat_activity
    WHERE state = 'idle in transaction'
    AND now() - state_change > interval '10 minutes';
"

echo -e "\n=== Health Check Complete ==="
```

**Save as:** `/home/matt/projects/Distributed-Postgress-Cluster/scripts/operations/daily-health-check.sh`

### Connection Monitoring (As Needed)

```sql
-- Check current connections by database
SELECT
    datname,
    count(*) as connections,
    max_conn,
    round(100.0 * count(*) / max_conn, 2) as pct_used
FROM pg_stat_activity
CROSS JOIN (SELECT setting::int as max_conn FROM pg_settings WHERE name = 'max_connections') s
GROUP BY datname, max_conn
ORDER BY connections DESC;

-- Check connections by user
SELECT
    usename,
    count(*) as connections,
    max(backend_start) as latest_connection
FROM pg_stat_activity
WHERE usename IS NOT NULL
GROUP BY usename
ORDER BY connections DESC;

-- Check idle connections
SELECT
    pid,
    usename,
    datname,
    state,
    now() - state_change AS idle_duration
FROM pg_stat_activity
WHERE state = 'idle'
ORDER BY idle_duration DESC
LIMIT 20;

-- Kill long-running idle connections (>30 minutes)
SELECT
    pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle'
AND now() - state_change > interval '30 minutes'
AND pid <> pg_backend_pid();
```

### Query Performance Monitoring

```sql
-- Top 10 slowest queries (requires pg_stat_statements)
SELECT
    query,
    calls,
    total_time / 1000 as total_seconds,
    mean_time / 1000 as mean_seconds,
    max_time / 1000 as max_seconds,
    stddev_time / 1000 as stddev_seconds
FROM pg_stat_statements
ORDER BY mean_time DESC
LIMIT 10;

-- Reset query statistics (monthly)
SELECT pg_stat_statements_reset();
```

---

## 🔧 Weekly Maintenance

### Sunday Maintenance Window (1-2 hours)

#### 1. Vacuum and Analyze (30 minutes)

```bash
#!/bin/bash
# Weekly vacuum and analyze

echo "=== Weekly Maintenance - $(date) ==="

# Full vacuum analyze on all distributed tables
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster <<EOF

-- Get all distributed tables
\x on

SELECT 'VACUUM ANALYZE ' || logicalrelid::text || ';' as command
FROM citus_tables
\gexec

-- Vacuum system tables
VACUUM ANALYZE pg_catalog.pg_class;
VACUUM ANALYZE pg_catalog.pg_statistic;
VACUUM ANALYZE pg_catalog.pg_attribute;

-- Check bloat
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size,
    n_dead_tup,
    n_live_tup,
    round(100 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 2) AS dead_pct
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 20;
EOF

echo "✅ Vacuum complete"
```

#### 2. Index Maintenance (20 minutes)

```sql
-- Check for unused indexes
SELECT
    schemaname,
    tablename,
    indexname,
    idx_scan,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
AND indexrelname NOT LIKE 'pg_toast%'
ORDER BY pg_relation_size(indexrelid) DESC;

-- Rebuild bloated indexes (if any identified)
REINDEX INDEX CONCURRENTLY index_name;

-- Check index bloat
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 20;
```

#### 3. Log Rotation and Cleanup (10 minutes)

```bash
# Rotate PostgreSQL logs
docker exec postgres-coordinator-1 logrotate /etc/logrotate.d/postgresql

# Clean old logs (keep 30 days)
find /var/log/postgresql -name "*.log" -mtime +30 -delete
find /var/log/haproxy -name "*.log" -mtime +30 -delete

# Check log sizes
du -sh /var/log/postgresql
du -sh /var/log/haproxy
```

#### 4. Backup Verification (30 minutes)

```bash
# Verify latest backup
latest_backup=$(ls -t backups/ | head -1)
echo "Verifying backup: $latest_backup"

# Test restore to temporary database
./scripts/backup/verify-backup.sh $latest_backup

# Check backup integrity
md5sum backups/$latest_backup > backups/$latest_backup.md5
md5sum -c backups/$latest_backup.md5
```

---

## 📆 Monthly Operations

### First Sunday of Month (2-3 hours)

#### 1. Security Updates (30 minutes)

```bash
# Update Docker images
docker pull ruvnet/ruvector-postgres:14
docker pull haproxy:2.9
docker pull edoburu/pgbouncer:1.21
docker pull prom/prometheus:latest
docker pull grafana/grafana:latest

# Rolling update (zero downtime)
docker service update --image ruvnet/ruvector-postgres:14 postgres-mesh_worker
docker service update --image haproxy:2.9 postgres-mesh_haproxy

# Monitor rollout
watch docker service ps postgres-mesh_worker
```

#### 2. Performance Review (1 hour)

```sql
-- Database size growth
SELECT
    datname,
    pg_size_pretty(pg_database_size(datname)) as size,
    pg_size_pretty(pg_database_size(datname) -
        lag(pg_database_size(datname)) OVER (PARTITION BY datname ORDER BY now())) as growth
FROM pg_database
WHERE datname = 'distributed_postgres_cluster';

-- Table size analysis
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) -
        pg_relation_size(schemaname||'.'||tablename)) AS index_size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 20;

-- Query performance trends
SELECT
    query,
    calls,
    total_time / calls as avg_time_ms,
    min_time,
    max_time,
    stddev_time
FROM pg_stat_statements
WHERE calls > 100
ORDER BY total_time DESC
LIMIT 20;
```

#### 3. Capacity Planning (30 minutes)

```bash
# Generate capacity report
./scripts/operations/capacity-report.sh

# Check growth trends
# - Database size
# - Connection count
# - Query volume
# - Disk usage

# Forecast capacity needs (next 3 months)
# - Estimated data growth
# - Connection scaling
# - Performance degradation points
```

#### 4. Disaster Recovery Test (30 minutes)

```bash
# Test full restore procedure
echo "=== DR Test - $(date) ==="

# 1. Create test database
psql -h localhost -p 6432 -U dpg_cluster -c "CREATE DATABASE dr_test"

# 2. Restore latest backup
./scripts/backup/restore.sh backups/latest.tar.gz dr_test

# 3. Verify data integrity
psql -h localhost -p 6432 -U dpg_cluster -d dr_test -c "
    SELECT count(*) FROM users;
    SELECT count(*) FROM events;
    SELECT count(*) FROM vectors;
"

# 4. Test vector search
psql -h localhost -p 6432 -U dpg_cluster -d dr_test -c "
    SELECT * FROM vectors ORDER BY embedding <=> ARRAY[0.1, 0.2, 0.3] LIMIT 5;
"

# 5. Cleanup
psql -h localhost -p 6432 -U dpg_cluster -c "DROP DATABASE dr_test"

echo "✅ DR test complete"
```

---

## 💾 Backup Procedures

### Automated Daily Backups

```bash
#!/bin/bash
# /scripts/backup/daily-backup.sh
# Run via cron: 0 2 * * * /path/to/daily-backup.sh

BACKUP_DIR="/backups/postgres"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="backup_${TIMESTAMP}.tar.gz"
RETENTION_DAYS=30

echo "=== Starting backup - $(date) ==="

# 1. Create backup directory
mkdir -p $BACKUP_DIR

# 2. Dump all databases
pg_dumpall -h localhost -p 6432 -U dpg_cluster | gzip > $BACKUP_DIR/$BACKUP_FILE

# 3. Verify backup
if [ -f "$BACKUP_DIR/$BACKUP_FILE" ]; then
    echo "✅ Backup created: $BACKUP_FILE"
    echo "   Size: $(du -h $BACKUP_DIR/$BACKUP_FILE | cut -f1)"
else
    echo "❌ Backup failed!"
    exit 1
fi

# 4. Backup Citus metadata
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster <<EOF | gzip > $BACKUP_DIR/citus_metadata_${TIMESTAMP}.sql.gz
    -- Export Citus metadata
    SELECT * FROM pg_dist_node;
    SELECT * FROM pg_dist_partition;
    SELECT * FROM pg_dist_shard;
    SELECT * FROM pg_dist_placement;
EOF

# 5. Upload to remote storage (S3, etc.)
# aws s3 cp $BACKUP_DIR/$BACKUP_FILE s3://your-bucket/postgres-backups/

# 6. Clean old backups
find $BACKUP_DIR -name "backup_*.tar.gz" -mtime +$RETENTION_DAYS -delete
echo "✅ Cleaned backups older than $RETENTION_DAYS days"

echo "=== Backup complete - $(date) ==="
```

### Manual Backup

```bash
# Full cluster backup
pg_dumpall -h localhost -p 6432 -U dpg_cluster > full_backup_$(date +%Y%m%d).sql

# Single database backup
pg_dump -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster \
    -F custom -f backup_$(date +%Y%m%d).dump

# Compressed backup
pg_dump -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster | gzip > backup.sql.gz

# Parallel backup (faster for large databases)
pg_dump -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster \
    -F directory -j 4 -f backup_dir/
```

### Restore Procedures

```bash
#!/bin/bash
# Restore from backup

BACKUP_FILE=$1
TARGET_DB=${2:-distributed_postgres_cluster}

if [ -z "$BACKUP_FILE" ]; then
    echo "Usage: $0 <backup_file> [target_database]"
    exit 1
fi

echo "=== Restoring from $BACKUP_FILE to $TARGET_DB ==="

# 1. Stop application traffic (optional)
echo "⚠️  WARNING: Stop application traffic before proceeding"
read -p "Continue? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Restore cancelled"
    exit 0
fi

# 2. Drop and recreate database
psql -h localhost -p 6432 -U dpg_cluster <<EOF
    DROP DATABASE IF EXISTS $TARGET_DB;
    CREATE DATABASE $TARGET_DB;
EOF

# 3. Restore data
if [[ $BACKUP_FILE == *.gz ]]; then
    gunzip -c $BACKUP_FILE | psql -h localhost -p 6432 -U dpg_cluster -d $TARGET_DB
else
    psql -h localhost -p 6432 -U dpg_cluster -d $TARGET_DB < $BACKUP_FILE
fi

# 4. Verify restore
psql -h localhost -p 6432 -U dpg_cluster -d $TARGET_DB <<EOF
    SELECT count(*) as table_count FROM information_schema.tables WHERE table_schema = 'public';
    SELECT pg_size_pretty(pg_database_size('$TARGET_DB')) as database_size;
EOF

# 5. Rebuild Citus metadata
psql -h localhost -p 6432 -U dpg_cluster -d $TARGET_DB -c "
    SELECT citus_add_node('worker-1', 5432);
    SELECT citus_add_node('worker-2', 5432);
    SELECT citus_add_node('worker-3', 5432);
    SELECT citus_add_node('worker-4', 5432);
"

echo "✅ Restore complete"
```

---

## 🚨 Disaster Recovery

### Scenario 1: Single Coordinator Failure

```bash
# Detection
docker ps | grep coordinator
patronictl list

# Patroni automatically promotes replica
# Verify new master
patronictl list

# Replace failed coordinator
docker service update --force postgres-mesh_coordinator

# Verify cluster health
patronictl list
curl http://localhost:8008/health
```

### Scenario 2: Worker Node Failure

```bash
# Detection
SELECT * FROM citus_get_active_worker_nodes();

# Remove failed worker
SELECT citus_remove_node('worker-3', 5432);

# Add replacement worker
SELECT citus_add_node('worker-5', 5432);

# Rebalance shards
SELECT rebalance_table_shards('users');
SELECT rebalance_table_shards('events');
SELECT rebalance_table_shards('vectors');

# Monitor rebalancing
SELECT * FROM citus_rebalance_status();
```

### Scenario 3: Complete Cluster Loss

```bash
# 1. Deploy new cluster
cd deployment/docker-swarm
docker stack deploy -c docker-compose.yml postgres-mesh

# 2. Wait for cluster ready
sleep 60

# 3. Restore from backup
./scripts/backup/restore.sh /backups/latest.tar.gz

# 4. Verify data
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster -c "
    SELECT count(*) FROM users;
    SELECT version();
    SELECT * FROM citus_version();
"

# 5. Restore Citus worker nodes
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster <<EOF
    SELECT citus_add_node('worker-1', 5432);
    SELECT citus_add_node('worker-2', 5432);
    SELECT citus_add_node('worker-3', 5432);
    SELECT citus_add_node('worker-4', 5432);
EOF

# 6. Resume application traffic
echo "✅ Cluster restored, ready for traffic"
```

### RTO/RPO Targets

| Scenario | RTO | RPO | Notes |
|----------|-----|-----|-------|
| Single coordinator failure | 10s | 0 | Automatic failover |
| Single worker failure | 5min | 0 | Manual intervention |
| Complete cluster loss | 2 hours | 24 hours | From daily backup |
| Data corruption | 4 hours | 24 hours | Restore + verification |

---

## 🔍 Troubleshooting

### High CPU Usage

```bash
# Identify expensive queries
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster -c "
    SELECT
        pid,
        now() - pg_stat_activity.query_start AS duration,
        query
    FROM pg_stat_activity
    WHERE state = 'active'
    ORDER BY duration DESC;
"

# Check system load
docker exec postgres-coordinator-1 top -bn1 | head -20

# Kill expensive queries
SELECT pg_terminate_backend(PID);
```

### Memory Pressure

```bash
# Check memory usage
docker stats postgres-coordinator-1

# Check shared buffers usage
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster -c "
    SELECT
        pg_size_pretty(pg_total_relation_size('pg_class')) AS catalog_size,
        count(*) AS buffer_count
    FROM pg_buffercache;
"

# Adjust shared_buffers (if needed)
# Edit postgresql.conf: shared_buffers = 4GB
docker service update --force postgres-mesh_coordinator
```

### Disk Space Issues

```bash
# Check disk usage
df -h | grep postgresql

# Find largest tables
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster -c "
    SELECT
        schemaname,
        tablename,
        pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
    FROM pg_tables
    ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
    LIMIT 10;
"

# Clean up old data
VACUUM FULL;  # Reclaim space
```

### Connection Pool Exhaustion

```bash
# Check pool status
psql -h localhost -p 6432 -U dpg_cluster pgbouncer -c "SHOW POOLS"

# Check waiting clients
psql -h localhost -p 6432 -U dpg_cluster pgbouncer -c "SHOW CLIENTS"

# Increase pool size (if needed)
# Edit pgbouncer.ini: max_client_conn = 200
docker service update --force postgres-mesh_pgbouncer
```

### Replication Lag

```bash
# Check lag
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster -c "
    SELECT
        client_addr,
        state,
        pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) / 1024 / 1024 AS lag_mb
    FROM pg_stat_replication;
"

# If lag > 100MB:
# 1. Check network connectivity
# 2. Check worker load
# 3. Consider adding more resources
```

---

## ❓ Frequently Asked Questions

### Q: How do I check if the cluster is healthy?

```bash
# Quick health check
curl http://localhost:8008/health

# Detailed check
patronictl list
docker stack services postgres-mesh
```

### Q: How do I add a new worker node?

```bash
# 1. Deploy new worker
docker service scale postgres-mesh_worker=5

# 2. Register with coordinator
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster -c "
    SELECT citus_add_node('worker-5', 5432);
"

# 3. Rebalance shards
SELECT rebalance_table_shards();
```

### Q: How do I perform a manual failover?

```bash
# Graceful switchover
patronictl switchover --master coordinator-1 --candidate coordinator-2

# Emergency failover
patronictl failover --force
```

### Q: How do I check query performance?

```sql
-- Enable query statistics (if not enabled)
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Top slow queries
SELECT
    query,
    calls,
    mean_time,
    max_time
FROM pg_stat_statements
ORDER BY mean_time DESC
LIMIT 10;
```

### Q: How do I scale the cluster?

See **[Scaling Playbook](operations/SCALING_PLAYBOOK.md)** for detailed procedures.

---

## 📞 Escalation Procedures

### Severity Levels

| Severity | Response Time | Examples |
|----------|---------------|----------|
| P0 (Critical) | 15 minutes | Complete outage, data loss |
| P1 (High) | 1 hour | Performance degradation, single node failure |
| P2 (Medium) | 4 hours | Non-critical errors, monitoring alerts |
| P3 (Low) | 1 business day | Feature requests, optimizations |

### On-Call Procedures

1. **Acknowledge alert** within 5 minutes
2. **Assess severity** and impact
3. **Follow runbook** for the alert type
4. **Escalate if needed** to senior engineer
5. **Document resolution** in incident tracker
6. **Post-mortem** for P0/P1 incidents

---

## 📚 Related Documentation

- **[Runbooks](RUNBOOKS.md)** - Incident response procedures
- **[Monitoring](MONITORING.md)** - Monitoring configuration
- **[Scaling Playbook](operations/SCALING_PLAYBOOK.md)** - Scaling procedures
- **[Failover Runbook](operations/FAILOVER_RUNBOOK.md)** - Failover handling

---

**Last Updated:** 2026-02-12

*For questions, see [Documentation Index](README.md)*
