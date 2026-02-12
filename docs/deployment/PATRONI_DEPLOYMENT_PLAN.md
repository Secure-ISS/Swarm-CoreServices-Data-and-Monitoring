# Patroni High Availability - Deployment Plan

## Executive Summary

This document provides a comprehensive, step-by-step deployment procedure for the Patroni-based high availability PostgreSQL cluster. The deployment includes prerequisites, deployment steps, verification procedures, rollback strategy, and testing checklist.

**Deployment Timeline:**
- **Preparation:** 2-3 hours (prerequisites, configuration review)
- **Deployment:** 1-2 hours (initial deployment)
- **Validation:** 1 hour (testing and verification)
- **Total:** 4-6 hours

**Deployment Strategy:**
- Blue-Green deployment (new HA cluster alongside existing single-node)
- Zero-downtime migration (optional - after HA cluster validated)
- Rollback capability at each stage

---

## Prerequisites

### 1. Infrastructure Requirements

#### Hardware

**Minimum (3-node cluster):**
| Component | Specification |
|-----------|---------------|
| **Hosts** | 3 physical or virtual machines |
| **CPU** | 8 cores per host |
| **RAM** | 32GB per host |
| **Storage** | 200GB SSD per host |
| **Network** | 1Gbps between hosts |

**Recommended (production):**
| Component | Specification |
|-----------|---------------|
| **Hosts** | 3 physical or virtual machines |
| **CPU** | 16 cores per host |
| **RAM** | 64GB per host |
| **Storage** | 500GB NVMe SSD per host |
| **Network** | 10Gbps between hosts |

#### Software

| Software | Version | Purpose |
|----------|---------|---------|
| **Operating System** | Ubuntu 22.04 LTS | Base OS |
| **Docker Engine** | 24.0+ | Container runtime |
| **Docker Compose** | 2.20+ | Orchestration |
| **Docker Swarm** | (built-in) | Cluster orchestration |
| **Kernel** | 5.4+ | Overlay network support |

#### Network Requirements

**Ports to Open:**
| Port | Protocol | Service | Source | Destination |
|------|----------|---------|--------|-------------|
| 2377 | TCP | Docker Swarm | All hosts | All hosts |
| 7946 | TCP/UDP | Swarm discovery | All hosts | All hosts |
| 4789 | UDP | Overlay network | All hosts | All hosts |
| 5432 | TCP | PostgreSQL | HAProxy | Patroni nodes |
| 6432 | TCP | PgBouncer | Clients | HAProxy |
| 8008 | HTTP | Patroni REST | HAProxy | Patroni nodes |
| 2379 | TCP | etcd client | Patroni nodes | etcd nodes |
| 2380 | TCP | etcd peer | etcd nodes | etcd nodes |
| 8404 | HTTP | HAProxy stats | Monitoring | HAProxy |

### 2. Pre-Deployment Checklist

```bash
# 1. Verify Docker installation
docker --version
# Expected: Docker version 24.0.0 or higher

# 2. Verify network connectivity between hosts
ping -c 3 <HOST-2-IP>
ping -c 3 <HOST-3-IP>

# 3. Verify required ports are available
sudo netstat -tuln | grep -E '5432|6432|2379|2380|8008'
# Expected: No output (ports not in use)

# 4. Verify disk space
df -h /var/lib/docker
# Expected: At least 200GB available

# 5. Check system resources
free -h
# Expected: At least 32GB RAM

lscpu | grep -E 'CPU\(s\)'
# Expected: At least 8 CPUs

# 6. Verify time synchronization (critical for etcd)
timedatectl status
# Expected: System clock synchronized: yes

# If not synchronized:
sudo apt install -y chrony
sudo systemctl enable chrony
sudo systemctl start chrony
```

### 3. Configuration Preparation

