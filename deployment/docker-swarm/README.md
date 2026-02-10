# Docker Swarm Deployment - Distributed PostgreSQL Mesh

Complete Docker Swarm deployment specification for a distributed PostgreSQL cluster with RuVector support, connection pooling, and health monitoring.

## 📋 Architecture Overview

```
                    ┌─────────────────────┐
                    │   Load Balancer     │
                    │   (Swarm Ingress)   │
                    └──────────┬──────────┘
                               │
                    ┌──────────┴──────────┐
                    │    PgBouncer Pool   │
                    │  (2 replicas)       │
                    └──────────┬──────────┘
                               │
                    ┌──────────┴──────────┐
                    │   Coordinator Node  │
                    │  (Query Router)     │
                    └──────────┬──────────┘
                               │
          ┌────────────────────┼────────────────────┐
          │                    │                    │
     ┌────▼────┐         ┌────▼────┐         ┌────▼────┐
     │Worker-1 │         │Worker-2 │         │Worker-3 │
     │  (Data) │         │  (Data) │         │  (Data) │
     └─────────┘         └─────────┘         └─────────┘
```

## 🚀 Quick Start

### Prerequisites

1. **Docker Swarm initialized**
   ```bash
   docker swarm init --advertise-addr $(hostname -I | awk '{print $1}')
   ```

2. **Multiple nodes** (optional but recommended)
   - 1+ Manager nodes
   - 2+ Worker nodes

### Deploy the Cluster

```bash
cd deployment/docker-swarm
chmod +x ../../scripts/deployment/*.sh
../../scripts/deployment/initialize-cluster.sh postgres-mesh 3
```

This will:
- Initialize Docker Swarm (if needed)
- Create secrets for passwords
- Label nodes for service placement
- Deploy the complete stack
- Wait for services to be ready
- Verify cluster health

### Connection Information

After deployment, connect using:

**Direct (Coordinator):**
```bash
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster
```

**Via Connection Pool (Recommended):**
```bash
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster
```

**Get credentials:**
```bash
cat .secrets
```

## 📁 Directory Structure

```
deployment/docker-swarm/
├── stack.yml                  # Main stack definition
├── configs/
│   ├── coordinator.conf       # Coordinator PostgreSQL config
│   ├── worker.conf           # Worker PostgreSQL config
│   └── pgbouncer.ini         # PgBouncer config
├── init-scripts/             # Database initialization scripts
├── scripts/                  # Runtime scripts
├── logs/                     # Health monitor logs
└── backups/                  # Backup storage

scripts/deployment/
├── initialize-cluster.sh     # Initialize and deploy cluster
├── add-worker.sh            # Add a new worker node
├── remove-worker.sh         # Remove a worker node
├── backup-distributed.sh    # Distributed backup
├── restore-distributed.sh   # Restore from backup
├── health-check.sh          # Manual health check
└── health-monitor.py        # Continuous monitoring service
```

## 🏗️ Stack Components

### Services

| Service | Replicas | Purpose | Ports |
|---------|----------|---------|-------|
| **coordinator** | 1 | Query routing, metadata management | 5432 |
| **worker-1,2,3** | 1 each | Data storage and processing | Internal |
| **pgbouncer** | 2 | Connection pooling | 6432 |
| **health-monitor** | 1 | Continuous health monitoring | - |
| **backup-agent** | 1 | Automated backups | - |

### Networks

- **postgres_mesh**: Encrypted overlay network (10.0.10.0/24)

### Volumes

- **coordinator_data**: Coordinator data
- **worker_data_[1-3]**: Worker data volumes
- **pgbouncer_config**: Pooler configuration
- **backup_storage**: Backup storage

### Secrets

- **postgres_password**: Main database password
- **replication_password**: Replication user password
- **pgbouncer_auth**: PgBouncer authentication

## 🔧 Management Commands

### View Stack Status

```bash
docker stack services postgres-mesh
docker stack ps postgres-mesh
```

### Scale Services

```bash
# Scale PgBouncer replicas
docker service scale postgres-mesh_pgbouncer=3

# Add a new worker (use the script for proper setup)
../../scripts/deployment/add-worker.sh postgres-mesh worker-4
```

### View Logs

```bash
# Coordinator logs
docker service logs postgres-mesh_coordinator

# Worker logs
docker service logs postgres-mesh_worker-1

# Pooler logs
docker service logs postgres-mesh_pgbouncer

# Health monitor logs
docker service logs postgres-mesh_health-monitor
```

### Health Checks

**Manual health check:**
```bash
../../scripts/deployment/health-check.sh postgres-mesh comprehensive
```

**View health monitor logs:**
```bash
docker exec $(docker ps -q -f name=health-monitor) cat /logs/health-monitor.log
```

### Backup and Restore

**Create backup:**
```bash
# Full backup with zstd compression
../../scripts/deployment/backup-distributed.sh postgres-mesh full zstd

# Incremental backup
../../scripts/deployment/backup-distributed.sh postgres-mesh incremental zstd
```

**List backups:**
```bash
ls -lh backups/
```

**Restore from backup:**
```bash
../../scripts/deployment/restore-distributed.sh postgres-mesh /path/to/backup full
```

## 🔄 Scaling Operations

### Add a Worker Node

```bash
../../scripts/deployment/add-worker.sh postgres-mesh worker-4
```

This will:
1. Create a new worker service
2. Wait for the worker to be healthy
3. Verify connectivity
4. Display worker information

### Remove a Worker Node

```bash
../../scripts/deployment/remove-worker.sh postgres-mesh worker-4 300
```

This will:
1. Stop accepting new connections
2. Drain existing connections (up to 300s)
3. Create a backup of worker data
4. Remove the service
5. Optionally remove the data volume

