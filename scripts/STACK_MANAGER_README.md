# Stack Manager - User Guide

Unified stack management tool for the Distributed PostgreSQL Cluster project.

## Overview

The Stack Manager provides a single command-line interface to manage all deployment modes of the distributed PostgreSQL cluster. It handles:

- **Conflict Detection** - Automatically detects port conflicts between stacks
- **Resource Monitoring** - Shows system resource usage and container status
- **Health Checks** - Validates services are running correctly
- **Interactive Mode** - Menu-driven interface for ease of use
- **Comprehensive Logging** - All operations logged to `logs/stack-manager.log`

## Quick Start

```bash
# Make executable (first time only)
chmod +x scripts/stack-manager.sh

# Start development stack
./scripts/stack-manager.sh start dev

# Show status of all stacks
./scripts/stack-manager.sh status

# Interactive mode
./scripts/stack-manager.sh interactive
```

## Available Stacks

### 1. Development Stack (`dev`)

**Description:** Simple 4GB development stack with PostgreSQL, Redis, and optional PgAdmin

**Services:**
- PostgreSQL with RuVector (2.4GB memory)
- Redis cache (512MB memory)
- PgAdmin (512MB memory, optional)

**Ports:**
- `5432` - PostgreSQL
- `6379` - Redis
- `8080` - PgAdmin (with --tools flag)

**Memory:** ~4GB total

**Usage:**
```bash
# Start without PgAdmin
./scripts/stack-manager.sh start dev

# Start with PgAdmin
./scripts/stack-manager.sh start dev --tools

# View logs
./scripts/stack-manager.sh logs dev

# Stop
./scripts/stack-manager.sh stop dev
```

**Connection:**
```bash
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster
# Password: dpg_cluster_2026
```

---

### 2. Citus Distributed Stack (`citus`)

**Description:** Distributed sharding cluster with 1 coordinator and 3 worker nodes

**Services:**
- Citus Coordinator (2GB memory)
- Citus Worker 1 (4GB memory)
- Citus Worker 2 (4GB memory)
- Citus Worker 3 (4GB memory)
- Redis cache (512MB memory)
- PgAdmin (512MB memory, optional)

**Ports:**
- `5432` - Coordinator
- `5433` - Worker 1
- `5434` - Worker 2
- `5435` - Worker 3
- `6379` - Redis
- `8080` - PgAdmin (with --tools flag)

**Memory:** ~15GB total

**Usage:**
```bash
# Start cluster
./scripts/stack-manager.sh start citus

# Check status
./scripts/stack-manager.sh status

# Connect to coordinator
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster
```

**Features:**
- Horizontal sharding across 3 workers
- Distributed query execution
- Automatic shard rebalancing
- RuVector support on all nodes

---

### 3. Patroni HA Stack (`patroni`)

**Description:** High-availability cluster with automatic failover

**Services:**
- 3x etcd nodes (2GB each)
- 3x Patroni PostgreSQL nodes
- HAProxy load balancer
- Health monitoring

**Ports:**
- `5000` - Primary PostgreSQL (read-write)
- `5001` - Replica PostgreSQL (read-only)
- `5432-5434` - Direct node access
- `7000` - HAProxy stats page
- `8008-8010` - Patroni REST APIs

**Memory:** ~12GB total

**Usage:**
```bash
# Start HA cluster
./scripts/stack-manager.sh start patroni

# View HAProxy stats
open http://localhost:7000

# Connect to primary (read-write)
psql -h localhost -p 5000 -U postgres

# Connect to replicas (read-only)
psql -h localhost -p 5001 -U postgres

# Check cluster health
curl http://localhost:8008/cluster
```

**Features:**
- Automatic failover on primary failure
- Synchronous replication
- Load balancing via HAProxy
- etcd-based consensus
- Zero-downtime upgrades

---

### 4. Monitoring Stack (`monitoring`)

**Description:** Observability stack with Prometheus, Grafana, and exporters

**Services:**
- Prometheus (512MB memory)
- Grafana (512MB memory)
- AlertManager (256MB memory)
- PostgreSQL Exporter (128MB memory)
- Redis Exporter (64MB memory)
- Node Exporter (64MB memory)
- Custom App Exporter (128MB memory)

**Ports:**
- `9090` - Prometheus
- `3000` - Grafana
- `9093` - AlertManager
- `9187` - Postgres Exporter
- `9121` - Redis Exporter
- `9100` - Node Exporter
- `9999` - App Exporter

**Memory:** ~1.5GB total

**Usage:**
```bash
# Start monitoring stack
./scripts/stack-manager.sh start monitoring

# Access Grafana
open http://localhost:3000
# Login: admin / admin

# Access Prometheus
open http://localhost:9090
```

**Dashboards:**
- PostgreSQL cluster overview
- Query performance metrics
- Connection pool statistics
- Cache hit rates
- System resource usage
- Custom application metrics

---

### 5. Production Stack (`production`)

**Description:** Full production stack with all components for Docker Swarm

