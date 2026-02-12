# Patroni Operations Documentation

## Overview

This directory contains comprehensive operational documentation for managing the Patroni high-availability PostgreSQL cluster. These documents cover day-to-day operations, failover procedures, monitoring setup, and emergency response.

---

## Document Index

### 1. [PATRONI_OPERATIONS.md](PATRONI_OPERATIONS.md)

**Comprehensive operations guide covering:**
- Day-to-day operational tasks
- Cluster monitoring procedures
- Health check workflows
- Common troubleshooting scenarios
- Maintenance windows and upgrades
- Backup and recovery procedures
- Performance tuning guidelines

**When to use**: Daily operations, maintenance planning, troubleshooting

---

### 2. [FAILOVER_RUNBOOK.md](FAILOVER_RUNBOOK.md)

**Detailed failover procedures:**
- Automatic failover monitoring
- Manual failover instructions
- Controlled switchover procedures
- Rollback procedures
- Post-failover validation
- Disaster recovery scenarios

**When to use**: Failover events, planned switchovers, disaster recovery

---

### 3. [MONITORING_SETUP.md](MONITORING_SETUP.md)

**Monitoring infrastructure guide:**
- Prometheus metrics endpoints
- Key metrics to watch
- Grafana dashboard setup
- Alert rules and thresholds
- Integration with health check system

**When to use**: Setting up monitoring, configuring alerts, dashboard creation

---

### 4. [PATRONI_QUICK_REFERENCE.md](PATRONI_QUICK_REFERENCE.md)

**One-page reference card:**
- Critical commands
- Emergency procedures
- Troubleshooting flowchart
- Contact escalation
- Monitoring thresholds

**When to use**: Print and keep handy for emergencies, quick command reference

---

## Operational Scripts

### Location
All scripts are located in: `/scripts/patroni/`

### Available Scripts

| Script | Purpose | Usage |
|--------|---------|-------|
| **monitor-cluster.sh** | Real-time cluster monitoring | `./monitor-cluster.sh --watch` |
| **manual-failover.sh** | Controlled switchover/failover | `./manual-failover.sh --switchover --master <node> --candidate <node>` |
| **backup-cluster.sh** | Create cluster backups | `./backup-cluster.sh --cluster coordinator --compress` |
| **restore-cluster.sh** | Restore from backup | `./restore-cluster.sh --backup <path> --node <node> --cluster <name>` |

### Quick Start

```bash
# Real-time monitoring dashboard
./scripts/patroni/monitor-cluster.sh --watch

# Run health check
./scripts/patroni/monitor-cluster.sh --health-check

# Planned switchover
./scripts/patroni/manual-failover.sh \
  --switchover \
  --master coordinator-1 \
  --candidate coordinator-2

# Create backup
export POSTGRES_PASSWORD=your_password
./scripts/patroni/backup-cluster.sh \
  --cluster coordinator \
  --compress \
  --retention-days 7
```

---

## Architecture Overview

### Cluster Topology

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

### Key Components

| Component | Port | Purpose |
|-----------|------|---------|
| **Patroni REST API** | 8008 | Cluster topology, health checks |
| **PostgreSQL** | 5432 | Database connections |
| **etcd** | 2379 | Distributed configuration store |
| **HAProxy** | 5432 | Load balancer entry point |
| **Prometheus** | 9090 | Metrics collection |
| **Grafana** | 3000 | Visualization dashboards |

---

## Common Operational Tasks

### Daily Checklist

```bash
# 1. Check cluster health
patronictl -c /etc/patroni/patroni.yml list

# 2. Verify replication lag
PGPASSWORD=admin psql -h pg-coordinator -U admin -d postgres \
  -c "SELECT * FROM pg_stat_replication;"

# 3. Check for blocking queries
PGPASSWORD=admin psql -h pg-coordinator -U admin -d postgres \
  -c "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock';"

# 4. Review recent alerts
journalctl -u patroni -p err --since "1 hour ago"

# 5. Check etcd cluster health
etcdctl --endpoints=etcd-1:2379,etcd-2:2379,etcd-3:2379 endpoint health
```

