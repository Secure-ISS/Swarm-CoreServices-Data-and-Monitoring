# Quick Start Guide - Distributed PostgreSQL Cluster

**Deploy a distributed PostgreSQL cluster in 5 minutes**

---

## 🎯 What You'll Build

A distributed PostgreSQL cluster with:
- 3 coordinator nodes (Citus + Patroni HA)
- 4 worker nodes (100GB total capacity)
- Automatic failover (<10s coordinators, <5s workers)
- Vector operations (RuVector 2.0)
- Load balancing (HAProxy + PgBouncer)
- Monitoring (Prometheus + Grafana)

**Architecture:**
```
Application → postgres://cluster:5432/mydb
                ↓
        HAProxy (Load Balancer)
                ↓
    3 Coordinators (Citus + Patroni)
                ↓
    4 Workers (25GB each = 100GB total)
```

---

## ⚡ Prerequisites (5 minutes)

### Required Software
```bash
# Check versions
docker --version      # 20.10+
docker compose version  # 2.0+
git --version         # 2.30+

# Install if missing
# Ubuntu/Debian:
sudo apt update
sudo apt install -y docker.io docker-compose-v2 git

# macOS:
brew install docker docker-compose git
```

### Required Resources
- **CPU:** 4+ cores
- **RAM:** 8GB+ available
- **Disk:** 20GB+ free space
- **Network:** Internet connection for images

### Environment Setup
```bash
# Clone repository
git clone https://github.com/yourusername/Distributed-Postgress-Cluster.git
cd Distributed-Postgress-Cluster

# Set environment variables (optional)
export POSTGRES_VERSION=14.10  # Default: 14.10
export CLUSTER_SIZE=3          # Default: 3 coordinators
export WORKER_COUNT=4          # Default: 4 workers
```

---

## 🚀 Deployment (2 minutes)

### Option 1: Automated Deployment (Recommended)

```bash
# Deploy complete cluster
cd deployment/docker-swarm
../../scripts/deployment/initialize-cluster.sh postgres-mesh 3

# Wait for deployment (30-60 seconds)
# Watch logs
docker logs -f postgres-coordinator-1
```

### Option 2: Manual Deployment

```bash
# Initialize Docker Swarm
docker swarm init

# Deploy stack
cd deployment/docker-swarm
docker stack deploy -c docker-compose.yml postgres-mesh

# Verify deployment
docker stack services postgres-mesh
docker service ls | grep postgres-mesh
```

### Verify Deployment
```bash
# Check all services are running
docker stack services postgres-mesh

# Expected output:
# NAME                         REPLICAS  IMAGE
# postgres-mesh_coordinator    3/3       ruvnet/ruvector-postgres:14
# postgres-mesh_worker         4/4       ruvnet/ruvector-postgres:14
# postgres-mesh_haproxy        1/1       haproxy:2.9
# postgres-mesh_pgbouncer      3/3       edoburu/pgbouncer:1.21
# postgres-mesh_etcd           3/3       quay.io/coreos/etcd:v3.5
# postgres-mesh_prometheus     1/1       prom/prometheus:v2.47
# postgres-mesh_grafana        1/1       grafana/grafana:10.2

# Check health
curl http://localhost:8008/health  # HAProxy health
```

---

## 🔌 Connect to Cluster (30 seconds)

### Using psql
```bash
# Connect via HAProxy (recommended)
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster

# Or connect directly to coordinator
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster

# Password: dpg_cluster_2026
```

### Using Python
```python
import psycopg2

# Connect via connection pool
conn = psycopg2.connect(
    host="localhost",
    port=6432,  # PgBouncer port
    database="distributed_postgres_cluster",
    user="dpg_cluster",
    password="dpg_cluster_2026"
)

# Test connection
with conn.cursor() as cur:
    cur.execute("SELECT version()")
    print(cur.fetchone()[0])

conn.close()
```

### Using Application Connection String
```bash
# General format
postgres://dpg_cluster:dpg_cluster_2026@localhost:6432/distributed_postgres_cluster

# For Python (psycopg2)
postgresql://dpg_cluster:dpg_cluster_2026@localhost:6432/distributed_postgres_cluster

# For Node.js (pg)
postgres://dpg_cluster:dpg_cluster_2026@localhost:6432/distributed_postgres_cluster
```

---

## 📊 Create Distributed Tables (1 minute)

