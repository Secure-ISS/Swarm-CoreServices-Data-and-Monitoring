# Distributed PostgreSQL Cluster - Deployment Guide

## Prerequisites

### Hardware Requirements (Minimum)

**For 3-host production cluster:**
- **3 hosts** (VMs or bare metal)
- **Each host:**
  - 8 CPU cores
  - 32GB RAM
  - 200GB SSD storage
  - 1Gbps network

**For development/testing (single host):**
- 16 CPU cores
- 64GB RAM
- 500GB SSD

### Software Requirements

- **Operating System:** Ubuntu 22.04 LTS (or RHEL 8+, CentOS 8+)
- **Docker Engine:** 24.0+
- **Docker Compose:** 2.20+
- **Kernel:** 5.4+ (for overlay network support)

### Network Requirements

- **Ports to open:**
  - 2377/tcp - Docker Swarm cluster management
  - 7946/tcp,udp - Container network discovery
  - 4789/udp - Overlay network traffic (VXLAN)
  - 5432/tcp - PostgreSQL (external clients)
  - 8404/tcp - HAProxy stats (optional)

---

## Quick Start (3-Host Cluster)

### Step 1: Prepare Hosts

Run on all hosts:

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Enable Docker service
sudo systemctl enable docker
sudo systemctl start docker

# Label nodes (run on each host)
# Manager 1 (coordinator host)
docker node update --label-add postgres_role=coordinator $(docker node ls --format "{{.Hostname}}" | grep host1)

# Manager 2 (mixed host)
docker node update --label-add postgres_role=coordinator $(docker node ls --format "{{.Hostname}}" | grep host2)

# Manager 3 (mixed host)
docker node update --label-add postgres_role=coordinator $(docker node ls --format "{{.Hostname}}" | grep host3)
```

### Step 2: Initialize Docker Swarm

**On Manager 1 (first host):**

```bash
# Initialize swarm
docker swarm init --advertise-addr <MANAGER-1-IP>

# Save the join tokens
docker swarm join-token manager > /tmp/swarm-manager-token.txt
docker swarm join-token worker > /tmp/swarm-worker-token.txt
```

**On Manager 2 and Manager 3:**

```bash
# Join as manager (for HA)
docker swarm join --token <MANAGER-TOKEN> <MANAGER-1-IP>:2377
```

### Step 3: Create Docker Secrets

**On Manager 1:**

```bash
# Generate secure passwords
POSTGRES_PASSWORD=$(openssl rand -base64 32)
REPLICATION_PASSWORD=$(openssl rand -base64 32)
MCP_PASSWORD=$(openssl rand -base64 32)

# Create Docker secrets
echo "$POSTGRES_PASSWORD" | docker secret create postgres_password -
echo "$REPLICATION_PASSWORD" | docker secret create replication_password -
echo "$MCP_PASSWORD" | docker secret create mcp_password -

# Save passwords securely
cat > /tmp/cluster-passwords.txt <<EOF
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
REPLICATION_PASSWORD=$REPLICATION_PASSWORD
MCP_PASSWORD=$MCP_PASSWORD
EOF
chmod 600 /tmp/cluster-passwords.txt

echo "Passwords saved to /tmp/cluster-passwords.txt"
echo "IMPORTANT: Back up this file and delete it from the server!"
```

### Step 4: Create Overlay Networks

```bash
docker network create \
  --driver overlay \
  --subnet 10.0.1.0/26 \
  --attachable \
  coordinator-net

docker network create \
  --driver overlay \
  --subnet 10.0.1.64/26 \
  --attachable \
  worker-net

docker network create \
  --driver overlay \
  --subnet 10.0.1.128/26 \
  --attachable \
  admin-net
```

### Step 5: Deploy the Stack

```bash
# Clone repository (or copy configuration files)
git clone https://github.com/yourusername/Distributed-Postgress-Cluster.git
cd Distributed-Postgress-Cluster/docs/architecture/configs

# Deploy stack
docker stack deploy -c docker-compose-swarm.yml postgres-cluster

# Verify deployment
docker stack ps postgres-cluster
docker service ls
```

### Step 6: Wait for Services to Start

```bash
# Monitor service status (wait for all replicas to be "Running")
watch -n 2 'docker service ls'

# Check logs
docker service logs postgres-cluster_coordinator-1
docker service logs postgres-cluster_etcd-1

# Wait ~60 seconds for Patroni cluster formation
```

### Step 7: Initialize Citus Cluster

```bash
# Get coordinator container ID
COORDINATOR_CONTAINER=$(docker ps -q -f name=postgres-cluster_coordinator-1)

# Copy initialization script
docker cp init-citus-cluster.sql $COORDINATOR_CONTAINER:/tmp/

# Run initialization
docker exec -it $COORDINATOR_CONTAINER psql -U postgres -f /tmp/init-citus-cluster.sql

