# Production Readiness Guide

This document provides a comprehensive checklist and procedures for validating production readiness of the Distributed PostgreSQL Cluster with RuVector.

## Table of Contents

1. [Overview](#overview)
2. [Automated Validation](#automated-validation)
3. [Infrastructure Requirements](#infrastructure-requirements)
4. [Database Configuration](#database-configuration)
5. [Security Hardening](#security-hardening)
6. [Monitoring & Alerting](#monitoring--alerting)
7. [Performance Validation](#performance-validation)
8. [High Availability](#high-availability)
9. [Disaster Recovery](#disaster-recovery)
10. [Pre-Launch Checklist](#pre-launch-checklist)
11. [Post-Launch Procedures](#post-launch-procedures)

## Overview

### Readiness Criteria

A production-ready cluster must meet:

- **100% of critical requirements** (blockers)
- **≥90% of recommended requirements** (warnings)
- **Overall readiness score ≥90%**

### Validation Levels

| Level | Score | Status | Action Required |
|-------|-------|--------|----------------|
| 🟢 Ready | ≥90% | No blockers | Deploy to production |
| 🟡 Ready with Warnings | 75-89% | No blockers | Address warnings, then deploy |
| 🔴 Not Ready | <75% | Has blockers | Fix blockers before deployment |

## Automated Validation

### Running the Readiness Check

```bash
# Full validation
./scripts/production-readiness-check.sh

# Review detailed log
cat production-readiness-YYYYMMDD-HHMMSS.log
```

### Exit Codes

- `0` = Production ready (all checks passed)
- `1` = Not ready (critical failures)
- `2` = Ready with warnings

### Interpreting Results

The script validates 6 major categories:

1. **Infrastructure** - Docker, Swarm, networking, storage
2. **Database** - PostgreSQL, RuVector, configuration, replication
3. **Security** - SSL/TLS, secrets, firewall, audit logging
4. **Monitoring** - Prometheus, Grafana, alerts, notifications
5. **Performance** - Benchmarks, connection pools, resource usage
6. **High Availability** - Patroni, failover, backups, DR

## Infrastructure Requirements

### ✅ Critical Requirements

#### Docker & Container Runtime

```bash
# Check Docker version (≥20.10)
docker --version

# Check Docker Compose (≥2.0)
docker compose version

# Verify Docker is running
docker info
```

**Requirement**: Docker 20.10+ and Docker Compose 2.0+

#### Docker Swarm Mode (for HA)

```bash
# Initialize swarm
docker swarm init --advertise-addr <MANAGER_IP>

# Verify swarm status
docker info | grep Swarm

# List nodes
docker node ls
```

**Requirement**: ≥3 nodes for production HA (1 manager, 2+ workers)

#### Network Configuration

```bash
# Create overlay network
docker network create --driver overlay --attachable dpg-network

# Verify network
docker network inspect dpg-network
```

**Requirement**: Overlay network for multi-node communication

#### Storage Capacity

```bash
# Check available space
df -h /var/lib/docker

# Check volume usage
docker system df -v
```

**Requirements**:
- **Minimum**: 20GB available
- **Recommended**: 50GB+ available
- **Production**: 100GB+ with monitoring

#### SSL/TLS Certificates

```bash
# Generate certificates
./scripts/generate_ssl_certs.sh

# Verify certificate validity
openssl x509 -in config/ssl/server.crt -noout -dates

# Check expiry
openssl x509 -in config/ssl/server.crt -noout -enddate
```

**Requirement**: Valid SSL certificates with ≥30 days until expiry

### 🟡 Recommended Requirements

- **Load balancer**: HAProxy or nginx for connection pooling
- **Shared storage**: NFS/Ceph for backup/restore across nodes
- **Monitoring nodes**: Dedicated nodes for Prometheus/Grafana

## Database Configuration

### ✅ Critical Requirements

#### PostgreSQL Version

```bash
# Check PostgreSQL version (≥15.0)
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT version();"
```

**Requirement**: PostgreSQL 15.0+ with RuVector 2.0+

#### RuVector Extension

```bash
# Verify RuVector installation
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'ruvector';"

# Test vector operations
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT '[1,2,3]'::ruvector <-> '[1,2,4]'::ruvector AS distance;"
```

**Requirement**: RuVector 2.0.0+ installed and functional

#### Configuration Parameters

Essential PostgreSQL settings:

```sql
-- Connection settings
max_connections = 100              -- Support 100 concurrent connections
superuser_reserved_connections = 3 -- Reserve for admin access

-- Memory settings (for 8GB RAM)
shared_buffers = 2GB               -- 25% of RAM
effective_cache_size = 6GB         -- 75% of RAM
work_mem = 32MB                    -- Per-operation memory
maintenance_work_mem = 512MB       -- For VACUUM, CREATE INDEX

-- WAL settings
wal_buffers = 16MB
min_wal_size = 1GB
max_wal_size = 4GB
wal_compression = on

-- Checkpoint settings
checkpoint_completion_target = 0.9
checkpoint_timeout = 15min

-- Query planning
random_page_cost = 1.1             -- For SSD storage
effective_io_concurrency = 200     -- For SSD storage

-- Logging
logging_collector = on
log_destination = 'stderr'
log_statement = 'ddl'              -- Log DDL changes
log_min_duration_statement = 1000  -- Log slow queries (>1s)
log_line_prefix = '%m [%p] %u@%d '
```

**Validate configuration**:

```bash
# Check critical settings
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "
SELECT name, setting, unit, context
FROM pg_settings
WHERE name IN (
    'max_connections',
    'shared_buffers',
    'effective_cache_size',
    'work_mem',
    'maintenance_work_mem',
    'wal_buffers',
    'random_page_cost',
    'effective_io_concurrency'
);"
```

#### Replication Setup (Patroni HA)

```bash
# Check replication status
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "
SELECT client_addr, state, sync_state, replay_lag
FROM pg_stat_replication;"

# Check replication lag
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "
SELECT
    CASE
        WHEN pg_is_in_recovery() THEN
            EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::INTEGER
        ELSE 0
    END AS replication_lag_seconds;"
```

**Requirement**: Replication lag <5 seconds for read replicas

#### Connection Pool Configuration

Validate pool settings in `src/db/pool.py`:

```python
# Project database pool
maxconn: 40  # Support 35+ concurrent agents

# Shared database pool
maxconn: 15  # Support shared knowledge queries
```

**Test connection pool**:

```bash
python3 scripts/test_pool_capacity.py
```

**Requirement**: 100% success rate with 35+ concurrent connections

#### Backup System

```bash
# Verify backup script
ls -l scripts/deployment/backup-distributed.sh

# Test backup creation
./scripts/deployment/backup-distributed.sh

# Verify backup file
ls -lh /var/backups/postgres/
```

**Requirement**: Automated backups with retention policy

### 🟡 Recommended Requirements

- **Point-in-time recovery (PITR)**: WAL archiving enabled
- **Backup encryption**: Encrypt backups at rest
- **Offsite backups**: Copy backups to remote location
- **Backup validation**: Regular restore testing

## Security Hardening

### ✅ Critical Requirements

#### Strong Authentication

```bash
# Change default passwords
# Edit .env file
POSTGRES_PASSWORD=<strong-random-password>
SHARED_KNOWLEDGE_PASSWORD=<strong-random-password>
PGADMIN_PASSWORD=<strong-random-password>

# Use Docker secrets for production
./scripts/deployment/create-secrets.sh
```

**Requirements**:
- Unique, complex passwords (≥16 characters)
- No default passwords in production
- Use Docker secrets or vault for credential management

#### SSL/TLS Enforcement

```bash
# Enable SSL in .env
RUVECTOR_SSLMODE=require
SHARED_KNOWLEDGE_SSLMODE=require

# For certificate validation
RUVECTOR_SSLMODE=verify-full
RUVECTOR_SSLROOTCERT=/path/to/ca.crt
```

**Verify SSL connections**:

```bash
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "
SELECT pid, usename, ssl, cipher, bits
FROM pg_stat_ssl
JOIN pg_stat_activity USING (pid)
WHERE datname = 'distributed_postgres_cluster';"
```

**Requirement**: All connections use SSL/TLS

#### Firewall Rules

```bash
# Ubuntu/Debian (UFW)
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp    # SSH
sudo ufw allow 5432/tcp  # PostgreSQL (restrict to app network)
sudo ufw allow 9090/tcp  # Prometheus (internal only)
sudo ufw allow 3000/tcp  # Grafana (internal only)
sudo ufw enable

# RHEL/CentOS (firewalld)
sudo firewall-cmd --permanent --add-service=postgresql
sudo firewall-cmd --permanent --add-port=9090/tcp
sudo firewall-cmd --permanent --add-port=3000/tcp
sudo firewall-cmd --reload
```

**Requirement**: Firewall configured with principle of least privilege

#### Database User Permissions

```sql
-- Verify user privileges
SELECT usename, usecreatedb, usesuper, userepl
FROM pg_user;

-- Application user should NOT be superuser
-- ALTER USER dpg_cluster NOSUPERUSER;

-- Grant only required permissions
GRANT CONNECT ON DATABASE distributed_postgres_cluster TO dpg_cluster;
GRANT USAGE ON SCHEMA public, claude_flow TO dpg_cluster;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public, claude_flow TO dpg_cluster;
```

**Requirement**: Principle of least privilege for application users

#### Audit Logging

```sql
-- Enable audit logging
ALTER SYSTEM SET log_statement = 'ddl';
ALTER SYSTEM SET log_min_duration_statement = 1000;
ALTER SYSTEM SET log_connections = on;
ALTER SYSTEM SET log_disconnections = on;
SELECT pg_reload_conf();

-- Verify settings
SHOW log_statement;
SHOW log_min_duration_statement;
```

**Requirement**: DDL and slow queries logged

### 🟡 Recommended Requirements

- **Network segmentation**: Separate networks for database, app, monitoring
- **Intrusion detection**: fail2ban or similar
- **Security scanning**: Regular CVE scans with Trivy/Grype
- **Two-factor authentication**: For admin access
- **Certificate rotation**: Automated certificate renewal

## Monitoring & Alerting

### ✅ Critical Requirements

#### Prometheus Setup

```bash
# Verify Prometheus configuration
cat config/prometheus/prometheus.yml

# Check Prometheus is running
docker ps | grep prometheus

# Verify Prometheus is scraping targets
curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, state: .health}'
```

**Requirement**: Prometheus scraping all targets successfully

#### Grafana Dashboards

```bash
# Verify dashboards exist
ls -l config/grafana/dashboards/

# Access Grafana
open http://localhost:3000

# Import dashboards
# Grafana UI > Dashboards > Import > Upload JSON
```

**Required dashboards**:
- PostgreSQL Overview
- RuVector Performance
- System Resources
- Replication Status

#### Alert Rules

```bash
# Verify alert files
ls -l config/prometheus/alerts/

# Check alerts are loaded
curl http://localhost:9090/api/v1/rules | jq '.data.groups[].rules[] | {alert: .name, state: .state}'
```

**Critical alerts**:
- Database down
- Replication lag >30s
- Disk space <10%
- Connection pool exhaustion
- Query latency >500ms
- Memory usage >90%

#### Alertmanager Configuration

```bash
# Verify Alertmanager config
cat config/alertmanager/config.yml

# Test notifications
amtool alert add alertname=test severity=warning --alertmanager.url=http://localhost:9093
```

**Requirement**: At least one notification channel configured and tested

### 🟡 Recommended Requirements

- **Log aggregation**: ELK/Loki for centralized logging
- **Tracing**: Jaeger/Zipkin for distributed tracing
- **Custom metrics**: Application-specific metrics
- **Dashboard automation**: Terraform/Ansible for dashboard provisioning
- **Alert escalation**: PagerDuty/Opsgenie integration

## Performance Validation

### ✅ Critical Requirements

#### Baseline Performance Metrics

```bash
# Run comprehensive benchmark
python3 scripts/benchmark/quick_benchmark.py

# Expected results:
# - Simple query: <10ms
# - Vector search: <50ms
# - HNSW index search: <5ms
# - Connection pool: 100% success at 35+ agents
```

**Requirements**:
- Vector search: <50ms p95
- Simple queries: <10ms p95
- Connection pool: 100% success at peak load

#### Connection Pool Load Testing

```bash
# Test with 40 concurrent agents
python3 scripts/test_pool_capacity.py

# Expected: 100% success rate
```

**Requirement**: Zero connection failures under peak load

#### Resource Utilization

```bash
# Monitor container resources
docker stats --no-stream

# Check PostgreSQL memory
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "
SELECT
    pg_size_pretty(pg_database_size(current_database())) AS db_size,
    pg_size_pretty(pg_total_relation_size('memory_entries')) AS memory_entries_size,
    pg_size_pretty(pg_total_relation_size('embeddings')) AS embeddings_size;"
```

**Requirements**:
- PostgreSQL CPU: <70% average
- PostgreSQL Memory: <80% of limit
- Disk I/O: <80% saturation

#### Index Performance

```bash
# Check HNSW index usage
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "
SELECT
    schemaname,
    tablename,
    indexname,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_user_indexes
WHERE indexname LIKE '%hnsw%'
ORDER BY idx_scan DESC;"
```

**Requirement**: HNSW indexes used for vector searches

### 🟡 Recommended Requirements

- **Query optimization**: Use EXPLAIN ANALYZE for slow queries
- **Index maintenance**: Regular REINDEX for fragmentation
- **Vacuuming**: Automated VACUUM schedule
- **Connection pooling**: PgBouncer for additional pooling layer
- **Caching**: Redis for frequently accessed data

## High Availability

### ✅ Critical Requirements

#### Patroni Cluster Health

```bash
# Check Patroni cluster status
patronictl -c /etc/patroni/patroni.yml list

# Expected output:
# + Cluster: dpg-cluster
# | Member    | Host       | Role    | State   | Lag in MB |
# +-----------+------------+---------+---------+-----------+
# | postgres1 | 10.0.1.10  | Leader  | running |         0 |
# | postgres2 | 10.0.1.11  | Replica | running |         0 |
# | postgres3 | 10.0.1.12  | Replica | running |         0 |
```

**Requirement**: All nodes healthy, replication lag <10MB

#### Automatic Failover

```bash
# Simulate leader failure
docker stop dpg-postgres1

# Verify automatic failover (should take <30s)
patronictl -c /etc/patroni/patroni.yml list

# New leader should be elected
```

**Requirement**: Failover completes in <30 seconds with zero data loss

#### Backup Verification

```bash
# List recent backups
ls -lh /var/backups/postgres/ | head -10

# Test backup restoration (non-production environment)
./scripts/deployment/restore-distributed.sh /var/backups/postgres/backup-latest.sql.gz

# Verify restored data
docker exec dpg-postgres-test psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT COUNT(*) FROM memory_entries;"
```

**Requirement**: Successful backup restoration within RPO/RTO targets

### 🟡 Recommended Requirements

- **Geographic distribution**: Nodes in multiple availability zones
- **Automated failover testing**: Regular chaos engineering exercises
- **Backup encryption**: Encrypt backups with GPG/KMS
- **Multi-region replication**: For disaster recovery
- **Quorum-based consensus**: Prevent split-brain scenarios

## Disaster Recovery

### Recovery Objectives

| Metric | Target | Critical Systems |
|--------|--------|-----------------|
| **RPO** (Recovery Point Objective) | <5 minutes | All data |
| **RTO** (Recovery Time Objective) | <15 minutes | Database cluster |
| **RTO** | <30 minutes | Full stack with monitoring |

### Disaster Recovery Procedures

#### 1. Total Cluster Failure

**Scenario**: All database nodes are down

**Recovery Steps**:

```bash
# 1. Restore from latest backup
./scripts/deployment/restore-distributed.sh /var/backups/postgres/backup-latest.sql.gz

# 2. Reinitialize Patroni cluster
./scripts/deployment/initialize-cluster.sh

# 3. Verify cluster health
patronictl -c /etc/patroni/patroni.yml list

# 4. Restore application connections
docker compose -f docker-compose.yml restart app

# 5. Verify data integrity
python3 scripts/validate_data_integrity.py
```

#### 2. Data Corruption

**Scenario**: Corrupted data detected in database

**Recovery Steps**:

```bash
# 1. Identify corruption extent
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "
SELECT * FROM memory_entries WHERE embedding IS NULL OR LENGTH(embedding::text) < 10;"

# 2. Restore from point-in-time backup
./scripts/deployment/restore-distributed.sh --pitr "2024-02-12 10:00:00"

# 3. Verify restored data
python3 scripts/validate_data_integrity.py

# 4. Replay WAL logs if needed
pg_waldump --start <start_lsn> --end <end_lsn>
```

#### 3. Network Partition

**Scenario**: Split-brain between database nodes

**Recovery Steps**:

```bash
# 1. Identify the true leader
patronictl -c /etc/patroni/patroni.yml list

# 2. Reinitialize failed nodes
patronictl -c /etc/patroni/patroni.yml reinit postgres2

# 3. Verify replication is restored
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT * FROM pg_stat_replication;"
```

### Testing Disaster Recovery

**Quarterly DR Test Schedule**:

1. **Q1**: Backup restoration test
2. **Q2**: Failover simulation
3. **Q3**: Full cluster rebuild from backup
4. **Q4**: Multi-region failover (if applicable)

**Document each test**:

```bash
# Create DR test report
cat > dr-test-$(date +%Y%m%d).md << EOF
# Disaster Recovery Test Report

**Date**: $(date)
**Type**: Backup Restoration Test
**Outcome**: PASS/FAIL
**RPO Achieved**: X minutes
**RTO Achieved**: X minutes

## Test Steps
1. ...

## Issues Encountered
- ...

## Recommendations
- ...
EOF
```

## Pre-Launch Checklist

### 1 Week Before Launch

- [ ] Run full production readiness validation
- [ ] Review and address all warnings
- [ ] Test disaster recovery procedures
- [ ] Verify backup restoration
- [ ] Load test with 2x expected traffic
- [ ] Security audit and penetration testing
- [ ] Update documentation
- [ ] Train operations team

### 3 Days Before Launch

- [ ] Freeze code (no new features)
- [ ] Final production readiness check
- [ ] Verify monitoring dashboards
- [ ] Test all alert channels
- [ ] Schedule deployment window
- [ ] Notify stakeholders
- [ ] Prepare rollback plan

### Day of Launch

- [ ] Final health check
- [ ] Verify backups are current
- [ ] Deploy to production
- [ ] Smoke test critical paths
- [ ] Monitor dashboards (first 4 hours)
- [ ] Verify alert silence (no false alarms)
- [ ] Document any issues

### Post-Launch (First 24 Hours)

- [ ] Continuous monitoring
- [ ] Review performance metrics
- [ ] Check error rates
- [ ] Verify backup completion
- [ ] Collect user feedback
- [ ] Document lessons learned

## Post-Launch Procedures

### Daily Operations

```bash
# Morning health check
./scripts/production-readiness-check.sh

# Review overnight alerts
curl -s http://localhost:9093/api/v2/alerts | jq '.[] | {alertname: .labels.alertname, state: .status.state}'

# Check backup status
ls -lh /var/backups/postgres/ | head -3

# Monitor key metrics
curl -s http://localhost:9090/api/v1/query?query=up | jq '.data.result[] | {job: .metric.job, value: .value[1]}'
```

### Weekly Operations

```bash
# Review performance trends
# - Grafana dashboards for weekly trends
# - Identify performance degradation
# - Plan capacity adjustments

# Security updates
docker images | grep ruvector
docker pull ruvnet/ruvector-postgres:latest

# Backup verification
./scripts/deployment/restore-distributed.sh --dry-run
```

### Monthly Operations

```bash
# Capacity planning review
# - Review resource utilization trends
# - Project 3-month capacity needs
# - Plan infrastructure scaling

# Disaster recovery test
./scripts/deployment/dr-test.sh

# Security audit
./scripts/security/audit.sh

# Performance optimization
EXPLAIN ANALYZE <slow-queries>
```

### Quarterly Operations

- Strategic review of architecture
- Technology upgrade planning
- Disaster recovery full test
- Business continuity review
- Staff training and knowledge transfer

## Troubleshooting

### Common Issues

#### Database Connection Failures

```bash
# Check database is running
docker ps | grep postgres

# Check connection pool
docker logs dpg-postgres-dev | tail -50

# Verify credentials
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT 1;"
```

#### Slow Queries

```bash
# Identify slow queries
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "
SELECT
    query,
    calls,
    total_exec_time,
    mean_exec_time,
    max_exec_time
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;"

# Analyze query plan
EXPLAIN (ANALYZE, BUFFERS) <slow-query>;
```

#### Replication Lag

```bash
# Check replication status
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT * FROM pg_stat_replication;"

# Identify lag causes
# - Network issues
# - Long-running transactions
# - Checkpoint delays
```

## Additional Resources

- [Deployment Guide](deployment/DEPLOYMENT_GUIDE.md)
- [Patroni HA Design](docs/architecture/PATRONI_HA_DESIGN.md)
- [Failover Runbook](docs/operations/FAILOVER_RUNBOOK.md)
- [Monitoring Guide](docs/operations/MONITORING.md)
- [Performance Tuning](docs/operations/PERFORMANCE_TUNING.md)

## Support

For issues or questions:

1. Check documentation in `docs/`
2. Review runbooks in `docs/operations/`
3. Contact: ops-team@example.com
4. Emergency: on-call rotation

---

**Document Version**: 1.0
**Last Updated**: 2026-02-12
**Review Cycle**: Quarterly
