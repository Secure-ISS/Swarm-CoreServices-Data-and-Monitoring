# Patroni HA Setup Guide

This guide covers setting up a Patroni high-availability cluster for the Distributed PostgreSQL Cluster project.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Patroni Installation](#patroni-installation)
4. [Configuration](#configuration)
5. [Cluster Initialization](#cluster-initialization)
6. [Verification](#verification)
7. [Integration with Application](#integration-with-application)

## Architecture Overview

Patroni provides automatic failover and high availability for PostgreSQL through:

- **Leader Election**: Automatic primary node election via DCS (etcd/Consul/ZooKeeper)
- **Health Monitoring**: Continuous health checks on all nodes
- **Automatic Failover**: Promotes replica to primary when primary fails
- **REST API**: Exposes cluster state and topology

### Typical Setup

```
┌─────────────────────────────────────────────────────────┐
│                    Load Balancer                        │
│                   (HAProxy/PgBouncer)                   │
└────────────┬───────────────────────────┬────────────────┘
             │                           │
    ┌────────▼─────────┐        ┌───────▼────────┐
    │   Primary Node   │        │  Replica Node  │
    │  (node1:5432)    │◄──────►│  (node2:5432)  │
    │  Patroni:8008    │ Repl.  │  Patroni:8008  │
    └────────┬─────────┘        └────────┬───────┘
             │                           │
             │    ┌───────────────┐     │
             └───►│  DCS (etcd)   │◄────┘
                  │  node1:2379   │
                  └───────────────┘
```

## Prerequisites

### Hardware Requirements

- **Minimum**: 3 nodes (1 primary, 2 replicas)
- **CPU**: 4+ cores per node
- **RAM**: 8GB+ per node
- **Disk**: 100GB+ SSD per node
- **Network**: 1 Gbps+ between nodes

### Software Requirements

- **OS**: Ubuntu 20.04+ or RHEL 8+ (or compatible)
- **PostgreSQL**: 12+ (14+ recommended)
- **Python**: 3.7+ (for Patroni)
- **DCS**: etcd 3.3+ OR Consul 1.9+ OR ZooKeeper 3.4+

### Network Requirements

- All nodes must be able to reach each other
- Ports required:
  - **5432**: PostgreSQL
  - **8008**: Patroni REST API
  - **2379**: etcd client (if using etcd)
  - **2380**: etcd peer (if using etcd)

## Patroni Installation

### Install on Ubuntu/Debian

```bash
# Install PostgreSQL 14
sudo apt-get update
sudo apt-get install -y postgresql-14 postgresql-server-dev-14

# Install Python and pip
sudo apt-get install -y python3 python3-pip python3-dev

# Install Patroni and dependencies
sudo pip3 install patroni[etcd]
# OR for Consul: sudo pip3 install patroni[consul]
# OR for ZooKeeper: sudo pip3 install patroni[zookeeper]

# Install psycopg2 (PostgreSQL adapter)
sudo pip3 install psycopg2-binary
```

### Install on RHEL/CentOS

```bash
# Install PostgreSQL 14
sudo dnf install -y postgresql14-server postgresql14-devel

# Install Python and pip
sudo dnf install -y python3 python3-pip python3-devel

# Install Patroni
sudo pip3 install patroni[etcd]

# Install psycopg2
sudo pip3 install psycopg2-binary
```

### Install etcd (DCS)

etcd is the recommended DCS for Patroni.

```bash
# Download and install etcd
ETCD_VERSION="3.5.9"
wget https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz
tar xzvf etcd-v${ETCD_VERSION}-linux-amd64.tar.gz
sudo mv etcd-v${ETCD_VERSION}-linux-amd64/etcd* /usr/local/bin/

# Create etcd user and directories
sudo useradd -r -s /bin/false etcd
sudo mkdir -p /var/lib/etcd
sudo chown etcd:etcd /var/lib/etcd

# Create systemd service
sudo tee /etc/systemd/system/etcd.service > /dev/null <<EOF
[Unit]
Description=etcd key-value store
After=network.target

[Service]
Type=notify
User=etcd
ExecStart=/usr/local/bin/etcd \\
  --name node1 \\
  --data-dir /var/lib/etcd \\
  --listen-client-urls http://0.0.0.0:2379 \\
  --advertise-client-urls http://node1:2379 \\
  --listen-peer-urls http://0.0.0.0:2380 \\
  --initial-advertise-peer-urls http://node1:2380 \\
  --initial-cluster node1=http://node1:2380 \\
  --initial-cluster-token my-etcd-cluster \\
  --initial-cluster-state new
Restart=always
RestartSec=10s
LimitNOFILE=40000

[Install]
WantedBy=multi-user.target
EOF

# Enable and start etcd
sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd

# Verify etcd is running
etcdctl member list
```

## Configuration

### 1. PostgreSQL Configuration

Stop PostgreSQL if it's running:

```bash
sudo systemctl stop postgresql
```

### 2. Patroni Configuration

Create Patroni configuration file `/etc/patroni/patroni.yml`:

```yaml
scope: postgres-cluster
namespace: /service/
name: node1  # Change per node: node1, node2, node3

restapi:
  listen: 0.0.0.0:8008
  connect_address: node1:8008  # Change per node

etcd:
  hosts: node1:2379  # Add all etcd nodes if clustering etcd

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      parameters:
        max_connections: 100
        shared_buffers: 2GB
        effective_cache_size: 6GB
        maintenance_work_mem: 512MB
        checkpoint_completion_target: 0.9
        wal_buffers: 16MB
        default_statistics_target: 100
        random_page_cost: 1.1
        effective_io_concurrency: 200
        work_mem: 10485kB
        min_wal_size: 1GB
        max_wal_size: 4GB
        max_worker_processes: 4
        max_parallel_workers_per_gather: 2
        max_parallel_workers: 4
        max_parallel_maintenance_workers: 2
        wal_level: replica
        hot_standby: on
        max_wal_senders: 10
        max_replication_slots: 10
        hot_standby_feedback: on
        logging_collector: on
        log_directory: pg_log
        log_filename: postgresql-%a.log
        log_truncate_on_rotation: on
        log_rotation_age: 1d
        log_min_duration_statement: 1000

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - host replication replicator 0.0.0.0/0 md5
    - host all all 0.0.0.0/0 md5

  users:
    admin:
      password: admin_password_change_me
      options:
        - createrole
        - createdb
    replicator:
      password: replicator_password_change_me
      options:
        - replication

postgresql:
  listen: 0.0.0.0:5432
  connect_address: node1:5432  # Change per node
  data_dir: /var/lib/postgresql/14/main
  bin_dir: /usr/lib/postgresql/14/bin
  pgpass: /tmp/pgpass
  authentication:
    replication:
      username: replicator
      password: replicator_password_change_me
    superuser:
      username: postgres
      password: postgres_password_change_me
  parameters:
    unix_socket_directories: /var/run/postgresql

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
```

### 3. Create Systemd Service for Patroni

```bash
sudo tee /etc/systemd/system/patroni.service > /dev/null <<EOF
[Unit]
Description=Patroni PostgreSQL Cluster Manager
After=syslog.target network.target etcd.service

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/local/bin/patroni /etc/patroni/patroni.yml
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
TimeoutSec=30
Restart=no

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
```

## Cluster Initialization

### Node 1 (Primary)

```bash
# Create configuration directory
sudo mkdir -p /etc/patroni
sudo chown postgres:postgres /etc/patroni

# Copy patroni.yml configuration (adjust for node1)
sudo cp patroni-node1.yml /etc/patroni/patroni.yml

# Enable and start Patroni
sudo systemctl enable patroni
sudo systemctl start patroni

# Check status
sudo systemctl status patroni
patronictl -c /etc/patroni/patroni.yml list
```

### Node 2 (Replica)

```bash
# Update patroni.yml with node2 settings:
# - name: node2
# - connect_address: node2:5432
# - restapi.connect_address: node2:8008

# Start Patroni
sudo systemctl enable patroni
sudo systemctl start patroni

# Verify replication
patronictl -c /etc/patroni/patroni.yml list
```

### Node 3 (Replica)

Repeat Node 2 steps with node3 settings.

## Verification

### Check Cluster Status

```bash
# List cluster members
patronictl -c /etc/patroni/patroni.yml list

# Expected output:
# + Cluster: postgres-cluster (7234567890123456789) ---+----+-----------+
# | Member  | Host        | Role    | State   | TL | Lag in MB |
# +---------+-------------+---------+---------+----+-----------+
# | node1   | node1:5432  | Leader  | running |  1 |           |
# | node2   | node2:5432  | Replica | running |  1 |         0 |
# | node3   | node3:5432  | Replica | running |  1 |         0 |
# +---------+-------------+---------+---------+----+-----------+
```

### Verify REST API

```bash
# Check cluster endpoint
curl http://node1:8008/cluster

# Check primary
curl http://node1:8008/leader

# Check replica
curl http://node2:8008/replica
```

### Test Replication

```bash
# On primary (node1)
psql -U postgres -h node1 -c "CREATE DATABASE test_replication;"
psql -U postgres -h node1 -d test_replication -c "CREATE TABLE test (id SERIAL, data TEXT);"
psql -U postgres -h node1 -d test_replication -c "INSERT INTO test (data) VALUES ('test-data');"

# Wait a moment, then check replica (node2)
psql -U postgres -h node2 -d test_replication -c "SELECT * FROM test;"

# Should see the inserted data
```

### Test Failover

```bash
# Stop primary node
sudo systemctl stop patroni  # On node1

# Wait 30-60 seconds for failover

# Check cluster status
patronictl -c /etc/patroni/patroni.yml list

# One of the replicas should now be Leader
```

## Integration with Application

### Update Environment Variables

In your application's `.env` file:

```bash
# Enable Patroni HA mode
ENABLE_PATRONI=true

# Patroni REST API endpoints (all nodes)
PATRONI_HOSTS=node1,node2,node3
PATRONI_PORT=8008

# Database credentials
PATRONI_DB=distributed_postgres_cluster
PATRONI_USER=postgres
PATRONI_PASSWORD=postgres_password_change_me

# Connection pool settings
PATRONI_MIN_CONNECTIONS=2
PATRONI_MAX_CONNECTIONS=20
PATRONI_HEALTH_CHECK_INTERVAL=30
```

### Install RuVector Extension

On all nodes:

```bash
# Clone and build RuVector
git clone https://github.com/ruvnet/ruvector.git
cd ruvector
make
sudo make install

# Create extension in database
psql -U postgres -h node1 -d distributed_postgres_cluster -c "CREATE EXTENSION IF NOT EXISTS ruvector;"
```

### Run Application Tests

```bash
# Test Patroni connection
python scripts/test_patroni_connection.py

# Run health check
from src.db.pool import get_pools
pools = get_pools()
health = pools.health_check()
print(health)
```

## Best Practices

### 1. Use HAProxy for Load Balancing

Configure HAProxy to route writes to primary and reads to replicas:

```
frontend postgres_write
    bind *:5433
    default_backend postgres_primary

backend postgres_primary
    option httpchk GET /leader
    http-check expect status 200
    server node1 node1:5432 check port 8008
    server node2 node2:5432 check port 8008 backup
    server node3 node3:5432 check port 8008 backup

frontend postgres_read
    bind *:5434
    default_backend postgres_replicas

backend postgres_replicas
    option httpchk GET /replica
    balance roundrobin
    server node2 node2:5432 check port 8008
    server node3 node3:5432 check port 8008
```

### 2. Monitor Cluster Health

Set up monitoring with:
- Prometheus + Grafana for metrics
- patroni_exporter for Patroni metrics
- postgres_exporter for PostgreSQL metrics

### 3. Regular Backups

```bash
# Backup from replica to avoid primary load
pg_basebackup -h node2 -U replicator -D /backup/$(date +%Y%m%d) -Fp -Xs -P
```

### 4. Configure Alerts

Alert on:
- Failover events
- Replication lag > 10 MB
- Node down for > 1 minute
- DCS (etcd) unavailable

## Troubleshooting

### Issue: Replica won't join cluster

**Check:**
1. Can replica reach etcd?
2. Is replicator user configured correctly?
3. Are pg_hba.conf rules correct?

```bash
# Test replication connection
psql "host=node1 user=replicator dbname=postgres replication=database" -c "IDENTIFY_SYSTEM"
```

### Issue: Split-brain after network partition

Patroni prevents split-brain via DCS. Ensure etcd is configured with proper quorum (odd number of nodes).

### Issue: High replication lag

**Check:**
1. Network bandwidth between nodes
2. Disk I/O on replica
3. Large transactions on primary

```bash
# Check replication lag
psql -U postgres -h node2 -c "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"
```

## Summary

This guide covered:
- ✓ Patroni architecture and setup
- ✓ etcd DCS installation
- ✓ Cluster initialization with 3 nodes
- ✓ Verification and testing
- ✓ Application integration
- ✓ Best practices and troubleshooting

For more information:
- Patroni documentation: https://patroni.readthedocs.io/
- PostgreSQL replication: https://www.postgresql.org/docs/current/high-availability.html