### Basic Distributed Table
```sql
-- Connect to coordinator
\c distributed_postgres_cluster

-- Create table
CREATE TABLE events (
    id BIGSERIAL,
    event_type TEXT,
    user_id BIGINT,
    data JSONB,
    created_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (id, user_id)
);

-- Distribute table across workers
SELECT create_distributed_table('events', 'user_id');

-- Verify distribution
SELECT * FROM citus_tables WHERE table_name = 'events';

-- Insert test data
INSERT INTO events (event_type, user_id, data)
VALUES
    ('login', 1, '{"ip": "192.168.1.1"}'),
    ('purchase', 2, '{"amount": 99.99}'),
    ('logout', 1, '{"duration": 3600}');

-- Query distributed data
SELECT * FROM events WHERE user_id = 1;
```

### Distributed Table with Vector Operations
```sql
-- Create table with vector embeddings
CREATE TABLE documents (
    id BIGSERIAL,
    namespace TEXT,
    content TEXT,
    embedding REAL[],
    metadata JSONB,
    created_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (id, namespace)
);

-- Distribute by namespace
SELECT create_distributed_table('documents', 'namespace');

-- Create HNSW index for vector search
CREATE INDEX ON documents USING hnsw (embedding) WITH (m=16, ef_construction=100);

-- Insert vectors
INSERT INTO documents (namespace, content, embedding, metadata)
VALUES
    ('docs', 'Hello world', ARRAY[0.1, 0.2, 0.3, 0.4], '{"lang": "en"}'),
    ('docs', 'Bonjour monde', ARRAY[0.2, 0.3, 0.4, 0.5], '{"lang": "fr"}');

-- Vector similarity search
SELECT id, content,
       1 - (embedding <=> ARRAY[0.1, 0.2, 0.3, 0.4]) AS similarity
FROM documents
WHERE namespace = 'docs'
ORDER BY embedding <=> ARRAY[0.1, 0.2, 0.3, 0.4]
LIMIT 10;
```

---

## 🎨 Access Monitoring (30 seconds)

### Grafana Dashboards
```bash
# Open Grafana
open http://localhost:3000

# Default credentials
# Username: admin
# Password: admin
# (change on first login)

# Pre-configured dashboards:
# - PostgreSQL Overview
# - Citus Distributed Metrics
# - Patroni HA Status
# - Connection Pool Metrics
# - System Resources
```

### Prometheus Metrics
```bash
# Access Prometheus
open http://localhost:9090

# Useful queries:
# - pg_up - Database availability
# - pg_stat_database_numbackends - Active connections
# - citus_shard_count - Shard distribution
# - patroni_master - Current master node
```

### HAProxy Stats
```bash
# Access HAProxy statistics
open http://localhost:8404/stats

# Username: admin
# Password: admin

# Shows:
# - Backend health
# - Connection counts
# - Request rates
# - Error rates
```

---

## 🧪 Test High Availability (1 minute)

### Test Automatic Failover
```bash
# Find current master
docker exec postgres-coordinator-1 patronictl list

# Simulate master failure
docker stop postgres-coordinator-1

# Watch automatic failover (should complete in <10s)
watch -n 1 "docker exec postgres-coordinator-2 patronictl list"

# Verify new master elected
# Connect and test
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster -c "SELECT 1"

# Restart old master (becomes replica)
docker start postgres-coordinator-1
```

### Test Load Balancing
```bash
# Run concurrent connections
for i in {1..10}; do
    psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster \
        -c "SELECT pg_backend_pid()" &
done

# Check connection distribution
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster \
    -c "SELECT count(*), client_addr FROM pg_stat_activity GROUP BY client_addr"
```

---

## 📈 Performance Testing (1 minute)

### Simple Load Test
```bash
# Install pgbench (if not installed)
sudo apt install postgresql-client  # Ubuntu/Debian
brew install postgresql               # macOS

# Initialize test database
pgbench -i -h localhost -p 6432 -U dpg_cluster distributed_postgres_cluster

# Run benchmark (1 minute, 10 clients)
pgbench -h localhost -p 6432 -U dpg_cluster \
    -c 10 -j 2 -T 60 distributed_postgres_cluster

# Expected output:
# transaction type: <builtin: TPC-B (sort of)>
# scaling factor: 1
# number of clients: 10
# number of threads: 2
# duration: 60 s
# number of transactions: 10000+
# tps = 166+ (including connections)
```

### Vector Search Performance
```bash
# Run vector search benchmark
python scripts/benchmark/vector_search_benchmark.py

# Expected results:
# - Insert rate: 1000+ ops/sec
# - Search latency (p95): <12ms
# - Concurrent queries: 100+ QPS
```

---

## 🔍 Verify Installation

