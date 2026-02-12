# Patroni Operations Guide

## Table of Contents

1. [Overview](#overview)
2. [Day-to-Day Operations](#day-to-day-operations)
3. [Cluster Monitoring](#cluster-monitoring)
4. [Health Check Procedures](#health-check-procedures)
5. [Common Troubleshooting](#common-troubleshooting)
6. [Maintenance Windows](#maintenance-windows)
7. [Backup and Recovery](#backup-and-recovery)
8. [Performance Tuning](#performance-tuning)

---

## Overview

### Architecture Components

```
┌────────────────────────────────────────────────────────┐
│                  Patroni HA Cluster                     │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │ Coordinator  │  │ Coordinator  │  │ Coordinator  │ │
│  │      1       │  │      2       │  │      3       │ │
│  │  (Leader)    │  │  (Replica)   │  │  (Replica)   │ │
│  │              │  │              │  │              │ │
│  │  Patroni     │  │  Patroni     │  │  Patroni     │ │
│  │  PostgreSQL  │  │  PostgreSQL  │  │  PostgreSQL  │ │
│  │  Citus       │  │  Citus       │  │  Citus       │ │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘ │
│         │                 │                 │         │
│         └─────────────────┼─────────────────┘         │
│                           │                           │
└───────────────────────────┼───────────────────────────┘
                            │
                ┌───────────┴───────────┐
                │  etcd Cluster (DCS)   │
                │  - Leader election    │
                │  - Configuration      │
                │  - Health tracking    │
                └───────────────────────┘
```

### Key Concepts

- **DCS (Distributed Configuration Store)**: etcd cluster that stores cluster state
- **Leader**: The primary PostgreSQL instance accepting writes
- **Replica**: Standby instances streaming from the leader
- **Synchronous Replication**: Coordinator nodes use sync replication for consistency
- **Asynchronous Replication**: Worker nodes use async for performance
- **Automatic Failover**: Patroni detects leader failure and promotes replica

---

## Day-to-Day Operations

### Starting Your Shift

```bash
# 1. Check overall cluster health
./scripts/patroni/monitor-cluster.sh

# 2. Verify all nodes are running
patronictl -c /etc/patroni/patroni.yml list

# 3. Check replication lag
PGPASSWORD=admin psql -h pg-coordinator -U admin -d distributed_postgres_cluster \
  -c "SELECT * FROM pg_stat_replication;"

# 4. Review recent alerts
grep -i "error\|warning\|failover" /var/log/patroni/patroni.log | tail -50

# 5. Check etcd cluster health
etcdctl --endpoints=etcd-1:2379,etcd-2:2379,etcd-3:2379 endpoint health
```

### Common Daily Tasks

#### Check Cluster Status

```bash
# Quick status check
patronictl -c /etc/patroni/patroni.yml list

# Expected output:
# + Cluster: postgres-cluster-coordinators (7303434343434343434) -----+----+-----------+
# | Member        | Host          | Role    | State     | TL | Lag in MB |
# +---------------+---------------+---------+-----------+----+-----------+
# | coordinator-1 | 10.0.1.11     | Leader  | running   |  3 |           |
# | coordinator-2 | 10.0.1.12     | Replica | streaming |  3 |         0 |
# | coordinator-3 | 10.0.1.13     | Replica | streaming |  3 |         0 |
# +---------------+---------------+---------+-----------+----+-----------+
```

#### Monitor Replication Lag

```bash
# Check replication lag (coordinator cluster)
PGPASSWORD=admin psql -h pg-coordinator -U admin -d postgres << 'EOF'
SELECT
    application_name,
    client_addr,
    state,
    sync_state,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes,
    EXTRACT(EPOCH FROM (now() - replay_timestamp))::int AS lag_seconds
FROM pg_stat_replication
ORDER BY lag_bytes DESC;
EOF

# Alert thresholds:
# Warning: lag_bytes > 10MB or lag_seconds > 10s
# Critical: lag_bytes > 100MB or lag_seconds > 60s
```

#### View Active Connections

```bash
# Check connection counts by database and user
PGPASSWORD=admin psql -h pg-coordinator -U admin -d postgres << 'EOF'
SELECT
    datname,
    usename,
    count(*) as connections,
    sum(CASE WHEN state = 'active' THEN 1 ELSE 0 END) as active,
    sum(CASE WHEN state = 'idle' THEN 1 ELSE 0 END) as idle
FROM pg_stat_activity
WHERE datname IS NOT NULL
GROUP BY datname, usename
ORDER BY connections DESC;
EOF
```

#### Check Long-Running Queries

```bash
# Queries running longer than 5 minutes
PGPASSWORD=admin psql -h pg-coordinator -U admin -d distributed_postgres_cluster << 'EOF'
SELECT
    pid,
    now() - query_start AS duration,
    usename,
    datname,
    state,
    wait_event_type,
    wait_event,
    query
FROM pg_stat_activity
WHERE state != 'idle'
  AND query_start < now() - INTERVAL '5 minutes'
ORDER BY duration DESC;
EOF
```

### Log Locations

```bash
# Patroni logs
/var/log/patroni/patroni.log                    # Main Patroni agent log
/var/log/patroni/patroni-callback.log           # Callback script logs

# PostgreSQL logs
/var/log/postgresql/postgresql-*.log             # PostgreSQL server logs

# etcd logs
/var/log/etcd/etcd.log                          # etcd cluster logs

# HAProxy logs
/var/log/haproxy.log                            # Load balancer logs

# Docker logs (if using containers)
docker service logs postgres-coordinator        # Coordinator service logs
docker service logs postgres-worker-1           # Worker shard logs
```

---

## Cluster Monitoring

### Real-Time Monitoring Dashboard

Use the monitoring script for a live view:

```bash
# Start real-time cluster monitor (refreshes every 5 seconds)
./scripts/patroni/monitor-cluster.sh --watch

# Output example:
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  PATRONI CLUSTER MONITOR - Coordinator Cluster
#  Last Updated: 2026-02-12 10:30:15 PST
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# CLUSTER TOPOLOGY (postgres-cluster-coordinators)
# ┌─────────────────┬──────────────┬─────────┬──────────┬────────┬──────────┐
# │ Member          │ Host         │ Role    │ State    │ TL     │ Lag (MB) │
# ├─────────────────┼──────────────┼─────────┼──────────┼────────┼──────────┤
# │ coordinator-1   │ 10.0.1.11    │ Leader  │ running  │ 3      │ -        │
# │ coordinator-2   │ 10.0.1.12    │ Replica │ streaming│ 3      │ 0        │
# │ coordinator-3   │ 10.0.1.13    │ Replica │ streaming│ 3      │ 0        │
# └─────────────────┴──────────────┴─────────┴──────────┴────────┴──────────┘
```

### Patroni REST API Monitoring

Each Patroni node exposes a REST API on port 8008:

```bash
# Check leader endpoint
curl -s http://coordinator-1:8008/leader | jq .

# Health check (returns 200 if healthy)
curl -I http://coordinator-1:8008/health

# Replica check (returns 200 if replica)
curl -I http://coordinator-2:8008/replica

# Cluster topology
curl -s http://coordinator-1:8008/cluster | jq .

# Configuration
curl -s http://coordinator-1:8008/config | jq .
```

### Key Metrics to Watch

#### Cluster Health Metrics

| Metric | Command | Threshold | Action |
|--------|---------|-----------|--------|
| **Leader availability** | `patronictl list` | Leader must exist | Manual failover if no leader |
| **Replication lag** | `pg_stat_replication.replay_lag` | < 10MB | Investigate slow replica |
| **Member state** | `patronictl list` | All "running" or "streaming" | Check failed member |
| **Timeline consistency** | `patronictl list` | All same TL | Indicates failover occurred |

#### PostgreSQL Metrics

```sql
-- Connection pool utilization
SELECT
    count(*) * 100.0 / current_setting('max_connections')::int as pct_used
FROM pg_stat_activity;

-- Cache hit ratio (should be > 95%)
SELECT
    sum(heap_blks_hit) / NULLIF(sum(heap_blks_hit + heap_blks_read), 0) * 100 AS cache_hit_ratio
FROM pg_statio_user_tables;

-- Lock monitoring
SELECT
    count(*) as blocked_queries
FROM pg_stat_activity
WHERE wait_event_type = 'Lock';

-- Checkpoint frequency (should be consistent)
SELECT
    checkpoints_timed,
    checkpoints_req,
    checkpoint_write_time,
    checkpoint_sync_time
FROM pg_stat_bgwriter;
```

### Alerting Thresholds

#### Critical Alerts

- No leader for > 30 seconds
- Replication lag > 100MB or 60 seconds
- etcd cluster has < 2 healthy members
- PostgreSQL process down
- Disk space < 10% free

#### Warning Alerts

- Replication lag > 10MB or 10 seconds
- Connection count > 80% of max_connections
- Query duration > 10 minutes
- Cache hit ratio < 90%
- Checkpoint rate > 1 per minute

---

## Health Check Procedures

### Manual Health Check Workflow

```bash
#!/bin/bash
# Complete health check procedure

echo "=== PATRONI HEALTH CHECK ==="
echo

# 1. Check Patroni cluster status
echo "1. Patroni Cluster Status:"
patronictl -c /etc/patroni/patroni.yml list
echo

# 2. Check etcd cluster health
echo "2. etcd Cluster Health:"
etcdctl --endpoints=etcd-1:2379,etcd-2:2379,etcd-3:2379 endpoint health
echo

# 3. Check PostgreSQL replication
echo "3. PostgreSQL Replication:"
PGPASSWORD=admin psql -h pg-coordinator -U admin -d postgres \
  -c "SELECT application_name, state, sync_state, replay_lag FROM pg_stat_replication;"
echo

# 4. Check for blocking queries
echo "4. Blocking Queries:"
PGPASSWORD=admin psql -h pg-coordinator -U admin -d postgres \
  -c "SELECT count(*) as blocked FROM pg_stat_activity WHERE wait_event_type = 'Lock';"
echo

# 5. Check disk space
echo "5. Disk Space:"
df -h /var/lib/postgresql/data
echo

# 6. Check log errors (last 10 minutes)
echo "6. Recent Errors:"
journalctl -u patroni -p err --since "10 minutes ago" | tail -20
echo

echo "=== HEALTH CHECK COMPLETE ==="
```

### Automated Health Checks

Set up cron job for periodic health checks:

```bash
# Add to crontab
*/5 * * * * /home/admin/scripts/patroni/monitor-cluster.sh --health-check > /var/log/patroni/health-$(date +\%Y\%m\%d).log 2>&1
```

### Health Check Endpoints

```bash
# HAProxy stats (check backend health)
curl http://haproxy:8404/stats
# Look for: Backend status, Health checks, Response times

# Patroni health endpoints
# Primary: Returns 200 if this node is leader
curl http://coordinator-1:8008/leader

# Replica: Returns 200 if this node is replica
curl http://coordinator-2:8008/replica

# Read-write: Returns 200 if leader or sync replica
curl http://coordinator-1:8008/read-write

# Read-only: Returns 200 if replica
curl http://coordinator-2:8008/read-only
```

---

## Common Troubleshooting

### Problem: Cluster Has No Leader

**Symptoms**:
- `patronictl list` shows no leader
- Applications cannot write to database
- HAProxy routing fails

**Diagnosis**:
```bash
# Check patroni status
patronictl -c /etc/patroni/patroni.yml list

# Check etcd connectivity
etcdctl --endpoints=etcd-1:2379,etcd-2:2379,etcd-3:2379 endpoint health

# Check patroni logs
journalctl -u patroni -n 100
```

**Common Causes**:
1. **etcd cluster down or unreachable** - Patroni cannot perform leader election
2. **Network partition** - Nodes cannot reach etcd or each other
3. **All nodes failed simultaneously** - No healthy candidate for leader
4. **DCS key corruption** - Patroni state in etcd is invalid

**Resolution**:
```bash
# 1. Check if any node is healthy
patronictl -c /etc/patroni/patroni.yml list

# 2. If a node is running but not elected, reinitialize
patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster-coordinators coordinator-2

# 3. If all nodes down, start the most recent primary first
systemctl start patroni@coordinator-1

# 4. If etcd is down, restore etcd cluster first
# See etcd disaster recovery procedures

# 5. Manual leader promotion (last resort)
# Edit /etc/patroni/patroni.yml and temporarily disable DCS
# Then manually promote a node
```

---

### Problem: High Replication Lag

**Symptoms**:
- `pg_stat_replication.replay_lag` > 100MB
- Replica falling behind leader
- Read queries on replica return stale data

**Diagnosis**:
```sql
-- Check replication status
SELECT
    application_name,
    client_addr,
    state,
    sync_state,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes,
    EXTRACT(EPOCH FROM (now() - replay_timestamp))::int AS lag_seconds,
    replay_lag
FROM pg_stat_replication;

-- Check replica resource usage
SELECT * FROM pg_stat_bgwriter;

-- Check for replication conflicts
SELECT * FROM pg_stat_database_conflicts WHERE datname = 'distributed_postgres_cluster';
```

**Common Causes**:
1. **Network congestion** - Slow network between leader and replica
2. **Replica overloaded** - High CPU/IO on replica server
3. **Long-running queries on replica** - Blocking replication apply
4. **Large transactions** - Single large transaction creates lag spike

**Resolution**:
```bash
# 1. Check network latency
ping -c 10 coordinator-2

# 2. Check replica resource usage
docker stats postgres-coordinator-2

# 3. Terminate long-running queries on replica
PGPASSWORD=admin psql -h pg-coordinator-2 -U admin -d postgres \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state = 'active' AND query_start < now() - interval '10 minutes';"

# 4. Temporarily disable synchronous replication (emergency only)
# This will reduce consistency guarantees!
PGPASSWORD=admin psql -h pg-coordinator -U admin -d postgres \
  -c "ALTER SYSTEM SET synchronous_commit = 'local'; SELECT pg_reload_conf();"

# 5. If lag is persistent, rebuild replica from leader
patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster-coordinators coordinator-2
```

---

### Problem: Patroni Service Not Starting

**Symptoms**:
- `systemctl status patroni` shows failed
- PostgreSQL not managed by Patroni
- No leader election happening

**Diagnosis**:
```bash
# Check service status
systemctl status patroni

# Check logs
journalctl -u patroni -n 100 --no-pager

# Check configuration
patronictl -c /etc/patroni/patroni.yml show-config

# Test etcd connectivity
etcdctl --endpoints=etcd-1:2379 member list
```

**Common Causes**:
1. **Invalid configuration** - Syntax error in patroni.yml
2. **etcd unreachable** - Network issue or etcd service down
3. **Permission issues** - Patroni cannot access data directory
4. **Port conflicts** - PostgreSQL port already in use

**Resolution**:
```bash
# 1. Validate configuration
patronictl -c /etc/patroni/patroni.yml show-config

# 2. Check file permissions
ls -la /var/lib/postgresql/data
chown -R postgres:postgres /var/lib/postgresql/data

# 3. Test PostgreSQL startup manually
su - postgres -c "pg_ctl start -D /var/lib/postgresql/data"

# 4. Check for port conflicts
ss -tuln | grep 5432
ss -tuln | grep 8008

# 5. Reset Patroni state (if corrupted)
rm -rf /var/lib/postgresql/data/patroni.dynamic.json
systemctl restart patroni
```

---

### Problem: Split-Brain Scenario

**Symptoms**:
- Multiple nodes claiming to be leader
- Divergent data between nodes
- Timeline mismatch in `patronictl list`

**Diagnosis**:
```bash
# Check cluster status
patronictl -c /etc/patroni/patroni.yml list

# Check etcd cluster status
etcdctl --endpoints=etcd-1:2379,etcd-2:2379,etcd-3:2379 endpoint health

# Check network connectivity
for node in coordinator-1 coordinator-2 coordinator-3; do
    echo "Testing $node:"
    ping -c 3 $node
done
```

**Common Causes**:
1. **Network partition** - Nodes isolated from each other
2. **etcd quorum lost** - etcd cluster split or down
3. **Watchdog failure** - STONITH device not fencing failed nodes

**Resolution** (CRITICAL - Follow carefully):
```bash
# 1. STOP - Do not write to any node until resolved
# 2. Identify the TRUE leader (most recent timeline)
patronictl -c /etc/patroni/patroni.yml list

# 3. Stop PostgreSQL on all nodes except true leader
patronictl -c /etc/patroni/patroni.yml pause

# 4. Manually stop PostgreSQL on false leaders
systemctl stop patroni@coordinator-2
systemctl stop patroni@coordinator-3

# 5. Reinitialize false leaders from true leader
patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster-coordinators coordinator-2
patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster-coordinators coordinator-3

# 6. Resume automatic failover
patronictl -c /etc/patroni/patroni.yml resume

# 7. Verify cluster health
patronictl -c /etc/patroni/patroni.yml list
```

---

## Maintenance Windows

### Planned Maintenance Checklist

**Before Maintenance**:
- [ ] Announce maintenance window (email, Slack, status page)
- [ ] Verify backups are current and restorable
- [ ] Document current cluster state (`patronictl list`)
- [ ] Disable automated failover (if necessary)
- [ ] Scale down non-essential services
- [ ] Prepare rollback plan

**During Maintenance**:
- [ ] Execute changes on replicas first
- [ ] Verify replica health before promoting
- [ ] Perform controlled switchover (not failover)
- [ ] Monitor replication lag continuously
- [ ] Test read/write operations after each step

**After Maintenance**:
- [ ] Verify cluster health (`patronictl list`)
- [ ] Re-enable automated failover
- [ ] Monitor for 30 minutes post-maintenance
- [ ] Update documentation with changes
- [ ] Post all-clear notification

### Rolling PostgreSQL Upgrade

```bash
# Zero-downtime PostgreSQL upgrade procedure

# 1. Verify current version
PGPASSWORD=admin psql -h pg-coordinator -U admin -d postgres -c "SELECT version();"

# 2. Disable automatic failover
patronictl -c /etc/patroni/patroni.yml pause

# 3. Upgrade replicas first (one at a time)
# Update coordinator-3 (replica)
docker service update --image ruvnet/ruvector-postgres:16.2 postgres-coordinator \
  --constraint 'node.hostname==coordinator-3'

# Wait for coordinator-3 to catch up
patronictl -c /etc/patroni/patroni.yml list

# 4. Repeat for coordinator-2
docker service update --image ruvnet/ruvector-postgres:16.2 postgres-coordinator \
  --constraint 'node.hostname==coordinator-2'

# 5. Controlled switchover to upgraded replica
patronictl -c /etc/patroni/patroni.yml switchover \
  --master coordinator-1 \
  --candidate coordinator-2 \
  --force

# 6. Upgrade old leader (now replica)
docker service update --image ruvnet/ruvector-postgres:16.2 postgres-coordinator \
  --constraint 'node.hostname==coordinator-1'

# 7. Re-enable automatic failover
patronictl -c /etc/patroni/patroni.yml resume

# 8. Verify all nodes upgraded
patronictl -c /etc/patroni/patroni.yml list
```

### Configuration Changes

```bash
# Safe configuration change procedure

# 1. Pause automatic failover
patronictl -c /etc/patroni/patroni.yml pause

# 2. Edit configuration (PostgreSQL parameters)
patronictl -c /etc/patroni/patroni.yml edit-config

# Example: Increase work_mem
# In the editor, add:
# postgresql:
#   parameters:
#     work_mem: 128MB

# 3. Reload configuration
patronictl -c /etc/patroni/patroni.yml reload postgres-cluster-coordinators coordinator-1
patronictl -c /etc/patroni/patroni.yml reload postgres-cluster-coordinators coordinator-2
patronictl -c /etc/patroni/patroni.yml reload postgres-cluster-coordinators coordinator-3

# 4. Verify configuration applied
PGPASSWORD=admin psql -h pg-coordinator -U admin -d postgres -c "SHOW work_mem;"

# 5. Resume automatic failover
patronictl -c /etc/patroni/patroni.yml resume
```

---

## Backup and Recovery

### Backup Strategy

**Backup Types**:
1. **Physical backups (pg_basebackup)**: Full cluster backup
2. **Logical backups (pg_dump)**: Database-level backup
3. **Continuous WAL archiving**: Point-in-time recovery (PITR)

### Physical Backup Procedure

```bash
# Backup coordinator cluster (from replica to avoid load on leader)
./scripts/patroni/backup-cluster.sh --cluster coordinator --node coordinator-2

# Manual pg_basebackup
PGPASSWORD=admin pg_basebackup \
  -h coordinator-2 \
  -U admin \
  -D /backups/coordinator-$(date +%Y%m%d-%H%M%S) \
  -Ft -z -P \
  --wal-method=stream

# Backup retention
# Keep: Daily for 7 days, Weekly for 4 weeks, Monthly for 12 months
find /backups -name "coordinator-*.tar.gz" -mtime +7 -delete
```

### Continuous WAL Archiving

Configure in `patroni.yml`:
```yaml
postgresql:
  parameters:
    archive_mode: "on"
    archive_command: "test ! -f /wal_archive/%f && cp %p /wal_archive/%f"
    archive_timeout: 300  # 5 minutes

# For production, use remote storage:
# archive_command: "aws s3 cp %p s3://postgres-backups/wal/%f"
```

### Point-in-Time Recovery (PITR)

```bash
# Restore to specific point in time

# 1. Stop Patroni on target node
systemctl stop patroni

# 2. Clear data directory
rm -rf /var/lib/postgresql/data/*

# 3. Restore base backup
tar -xzf /backups/coordinator-20260212.tar.gz -C /var/lib/postgresql/data

# 4. Create recovery.signal
touch /var/lib/postgresql/data/recovery.signal

# 5. Configure recovery target
cat > /var/lib/postgresql/data/recovery.conf << EOF
restore_command = 'cp /wal_archive/%f %p'
recovery_target_time = '2026-02-12 10:30:00'
recovery_target_action = 'promote'
EOF

# 6. Start PostgreSQL (will replay WAL to target time)
su - postgres -c "pg_ctl start -D /var/lib/postgresql/data"

# 7. Verify recovery
PGPASSWORD=admin psql -h localhost -U admin -d postgres -c "SELECT now();"

# 8. Reinitialize Patroni
patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster-coordinators coordinator-1
```

### Disaster Recovery Procedure

See [PATRONI_OPERATIONS.md](FAILOVER_RUNBOOK.md#disaster-recovery) for full DR procedures.

---

## Performance Tuning

### Patroni-Specific Tuning

```yaml
# /etc/patroni/patroni.yml

# Reduce failover time (faster detection)
bootstrap:
  dcs:
    ttl: 20                     # Leader key TTL (default: 30s)
    loop_wait: 5                # Patroni loop interval (default: 10s)
    retry_timeout: 5            # Retry timeout (default: 10s)
    maximum_lag_on_failover: 1048576  # 1MB max lag for failover

# Optimize replication
postgresql:
  parameters:
    # Synchronous replication (coordinators)
    synchronous_commit: 'on'
    synchronous_standby_names: '*'

    # Asynchronous replication (workers)
    # synchronous_commit: 'local'

    # WAL settings
    wal_keep_size: 2048MB       # Keep 2GB of WAL
    max_wal_senders: 10         # Support 10 replicas
    wal_level: replica

    # Streaming replication
    hot_standby: on
    hot_standby_feedback: on    # Reduce replication conflicts
```

### PostgreSQL Tuning for HA

```sql
-- Memory settings
ALTER SYSTEM SET shared_buffers = '4GB';            -- 25% of RAM
ALTER SYSTEM SET effective_cache_size = '12GB';     -- 75% of RAM
ALTER SYSTEM SET work_mem = '64MB';                 -- Per-query memory
ALTER SYSTEM SET maintenance_work_mem = '1GB';      -- Vacuum, index builds

-- Connection settings
ALTER SYSTEM SET max_connections = 200;
ALTER SYSTEM SET superuser_reserved_connections = 10;

-- WAL settings for performance
ALTER SYSTEM SET wal_buffers = '16MB';
ALTER SYSTEM SET checkpoint_timeout = '15min';
ALTER SYSTEM SET max_wal_size = '4GB';
ALTER SYSTEM SET min_wal_size = '1GB';
ALTER SYSTEM SET checkpoint_completion_target = 0.9;

-- Query planning
ALTER SYSTEM SET random_page_cost = 1.1;            -- SSD-optimized
ALTER SYSTEM SET effective_io_concurrency = 200;

-- Reload configuration
SELECT pg_reload_conf();
```

### Monitoring Query Performance

```sql
-- Enable pg_stat_statements
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Top 20 slowest queries
SELECT
    query,
    calls,
    total_exec_time / 1000 AS total_time_seconds,
    mean_exec_time / 1000 AS mean_time_seconds,
    max_exec_time / 1000 AS max_time_seconds,
    stddev_exec_time / 1000 AS stddev_time_seconds
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 20;

-- Queries with high I/O
SELECT
    query,
    calls,
    shared_blks_hit,
    shared_blks_read,
    shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0) AS cache_hit_ratio
FROM pg_stat_statements
WHERE shared_blks_read > 1000
ORDER BY shared_blks_read DESC
LIMIT 20;
```

---

## Quick Reference Commands

### Cluster Management

```bash
# List cluster status
patronictl -c /etc/patroni/patroni.yml list

# Show configuration
patronictl -c /etc/patroni/patroni.yml show-config

# Edit configuration
patronictl -c /etc/patroni/patroni.yml edit-config

# Reload configuration
patronictl -c /etc/patroni/patroni.yml reload <cluster> <member>

# Pause automatic failover
patronictl -c /etc/patroni/patroni.yml pause

# Resume automatic failover
patronictl -c /etc/patroni/patroni.yml resume
```

### Failover Management

```bash
# Controlled switchover
patronictl -c /etc/patroni/patroni.yml switchover \
  --master <current-leader> \
  --candidate <target-leader>

# Force failover (removes current leader)
patronictl -c /etc/patroni/patroni.yml failover --force

# Reinitialize replica
patronictl -c /etc/patroni/patroni.yml reinit <cluster> <member>
```

### Monitoring

```bash
# Real-time cluster monitor
./scripts/patroni/monitor-cluster.sh --watch

# Check replication status
PGPASSWORD=admin psql -h pg-coordinator -U admin -d postgres \
  -c "SELECT * FROM pg_stat_replication;"

# Check for blocking queries
PGPASSWORD=admin psql -h pg-coordinator -U admin -d postgres \
  -c "SELECT * FROM pg_stat_activity WHERE wait_event_type = 'Lock';"

# etcd cluster health
etcdctl --endpoints=etcd-1:2379,etcd-2:2379,etcd-3:2379 endpoint health
```

---

## Additional Resources

- [Failover Runbook](FAILOVER_RUNBOOK.md) - Detailed failover procedures
- [Monitoring Setup](MONITORING_SETUP.md) - Prometheus/Grafana configuration
- [Quick Reference Card](PATRONI_QUICK_REFERENCE.md) - One-page command reference
- [Patroni Documentation](https://patroni.readthedocs.io/)
- [PostgreSQL HA Best Practices](https://www.postgresql.org/docs/current/high-availability.html)

---

**Document Version**: 1.0
**Last Updated**: 2026-02-12
**Maintained By**: Database Operations Team
**Review Schedule**: Quarterly
