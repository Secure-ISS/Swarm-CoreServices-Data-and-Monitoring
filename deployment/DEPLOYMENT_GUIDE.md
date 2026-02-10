# Complete Deployment Guide - Distributed PostgreSQL Mesh

This guide covers the complete Docker Swarm deployment of a distributed PostgreSQL cluster with RuVector support, connection pooling, automated backups, and health monitoring.

## 📦 Deployment Package Contents

### 1. Docker Swarm Stack (`deployment/docker-swarm/`)

**Main Stack File:**
- `stack.yml` - Complete service definitions for:
  - 1 Coordinator node (query router)
  - 3 Worker nodes (data storage)
  - 2 PgBouncer instances (connection pooling)
  - 1 Health monitor service
  - 1 Backup agent service

**Configuration Files:**
- `configs/coordinator.conf` - PostgreSQL config optimized for coordination
- `configs/worker.conf` - PostgreSQL config optimized for data storage
- `configs/pgbouncer.ini` - Connection pooler configuration

### 2. Komodo MCP Integration (`deployment/komodo-mcp/`)

**MCP Server Definition:**
- `postgres-mesh-mcp.json` - Complete MCP tool definitions for:
  - Cluster deployment and scaling
  - Health monitoring
  - Backup and restore operations
  - Configuration management
  - Failover and rebalancing

**Available MCP Tools:**
1. `postgres_mesh_deploy` - Deploy the cluster
2. `postgres_mesh_scale_workers` - Scale worker nodes
3. `postgres_mesh_add_worker` - Add individual worker
4. `postgres_mesh_remove_worker` - Remove worker safely
5. `postgres_mesh_health_check` - Comprehensive health check
6. `postgres_mesh_backup` - Distributed backup
7. `postgres_mesh_restore` - Restore from backup
8. `postgres_mesh_config_update` - Update configurations
9. `postgres_mesh_status` - Get cluster status
10. `postgres_mesh_failover` - Manual failover
11. `postgres_mesh_rebalance` - Data rebalancing

### 3. Deployment Scripts (`scripts/deployment/`)

**Shell Scripts:**
1. `initialize-cluster.sh` - Complete cluster initialization
2. `add-worker.sh` - Add new worker node
3. `remove-worker.sh` - Safely remove worker
4. `backup-distributed.sh` - Distributed backup with parallel processing
5. `restore-distributed.sh` - Restore with point-in-time recovery
6. `health-check.sh` - Manual health check with multiple levels

**Python Scripts:**
1. `health-monitor.py` - Continuous monitoring service with alerting

## 🚀 Quick Start Deployment

### Step 1: Prerequisites

```bash
# Install Docker (if not already installed)
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh

# Initialize Docker Swarm
docker swarm init --advertise-addr $(hostname -I | awk '{print $1}')

# (Optional) Add worker nodes
# On worker machines:
docker swarm join --token <token> <manager-ip>:2377
```

### Step 2: Deploy the Cluster

```bash
cd deployment/docker-swarm
chmod +x ../../scripts/deployment/*.sh

# Initialize and deploy (3 workers by default)
../../scripts/deployment/initialize-cluster.sh postgres-mesh 3
```

**What this does:**
1. ✅ Checks prerequisites (Docker, Swarm)
2. ✅ Creates Docker secrets for passwords
3. ✅ Labels nodes for service placement
4. ✅ Creates necessary directories and configs
5. ✅ Deploys the complete stack
6. ✅ Waits for services to be ready
7. ✅ Verifies cluster health
8. ✅ Displays connection information

### Step 3: Verify Deployment

```bash
# Check stack status
docker stack services postgres-mesh

# Run health check
../../scripts/deployment/health-check.sh postgres-mesh standard

# View health monitor logs
docker service logs postgres-mesh_health-monitor --tail 50
```

### Step 4: Connect to the Cluster

```bash
# Get credentials
cat .secrets

# Connect via PgBouncer (recommended)
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster

# Or connect directly to coordinator
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster
```

## 🏗️ Architecture Overview