**Generate secure passwords:**
```bash
# Generate passwords
POSTGRES_PASSWORD=$(openssl rand -base64 32)
REPLICATION_PASSWORD=$(openssl rand -base64 32)
DPG_PASSWORD=$(openssl rand -base64 32)
SHARED_PASSWORD=$(openssl rand -base64 32)
MCP_PASSWORD=$(openssl rand -base64 32)

# Save to secure file (will create Docker secrets later)
cat > /tmp/cluster-passwords.txt <<EOF
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
REPLICATION_PASSWORD=$REPLICATION_PASSWORD
DPG_PASSWORD=$DPG_PASSWORD
SHARED_PASSWORD=$SHARED_PASSWORD
MCP_PASSWORD=$MCP_PASSWORD
EOF

chmod 600 /tmp/cluster-passwords.txt

echo "Passwords saved to /tmp/cluster-passwords.txt"
echo "IMPORTANT: Back up this file securely and delete from server after deployment!"
```

**Review configuration files:**
```bash
# Clone repository
git clone https://github.com/yourusername/Distributed-Postgress-Cluster.git
cd Distributed-Postgress-Cluster

# Review configurations
less config/patroni/patroni.yml
less config/etcd/etcd.conf
less config/postgresql/postgresql.conf

# Customize if needed (hostnames, IPs, resource limits)
```

---

## Deployment Procedure

### Phase 1: Docker Swarm Initialization

#### Step 1.1: Initialize Swarm on Manager Node

**On Host 1 (Manager Node):**
```bash
# Initialize Docker Swarm
docker swarm init --advertise-addr <HOST-1-IP>

# Expected output:
# Swarm initialized: current node (xyz123) is now a manager.
# To add a worker to this swarm, run the following command:
#     docker swarm join --token SWMTKN-1-xxx... <HOST-1-IP>:2377

# Save manager token
docker swarm join-token manager > /tmp/swarm-manager-token.txt

echo "Swarm initialized on Host 1"
```

#### Step 1.2: Join Additional Manager Nodes

**On Host 2:**
```bash
# Join as manager
docker swarm join --token <MANAGER-TOKEN> <HOST-1-IP>:2377

# Expected output:
# This node joined a swarm as a manager.

# Verify
docker node ls
# Expected: 2 nodes listed (both as managers)
```

**On Host 3:**
```bash
# Join as manager
docker swarm join --token <MANAGER-TOKEN> <HOST-1-IP>:2377

# Verify
docker node ls
# Expected: 3 nodes listed (all as managers)
```

#### Step 1.3: Label Nodes

**On Host 1:**
```bash
# Get node IDs
HOST1_ID=$(docker node ls --format "{{.ID}}" --filter "name=host1")
HOST2_ID=$(docker node ls --format "{{.ID}}" --filter "name=host2")
HOST3_ID=$(docker node ls --format "{{.ID}}" --filter "name=host3")

# Label nodes for placement constraints
docker node update --label-add patroni_node=node-1 $HOST1_ID
docker node update --label-add patroni_node=node-2 $HOST2_ID
docker node update --label-add patroni_node=node-3 $HOST3_ID

docker node update --label-add etcd_node=etcd-1 $HOST1_ID
docker node update --label-add etcd_node=etcd-2 $HOST2_ID
docker node update --label-add etcd_node=etcd-3 $HOST3_ID

# Verify labels
docker node inspect host1 --format '{{ .Spec.Labels }}'
# Expected: map[patroni_node:node-1 etcd_node:etcd-1]
```

### Phase 2: Network and Secret Setup

#### Step 2.1: Create Overlay Networks

**On Host 1:**
```bash
# Create coordinator network (Patroni + etcd)
docker network create \
  --driver overlay \
  --subnet 10.0.1.0/26 \
  --attachable \
  coordinator-net

# Create admin network (HAProxy + monitoring)
docker network create \
  --driver overlay \
  --subnet 10.0.1.128/26 \
  --attachable \
  admin-net

# Verify networks
docker network ls | grep -E 'coordinator-net|admin-net'
```

#### Step 2.2: Create Docker Secrets

**On Host 1:**
```bash
# Source password file
source /tmp/cluster-passwords.txt

# Create secrets
echo "$POSTGRES_PASSWORD" | docker secret create postgres_password -
echo "$REPLICATION_PASSWORD" | docker secret create replication_password -
echo "$DPG_PASSWORD" | docker secret create dpg_password -
echo "$SHARED_PASSWORD" | docker secret create shared_password -
echo "$MCP_PASSWORD" | docker secret create mcp_password -

# Verify secrets
docker secret ls
# Expected: 5 secrets listed

echo "Secrets created successfully"
```