**Services:**
- 3x etcd nodes
- 3x Patroni PostgreSQL nodes
- 2x HAProxy load balancers
- 2x PgBouncer connection poolers
- Redis Sentinel cluster
- Prometheus + Grafana
- Automated backup agent
- PostgreSQL Exporter

**Ports:**
- `5432` - HAProxy read-write
- `5433` - HAProxy read-only
- `6432` - PgBouncer
- `7000` - HAProxy stats
- `9090` - Prometheus
- `3001` - Grafana

**Memory:** ~80GB total (production grade)

**Requirements:**
- Docker Swarm mode initialized
- Node labels configured
- Secrets created
- SSL certificates generated

**Usage:**
```bash
# Deploy to Docker Swarm
docker stack deploy -c docker/production/docker-compose.yml postgres-prod

# Check deployment
docker stack ps postgres-prod

# Scale services
docker service scale postgres-prod_patroni=5
```

**Features:**
- Multi-node Swarm deployment
- Automatic failover
- Connection pooling
- Query caching
- SSL/TLS encryption
- Automated backups
- Full monitoring
- Rolling updates
- Health checks

---

## Commands

### Start Stack

Start a stack with optional PgAdmin:

```bash
./scripts/stack-manager.sh start <mode> [--tools]

# Examples
./scripts/stack-manager.sh start dev          # Without PgAdmin
./scripts/stack-manager.sh start dev --tools  # With PgAdmin
./scripts/stack-manager.sh start citus --tools
./scripts/stack-manager.sh start patroni
```

### Stop Stack

Stop a running stack:

```bash
./scripts/stack-manager.sh stop <mode> [--force]

# Examples
./scripts/stack-manager.sh stop dev
./scripts/stack-manager.sh stop citus --force  # Force kill containers
```

### Restart Stack

Restart a stack (stop + start):

```bash
./scripts/stack-manager.sh restart <mode> [--tools]

# Examples
./scripts/stack-manager.sh restart dev
./scripts/stack-manager.sh restart monitoring
```

### Show Status

Display status of all stacks:

```bash
./scripts/stack-manager.sh status
```

Output includes:
- System resource usage (CPU, memory, disk)
- Container counts
- Stack status (running/stopped/partial)
- Currently running stacks

### View Logs

View logs for a specific stack:

```bash
./scripts/stack-manager.sh logs <mode> [--follow]

# Examples
./scripts/stack-manager.sh logs dev           # Last 100 lines
./scripts/stack-manager.sh logs dev --follow  # Follow logs (Ctrl+C to exit)
./scripts/stack-manager.sh logs patroni -f    # Short flag for follow
```

### Clean Stack

Stop stack and remove all volumes (destructive):

```bash
./scripts/stack-manager.sh clean <mode>

# Example
./scripts/stack-manager.sh clean dev

# Warning: This will delete all data!
# You will be prompted for confirmation
```

### Interactive Mode

Launch menu-driven interface:

```bash
./scripts/stack-manager.sh interactive

# Or
./scripts/stack-manager.sh menu
```

Features:
- Visual status dashboard
- Easy navigation
- Real-time resource monitoring
- No need to remember commands

---

## Features

### 1. Conflict Detection

The stack manager automatically detects port conflicts:

```bash
$ ./scripts/stack-manager.sh start citus
⚠ Port conflicts detected:
  - Port 5432 is in use by PID 12345
✗ Cannot start citus stack due to port conflicts
ℹ Stop conflicting stacks or services first
```

### 2. Automatic Stack Stopping

When starting a new stack, the manager detects running stacks and offers to stop them:

```bash
$ ./scripts/stack-manager.sh start citus
⚠ Other stacks are running: dev
Do you want to stop them first? [y/N] y
→ Stopping dev stack...
✓ dev stack stopped successfully
→ Starting citus stack...
```

### 3. Health Checks

The manager waits for services to be healthy after starting:

```bash
$ ./scripts/stack-manager.sh start dev
→ Starting dev stack...
→ Pulling latest images...
→ Starting containers...
→ Waiting for services to be healthy...
✓ dev stack started successfully
```

### 4. Resource Monitoring

View real-time system resource usage:

```bash
System Resources:
  Containers: 5 running / 8 total
  Images: 88
  Volumes: 153
  Memory: 6.3Gi / 19Gi
  Disk: 65G / 1007G
```

### 5. Comprehensive Logging

All operations are logged to `logs/stack-manager.log`:

```
[2026-02-12 10:30:45] [INFO] Starting dev stack...
[2026-02-12 10:30:47] [STEP] Pulling latest images...
[2026-02-12 10:30:52] [STEP] Starting containers...
[2026-02-12 10:31:00] [SUCCESS] dev stack started successfully
```

---

## Troubleshooting

### Port Already in Use

**Problem:** Port conflict when starting stack

**Solution:**
```bash
# Check what's using the port
lsof -i :5432

# Stop the conflicting service
./scripts/stack-manager.sh stop dev

# Or kill the process
kill -9 <PID>
```