# Verify cluster
docker exec -it $COORDINATOR_CONTAINER psql -U postgres -d distributed_postgres_cluster -c "SELECT * FROM citus_get_active_worker_nodes();"
```

### Step 8: Test Connection

```bash
# Get HAProxy IP (should be accessible from outside)
HAPROXY_IP=$(docker service inspect postgres-cluster_haproxy --format '{{range .Endpoint.VirtualIPs}}{{.Addr}}{{end}}' | cut -d'/' -f1)

# Test connection (from your local machine)
psql -h $HAPROXY_IP -p 5432 -U mcp_user -d distributed_postgres_cluster -c "SELECT version();"

# Test vector operation
psql -h $HAPROXY_IP -p 5432 -U mcp_user -d distributed_postgres_cluster -c "SELECT '[0.1,0.2,0.3]'::ruvector;"
```

---

## Deployment Verification Checklist

### 1. etcd Cluster Health

```bash
# Check etcd members
docker exec $(docker ps -q -f name=etcd-1) etcdctl member list

# Expected output: 3 members (etcd-1, etcd-2, etcd-3)
```

### 2. Patroni Cluster Health

```bash
# Check coordinator cluster
docker exec $(docker ps -q -f name=coordinator-1) patronictl -c /etc/patroni.yml list postgres-cluster-coordinators

# Expected output:
# + Cluster: postgres-cluster-coordinators
# | Member        | Host           | Role    | State   | TL | Lag in MB |
# +---------------+----------------+---------+---------+----+-----------+
# | coordinator-1 | coordinator-1  | Leader  | running |  1 |           |
# | coordinator-2 | coordinator-2  | Replica | running |  1 |         0 |
# | coordinator-3 | coordinator-3  | Replica | running |  1 |         0 |

# Check worker shard 1
docker exec $(docker ps -q -f name=worker-1-1) patronictl -c /etc/patroni.yml list postgres-cluster-shard-1

# Expected: 2 members (worker-1-1 as leader, worker-1-2 as replica)
```

### 3. Citus Cluster Status

```bash
# Check worker nodes
docker exec $(docker ps -q -f name=coordinator-1) psql -U postgres -d distributed_postgres_cluster -c "SELECT * FROM citus_get_active_worker_nodes();"

# Expected: 6 rows (3 shards × 2 workers)

# Check shard distribution
docker exec $(docker ps -q -f name=coordinator-1) psql -U postgres -d distributed_postgres_cluster -c "
SELECT logicalrelid::regclass as table_name, count(*) as shard_count
FROM pg_dist_shard
GROUP BY logicalrelid
ORDER BY logicalrelid;
"

# Expected: memory_entries, patterns, etc. with ~32 shards each
```

### 4. HAProxy Status

```bash
# Check HAProxy stats page
curl http://<HAPROXY-IP>:8404/

# Or open in browser: http://<HAPROXY-IP>:8404/
# Expected: All backends GREEN
```

### 5. RuVector Extension

```bash
# Test vector operations
docker exec $(docker ps -q -f name=coordinator-1) psql -U postgres -d distributed_postgres_cluster -c "
INSERT INTO memory_entries (namespace, key, value, embedding)
VALUES ('test', 'test-key', 'test value', '[0.1,0.2,0.3]'::ruvector(3));

SELECT namespace, key, value FROM memory_entries WHERE namespace = 'test';
"

# Expected: Row inserted and retrieved
```

### 6. Distributed Query Test

```bash
# Test distributed query (should hit all shards)
docker exec $(docker ps -q -f name=coordinator-1) psql -U postgres -d distributed_postgres_cluster -c "
EXPLAIN (ANALYZE, VERBOSE) SELECT count(*) FROM memory_entries;
"

# Expected: Query plan showing parallel execution across workers
```

---

## Post-Deployment Configuration

### 1. Update Default Passwords

```bash
# Connect to coordinator
docker exec -it $(docker ps -q -f name=coordinator-1) psql -U postgres -d distributed_postgres_cluster

# Change user passwords
ALTER USER mcp_user WITH PASSWORD 'new_secure_password_for_mcp';
ALTER USER app_user WITH PASSWORD 'new_secure_password_for_app';
ALTER USER readonly_user WITH PASSWORD 'new_secure_password_for_readonly';

# Distribute password changes to workers (Citus automatically propagates)
\q
```

### 2. Configure SSL/TLS (Optional but Recommended)

```bash
# Generate SSL certificates (on manager node)
openssl req -new -x509 -days 365 -nodes -text \
  -out /tmp/server.crt \
  -keyout /tmp/server.key \
  -subj "/CN=postgres-cluster"

# Create Docker secret
docker secret create postgres_server_crt /tmp/server.crt
docker secret create postgres_server_key /tmp/server.key

# Update docker-compose-swarm.yml to mount SSL secrets
# (See SSL configuration section)

# Redeploy stack
docker stack deploy -c docker-compose-swarm.yml postgres-cluster
```

### 3. Set Up Monitoring

```bash
# Prometheus and Grafana are included in the stack
# Access Grafana: http://<MANAGER-IP>:3000
# Default credentials: admin/admin

# Import Patroni dashboard (ID: 13927)
# Import Citus dashboard (ID: 14674)
```

---

## Scaling Operations

### Adding a New Worker Shard

```bash
# 1. Scale worker service (add 2 more workers for shard 4)
docker service scale postgres-cluster_worker=8