### Phase 3: etcd Cluster Deployment

#### Step 3.1: Create etcd Configuration

**On Host 1:**
```bash
# Create etcd Docker config
docker config create etcd-config config/etcd/etcd.conf

# Verify
docker config ls
```

#### Step 3.2: Deploy etcd Cluster

**On Host 1:**
```bash
# Create etcd service (3 replicas)
cat > /tmp/etcd-stack.yml <<'EOF'
version: '3.8'

services:
  etcd:
    image: quay.io/coreos/etcd:v3.5.11
    networks:
      - coordinator-net
    environment:
      - ETCD_DATA_DIR=/var/lib/etcd
      - ETCD_HEARTBEAT_INTERVAL=100
      - ETCD_ELECTION_TIMEOUT=1000
      - ETCD_SNAPSHOT_COUNT=10000
      - ETCD_LISTEN_PEER_URLS=http://0.0.0.0:2380
      - ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379
      - ETCD_INITIAL_CLUSTER_STATE=new
      - ETCD_INITIAL_CLUSTER_TOKEN=postgres-cluster-etcd
    command:
      - /usr/local/bin/etcd
    deploy:
      mode: global
      placement:
        constraints:
          - node.labels.etcd_node != null
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
    volumes:
      - etcd-data:/var/lib/etcd

networks:
  coordinator-net:
    external: true

volumes:
  etcd-data:
EOF

# Deploy etcd stack
docker stack deploy -c /tmp/etcd-stack.yml etcd-cluster

# Wait for etcd to start
sleep 30

# Verify etcd cluster
docker exec $(docker ps -q -f name=etcd-cluster_etcd | head -1) \
  etcdctl --endpoints=http://localhost:2379 endpoint health

# Expected output:
# http://localhost:2379 is healthy: successfully committed proposal: took = 2.345ms
```

#### Step 3.3: Configure etcd Cluster

**On Host 1:**
```bash
# Get etcd container IDs for each node
ETCD1=$(docker ps -q -f name=etcd-cluster_etcd -f node=host1)
ETCD2=$(docker ps -q -f name=etcd-cluster_etcd -f node=host2)
ETCD3=$(docker ps -q -f name=etcd-cluster_etcd -f node=host3)

# Add member configuration
docker exec $ETCD1 etcdctl \
  --endpoints=http://localhost:2379 \
  member add etcd-2 --peer-urls=http://etcd-2:2380

docker exec $ETCD1 etcdctl \
  --endpoints=http://localhost:2379 \
  member add etcd-3 --peer-urls=http://etcd-3:2380

# Verify cluster membership
docker exec $ETCD1 etcdctl \
  --endpoints=http://localhost:2379 \
  member list

# Expected: 3 members listed
```

### Phase 4: Patroni Cluster Deployment

#### Step 4.1: Create Patroni Configuration

**On Host 1:**
```bash
# Create Patroni Docker config
docker config create patroni-config config/patroni/patroni.yml

# Create PostgreSQL config
docker config create postgresql-config config/postgresql/postgresql.conf

# Verify
docker config ls | grep -E 'patroni|postgresql'
```

#### Step 4.2: Deploy Patroni Services

