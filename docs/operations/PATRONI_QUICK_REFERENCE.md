# Patroni Quick Reference Card

**Print this page and keep it handy for emergency situations**

---

## Emergency Contacts

| Role | Name | Phone | Email |
|------|------|-------|-------|
| On-Call DBA | _______________ | _______________ | _______________ |
| Security Lead | _______________ | _______________ | _______________ |
| Team Lead | _______________ | _______________ | _______________ |

---

## Critical Commands

### Cluster Status
```bash
# Quick status check
patronictl -c /etc/patroni/patroni.yml list

# Continuous monitoring
watch -n 5 'patronictl -c /etc/patroni/patroni.yml list'

# Detailed cluster info
patronictl -c /etc/patroni/patroni.yml show-config
```

### Failover Commands
```bash
# Controlled switchover (preferred for maintenance)
patronictl switchover --master <current> --candidate <new>

# Manual failover (force)
patronictl failover --master <current> --candidate <new> --force

# Pause automatic failover
patronictl pause

# Resume automatic failover
patronictl resume
```

### Health Checks
```bash
# PostgreSQL replication status
PGPASSWORD=admin psql -h pg-coordinator -U admin -d postgres \
  -c "SELECT * FROM pg_stat_replication;"

# Check for blocking queries
PGPASSWORD=admin psql -h pg-coordinator -U admin -d postgres \
  -c "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock';"

# etcd cluster health
etcdctl --endpoints=etcd-1:2379,etcd-2:2379,etcd-3:2379 endpoint health
```

### Recovery Commands
```bash
# Reinitialize failed replica
patronictl reinit <cluster-name> <member-name>

# Restart Patroni service
systemctl restart patroni

# View recent logs
journalctl -u patroni -n 100 --no-pager
```

---

## Common Issues Flowchart

```
┌─────────────────────────────────────────────────────────────────┐
│                      PROBLEM?                                    │
└──────────────────────┬──────────────────────────────────────────┘
                       │
        ┌──────────────┼──────────────┐
        │              │              │
   NO LEADER      HIGH LAG      NODE DOWN
        │              │              │
        │              │              │
    ┌───▼────┐    ┌────▼────┐    ┌───▼────┐
    │Check   │    │Check    │    │Check   │
    │etcd    │    │replica  │    │logs &  │
    │cluster │    │resources│    │restart │
    └───┬────┘    └────┬────┘    └───┬────┘
        │              │              │
        │         ┌────▼────┐         │
        │         │Terminate│         │
        │         │long     │         │
        │         │queries  │         │
        │         └────┬────┘         │
        │              │              │
    ┌───▼──────────────▼──────────────▼────┐
    │    STILL NOT RESOLVED?                │
    │    → Contact On-Call DBA              │
    │    → Check runbooks for details       │
    └───────────────────────────────────────┘
```

---

## Monitoring Thresholds

### Critical Alerts (Page On-Call)
| Metric | Threshold | Action |
|--------|-----------|--------|
| **No Leader** | 0 leaders for > 30s | Check etcd, manual failover |
| **Member Down** | Node unreachable > 1m | Investigate logs, restart |
| **Replication Lag** | > 100MB or 60s | Check network, resources |
| **etcd Quorum** | < 2 healthy nodes | Restore etcd cluster |
| **Disk Space** | < 10% free | Free up space immediately |
| **Connections** | > 90% of max | Scale PgBouncer, kill idle |

### Warning Alerts (Investigate)
| Metric | Threshold | Action |
|--------|-----------|--------|
| **Moderate Lag** | > 10MB or 10s | Monitor, check resources |
| **Cache Hit Ratio** | < 90% | Review query patterns |
| **Long Queries** | > 10 minutes | Consider terminating |
| **Checkpoints** | > 1/minute | Tune max_wal_size |
| **Disk Space** | < 20% free | Plan cleanup |

---

## Patroni Configuration Files

| File | Location | Purpose |
|------|----------|---------|
| **patroni.yml** | `/etc/patroni/patroni.yml` | Main configuration |
| **PostgreSQL conf** | `/var/lib/postgresql/data/postgresql.conf` | DB settings |
| **pg_hba.conf** | `/var/lib/postgresql/data/pg_hba.conf` | Authentication |
| **Patroni logs** | `/var/log/patroni/patroni.log` | Patroni agent logs |
| **PostgreSQL logs** | `/var/log/postgresql/*.log` | Database logs |

---

## Replication Status Interpretation

```sql
-- Run on leader:
SELECT * FROM pg_stat_replication;

-- Key columns:
--   application_name: Replica identifier
--   state:           'streaming' = healthy, 'catchup' = recovering
--   sync_state:      'sync' = synchronous, 'async' = asynchronous
--   replay_lag:      Replication delay (should be < 10MB)
--   replay_timestamp: Last WAL replay time
```

**Healthy Output:**
```
 application_name | state     | sync_state | replay_lag
------------------+-----------+------------+------------
 coordinator-2    | streaming | sync       | 0 MB
 coordinator-3    | streaming | async      | 0 MB
```

---

## Timeline History

```bash
# View failover history
patronictl -c /etc/patroni/patroni.yml history <cluster-name>

# Timeline interpretation:
#   TL 1: Initial cluster bootstrap
#   TL 2: First failover (leader change)
#   TL 3: Second failover
#   etc.

# All replicas should have the same timeline number
```