```
┌────────────────────────────────────────────────────────┐
│                   Docker Swarm                         │
│                                                        │
│  ┌──────────────────────────────────────────────┐   │
│  │         Overlay Network (Encrypted)          │   │
│  │          10.0.10.0/24                        │   │
│  │                                              │   │
│  │  ┌────────────┐      ┌─────────────┐       │   │
│  │  │ PgBouncer  │◄─────┤Load Balancer│       │   │
│  │  │  (2 pods)  │      └─────────────┘       │   │
│  │  └─────┬──────┘                             │   │
│  │        │                                    │   │
│  │  ┌─────▼──────────┐                        │   │
│  │  │  Coordinator   │                        │   │
│  │  │  (Manager)     │                        │   │
│  │  └─────┬──────────┘                        │   │
│  │        │                                    │   │
│  │  ┌─────┴──────┬──────────┬──────────┐    │   │
│  │  │            │          │          │    │   │
│  │  ▼            ▼          ▼          ▼    │   │
│  │ Worker-1   Worker-2  Worker-3  Worker-N  │   │
│  │ (Data)     (Data)    (Data)    (Data)    │   │
│  │                                            │   │
│  └────────────────────────────────────────────┘   │
│                                                    │
│  Support Services:                                 │
│  ├─ Health Monitor (continuous monitoring)        │
│  └─ Backup Agent (scheduled backups)              │
└────────────────────────────────────────────────────┘
```

## 📊 Service Specifications

### Coordinator Node

**Resources:**
- CPU: 2-4 cores (reserved: 2, limit: 4)
- Memory: 4-8 GB (reserved: 4GB, limit: 8GB)
- Storage: Local volume (scalable)

**Configuration:**
- max_connections: 500
- shared_buffers: 4GB
- effective_cache_size: 12GB
- Replication: Enabled
- RuVector: Enabled with JIT

**Responsibilities:**
- Query routing and distribution
- Metadata management
- Replication coordination
- Connection management

### Worker Nodes

**Resources:**
- CPU: 1-2 cores (reserved: 1, limit: 2)
- Memory: 2-4 GB (reserved: 2GB, limit: 4GB)
- Storage: Dedicated volume per worker

**Configuration:**
- max_connections: 200
- shared_buffers: 2GB
- effective_cache_size: 6GB
- Hot standby: Enabled
- Replication: Enabled

**Responsibilities:**
- Data storage and retrieval
- Query processing
- Data replication
- Index management

### Connection Pooler (PgBouncer)

**Resources:**
- CPU: 0.5-1 core
- Memory: 512MB-1GB
- Replicas: 2 (load balanced)

**Configuration:**
- Pool mode: Transaction
- max_client_conn: 1000
- default_pool_size: 25
- Timeouts: Configured for optimal performance

**Responsibilities:**
- Connection pooling and reuse
- Load balancing
- Connection limit enforcement
- Client connection management

### Health Monitor

**Resources:**
- CPU: 0.25 cores
- Memory: 128-256MB

**Monitoring:**
- Coordinator health and metrics
- Worker health and status
- Connection pooling status
- Performance metrics
- Real-time alerting

### Backup Agent

**Resources:**
- CPU: 0.5-1 core
- Memory: 512MB-1GB

**Features:**
- Scheduled backups (cron)
- Full and incremental backups
- Parallel backup processing
- Compression support
- Backup retention management

## 🔧 Management Operations

### Scaling Operations

**Add Worker Node:**
```bash
# Add worker-4
../../scripts/deployment/add-worker.sh postgres-mesh worker-4

# Add worker with specific node placement
../../scripts/deployment/add-worker.sh postgres-mesh worker-4 "node.hostname==worker-node-1"
```

**Remove Worker Node:**
```bash
# Graceful removal with 5-minute drain timeout
../../scripts/deployment/remove-worker.sh postgres-mesh worker-4 300

# Force removal
../../scripts/deployment/remove-worker.sh postgres-mesh worker-4 60
```

**Scale PgBouncer:**
```bash
# Scale to 3 replicas
docker service scale postgres-mesh_pgbouncer=3
```

### Backup Operations

**Create Full Backup:**
```bash
# Full backup with zstd compression
../../scripts/deployment/backup-distributed.sh postgres-mesh full zstd
```

**Create Incremental Backup:**
```bash
# Incremental backup
../../scripts/deployment/backup-distributed.sh postgres-mesh incremental zstd
```

**List Backups:**
```bash
ls -lh backups/
cat backups/backup-*/manifest.json | jq
```

