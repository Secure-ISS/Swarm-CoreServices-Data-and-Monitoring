# Production Deployment - Docker Swarm

This directory contains the production-ready Docker Compose configuration for deploying a highly available Distributed PostgreSQL Cluster with Patroni, etcd, HAProxy, PgBouncer, Redis, and full monitoring stack.

## Quick Start

```bash
# 1. Create secrets
../../scripts/deployment/create-secrets.sh

# 2. Deploy stack
../../scripts/deployment/deploy-production.sh

# 3. Verify deployment
docker stack ps postgres-prod
docker service ls
```

## Architecture

- **3-node Patroni HA cluster** - PostgreSQL with automatic failover
- **3-node etcd cluster** - Distributed consensus
- **2 HAProxy load balancers** - Traffic distribution
- **2 PgBouncer connection poolers** - Connection management
- **Redis caching** - Query result caching
- **Prometheus + Grafana** - Monitoring and dashboards
- **Automated backups** - Daily/weekly/monthly backups

## Prerequisites

### Infrastructure

- Docker 20.10+
- Docker Swarm mode initialized
- 8-9 nodes total:
  - 3 manager nodes (etcd + control plane)
  - 3 worker nodes (Patroni PostgreSQL)
  - 2 application nodes (PgBouncer + Redis)

### Node Labels

```bash
# etcd nodes
docker node update --label-add postgres.etcd=etcd-1 node-1
docker node update --label-add postgres.etcd=etcd-2 node-2
docker node update --label-add postgres.etcd=etcd-3 node-3

# Patroni nodes
docker node update --label-add postgres.role=patroni node-4
docker node update --label-add postgres.patroni-id=1 node-4
docker node update --label-add postgres.role=patroni node-5
docker node update --label-add postgres.patroni-id=2 node-5
docker node update --label-add postgres.role=patroni node-6
docker node update --label-add postgres.patroni-id=3 node-6

# Redis node
docker node update --label-add redis.role=master node-7
```

### Storage

```bash
# Create storage directories on each node
mkdir -p /mnt/postgres-cluster/{patroni-1,patroni-2,patroni-3}
mkdir -p /mnt/postgres-cluster/{etcd-1,etcd-2,etcd-3}
mkdir -p /mnt/postgres-cluster/{backups,archives}

# Set permissions
chown -R 999:999 /mnt/postgres-cluster/patroni-*
chown -R 999:999 /mnt/postgres-cluster/etcd-*
chmod 700 /mnt/postgres-cluster/patroni-*
chmod 700 /mnt/postgres-cluster/etcd-*
```

### Secrets

Required Docker secrets (created by `create-secrets.sh`):
- postgres_password
- replication_password
- postgres_mcp_password
- redis_password
- grafana_admin_password
- postgres_ssl_cert
- postgres_ssl_key
- postgres_ssl_ca

## Deployment

### Manual Deployment

```bash
# Deploy stack
docker stack deploy -c docker-compose.yml postgres-prod

# Watch deployment
watch docker stack ps postgres-prod

# Check service status
docker service ls
```

### Automated Deployment

```bash
# Full deployment with validation
../../scripts/deployment/deploy-production.sh

# Skip validation (not recommended)
../../scripts/deployment/deploy-production.sh --skip-validation

# Rollback
../../scripts/deployment/deploy-production.sh --rollback
```

## Access Points

| Service | Endpoint | Port | Credentials |
|---------|----------|------|-------------|
| PostgreSQL (RW) | haproxy | 5432 | postgres / [secret] |
| PostgreSQL (RO) | haproxy | 5433 | postgres / [secret] |
| PgBouncer | pgbouncer | 6432 | postgres / [secret] |
| Redis | redis-master | 6379 | [secret] |
| HAProxy Stats | http://manager:7000 | 7000 | - |
| Patroni API | http://patroni-N:8008 | 8008 | - |
| Prometheus | http://manager:9090 | 9090 | - |
| Grafana | http://manager:3001 | 3001 | admin / [secret] |

## Verification

### Cluster Health

```bash
# Check etcd cluster
docker exec $(docker ps -q -f name=postgres-prod_etcd-1) \
  etcdctl endpoint health --cluster

# Check Patroni cluster
curl http://patroni-1:8008/cluster | jq

# Check replication
psql -h haproxy -U postgres -c "SELECT * FROM pg_stat_replication;"
```