### Docker Not Running

**Problem:** `Docker daemon is not running`

**Solution:**
```bash
# Start Docker daemon
sudo systemctl start docker

# Or on macOS
open -a Docker
```

### Containers Not Starting

**Problem:** Containers fail health checks

**Solution:**
```bash
# View logs
./scripts/stack-manager.sh logs dev --follow

# Check Docker resources
docker system df

# Restart Docker
sudo systemctl restart docker

# Clean and retry
./scripts/stack-manager.sh clean dev
./scripts/stack-manager.sh start dev
```

### Out of Memory

**Problem:** System running out of memory

**Solution:**
```bash
# Check current usage
./scripts/stack-manager.sh status

# Stop unused stacks
./scripts/stack-manager.sh stop citus

# Clean unused Docker resources
docker system prune -a --volumes
```

### Permission Denied

**Problem:** Cannot execute script

**Solution:**
```bash
# Make executable
chmod +x scripts/stack-manager.sh

# Or run with bash
bash scripts/stack-manager.sh status
```

---

## Tips & Best Practices

### 1. Use Interactive Mode for Exploration

Interactive mode is great for:
- Learning the available stacks
- Testing different configurations
- Quick status checks

```bash
./scripts/stack-manager.sh interactive
```

### 2. Check Status Before Starting

Always check status to avoid conflicts:

```bash
./scripts/stack-manager.sh status
./scripts/stack-manager.sh start <mode>
```

### 3. Use --tools Flag for GUI Access

PgAdmin and other tools are hidden by default to save resources:

```bash
# Start with PgAdmin
./scripts/stack-manager.sh start dev --tools

# Access PgAdmin
open http://localhost:8080
```

### 4. Follow Logs During Development

Watch logs in real-time:

```bash
./scripts/stack-manager.sh logs dev --follow
```

### 5. Clean Stacks for Fresh Start

Remove all data for clean slate:

```bash
./scripts/stack-manager.sh clean dev
./scripts/stack-manager.sh start dev
```

### 6. Monitor Resources

Keep an eye on system resources:

```bash
# Quick status
./scripts/stack-manager.sh status

# Docker stats
docker stats

# System monitoring
htop
```

---

## Architecture Comparison

| Feature | Dev | Citus | Patroni | Monitoring | Production |
|---------|-----|-------|---------|------------|------------|
| **Nodes** | 1 | 4 | 7 | 7 | 10+ |
| **HA** | ❌ | ❌ | ✅ | ❌ | ✅ |
| **Sharding** | ❌ | ✅ | ❌ | ❌ | ❌ |
| **Failover** | ❌ | ❌ | ✅ | ❌ | ✅ |
| **Monitoring** | ❌ | ❌ | ❌ | ✅ | ✅ |
| **Load Balancing** | ❌ | ❌ | ✅ | ❌ | ✅ |
| **Connection Pooling** | ❌ | ❌ | ❌ | ❌ | ✅ |
| **SSL/TLS** | ❌ | ❌ | ❌ | ❌ | ✅ |
| **Backups** | ❌ | ❌ | ❌ | ❌ | ✅ |
| **Memory** | 4GB | 15GB | 12GB | 1.5GB | 80GB |
| **Use Case** | Development | Horizontal Scale | High Availability | Observability | Production |

---

## Environment Variables

All stacks support environment variables via `.env` file:

```bash
# Create .env file in project root
cat > .env << EOF
POSTGRES_USER=dpg_cluster
POSTGRES_PASSWORD=dpg_cluster_2026
POSTGRES_DB=distributed_postgres_cluster

PGADMIN_EMAIL=admin@dpg.local
PGADMIN_PASSWORD=admin

GRAFANA_USER=admin
GRAFANA_PASSWORD=admin
EOF
```

---

## Advanced Usage

### Custom Compose Files

Run with custom compose file:

```bash
docker-compose -f custom-compose.yml up -d
```

### Scaling Services

Scale specific services:

```bash
docker-compose -f docker-compose.dev.yml up -d --scale redis=3
```

### Override Configuration

Use docker-compose.override.yml:

```yaml
version: '3.9'

services:
  postgres:
    ports:
      - "15432:5432"  # Use different port
```

---

## Support

For issues or questions:

1. Check logs: `logs/stack-manager.log`
2. View container logs: `./scripts/stack-manager.sh logs <mode>`
3. Check Docker status: `docker ps -a`
4. Review documentation: `docs/`

---

## Related Documentation

- [Architecture Overview](../docs/architecture/README.md)
- [Development Guide](../docs/DEVELOPMENT.md)
- [Pool Capacity Documentation](../docs/POOL_CAPACITY.md)
- [Error Handling Guide](../docs/ERROR_HANDLING.md)

---

## Version History

- **v1.0.0** (2026-02-12)
  - Initial release
  - Support for 5 stack modes
  - Interactive menu mode
  - Conflict detection
  - Resource monitoring
  - Comprehensive logging