### Weekly Tasks

- Review backup success rates
- Analyze query performance trends
- Check disk space utilization
- Review alert frequency
- Update documentation with any changes

### Monthly Tasks

- Test disaster recovery procedures
- Review and update runbooks
- Conduct failover drills
- Analyze performance trends
- Update monitoring dashboards

---

## Emergency Procedures

### 1. No Leader (Cluster Has No Primary)

```bash
# Check cluster status
patronictl list

# Check etcd health
etcdctl endpoint health

# Manual leader promotion (if automatic failover failed)
patronictl failover --master <old-master> --candidate <best-replica> --force
```

### 2. High Replication Lag

```bash
# Check lag
PGPASSWORD=admin psql -h pg-coordinator -U admin -d postgres \
  -c "SELECT * FROM pg_stat_replication;"

# Terminate long-running queries on replica
PGPASSWORD=admin psql -h pg-coordinator-2 -U admin -d postgres \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state = 'active' AND query_start < now() - interval '10 minutes';"

# If lag persists, reinitialize replica
patronictl reinit postgres-cluster-coordinators coordinator-2
```

### 3. etcd Cluster Failure

```bash
# Check etcd status
systemctl status etcd

# Restart etcd
systemctl restart etcd@*

# If restart fails, restore from backup
etcdctl snapshot restore /backups/etcd-latest.db
```

### 4. Split-Brain Scenario

```bash
# 1. STOP - Do not write to any node
patronictl pause

# 2. Identify true leader (check timelines)
patronictl list

# 3. Stop false leaders
systemctl stop patroni@<false-leader>

# 4. Reinitialize from true leader
patronictl reinit postgres-cluster-coordinators <false-leader>

# 5. Resume automatic failover
patronictl resume
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

## Contact Information

### Emergency Contacts

| Role | Contact | Phone | Email |
|------|---------|-------|-------|
| On-Call DBA | _______________ | _______________ | _______________ |
| Security Lead | _______________ | _______________ | _______________ |
| Team Lead | _______________ | _______________ | _______________ |

### Escalation Matrix

| Severity | First Contact | Escalation (15 min) | Executive (30 min) |
|----------|--------------|---------------------|-------------------|
| **Critical** | On-call DBA | Database Manager | VP Engineering |
| **High** | On-call DBA | Team Lead | Database Manager |
| **Medium** | Team Member | Team Lead | N/A |

---

## Additional Resources

### Internal Documentation

- [Architecture Design](../architecture/distributed-postgres-design.md)
- [Deployment Guide](../architecture/DEPLOYMENT_GUIDE.md)
- [Security Incident Response](../security/incident-response-runbook.md)
- [Performance Testing](../performance/PERFORMANCE_TESTING_GUIDE.md)

### External Resources

- [Patroni Documentation](https://patroni.readthedocs.io/)
- [PostgreSQL High Availability](https://www.postgresql.org/docs/current/high-availability.html)
- [etcd Documentation](https://etcd.io/docs/)
- [Prometheus Best Practices](https://prometheus.io/docs/practices/)

---

## Maintenance Schedule

| Task | Frequency | Last Performed | Next Due |
|------|-----------|----------------|----------|
| Failover Drill | Monthly | _______________ | _______________ |
| Backup Validation | Weekly | _______________ | _______________ |
| DR Test | Quarterly | _______________ | _______________ |
| Documentation Review | Quarterly | 2026-02-12 | 2026-05-12 |
| Security Audit | Quarterly | _______________ | _______________ |

---

## Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-02-12 | Database Operations Team | Initial creation |

---

**Maintained By**: Database Operations Team
**Last Updated**: 2026-02-12
**Review Schedule**: Quarterly
**Next Review**: 2026-05-12