### Health Checks
```bash
# Check cluster health
./scripts/health-check.sh

# Expected output:
# ✅ Docker Swarm: Active
# ✅ PostgreSQL Coordinators: 3/3 running
# ✅ PostgreSQL Workers: 4/4 running
# ✅ HAProxy: Running
# ✅ PgBouncer: 3/3 running
# ✅ etcd: 3/3 running
# ✅ Monitoring: Prometheus + Grafana running

# Check database health
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster <<EOF
-- Check Citus extension
SELECT * FROM citus_version();

-- Check worker nodes
SELECT * FROM citus_get_active_worker_nodes();

-- Check shard distribution
SELECT
    nodename,
    count(*) as shard_count
FROM citus_shards
GROUP BY nodename;
EOF
```

### Configuration Validation
```bash
# Validate Patroni configuration
docker exec postgres-coordinator-1 patronictl list

# Expected output:
# + Cluster: postgres-cluster -----+----+-----------+
# | Member       | Host    | Role    | State   | TL |
# +--------------+---------+---------+---------+----+
# | coordinator-1| 10.0.1.2| Leader  | running | 1  |
# | coordinator-2| 10.0.1.3| Replica | running | 1  |
# | coordinator-3| 10.0.1.4| Replica | running | 1  |

# Check connection pooling
docker exec postgres-pgbouncer-1 psql -p 6432 -U dpg_cluster pgbouncer -c "SHOW POOLS"

# Check HAProxy
curl http://localhost:8008/health
```

---

## 🚨 Troubleshooting

### Common Issues

#### Services Not Starting
```bash
# Check service logs
docker service logs postgres-mesh_coordinator
docker service logs postgres-mesh_worker

# Check resource constraints
docker stats

# Restart services
docker service update --force postgres-mesh_coordinator
```

#### Connection Refused
```bash
# Check ports
netstat -tlnp | grep -E '5432|6432|8008'

# Check HAProxy health
curl http://localhost:8008/health

# Check PgBouncer
psql -h localhost -p 6432 -U dpg_cluster pgbouncer -c "SHOW DATABASES"

# Check firewall
sudo ufw status
```

#### Failover Not Working
```bash
# Check etcd cluster
docker exec postgres-etcd-1 etcdctl member list
docker exec postgres-etcd-1 etcdctl endpoint health

# Check Patroni configuration
docker exec postgres-coordinator-1 cat /etc/patroni.yml

# Check logs
docker logs postgres-coordinator-1 | grep -i failover
```

#### Poor Performance
```bash
# Check connection pool
psql -h localhost -p 6432 -U dpg_cluster pgbouncer -c "SHOW POOLS"

# Check query performance
psql -h localhost -p 6432 -U dpg_cluster -d distributed_postgres_cluster \
    -c "SELECT * FROM pg_stat_statements ORDER BY total_time DESC LIMIT 10"

# Check resource usage
docker stats
```

---

## 📚 Next Steps

### Learn More
1. **[Architecture Overview](ARCHITECTURE_OVERVIEW.md)** - Understand system design
2. **[Operations Guide](OPERATIONS_GUIDE.md)** - Daily operations
3. **[Performance Tuning](performance/distributed-optimization.md)** - Optimize performance
4. **[Security Setup](SSL_TLS_SETUP.md)** - Enable TLS/SSL

### Advanced Features
- **[Scaling Guide](operations/SCALING_PLAYBOOK.md)** - Add more nodes
- **[Backup & Recovery](OPERATIONS_GUIDE.md#backup-procedures)** - Protect your data
- **[Monitoring Setup](MONITORING.md)** - Advanced monitoring
- **[Load Testing](LOAD_TESTING.md)** - Comprehensive benchmarks

### Production Deployment
- **[Production Deployment Guide](architecture/PRODUCTION_DEPLOYMENT.md)** - Deploy to production
- **[Security Hardening](security/distributed-security-architecture.md)** - Secure your cluster
- **[High Availability Setup](PATRONI_SETUP.md)** - Configure HA properly
- **[Disaster Recovery](OPERATIONS_GUIDE.md#disaster-recovery)** - DR planning

---

## 🎉 Congratulations!

You now have a fully functional distributed PostgreSQL cluster with:
- ✅ Distributed data storage across 4 workers
- ✅ High availability with automatic failover
- ✅ Load balancing and connection pooling
- ✅ Vector search capabilities
- ✅ Complete monitoring stack

**Ready for development!** 🚀

---

## 🆘 Getting Help

**Issues?**
- Check [Troubleshooting Guide](OPERATIONS_GUIDE.md#troubleshooting)
- Review [Runbooks](RUNBOOKS.md)
- See [Documentation Index](README.md)

**Questions?**
- Review [Architecture Overview](ARCHITECTURE_OVERVIEW.md)
- Check [Operations Guide](OPERATIONS_GUIDE.md)
- See [FAQ](OPERATIONS_GUIDE.md#faq)

---

**Total Time:** ~5 minutes ⏱️

*Last Updated: 2026-02-12*
