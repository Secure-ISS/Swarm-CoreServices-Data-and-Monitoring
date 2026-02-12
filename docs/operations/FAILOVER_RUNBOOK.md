# Patroni Failover Runbook

## Quick Reference

| Scenario | Action | Command | Expected Time |
|----------|--------|---------|---------------|
| **Automatic Failover** | Monitor only | `patronictl list` | 6-10 seconds |
| **Planned Switchover** | Controlled switch | `patronictl switchover` | 2-5 seconds |
| **Manual Failover** | Force failover | `patronictl failover --force` | 5-10 seconds |
| **Rollback** | Switch back | `patronictl switchover` | 2-5 seconds |

---

## Table of Contents

1. [Failover Overview](#failover-overview)
2. [Automatic Failover](#automatic-failover)
3. [Manual Failover](#manual-failover)
4. [Controlled Switchover](#controlled-switchover)
5. [Rollback Procedures](#rollback-procedures)
6. [Post-Failover Validation](#post-failover-validation)
7. [Disaster Recovery](#disaster-recovery)
8. [Troubleshooting](#troubleshooting)

---

## Failover Overview

### Failover Types

```
┌─────────────────────────────────────────────────────────────┐
│                    Failover Scenarios                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. AUTOMATIC FAILOVER (Leader Crash)                       │
│     ┌──────────┐                                            │
│     │ Leader   │ ──X──> Crashes                             │
│     └──────────┘                                            │
│           ↓                                                  │
│     Patroni detects failure (6s)                            │
│           ↓                                                  │
│     ┌──────────┐                                            │
│     │ Replica  │ ──> Promoted to Leader                     │
│     └──────────┘                                            │
│     Time: 6-10 seconds                                      │
│     Data Loss: None (sync replication)                      │
│                                                              │
│  2. CONTROLLED SWITCHOVER (Planned Maintenance)             │
│     ┌──────────┐         ┌──────────┐                       │
│     │ Leader   │ ──sync─>│ Replica  │                       │
│     └──────────┘         └──────────┘                       │
│           ↓                    ↓                             │
│     Graceful shutdown    Promoted to Leader                 │
│           ↓                    ↓                             │
│     Becomes Replica      Accepts writes                     │
│     Time: 2-5 seconds                                       │
│     Data Loss: None                                         │
│                                                              │
│  3. MANUAL FAILOVER (Force Promotion)                       │
│     Used when automatic failover fails                      │
│     Time: 5-10 seconds                                      │
│     Data Loss: Possible (if replicas lag)                   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Patroni Failover Decision Process

```
┌──────────────────────────────────────────────────────────────┐
│              Patroni Failover Decision Tree                   │
└──────────────────────────────────────────────────────────────┘
                            │
                    Leader fails (missed heartbeats)
                            │
                            ↓
              ┌─────────────────────────────┐
              │  etcd leader key expires    │
              │  (TTL = 30s, but detected   │
              │   after 2-3 missed checks)  │
              └─────────────┬───────────────┘
                            │
                            ↓
              ┌─────────────────────────────┐
              │  Patroni selects candidate  │
              │  Criteria:                  │
              │  1. Lowest replication lag  │
              │  2. Timeline consistency    │
              │  3. No nofailover tag       │
              └─────────────┬───────────────┘
                            │
                            ↓
              ┌─────────────────────────────┐
              │  Candidate acquires leader  │
              │  key in etcd (atomic CAS)   │
              └─────────────┬───────────────┘
                            │
                            ↓
              ┌─────────────────────────────┐
              │  PostgreSQL promotion       │
              │  - Stop replication         │
              │  - Write timeline history   │
              │  - Accept connections       │
              └─────────────┬───────────────┘
                            │
                            ↓
              ┌─────────────────────────────┐
              │  Other replicas follow      │
              │  new leader (automatic)     │
              └─────────────────────────────┘
```

---

## Automatic Failover

### When It Happens

Automatic failover triggers when:
- Leader PostgreSQL process crashes
- Leader server becomes unreachable
- etcd leader key expires (missed 2-3 heartbeats)
- Patroni agent on leader stops

**Expected Behavior**: Patroni automatically promotes the best replica to leader without human intervention.

### Monitoring Automatic Failover

```bash
# Real-time failover monitoring
./scripts/patroni/monitor-cluster.sh --watch

# Watch for failover events in logs
journalctl -u patroni -f | grep -i "failover\|promoted\|elected"

# Check cluster status during failover
watch -n 1 'patronictl -c /etc/patroni/patroni.yml list'
```

### Timeline of Events

```
T+0s:  Leader fails (coordinator-1 crashes)
       │
       ├─> PostgreSQL process exits
       ├─> Patroni agent loses control
       │
T+2s:  First missed heartbeat
       │
       ├─> Patroni on coordinator-1 tries to update etcd leader key
       ├─> Update fails (process dead)
       │
T+4s:  Second missed heartbeat
       │
       ├─> Replicas detect stale leader key
       │
T+6s:  Leader key expires (TTL=30s, but detected earlier)
       │
       ├─> Patroni on coordinator-2 and coordinator-3 race for leader key
       │
T+7s:  Coordinator-2 wins election
       │
       ├─> Acquires leader key in etcd
       ├─> Stops replication from coordinator-1
       ├─> Promotes to leader (pg_ctl promote)
       │
T+8s:  Coordinator-3 follows new leader
       │
       ├─> Detects new leader in etcd
       ├─> Reconnects replication to coordinator-2
       │
T+10s: Cluster stabilized
       │
       └─> All services route to new leader (coordinator-2)
```

### Post-Automatic Failover Actions

```bash
# 1. Verify cluster health
patronictl -c /etc/patroni/patroni.yml list

# Expected output:
# + Cluster: postgres-cluster-coordinators -----+----+-----------+
# | Member        | Host      | Role    | State     | TL | Lag in MB |
# +---------------+-----------+---------+-----------+----+-----------+
# | coordinator-1 | 10.0.1.11 | Replica | stopped   |  3 |           |  ← Failed node
# | coordinator-2 | 10.0.1.12 | Leader  | running   |  4 |           |  ← New leader
# | coordinator-3 | 10.0.1.13 | Replica | streaming |  4 |         0 |  ← Following
# +---------------+-----------+-----------+----+-----------+----------+

# 2. Check for data loss (should be 0 with sync replication)
PGPASSWORD=admin psql -h coordinator-2 -U admin -d postgres << 'EOF'
SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();
EOF

# 3. Verify application connectivity
PGPASSWORD=admin psql -h pg-coordinator -U admin -d distributed_postgres_cluster \
  -c "SELECT 1 AS health_check;"

# 4. Review failover logs
journalctl -u patroni --since "5 minutes ago" | grep -i "failover\|promoted"

# 5. Notify team (send alert via Slack, PagerDuty, etc.)
./scripts/patroni/send-failover-alert.sh

# 6. Investigate root cause of failure
# - Check coordinator-1 logs
# - Check system resources (OOM, disk full, etc.)
# - Check network connectivity

# 7. Decide on recovery action for failed node
# Option A: Restart and reintegrate
systemctl start patroni@coordinator-1
patronictl -c /etc/patroni/patroni.yml list  # Verify it rejoins as replica

# Option B: Rebuild from scratch
patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster-coordinators coordinator-1
```

### Automatic Failover Validation

```bash
# Verify new leader is accepting writes
PGPASSWORD=admin psql -h pg-coordinator -U admin -d distributed_postgres_cluster << 'EOF'
CREATE TABLE failover_test (id SERIAL, ts TIMESTAMP DEFAULT now());
INSERT INTO failover_test DEFAULT VALUES;
SELECT * FROM failover_test;
DROP TABLE failover_test;
EOF

# Verify replication is working
PGPASSWORD=admin psql -h coordinator-2 -U admin -d postgres << 'EOF'
SELECT
    application_name,
    client_addr,
    state,
    sync_state,
    replay_lag
FROM pg_stat_replication;
EOF

# Expected: coordinator-3 should be streaming from coordinator-2
```

---

## Manual Failover

### When to Use Manual Failover

Use manual failover when:
- Automatic failover is disabled (maintenance mode)
- Automatic failover failed (split-brain, no quorum)
- Need to force specific replica to become leader
- Emergency recovery situation

### Manual Failover Procedure

```bash
# 1. Assess current cluster state
patronictl -c /etc/patroni/patroni.yml list

# 2. Choose target replica (lowest lag, best hardware)
# Look for:
# - State: streaming
# - Lag: 0 or minimal
# - Timeline: matches current leader

# 3. Perform manual failover
patronictl -c /etc/patroni/patroni.yml failover \
  --master coordinator-1 \
  --candidate coordinator-2 \
  --force

# Interactive prompts:
# Current cluster topology
# + Cluster: postgres-cluster-coordinators -----+----+-----------+
# | Member        | Host      | Role    | State     | TL | Lag in MB |
# +---------------+-----------+---------+-----------+----+-----------+
# | coordinator-1 | 10.0.1.11 | Leader  | running   |  3 |           |
# | coordinator-2 | 10.0.1.12 | Replica | streaming |  3 |         0 |
# | coordinator-3 | 10.0.1.13 | Replica | streaming |  3 |         0 |
# +---------------+-----------+---------+-----------+----+-----------+
# Master [coordinator-1]:
# Candidate ['coordinator-2', 'coordinator-3'] []: coordinator-2
# When should the switchover take place (e.g. 2026-02-12T10:30 )  [now]:
# Are you sure you want to failover cluster postgres-cluster-coordinators, demoting current master coordinator-1? [y/N]: y

# 4. Monitor failover progress
watch -n 1 'patronictl -c /etc/patroni/patroni.yml list'

# 5. Verify new leader
PGPASSWORD=admin psql -h pg-coordinator -U admin -d distributed_postgres_cluster \
  -c "SELECT pg_is_in_recovery();"
# Expected: f (false) = leader
```

### Manual Failover with Specific Timeline

```bash
# Failover to specific timeline (advanced)
# Use when recovering from split-brain or timeline divergence

# 1. Check timelines
patronictl -c /etc/patroni/patroni.yml history postgres-cluster-coordinators

# Example output:
# +----+----------+---------------------------+---------+
# | TL | LSN      | Reason                    | Timestamp|
# +----+----------+---------------------------+---------+
# |  1 | 0/0      | Initial timeline          | ...      |
# |  2 | 0/3000000| Failover (coordinator-2) | ...      |
# |  3 | 0/5000000| Failover (coordinator-1) | ...      |
# |  4 | 0/7000000| Current timeline          | ...      |
# +----+----------+---------------------------+---------+

# 2. Select target with correct timeline
patronictl -c /etc/patroni/patroni.yml failover \
  --master coordinator-1 \
  --candidate coordinator-2 \
  --force

# 3. Reinit nodes on wrong timeline
patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster-coordinators coordinator-3
```

---

## Controlled Switchover

### Planned Switchover Procedure

Use switchover for:
- Planned maintenance on current leader
- Testing failover procedures
- Rebalancing load across nodes
- Upgrading leader hardware

```bash
# PLANNED SWITCHOVER (Zero Data Loss)

# 1. Pre-switchover checks
echo "=== Pre-Switchover Checks ==="

# Verify cluster health
patronictl -c /etc/patroni/patroni.yml list

# Check replication lag (should be 0)
PGPASSWORD=admin psql -h coordinator-1 -U admin -d postgres << 'EOF'
SELECT
    application_name,
    state,
    sync_state,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;
EOF

# Expected: lag_bytes should be 0 for synchronous replicas

# 2. Notify stakeholders
echo "Performing planned switchover at $(date)"
./scripts/patroni/send-switchover-notification.sh

# 3. Perform controlled switchover
patronictl -c /etc/patroni/patroni.yml switchover \
  --master coordinator-1 \
  --candidate coordinator-2 \
  --scheduled now \
  --force

# Switchover process:
# a) coordinator-1 finishes current transactions
# b) coordinator-1 syncs all WAL to coordinator-2
# c) coordinator-1 shuts down cleanly
# d) coordinator-2 promoted to leader
# e) coordinator-1 restarts as replica

# 4. Monitor switchover
watch -n 1 'patronictl -c /etc/patroni/patroni.yml list'

# 5. Verify switchover success
echo "=== Post-Switchover Verification ==="

# Check new leader
patronictl -c /etc/patroni/patroni.yml list

# Expected output:
# + Cluster: postgres-cluster-coordinators -----+----+-----------+
# | Member        | Host      | Role    | State     | TL | Lag in MB |
# +---------------+-----------+---------+-----------+----+-----------+
# | coordinator-1 | 10.0.1.11 | Replica | streaming |  4 |         0 |  ← Now replica
# | coordinator-2 | 10.0.1.12 | Leader  | running   |  4 |           |  ← New leader
# | coordinator-3 | 10.0.1.13 | Replica | streaming |  4 |         0 |
# +---------------+-----------+---------+-----------+----+-----------+

# Test write operations
PGPASSWORD=admin psql -h pg-coordinator -U admin -d distributed_postgres_cluster \
  -c "INSERT INTO test_table VALUES (NOW());"

# 6. Post-switchover notification
echo "Switchover complete. New leader: coordinator-2"
./scripts/patroni/send-switchover-complete.sh
```

### Scheduled Switchover

```bash
# Schedule switchover for specific time (e.g., maintenance window)

# Switchover at 2:00 AM tomorrow
patronictl -c /etc/patroni/patroni.yml switchover \
  --master coordinator-1 \
  --candidate coordinator-2 \
  --scheduled "2026-02-13T02:00:00" \
  --force

# Patroni will wait until scheduled time, then perform switchover
# Monitor pending switchover:
patronictl -c /etc/patroni/patroni.yml show-config | grep scheduled
```

---

## Rollback Procedures

### Rollback After Failover

```bash
# Scenario: Failover to coordinator-2, but want to rollback to coordinator-1

# 1. Verify coordinator-1 is healthy and caught up
patronictl -c /etc/patroni/patroni.yml list

# Expected: coordinator-1 should be "streaming" with 0 lag
# + Cluster: postgres-cluster-coordinators -----+----+-----------+
# | Member        | Host      | Role    | State     | TL | Lag in MB |
# +---------------+-----------+---------+-----------+----+-----------+
# | coordinator-1 | 10.0.1.11 | Replica | streaming |  4 |         0 |  ← Healthy
# | coordinator-2 | 10.0.1.12 | Leader  | running   |  4 |           |  ← Current
# | coordinator-3 | 10.0.1.13 | Replica | streaming |  4 |         0 |
# +---------------+-----------+---------+-----------+----+-----------+

# 2. Perform rollback switchover
patronictl -c /etc/patroni/patroni.yml switchover \
  --master coordinator-2 \
  --candidate coordinator-1 \
  --force

# 3. Verify rollback
patronictl -c /etc/patroni/patroni.yml list

# Expected: coordinator-1 is leader again
# + Cluster: postgres-cluster-coordinators -----+----+-----------+
# | Member        | Host      | Role    | State     | TL | Lag in MB |
# +---------------+-----------+---------+-----------+----+-----------+
# | coordinator-1 | 10.0.1.11 | Leader  | running   |  5 |           |  ← Restored
# | coordinator-2 | 10.0.1.12 | Replica | streaming |  5 |         0 |
# | coordinator-3 | 10.0.1.13 | Replica | streaming |  5 |         0 |
# +---------------+-----------+---------+-----------+----+-----------+
```

### Emergency Rollback (Data Divergence)

```bash
# Scenario: Failover caused data divergence, need to rollback

# 1. STOP - Do not continue writes to new leader
# Pause automatic failover
patronictl -c /etc/patroni/patroni.yml pause

# 2. Assess divergence
# Check timelines
patronictl -c /etc/patroni/patroni.yml history postgres-cluster-coordinators

# 3. Identify last common WAL LSN
PGPASSWORD=admin psql -h coordinator-1 -U admin -d postgres \
  -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"
PGPASSWORD=admin psql -h coordinator-2 -U admin -d postgres \
  -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"

# 4. Choose recovery strategy:

# Option A: Rollback to coordinator-1 (discard coordinator-2 changes)
patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster-coordinators coordinator-2
patronictl -c /etc/patroni/patroni.yml switchover --master coordinator-2 --candidate coordinator-1 --force

# Option B: Point-in-time recovery to last common state
# See "Disaster Recovery" section

# 5. Resume automatic failover
patronictl -c /etc/patroni/patroni.yml resume
```

---

## Post-Failover Validation

### Validation Checklist

```bash
#!/bin/bash
# Post-failover validation script

echo "=== POST-FAILOVER VALIDATION ==="
echo

# 1. Cluster topology
echo "1. Cluster Topology:"
patronictl -c /etc/patroni/patroni.yml list
echo

# 2. Leader write test
echo "2. Leader Write Test:"
PGPASSWORD=admin psql -h pg-coordinator -U admin -d distributed_postgres_cluster << 'EOF'
CREATE TABLE IF NOT EXISTS failover_validation (
    id SERIAL PRIMARY KEY,
    event VARCHAR(50),
    timestamp TIMESTAMP DEFAULT NOW()
);
INSERT INTO failover_validation (event) VALUES ('post_failover_test');
SELECT * FROM failover_validation ORDER BY id DESC LIMIT 1;
EOF
echo

# 3. Replication status
echo "3. Replication Status:"
PGPASSWORD=admin psql -h pg-coordinator -U admin -d postgres << 'EOF'
SELECT
    application_name,
    client_addr,
    state,
    sync_state,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) / 1024 / 1024 AS lag_mb,
    EXTRACT(EPOCH FROM (now() - replay_timestamp))::int AS lag_seconds
FROM pg_stat_replication
ORDER BY lag_mb DESC;
EOF
echo

# 4. Connection pool status
echo "4. Connection Status:"
PGPASSWORD=admin psql -h pg-coordinator -U admin -d postgres << 'EOF'
SELECT count(*) AS total_connections,
       count(*) FILTER (WHERE state = 'active') AS active,
       count(*) FILTER (WHERE state = 'idle') AS idle
FROM pg_stat_activity;
EOF
echo

# 5. Check for blocking queries
echo "5. Blocking Queries:"
PGPASSWORD=admin psql -h pg-coordinator -U admin -d postgres << 'EOF'
SELECT count(*) AS blocked_queries
FROM pg_stat_activity
WHERE wait_event_type = 'Lock';
EOF
echo

# 6. Timeline verification
echo "6. Timeline Verification:"
patronictl -c /etc/patroni/patroni.yml history postgres-cluster-coordinators | tail -5
echo

# 7. etcd health
echo "7. etcd Cluster Health:"
etcdctl --endpoints=etcd-1:2379,etcd-2:2379,etcd-3:2379 endpoint health
echo

# 8. HAProxy backend status
echo "8. Load Balancer Status:"
curl -s http://haproxy:8404/stats | grep -A 5 "postgres_backend"
echo

echo "=== VALIDATION COMPLETE ==="

# Success criteria:
# - All nodes in "running" or "streaming" state
# - Replication lag < 1MB and < 5 seconds
# - Write test successful
# - No blocking queries
# - All timelines consistent
# - etcd cluster healthy
```

### Automated Post-Failover Tests

```bash
# Run automated test suite
./scripts/patroni/failover-validation-tests.sh

# Test scenarios:
# - Write operations on new leader
# - Read operations on replicas
# - Connection pooling
# - Application connectivity
# - Replication lag recovery
# - Timeline consistency
```

---

## Disaster Recovery

### Total Cluster Failure

**Scenario**: All coordinator nodes failed simultaneously

```bash
# DISASTER RECOVERY PROCEDURE

# 1. Assess damage
# - Are any nodes salvageable?
# - Do we have recent backups?
# - What is the acceptable data loss (RPO)?

# 2. Identify recovery candidate
# Option A: Most recent primary (if available)
# Option B: Replica with least lag
# Option C: Restore from backup

# 3. Recovery from most recent primary
# If coordinator-1 was leader and has valid data:

# a) Stop all Patroni services
systemctl stop patroni@coordinator-2
systemctl stop patroni@coordinator-3

# b) Clear etcd state
etcdctl --endpoints=etcd-1:2379 del --prefix /service/postgres-cluster-coordinators/

# c) Bootstrap new cluster from coordinator-1
# Edit /etc/patroni/patroni.yml on coordinator-1:
bootstrap:
  method: existing
  existing:
    datadir: /var/lib/postgresql/data

# d) Start coordinator-1 as new leader
systemctl start patroni@coordinator-1

# e) Verify coordinator-1 is leader
patronictl -c /etc/patroni/patroni.yml list

# f) Reinitialize other nodes
patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster-coordinators coordinator-2
patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster-coordinators coordinator-3

# 4. Recovery from backup (if no salvageable nodes)
./scripts/patroni/restore-cluster.sh --backup /backups/latest.tar.gz

# 5. Verify cluster health
patronictl -c /etc/patroni/patroni.yml list
./scripts/patroni/validate-cluster.sh

# 6. Notify stakeholders and document incident
./scripts/patroni/send-dr-notification.sh
```

### etcd Cluster Failure

```bash
# Scenario: All etcd nodes failed

# 1. Attempt etcd recovery
# If etcd data is intact:
systemctl start etcd@etcd-1
systemctl start etcd@etcd-2
systemctl start etcd@etcd-3

# Verify etcd cluster
etcdctl --endpoints=etcd-1:2379,etcd-2:2379,etcd-3:2379 member list

# 2. If etcd cannot be recovered, bootstrap new etcd cluster
# Stop all Patroni services
for node in coordinator-1 coordinator-2 coordinator-3; do
    systemctl stop patroni@$node
done

# Remove old etcd data
rm -rf /var/lib/etcd/*

# Bootstrap new etcd cluster
./scripts/patroni/bootstrap-etcd.sh

# 3. Reconfigure Patroni to use new etcd
# Edit /etc/patroni/patroni.yml on all nodes:
etcd3:
  hosts: etcd-1:2379,etcd-2:2379,etcd-3:2379
  protocol: http

# 4. Restart Patroni (leader first)
systemctl start patroni@coordinator-1
sleep 10
systemctl start patroni@coordinator-2
systemctl start patroni@coordinator-3

# 5. Verify cluster reformed
patronictl -c /etc/patroni/patroni.yml list
```

---

## Troubleshooting

### Failover Not Happening

**Symptoms**:
- Leader failed but no replica promoted
- Cluster has no leader for > 30 seconds

**Diagnosis**:
```bash
# Check Patroni status
patronictl -c /etc/patroni/patroni.yml list

# Check etcd connectivity
etcdctl --endpoints=etcd-1:2379,etcd-2:2379,etcd-3:2379 endpoint health

# Check Patroni logs
journalctl -u patroni -n 100

# Check failover configuration
patronictl -c /etc/patroni/patroni.yml show-config | grep -A 10 "failover"
```

**Common Causes**:
1. etcd cluster down (no quorum for leader election)
2. All replicas have `nofailover: true` tag
3. Automatic failover paused
4. Replication lag exceeds `maximum_lag_on_failover`

**Resolution**:
```bash
# 1. Check if failover is paused
patronictl -c /etc/patroni/patroni.yml show-config | grep pause
# If paused: patronictl -c /etc/patroni/patroni.yml resume

# 2. Check nofailover tags
patronictl -c /etc/patroni/patroni.yml list
# If all replicas have nofailover, remove tag from best replica

# 3. Manual failover
patronictl -c /etc/patroni/patroni.yml failover --force
```

---

### Split-Brain After Failover

**Symptoms**:
- Multiple nodes claiming to be leader
- Different timelines on different nodes

**Resolution**:
See [PATRONI_OPERATIONS.md](PATRONI_OPERATIONS.md#split-brain-scenario)

---

### Failed Node Won't Rejoin

**Symptoms**:
- Node shows "stopped" or "failed" in `patronictl list`
- Node cannot stream from new leader

**Resolution**:
```bash
# Reinitialize from leader
patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster-coordinators <failed-node>

# If reinit fails, manually rebuild:
systemctl stop patroni@<failed-node>
rm -rf /var/lib/postgresql/data/*
systemctl start patroni@<failed-node>
# Patroni will automatically pg_basebackup from leader
```

---

## Quick Reference

### Failover Commands

```bash
# Automatic failover (monitor only)
patronictl list

# Planned switchover
patronictl switchover --master <current> --candidate <target>

# Manual failover
patronictl failover --master <current> --candidate <target> --force

# Pause automatic failover
patronictl pause

# Resume automatic failover
patronictl resume

# Reinitialize replica
patronictl reinit <cluster> <member>
```

### Validation Commands

```bash
# Check cluster health
patronictl list

# Check replication
psql -c "SELECT * FROM pg_stat_replication;"

# Test write
psql -c "INSERT INTO test VALUES (NOW());"

# Check timeline
patronictl history <cluster>
```

---

## Additional Resources

- [Patroni Operations Guide](PATRONI_OPERATIONS.md)
- [Monitoring Setup](MONITORING_SETUP.md)
- [Quick Reference Card](PATRONI_QUICK_REFERENCE.md)

---

**Document Version**: 1.0
**Last Updated**: 2026-02-12
**Maintained By**: Database Operations Team
**Review Schedule**: Quarterly