**Restore from Backup:**
```bash
# Full restore
../../scripts/deployment/restore-distributed.sh postgres-mesh backups/backup-postgres-mesh-full-20260210-105500 full

# Point-in-time restore
../../scripts/deployment/restore-distributed.sh postgres-mesh backups/backup-postgres-mesh-full-20260210-105500 point-in-time
```

### Health Check Operations

**Manual Health Check:**
```bash
# Basic check
../../scripts/deployment/health-check.sh postgres-mesh basic

# Standard check (default)
../../scripts/deployment/health-check.sh postgres-mesh standard

# Comprehensive check with performance metrics
../../scripts/deployment/health-check.sh postgres-mesh comprehensive
```

**View Continuous Monitoring:**
```bash
# View health monitor logs
docker service logs -f postgres-mesh_health-monitor

# View health reports
docker exec $(docker ps -q -f name=health-monitor) cat /logs/health-report-$(date +%Y%m%d).json | jq
```

### Configuration Updates

**Update Coordinator Configuration:**
```bash
# Edit config
vim configs/coordinator.conf

# Recreate config
docker config rm coordinator_config
docker config create coordinator_config configs/coordinator.conf

# Update service (rolling update)
docker service update --config-rm coordinator_config \
                      --config-add coordinator_config \
                      --force \
                      postgres-mesh_coordinator
```

**Update Worker Configuration:**
```bash
# Similar process for worker config
docker config rm worker_config
docker config create worker_config configs/worker.conf

# Update all workers
docker service update --config-rm worker_config \
                      --config-add worker_config \
                      --force \
                      postgres-mesh_worker-1

docker service update --config-rm worker_config \
                      --config-add worker_config \
                      --force \
                      postgres-mesh_worker-2

# Repeat for each worker
```

## 🔐 Security Best Practices

### Secrets Management

1. **Rotate secrets regularly:**
```bash
# Generate new password
NEW_PASSWORD=$(openssl rand -base64 32)

# Create new secret
echo "$NEW_PASSWORD" | docker secret create postgres_password_v2 -

# Update services
docker service update --secret-rm postgres_password \
                      --secret-add postgres_password_v2 \
                      postgres-mesh_coordinator
```

2. **Secure secrets file:**
```bash
chmod 600 .secrets
chown root:root .secrets
```

3. **Use external secrets management** (Vault, AWS Secrets Manager, etc.)

### Network Security

1. **Encrypted overlay network** - All traffic encrypted by default
2. **Network isolation** - Services only accessible within mesh
3. **Port exposure** - Minimal ports exposed (5432, 6432 only)

### Access Control

1. **Update pg_hba.conf** for fine-grained access:
```bash
# Add to coordinator init script
cat >> /var/lib/postgresql/data/pgdata/pg_hba.conf <<EOF
# Custom access rules
host    all    all    10.0.10.0/24    md5
host    all    all    172.16.0.0/12   reject
EOF
```

2. **Implement SCRAM-SHA-256** authentication:
```sql
ALTER SYSTEM SET password_encryption = 'scram-sha-256';
SELECT pg_reload_conf();
```

## 📈 Performance Tuning

### PostgreSQL Tuning

**Coordinator tuning** (`configs/coordinator.conf`):
```ini
# Increase for high-connection workloads
max_connections = 1000

# Adjust based on available RAM (25% of total RAM)
shared_buffers = 8GB

# 75% of total RAM
effective_cache_size = 24GB

# Per-query memory
work_mem = 128MB
```

**Worker tuning** (`configs/worker.conf`):
```ini
# Increase for more parallel queries
max_worker_processes = 8
max_parallel_workers = 8
max_parallel_workers_per_gather = 4

# Enable JIT for complex queries
jit = on
jit_above_cost = 100000
```

### PgBouncer Tuning

**For high-throughput** (`configs/pgbouncer.ini`):
```ini
# Increase pool sizes
default_pool_size = 50
max_client_conn = 2000

# Adjust timeouts
server_idle_timeout = 300
query_timeout = 600
```

### RuVector Optimization

```sql
-- Adjust HNSW parameters for better performance
ALTER INDEX idx_embeddings SET (hnsw_ef_search = 200);

-- Increase m for better recall (rebuild required)
CREATE INDEX idx_embeddings_v2 ON embeddings
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 32, ef_construction = 200);
```

## 🐛 Troubleshooting Guide

### Common Issues

**1. Services Won't Start**
```bash
# Check service status
docker service ps postgres-mesh_coordinator --no-trunc

# Check logs
docker service logs postgres-mesh_coordinator --tail 100

# Check node availability
docker node ls
```