**Create Patroni stack file:**
```bash
cat > /tmp/patroni-stack.yml <<'EOF'
version: '3.8'

services:
  patroni-node-1:
    image: ruvnet/ruvector-postgres:latest
    hostname: node-1
    networks:
      - coordinator-net
    environment:
      - PATRONI_NAME=node-1
      - PATRONI_RESTAPI_CONNECT_ADDRESS=node-1:8008
      - PATRONI_POSTGRESQL_CONNECT_ADDRESS=node-1:5432
      - POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password
      - REPLICATION_PASSWORD_FILE=/run/secrets/replication_password
    configs:
      - source: patroni-config
        target: /etc/patroni.yml
      - source: postgresql-config
        target: /etc/postgresql/postgresql.conf
    secrets:
      - postgres_password
      - replication_password
      - dpg_password
      - shared_password
      - mcp_password
    deploy:
      placement:
        constraints:
          - node.labels.patroni_node == node-1
      restart_policy:
        condition: on-failure
    volumes:
      - patroni-node-1-data:/var/lib/postgresql/data
    command: patroni /etc/patroni.yml

  patroni-node-2:
    image: ruvnet/ruvector-postgres:latest
    hostname: node-2
    networks:
      - coordinator-net
    environment:
      - PATRONI_NAME=node-2
      - PATRONI_RESTAPI_CONNECT_ADDRESS=node-2:8008
      - PATRONI_POSTGRESQL_CONNECT_ADDRESS=node-2:5432
      - POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password
      - REPLICATION_PASSWORD_FILE=/run/secrets/replication_password
    configs:
      - source: patroni-config
        target: /etc/patroni.yml
      - source: postgresql-config
        target: /etc/postgresql/postgresql.conf
    secrets:
      - postgres_password
      - replication_password
      - dpg_password
      - shared_password
      - mcp_password
    deploy:
      placement:
        constraints:
          - node.labels.patroni_node == node-2
      restart_policy:
        condition: on-failure
    volumes:
      - patroni-node-2-data:/var/lib/postgresql/data
    command: patroni /etc/patroni.yml

  patroni-node-3:
    image: ruvnet/ruvector-postgres:latest
    hostname: node-3
    networks:
      - coordinator-net
    environment:
      - PATRONI_NAME=node-3
      - PATRONI_RESTAPI_CONNECT_ADDRESS=node-3:8008
      - PATRONI_POSTGRESQL_CONNECT_ADDRESS=node-3:5432
      - POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password
      - REPLICATION_PASSWORD_FILE=/run/secrets/replication_password
    configs:
      - source: patroni-config
        target: /etc/patroni.yml
      - source: postgresql-config
        target: /etc/postgresql/postgresql.conf
    secrets:
      - postgres_password
      - replication_password
      - dpg_password
      - shared_password
      - mcp_password
    deploy:
      placement:
        constraints:
          - node.labels.patroni_node == node-3
      restart_policy:
        condition: on-failure
    volumes:
      - patroni-node-3-data:/var/lib/postgresql/data
    command: patroni /etc/patroni.yml

configs:
  patroni-config:
    external: true
  postgresql-config:
    external: true

secrets:
  postgres_password:
    external: true
  replication_password:
    external: true
  dpg_password:
    external: true
  shared_password:
    external: true
  mcp_password:
    external: true

networks:
  coordinator-net:
    external: true

volumes:
  patroni-node-1-data:
  patroni-node-2-data:
  patroni-node-3-data:
EOF

# Deploy Patroni stack
docker stack deploy -c /tmp/patroni-stack.yml patroni-cluster

# Wait for initialization (60-90 seconds)
echo "Waiting 90 seconds for Patroni cluster initialization..."
sleep 90
```

#### Step 4.3: Verify Patroni Cluster

**On Host 1:**
```bash
# Get Patroni container ID
PATRONI_NODE1=$(docker ps -q -f name=patroni-cluster_patroni-node-1)

# Check cluster status
docker exec $PATRONI_NODE1 patronictl -c /etc/patroni.yml list postgres-cluster

# Expected output:
# + Cluster: postgres-cluster
# | Member   | Host   | Role    | State   | TL | Lag in MB |
# +----------+--------+---------+---------+----+-----------+
# | node-1   | node-1 | Leader  | running |  1 |           |
# | node-2   | node-2 | Replica | running |  1 |         0 |
# | node-3   | node-3 | Replica | running |  1 |         0 |

# Check replication status
docker exec $PATRONI_NODE1 psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# Expected: 2 rows (node-2 and node-3 replicating from node-1)
```

### Phase 5: HAProxy Deployment

#### Step 5.1: Create HAProxy Configuration