# Wait for new workers to start
docker service ps postgres-cluster_worker

# 2. Get new worker IPs
docker service inspect postgres-cluster_worker --format '{{range .Endpoint.VirtualIPs}}{{.Addr}}{{end}}'

# 3. Add workers to Citus cluster
docker exec -it $(docker ps -q -f name=coordinator-1) psql -U postgres -d distributed_postgres_cluster -c "
SELECT citus_add_node('worker-4-1', 5432);
SELECT citus_add_node('worker-4-2', 5432);
"

# 4. Rebalance shards
docker exec -it $(docker ps -q -f name=coordinator-1) psql -U postgres -d distributed_postgres_cluster -c "
SELECT citus_rebalance_start();
"

# 5. Monitor rebalancing progress
docker exec -it $(docker ps -q -f name=coordinator-1) psql -U postgres -d distributed_postgres_cluster -c "
SELECT * FROM citus_rebalance_status();
"
```

### Adding More Coordinators (beyond 3)

```bash
# Not recommended beyond 3 coordinators (Patroni quorum complexity)
# If needed, follow same pattern as workers but update Patroni scope
```

---

## Backup and Recovery

### Automated Backups (WAL Archiving)

Configure in `patroni-coordinator.yml` and `patroni-worker.yml`:

```yaml
postgresql:
  parameters:
    archive_mode: on
    archive_command: 's3cmd put %p s3://my-backup-bucket/wal/%f'
    archive_timeout: 300
```

### Manual Backup (pg_basebackup)

```bash
# Backup from standby (doesn't impact primary)
docker exec $(docker ps -q -f name=coordinator-2) pg_basebackup \
  -D /backup/coordinator-$(date +%Y%m%d-%H%M%S) \
  -F tar -z -P -U postgres

# Copy to external storage
docker cp $(docker ps -q -f name=coordinator-2):/backup /your/backup/location/
```

### Point-in-Time Recovery (PITR)

See `/docs/architecture/BACKUP_RECOVERY.md` for detailed PITR procedures.

---

## Troubleshooting

### Issue: etcd Cluster Not Forming

```bash
# Check etcd logs
docker service logs postgres-cluster_etcd-1

# Verify network connectivity
docker exec $(docker ps -q -f name=etcd-1) nc -zv etcd-2 2379
docker exec $(docker ps -q -f name=etcd-1) nc -zv etcd-3 2379

# Reset etcd cluster (destructive)
docker stack rm postgres-cluster
docker volume rm $(docker volume ls -q | grep etcd)
# Redeploy
```

### Issue: Patroni Not Starting

```bash
# Check Patroni logs
docker service logs postgres-cluster_coordinator-1

# Common issues:
# 1. etcd not reachable (check etcd health)
# 2. PostgreSQL port conflict (ensure 5432 is free)
# 3. Volume permission issues (check /var/lib/postgresql/data)

# Verify etcd connectivity from Patroni container
docker exec $(docker ps -q -f name=coordinator-1) curl http://etcd-1:2379/health
```

### Issue: Citus Workers Not Connecting

```bash
# Check worker status
docker exec $(docker ps -q -f name=coordinator-1) psql -U postgres -d distributed_postgres_cluster -c "
SELECT * FROM citus_check_cluster_node_health();
"

# Remove and re-add unhealthy worker
docker exec $(docker ps -q -f name=coordinator-1) psql -U postgres -d distributed_postgres_cluster -c "
SELECT citus_remove_node('worker-1-1', 5432);
SELECT citus_add_node('worker-1-1', 5432);
"
```

### Issue: HAProxy Not Routing

```bash
# Check HAProxy logs
docker service logs postgres-cluster_haproxy

# Verify backend health
docker exec $(docker ps -q -f name=haproxy) curl http://coordinator-1:8008/health

# Check Patroni REST API
curl http://<COORDINATOR-IP>:8008/leader
```

---

## Performance Tuning

See `/docs/architecture/PERFORMANCE_TUNING.md` for:
- PostgreSQL parameter optimization
- Citus configuration tuning
- RuVector HNSW index tuning
- Connection pooling optimization

---

## Security Hardening

See `/docs/architecture/SECURITY_GUIDE.md` for:
- SSL/TLS configuration
- Network security (firewalls, segmentation)
- Access control and roles
- Audit logging
- Secret rotation

---

## Migration from Single Node

See `/docs/architecture/MIGRATION_GUIDE.md` for:
- Data export from single node
- Import to distributed cluster
- Zero-downtime migration strategies

---

## Support and Resources

- **Documentation:** `/docs/architecture/`
- **GitHub Issues:** https://github.com/yourusername/Distributed-Postgress-Cluster/issues
- **Citus Documentation:** https://docs.citusdata.com/
- **Patroni Documentation:** https://patroni.readthedocs.io/
- **RuVector Documentation:** https://github.com/ruvnet/ruvector

---

**Document Version:** 1.0
**Last Updated:** 2026-02-10
**Status:** Production Ready