### Connectivity

```bash
# Test write (primary)
psql -h haproxy -U postgres -d distributed_postgres_cluster -c "CREATE TABLE test (id serial);"

# Test read (any node)
psql -h haproxy -p 5433 -U postgres -d distributed_postgres_cluster -c "SELECT * FROM test;"

# Test PgBouncer
psql -h pgbouncer -p 6432 -U postgres -d distributed_postgres_cluster -c "SELECT 1;"

# Test Redis
docker exec $(docker ps -q -f name=redis-master) redis-cli --pass [secret] PING
```

## Monitoring

### Prometheus Targets

```bash
# View all targets
open http://manager:9090/targets

# Key metrics
open http://manager:9090/graph
# Query: pg_stat_database_tup_fetched
# Query: pg_stat_replication_lag_bytes
# Query: patroni_postgres_running
```

### Grafana Dashboards

```bash
open http://manager:3001

# Default dashboards:
# - PostgreSQL Cluster Overview
# - Patroni HA Status
# - Resource Utilization
# - Replication Lag
```

## Operations

### Scaling

```bash
# Scale read replicas
docker service scale postgres-prod_patroni=5

# Scale connection poolers
docker service scale postgres-prod_pgbouncer=4

# Scale load balancers
docker service scale postgres-prod_haproxy=3
```

### Updates

```bash
# Rolling update (Patroni)
docker service update \
  --image ruvnet/ruvector-postgres:new-version \
  --update-parallelism 1 \
  --update-delay 60s \
  postgres-prod_patroni

# Rolling update (HAProxy)
docker service update \
  --update-parallelism 1 \
  --update-delay 10s \
  postgres-prod_haproxy
```

### Failover

```bash
# Planned switchover
docker exec $(docker ps -q -f name=patroni-1) \
  patronictl switchover postgres-cluster-main \
  --master patroni-1 --candidate patroni-2 --force

# Emergency failover
docker exec $(docker ps -q -f name=patroni-2) \
  patronictl failover postgres-cluster-main \
  --candidate patroni-2 --force
```

### Backups

```bash
# Manual backup
docker exec $(docker ps -q -f name=backup-agent) \
  /scripts/backup-patroni.sh

# View backup logs
docker service logs postgres-prod_backup-agent

# List backups
ls -lh /mnt/postgres-cluster/backups/daily/
```

## Troubleshooting

### Service Not Starting

```bash
# Check service logs
docker service logs postgres-prod_patroni-1

# Check service events
docker service ps postgres-prod_patroni-1 --no-trunc

# Check node resources
docker node inspect node-4
```

### Replication Issues

```bash
# Check replication status
psql -h haproxy -U postgres -c "SELECT * FROM pg_stat_replication;"

# Check Patroni cluster
curl http://patroni-1:8008/cluster | jq

# Check replication lag
curl http://patroni-1:8008/patroni | jq '.replication_state'
```

### Connection Issues

```bash
# Check HAProxy status
curl http://haproxy:7000/stats

# Check PgBouncer pools
docker exec $(docker ps -q -f name=pgbouncer) \
  psql -U postgres -p 6432 -d pgbouncer -c "SHOW POOLS;"

# Test direct connection to Patroni
psql -h patroni-1 -U postgres -d distributed_postgres_cluster -c "SELECT 1;"
```

### Performance Issues

```bash
# Check active queries
psql -h haproxy -U postgres -c "
SELECT pid, usename, application_name, state, query
FROM pg_stat_activity
WHERE state = 'active';
"

# Check slow queries
psql -h haproxy -U postgres -c "
SELECT query, calls, total_time, mean_time
FROM pg_stat_statements
ORDER BY total_time DESC LIMIT 10;
"

# Check replication lag
psql -h haproxy -U postgres -c "
SELECT application_name, state,
  pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes,
  extract(epoch FROM (now() - pg_last_xact_replay_timestamp())) AS lag_seconds
FROM pg_stat_replication;
"
```

## Configuration

### Network Segmentation

- **coordinator-net** (10.10.0.0/24) - etcd + Patroni coordination
- **data-net** (10.10.1.0/24) - PostgreSQL replication + data access
- **app-net** (10.10.2.0/24) - Application connections
- **monitoring-net** (10.10.3.0/24) - Metrics collection