**On Host 1:**
```bash
cat > /tmp/haproxy.cfg <<'EOF'
global
    log stdout format raw local0
    maxconn 10000
    stats socket /var/run/haproxy.sock mode 600 level admin
    stats timeout 2m

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    retries 3
    timeout connect 5s
    timeout client  30s
    timeout server  30s

# Stats page
listen stats
    bind *:8404
    mode http
    stats enable
    stats uri /
    stats refresh 10s
    stats show-node
    stats show-legends

# PostgreSQL primary (read-write)
frontend postgres_frontend
    bind *:5432
    mode tcp
    default_backend postgres_backend

backend postgres_backend
    mode tcp
    option tcp-check
    tcp-check connect
    tcp-check send "GET /leader HTTP/1.0\r\n\r\n"
    tcp-check expect string "200 OK"

    server node-1 node-1:5432 check port 8008 inter 2s fall 3 rise 2
    server node-2 node-2:5432 check port 8008 inter 2s fall 3 rise 2 backup
    server node-3 node-3:5432 check port 8008 inter 2s fall 3 rise 2 backup

# PostgreSQL replicas (read-only)
frontend postgres_replica_frontend
    bind *:5433
    mode tcp
    default_backend postgres_replica_backend

backend postgres_replica_backend
    mode tcp
    balance roundrobin
    option tcp-check
    tcp-check connect
    tcp-check send "GET /replica HTTP/1.0\r\n\r\n"
    tcp-check expect string "200 OK"

    server node-2 node-2:5432 check port 8008 inter 2s fall 3 rise 2
    server node-3 node-3:5432 check port 8008 inter 2s fall 3 rise 2
EOF

# Create HAProxy config
docker config create haproxy-config /tmp/haproxy.cfg
```

#### Step 5.2: Deploy HAProxy

**On Host 1:**
```bash
cat > /tmp/haproxy-stack.yml <<'EOF'
version: '3.8'

services:
  haproxy:
    image: haproxy:2.9-alpine
    networks:
      - coordinator-net
      - admin-net
    ports:
      - target: 5432
        published: 5432
        mode: host
      - target: 5433
        published: 5433
        mode: host
      - target: 8404
        published: 8404
        mode: host
    configs:
      - source: haproxy-config
        target: /usr/local/etc/haproxy/haproxy.cfg
    deploy:
      replicas: 2
      placement:
        max_replicas_per_node: 1
      restart_policy:
        condition: on-failure

configs:
  haproxy-config:
    external: true

networks:
  coordinator-net:
    external: true
  admin-net:
    external: true
EOF

# Deploy HAProxy
docker stack deploy -c /tmp/haproxy-stack.yml haproxy

# Wait for startup
sleep 10

# Verify HAProxy
curl http://localhost:8404/
# Expected: HAProxy stats page
```

### Phase 6: Initial Data Setup

#### Step 6.1: Create Databases

**On Host 1:**
```bash
PATRONI_NODE1=$(docker ps -q -f name=patroni-cluster_patroni-node-1)

# Create databases (via primary)
docker exec $PATRONI_NODE1 psql -U postgres <<'EOF'
CREATE DATABASE distributed_postgres_cluster;
CREATE DATABASE claude_flow_shared;
EOF

# Verify databases
docker exec $PATRONI_NODE1 psql -U postgres -c "\l"
```

#### Step 6.2: Install RuVector Extension

```bash
# Install RuVector on both databases
docker exec $PATRONI_NODE1 psql -U postgres -d distributed_postgres_cluster -c "CREATE EXTENSION IF NOT EXISTS ruvector;"
docker exec $PATRONI_NODE1 psql -U postgres -d claude_flow_shared -c "CREATE EXTENSION IF NOT EXISTS ruvector;"

# Verify extension
docker exec $PATRONI_NODE1 psql -U postgres -d distributed_postgres_cluster -c "SELECT * FROM pg_extension WHERE extname = 'ruvector';"
```

#### Step 6.3: Create Application Users

```bash
# Source passwords
source /tmp/cluster-passwords.txt

# Create users
docker exec $PATRONI_NODE1 psql -U postgres <<EOF
CREATE USER dpg_cluster WITH ENCRYPTED PASSWORD '$DPG_PASSWORD';
CREATE USER shared_user WITH ENCRYPTED PASSWORD '$SHARED_PASSWORD';
CREATE USER mcp_user WITH ENCRYPTED PASSWORD '$MCP_PASSWORD';

GRANT ALL PRIVILEGES ON DATABASE distributed_postgres_cluster TO dpg_cluster;
GRANT ALL PRIVILEGES ON DATABASE claude_flow_shared TO shared_user;

\c distributed_postgres_cluster
GRANT SELECT ON ALL TABLES IN SCHEMA public TO mcp_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO mcp_user;

\c claude_flow_shared
GRANT SELECT ON ALL TABLES IN SCHEMA public TO mcp_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO mcp_user;
EOF
```