**2. Connection Refused**
```bash
# Check if services are running
docker stack services postgres-mesh

# Test network connectivity
docker run --rm --network postgres-mesh_postgres_mesh postgres:latest \
  pg_isready -h pg-coordinator -U dpg_cluster

# Check firewall rules
iptables -L -n | grep 5432
```

**3. Replication Lag**
```bash
# Check replication status
docker exec <coordinator-container> psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT * FROM pg_stat_replication;"

# Check replication lag
docker exec <coordinator-container> psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT client_addr, state, sync_state,
   pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
   FROM pg_stat_replication;"
```

**4. Disk Space Issues**
```bash
# Check disk usage per service
for service in coordinator worker-1 worker-2 worker-3; do
  echo "=== $service ==="
  docker exec $(docker ps -q -f name=${service}) df -h /var/lib/postgresql/data
done

# Check volume sizes
docker system df -v | grep postgres-mesh
```

**5. Performance Degradation**
```bash
# Run comprehensive health check
../../scripts/deployment/health-check.sh postgres-mesh comprehensive

# Check for slow queries
docker exec <coordinator-container> psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT pid, now() - query_start AS duration, state, query
   FROM pg_stat_activity
   WHERE state = 'active' AND now() - query_start > interval '1 minute'
   ORDER BY duration DESC;"

# Check for locks
docker exec <coordinator-container> psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT blocked_locks.pid AS blocked_pid,
   blocked_activity.usename AS blocked_user,
   blocking_locks.pid AS blocking_pid,
   blocking_activity.usename AS blocking_user,
   blocked_activity.query AS blocked_statement
   FROM pg_catalog.pg_locks blocked_locks
   JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
   JOIN pg_catalog.pg_locks blocking_locks
     ON blocking_locks.locktype = blocked_locks.locktype
     AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
     AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
     AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
     AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
     AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
     AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
     AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
     AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
     AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
     AND blocking_locks.pid != blocked_locks.pid
   JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
   WHERE NOT blocked_locks.granted;"
```

## 📝 Maintenance Procedures

### Regular Maintenance Tasks

**Daily:**
- Check health monitor logs
- Verify backup completion
- Review performance metrics

**Weekly:**
- Run comprehensive health check
- Review and rotate logs
- Check disk space usage
- Verify replication status

**Monthly:**
- Test backup restoration
- Review and update configurations
- Security audit
- Performance tuning review

### Upgrade Procedures

**1. Update PostgreSQL Image:**
```bash
# Pull new image
docker pull ruvnet/ruvector-postgres:new-version

# Update coordinator (rolling update)
docker service update --image ruvnet/ruvector-postgres:new-version \
                      postgres-mesh_coordinator

# Update workers (one at a time)
docker service update --image ruvnet/ruvector-postgres:new-version \
                      postgres-mesh_worker-1
```

**2. Update Stack Configuration:**
```bash
# Edit stack.yml
vim stack.yml

# Update stack
docker stack deploy -c stack.yml postgres-mesh
```

## 🎯 Production Checklist

Before going to production:

- [ ] Docker Swarm initialized with multiple nodes
- [ ] Secrets created and secured
- [ ] Firewall rules configured
- [ ] Backup schedule configured
- [ ] Monitoring and alerting setup
- [ ] Health checks verified
- [ ] Performance tuning completed
- [ ] Security audit performed
- [ ] Disaster recovery plan documented
- [ ] Team training completed
- [ ] Connection pooling tested under load
- [ ] Replication verified and tested
- [ ] Backup restoration tested
- [ ] Documentation reviewed and updated

## 📚 Additional Resources

- **Docker Swarm**: https://docs.docker.com/engine/swarm/
- **PostgreSQL High Availability**: https://www.postgresql.org/docs/current/high-availability.html
- **PgBouncer**: https://www.pgbouncer.org/
- **RuVector**: https://github.com/ruvnet/ruvector
- **Komodo**: https://github.com/komodo-platform

## 🆘 Support

For issues and questions:
- Check `/docs` directory for detailed documentation
- Review health monitor logs in `/logs`
- Run health check: `health-check.sh`
- GitHub Issues: [Your Repository]

---

**Version:** 1.0.0
**Last Updated:** 2026-02-10
**Maintainer:** [Your Name/Team]