### Resource Limits

| Service | CPU Limit | CPU Reserve | Memory Limit | Memory Reserve |
|---------|-----------|-------------|--------------|----------------|
| etcd | 1 vCPU | 0.5 vCPU | 2 GB | 1 GB |
| Patroni | 8 vCPU | 4 vCPU | 32 GB | 16 GB |
| HAProxy | 2 vCPU | 1 vCPU | 2 GB | 1 GB |
| PgBouncer | 2 vCPU | 1 vCPU | 2 GB | 1 GB |
| Redis | 2 vCPU | 1 vCPU | 6 GB | 4 GB |
| Prometheus | 2 vCPU | 1 vCPU | 4 GB | 2 GB |
| Grafana | 1 vCPU | 0.5 vCPU | 2 GB | 1 GB |

### PostgreSQL Parameters

Key tuning parameters (via Patroni):
```yaml
shared_buffers: 8GB
effective_cache_size: 24GB
work_mem: 128MB
maintenance_work_mem: 2GB
max_connections: 500
max_worker_processes: 8
max_parallel_workers: 8
max_parallel_workers_per_gather: 4
```

## High Availability

### Availability SLA

- **Uptime:** 99.95% (4.38 hours downtime/year)
- **RPO:** 0 seconds (synchronous replication)
- **RTO:** <30 seconds (automatic failover)
- **Fault Tolerance:** Survives 1 node failure

### Failover Behavior

1. Patroni detects primary failure (<10 seconds)
2. etcd coordinates leader election
3. Standby promoted to primary (<20 seconds)
4. HAProxy updates routing table
5. Clients reconnect automatically

### Split-Brain Prevention

- etcd quorum consensus (requires 2/3 nodes)
- Patroni DCS locks
- HAProxy health checks
- Network segmentation

## Security

### Encryption

- **In Transit:** TLS 1.3 for all connections
- **At Rest:** AES-256 volume encryption
- **Backups:** AES-256 encrypted backups

### Authentication

- **PostgreSQL:** SCRAM-SHA-256
- **Replication:** Certificate-based
- **Redis:** Password authentication
- **Grafana:** Username/password

### Audit Logging

```sql
-- Enable audit logging
CREATE EXTENSION pgaudit;
ALTER SYSTEM SET pgaudit.log = 'ddl, write, read';
SELECT pg_reload_conf();
```

## Disaster Recovery

### Backup Schedule

- **Daily:** 2:00 AM (7-day retention)
- **Weekly:** Sunday 2:00 AM (4-week retention)
- **Monthly:** 1st of month (12-month retention)
- **WAL:** Continuous archiving (30-day retention)

### Recovery Procedures

```bash
# Point-in-time recovery
../../scripts/backup/restore-pitr.sh --target-time "2024-02-12 14:30:00"

# Full cluster rebuild
../../scripts/backup/restore-full.sh --backup /mnt/postgres-cluster/backups/daily/latest
```

## Cost Estimates

### Cloud Deployment (Monthly)

**AWS:**
- On-demand: $2,810
- 1-year reserved: $1,970 (30% savings)
- 3-year reserved: $1,685 (40% savings)

**GCP:** $3,200-4,000

**Azure:** $3,800-4,800

### On-Premises

- Per server: $25,000-40,000 (one-time)
- Total for 8 servers: $200,000-320,000

## Documentation

- **Complete Guide:** [PRODUCTION_DEPLOYMENT.md](../../docs/architecture/PRODUCTION_DEPLOYMENT.md)
- **Scaling Playbook:** [SCALING_PLAYBOOK.md](../../docs/operations/SCALING_PLAYBOOK.md)
- **Summary:** [DEPLOYMENT_SUMMARY.md](../../docs/architecture/DEPLOYMENT_SUMMARY.md)
- **Patroni HA Design:** [PATRONI_HA_DESIGN.md](../../docs/architecture/PATRONI_HA_DESIGN.md)

## Support

For issues or questions:
1. Check documentation in `/docs/`
2. Review logs: `docker service logs <service-name>`
3. Check Grafana dashboards
4. Consult operations team

## License

See LICENSE file in project root.

---

**Version:** 1.0.0
**Last Updated:** 2026-02-12
**Status:** Production Ready