---

## Useful PostgreSQL Queries

### Check Current Leader
```sql
SELECT pg_is_in_recovery();
-- f (false) = leader
-- t (true)  = replica
```

### Connection Count
```sql
SELECT count(*) AS total_connections,
       count(*) FILTER (WHERE state = 'active') AS active,
       count(*) FILTER (WHERE state = 'idle') AS idle
FROM pg_stat_activity;
```

### Find Blocking Queries
```sql
SELECT
    blocked.pid,
    blocked.usename,
    blocked.query AS blocked_query,
    blocking.pid AS blocking_pid,
    blocking.query AS blocking_query
FROM pg_stat_activity AS blocked
JOIN pg_stat_activity AS blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.wait_event_type = 'Lock';
```

### Terminate Query
```sql
-- Graceful termination (wait for query to finish)
SELECT pg_cancel_backend(<pid>);

-- Force termination (immediate)
SELECT pg_terminate_backend(<pid>);
```

---

## HAProxy Endpoints

| URL | Purpose |
|-----|---------|
| `http://haproxy:8404/stats` | Stats dashboard |
| `http://haproxy:5432` | PostgreSQL connection (read-write) |

**Check HAProxy backend status:**
```bash
curl -s http://haproxy:8404/stats | grep "postgres_backend"
```

---

## etcd Commands

### Check Cluster Health
```bash
etcdctl --endpoints=etcd-1:2379,etcd-2:2379,etcd-3:2379 endpoint health
```

### View Patroni Keys
```bash
# List all keys under Patroni namespace
etcdctl --endpoints=etcd-1:2379 get --prefix /service/postgres-cluster/

# Check leader key
etcdctl --endpoints=etcd-1:2379 get /service/postgres-cluster/leader
```

### Backup etcd
```bash
etcdctl --endpoints=etcd-1:2379 snapshot save /backups/etcd-$(date +%Y%m%d).db
```

---

## Docker Commands (if using containers)

### Check Service Status
```bash
docker service ls | grep postgres
docker service ps postgres-coordinator
```

### View Logs
```bash
docker service logs postgres-coordinator
docker logs <container-id>
```

### Scale Services
```bash
docker service scale postgres-worker-1=2
```

---

## Emergency Procedures

### 1. Total Cluster Failure
```bash
# 1. Stop all nodes
systemctl stop patroni@*

# 2. Identify best candidate (most recent timeline)
# Check /var/lib/postgresql/data/pg_control on each node

# 3. Bootstrap from best candidate
patronictl -c /etc/patroni/patroni.yml reinit <cluster> <node>

# 4. Start nodes one by one
systemctl start patroni@coordinator-1
# Wait for it to become leader
systemctl start patroni@coordinator-2
systemctl start patroni@coordinator-3
```

### 2. Split-Brain Scenario
```bash
# 1. STOP - Do not write to any node
patronictl pause

# 2. Identify true leader (check timelines)
patronictl list

# 3. Stop false leaders
systemctl stop patroni@<false-leader>

# 4. Reinitialize from true leader
patronictl reinit <cluster> <false-leader>

# 5. Resume automatic failover
patronictl resume
```

### 3. etcd Cluster Failure
```bash
# 1. Check if etcd data is intact
ls -la /var/lib/etcd/

# 2. Attempt restart
systemctl restart etcd@*

# 3. If restart fails, restore from backup
etcdctl snapshot restore /backups/etcd-latest.db

# 4. Restart Patroni nodes
systemctl restart patroni@*
```

---

## Key Performance Indicators (KPIs)

### Availability
- **Leader Uptime**: > 99.9% (< 8.76 hours downtime/year)
- **Failover Time**: < 10 seconds (target: 6 seconds)
- **Replica Lag**: < 1MB (target: 0MB for sync replicas)

### Performance
- **Query Response Time**: p95 < 50ms
- **Connection Pool Usage**: < 80%
- **Cache Hit Ratio**: > 95%
- **Checkpoint Frequency**: < 1 per 5 minutes

### Reliability
- **Backup Success Rate**: 100%
- **Replication Success Rate**: > 99.99%
- **Data Loss on Failover**: 0 bytes (sync replication)

---

## Escalation Path

```
Level 1: On-Call DBA
   │
   ├─> Response time: 15 minutes
   ├─> Authority: Restart services, kill queries, minor config changes
   │
   └─> If unresolved after 30 minutes:
       │
Level 2: Database Manager + Security Lead
       │
       ├─> Response time: 30 minutes
       ├─> Authority: Cluster reinit, failover, major config changes
       │
       └─> If unresolved after 1 hour:
           │
Level 3: VP Engineering + CTO
           │
           ├─> Response time: 1 hour
           ├─> Authority: All actions, vendor escalation
```

---

## Additional Resources

| Resource | Location |
|----------|----------|
| **Full Operations Guide** | `/docs/operations/PATRONI_OPERATIONS.md` |
| **Failover Runbook** | `/docs/operations/FAILOVER_RUNBOOK.md` |
| **Monitoring Setup** | `/docs/operations/MONITORING_SETUP.md` |
| **Incident Response** | `/docs/security/incident-response-runbook.md` |
| **Scripts** | `/scripts/patroni/` |

---

**Version**: 1.0
**Last Updated**: 2026-02-12
**Print Date**: _______________
**Next Review**: 2026-05-12