---

## Verification and Testing

### 1. Infrastructure Verification

```bash
# Check all services are running
docker stack services patroni-cluster
docker stack services haproxy
docker stack services etcd-cluster

# Expected: All replicas running (X/X)

# Check container health
docker ps | grep -E 'patroni|etcd|haproxy'
```

### 2. etcd Cluster Verification

```bash
ETCD1=$(docker ps -q -f name=etcd-cluster_etcd | head -1)

# Check cluster health
docker exec $ETCD1 etcdctl --endpoints=http://etcd-1:2379,http://etcd-2:2379,http://etcd-3:2379 endpoint health

# Expected: All 3 endpoints healthy

# Check leader
docker exec $ETCD1 etcdctl --endpoints=http://localhost:2379 endpoint status --write-out=table

# Verify Patroni keys
docker exec $ETCD1 etcdctl get /service/postgres-cluster/leader
# Expected: node-1 (or node-2, node-3)
```

### 3. Patroni Cluster Verification

```bash
PATRONI_NODE1=$(docker ps -q -f name=patroni-cluster_patroni-node-1)

# Check cluster status
docker exec $PATRONI_NODE1 patronictl -c /etc/patroni.yml list postgres-cluster

# Expected:
# | Member   | Host   | Role    | State   | TL | Lag in MB |
# | node-1   | node-1 | Leader  | running |  1 |           |
# | node-2   | node-2 | Replica | running |  1 |         0 |
# | node-3   | node-3 | Replica | running |  1 |         0 |

# Check replication
docker exec $PATRONI_NODE1 psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"

# Expected: 2 rows (streaming, async or sync)
```

### 4. Database Connectivity Test

```bash
# Test via HAProxy (primary)
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster -c "SELECT version();"

# Test via HAProxy (replica)
psql -h localhost -p 5433 -U dpg_cluster -d distributed_postgres_cluster -c "SELECT pg_is_in_recovery();"
# Expected: t (true - replica is in recovery mode)
```

### 5. RuVector Extension Test

```bash
# Test vector operations
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster <<'EOF'
-- Create test table
CREATE TABLE test_vectors (
    id SERIAL PRIMARY KEY,
    name TEXT,
    embedding ruvector(3)
);

-- Insert test data
INSERT INTO test_vectors (name, embedding) VALUES
('vec1', '[0.1, 0.2, 0.3]'),
('vec2', '[0.4, 0.5, 0.6]'),
('vec3', '[0.7, 0.8, 0.9]');

-- Test vector search
SELECT name, 1 - (embedding <=> '[0.2, 0.3, 0.4]'::ruvector) as similarity
FROM test_vectors
ORDER BY embedding <=> '[0.2, 0.3, 0.4]'::ruvector
LIMIT 2;

-- Clean up
DROP TABLE test_vectors;
EOF

# Expected: Query results with similarity scores
```

### 6. Failover Test

```bash
# Test automatic failover
PATRONI_NODE1=$(docker ps -q -f name=patroni-cluster_patroni-node-1)

# Stop primary
docker stop $PATRONI_NODE1

# Wait for failover (15-30 seconds)
sleep 30

# Check new primary
PATRONI_NODE2=$(docker ps -q -f name=patroni-cluster_patroni-node-2)
docker exec $PATRONI_NODE2 patronictl -c /etc/patroni.yml list postgres-cluster

# Expected: node-2 or node-3 is now Leader

# Test connectivity (should still work)
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster -c "SELECT 1;"

# Restart original primary (becomes standby)
docker start $PATRONI_NODE1

# Wait for rejoin
sleep 10

# Verify cluster
docker exec $PATRONI_NODE2 patronictl -c /etc/patroni.yml list postgres-cluster
# Expected: node-1 back as Replica
```

---

## Rollback Strategy

### Rollback Points