**Note:** Minimum 2 workers required for cluster health.

## 🛡️ Security

### Secrets Management

Secrets are stored in Docker Swarm's encrypted store:

```bash
# List secrets
docker secret ls

# Inspect secret (metadata only)
docker secret inspect postgres_password

# Rotate secrets (requires service update)
echo "new_password" | docker secret create postgres_password_v2 -
docker service update --secret-rm postgres_password \
                      --secret-add postgres_password_v2 \
                      postgres-mesh_coordinator
```

### Network Security

- **Encrypted overlay network**: All service communication is encrypted
- **Network isolation**: Services only accessible within the mesh network
- **Port exposure**: Only coordinator (5432) and pooler (6432) exposed

### Access Control

1. **Connection limits**: Configured in postgresql.conf
2. **Connection pooling**: PgBouncer limits and manages connections
3. **Authentication**: md5 password authentication (upgrade to SCRAM-SHA-256 recommended)

## 📊 Monitoring

### Built-in Health Monitoring

The `health-monitor` service continuously monitors:

- **Coordinator health**: Connectivity, connections, replication, cache hit ratio
- **Worker health**: Connectivity, connections, table count, disk usage
- **Pooler health**: Connection pooling status
- **Performance metrics**: Query duration, locks, long-running queries

**View real-time health:**
```bash
docker service logs -f postgres-mesh_health-monitor
```

### Health Check Levels

1. **Basic**: Service availability
2. **Standard**: + Connection stats, replication status
3. **Comprehensive**: + Performance metrics, disk usage, cache ratios

### Alerting

Extend `health-monitor.py` to add alerting:

```python
# In PostgreSQLHealthMonitor.run_monitor_loop()
if results['overall_status'] == 'unhealthy':
    send_alert(results)  # Implement your alerting logic
```

## ⚙️ Configuration

### PostgreSQL Configuration

**Coordinator** (`configs/coordinator.conf`):
- Optimized for query routing
- max_connections: 500
- shared_buffers: 4GB
- Replication enabled

**Worker** (`configs/worker.conf`):
- Optimized for data storage
- max_connections: 200
- shared_buffers: 2GB
- Hot standby enabled

### PgBouncer Configuration

(`configs/pgbouncer.ini`):
- Pool mode: transaction
- max_client_conn: 1000
- default_pool_size: 25
- Connection timeouts configured

### Resource Limits

**Coordinator:**
- CPU: 2-4 cores
- Memory: 4-8 GB

**Worker:**
- CPU: 1-2 cores
- Memory: 2-4 GB

**PgBouncer:**
- CPU: 0.5-1 core
- Memory: 512MB-1GB

## 🔄 Update Strategy

Services use rolling updates:

```yaml
update_config:
  parallelism: 1        # Update one replica at a time
  delay: 30s           # Wait 30s between updates
  failure_action: rollback  # Rollback on failure
  order: start-first   # Start new before stopping old (workers)
```

**Manual update:**
```bash
docker service update --image ruvnet/ruvector-postgres:new-tag postgres-mesh_coordinator
```

## 🐛 Troubleshooting

### Service Won't Start

```bash
# Check service status
docker service ps postgres-mesh_coordinator --no-trunc

# Check logs
docker service logs postgres-mesh_coordinator --tail 100

# Check node constraints
docker node ls
docker node inspect <node-id>
```

### Connection Issues

```bash
# Test coordinator connectivity
docker run --rm --network postgres-mesh_postgres_mesh postgres:latest \
  psql -h pg-coordinator -U dpg_cluster -d distributed_postgres_cluster -c "SELECT 1"

# Test pooler connectivity
docker run --rm --network postgres-mesh_postgres_mesh postgres:latest \
  psql -h pgbouncer -p 6432 -U dpg_cluster -d distributed_postgres_cluster -c "SELECT 1"
```

### Replication Issues

```bash
# Check replication status on coordinator
docker exec <coordinator-container> psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT * FROM pg_stat_replication;"

# Check replication slots
docker exec <coordinator-container> psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT * FROM pg_replication_slots;"
```

### Performance Issues

```bash
# Run comprehensive health check
../../scripts/deployment/health-check.sh postgres-mesh comprehensive

# Check for long-running queries
docker exec <coordinator-container> psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT pid, now() - query_start AS duration, query FROM pg_stat_activity WHERE state = 'active' ORDER BY duration DESC;"

# Check for locks
docker exec <coordinator-container> psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT * FROM pg_locks WHERE NOT granted;"
```

## 🔧 Komodo MCP Integration

The cluster can be managed via Komodo MCP server. See `../komodo-mcp/postgres-mesh-mcp.json` for available tools:

- `postgres_mesh_deploy`: Deploy cluster
- `postgres_mesh_scale_workers`: Scale worker count
- `postgres_mesh_health_check`: Health check
- `postgres_mesh_backup`: Trigger backup
- `postgres_mesh_restore`: Restore from backup
- `postgres_mesh_config_update`: Update configuration
- `postgres_mesh_failover`: Manual failover
- `postgres_mesh_rebalance`: Rebalance data

## 📚 Additional Resources

- [Docker Swarm Documentation](https://docs.docker.com/engine/swarm/)
- [PostgreSQL Replication](https://www.postgresql.org/docs/current/high-availability.html)
- [PgBouncer Documentation](https://www.pgbouncer.org/)
- [RuVector Extension](https://github.com/ruvnet/ruvector)

## 🆘 Support

For issues and questions:
- Project repository: https://github.com/yourusername/distributed-postgres-cluster
- Documentation: See `/docs` directory
- Health monitoring: Check `/logs` directory

## 📝 License

[Your License Here]