| Phase | Rollback Action | Impact | Time |
|-------|----------------|--------|------|
| **Phase 1** | Leave Docker Swarm | None (Swarm-only changes) | 1 min |
| **Phase 2** | Delete networks/secrets | None (no data) | 1 min |
| **Phase 3** | Remove etcd stack | None (no app data) | 2 min |
| **Phase 4** | Remove Patroni stack | Data loss if no backup | 5 min |
| **Phase 5** | Remove HAProxy stack | No client access | 1 min |
| **Phase 6** | Drop databases | Data loss | 2 min |

### Full Rollback Procedure

```bash
# 1. Stop all stacks
docker stack rm haproxy patroni-cluster etcd-cluster

# 2. Wait for services to stop
sleep 30

# 3. Remove volumes (WARNING: Data loss!)
docker volume rm $(docker volume ls -q | grep -E 'patroni|etcd')

# 4. Remove networks
docker network rm coordinator-net admin-net

# 5. Remove configs and secrets
docker config rm patroni-config postgresql-config haproxy-config etcd-config
docker secret rm postgres_password replication_password dpg_password shared_password mcp_password

# 6. Leave Docker Swarm (optional)
docker swarm leave --force
```

### Partial Rollback (Preserve Data)

```bash
# Stop HAProxy only (preserve Patroni/etcd)
docker service scale haproxy_haproxy=0

# Stop Patroni (preserve data volumes)
docker service scale patroni-cluster_patroni-node-1=0
docker service scale patroni-cluster_patroni-node-2=0
docker service scale patroni-cluster_patroni-node-3=0

# Data volumes remain intact for recovery
```

---

## Post-Deployment Tasks

### 1. Monitoring Setup

```bash
# Deploy Prometheus and Grafana
# (See monitoring stack configuration)

# Import Patroni dashboard (Grafana ID: 13927)
# Import PostgreSQL dashboard (Grafana ID: 9628)
```

### 2. Backup Configuration

```bash
# Enable WAL archiving (in patroni.yml)
# Configure pg_basebackup schedule
# Test backup restoration
```

### 3. Documentation

```bash
# Document:
# - Cluster topology (IPs, roles)
# - Password locations (secure vault)
# - Runbook procedures
# - Contact information
```

### 4. Security Hardening

```bash
# Enable SSL/TLS
# Configure firewall rules
# Rotate default passwords
# Enable audit logging
```

---

## Testing Checklist

### Functional Tests

- [ ] All services running (patroni, etcd, haproxy)
- [ ] etcd cluster healthy (3 nodes)
- [ ] Patroni cluster formed (1 primary + 2 standbys)
- [ ] Replication working (0 lag)
- [ ] HAProxy routing to primary
- [ ] Client connections successful
- [ ] RuVector extension working
- [ ] Both databases accessible (distributed_postgres_cluster, claude_flow_shared)
- [ ] Application users created with correct permissions

### High Availability Tests

- [ ] Primary failover (stop primary, new leader elected)
- [ ] Automatic rejoin (restart failed primary, becomes standby)
- [ ] Split-brain protection (network partition handled correctly)
- [ ] etcd leader failure (new leader elected)
- [ ] HAProxy failover (stop active HAProxy, passive takes over)

### Performance Tests

- [ ] Write throughput (target: 5,000 TPS)
- [ ] Read throughput (target: 50,000 TPS)
- [ ] Replication lag (<100ms)
- [ ] Failover time (<30s)
- [ ] Vector search performance (<10ms)

### Data Integrity Tests

- [ ] Write to primary, read from standby (data present)
- [ ] Failover preserves data (no data loss)
- [ ] Replication consistency (primary and standbys match)
- [ ] RuVector indexes replicated correctly

---

## Troubleshooting Guide

See `/docs/architecture/PATRONI_HA_DESIGN.md` Troubleshooting section for:
- Common deployment issues
- Service startup failures
- Replication problems
- Connectivity issues

---

## Support Resources

- **Architecture Document:** `/docs/architecture/PATRONI_HA_DESIGN.md`
- **Configuration Files:** `/config/patroni/`, `/config/etcd/`, `/config/postgresql/`
- **Patroni Documentation:** https://patroni.readthedocs.io/
- **etcd Documentation:** https://etcd.io/docs/
- **Docker Swarm Documentation:** https://docs.docker.com/engine/swarm/

---

**Document Version:** 1.0
**Last Updated:** 2026-02-12
**Author:** System Architecture Designer
**Status:** Ready for Deployment
