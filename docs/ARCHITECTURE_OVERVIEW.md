# Architecture Overview - Distributed PostgreSQL Cluster

**High-level system design and architectural patterns**

---

## 🎯 Executive Summary

A production-ready distributed PostgreSQL architecture that presents as **one database** while distributing data across multiple nodes with automatic failover, load balancing, and vector operations.

**Key Characteristics:**
- **Single Endpoint:** Applications connect to one URL
- **Distributed Storage:** Data sharded across 4 workers (100GB capacity)
- **High Availability:** <10s coordinator failover, <5s worker failover
- **Horizontal Scaling:** Add workers for capacity, coordinators for redundancy
- **Zero Licensing:** 100% open source PostgreSQL

---

## 🏗 System Architecture

### High-Level View

```
┌─────────────────────────────────────────────────────────────┐
│                        Application Layer                     │
│         postgres://cluster:5432/distributed_postgres_cluster │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Load Balancer Layer                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │  HAProxy     │  │  PgBouncer   │  │  PgBouncer   │      │
│  │  (Port 8008) │  │  (Port 6432) │  │  (Port 6432) │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   Coordinator Layer (Citus)                  │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐│
│  │ Coordinator-1  │  │ Coordinator-2  │  │ Coordinator-3  ││
│  │ (Master)       │  │ (Replica)      │  │ (Replica)      ││
│  │ Port 5432      │  │ Port 5432      │  │ Port 5432      ││
│  │ + Patroni      │  │ + Patroni      │  │ + Patroni      ││
│  └────────────────┘  └────────────────┘  └────────────────┘│
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      Worker Layer (Storage)                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │ Worker-1 │  │ Worker-2 │  │ Worker-3 │  │ Worker-4 │   │
│  │ 25GB     │  │ 25GB     │  │ 25GB     │  │ 25GB     │   │
│  │ Port 5432│  │ Port 5432│  │ Port 5432│  │ Port 5432│   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
│                    Total Capacity: 100GB                     │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                  Consensus Layer (etcd)                      │
│  ┌───────────┐      ┌───────────┐      ┌───────────┐       │
│  │  etcd-1   │      │  etcd-2   │      │  etcd-3   │       │
│  │ Port 2379 │      │ Port 2379 │      │ Port 2379 │       │
│  └───────────┘      └───────────┘      └───────────┘       │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Monitoring Layer                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ Prometheus   │  │  Grafana     │  │  Alertmanager│      │
│  │ Port 9090    │  │  Port 3000   │  │  Port 9093   │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
└─────────────────────────────────────────────────────────────┘
```

---

## 🔄 Request Flow

### Write Request Flow

```
1. Application → HAProxy:8008
   "INSERT INTO users VALUES (...)"

2. HAProxy → PgBouncer (coordinator-1):6432
   Routes to master coordinator

3. PgBouncer → Coordinator-1:5432
   Connection pooling (reuse existing connection)

4. Coordinator-1 → Query Planner
   "Which shard(s) need this data?"
   Determines worker based on distribution column

5. Coordinator-1 → Worker-2:5432
   Sends write to appropriate worker

6. Worker-2 → Disk
   Writes data to storage

7. Worker-2 → Coordinator-1
   ACK write completed

8. Coordinator-1 → PgBouncer
   Return success to client

9. PgBouncer → HAProxy → Application
   "INSERT 1"
```

### Read Request Flow

```
1. Application → HAProxy:8008
   "SELECT * FROM users WHERE tenant_id = 123"

2. HAProxy → PgBouncer (any coordinator):6432
   Can route to master or replica

3. PgBouncer → Coordinator-2:5432 (replica)
   Connection pooling

4. Coordinator-2 → Query Planner
   "Which shard(s) have tenant_id = 123?"
   Looks up metadata

5. Coordinator-2 → Worker-3:5432
   Sends query to specific worker(s)

6. Worker-3 → Coordinator-2
   Returns result rows

7. Coordinator-2 → PgBouncer
   Returns combined results

8. PgBouncer → HAProxy → Application
   Result set
```

### Vector Search Request Flow

```
1. Application → HAProxy:8008
   "SELECT * FROM vectors WHERE embedding <=> $1 ORDER BY ... LIMIT 10"

2. HAProxy → PgBouncer → Coordinator-1:5432

3. Coordinator-1 → Query Planner
   Distributed HNSW index lookup
   Determines which workers to query

4. Coordinator-1 → [Worker-1, Worker-2, Worker-3, Worker-4]
   Parallel queries to all workers with HNSW indexes

5. Workers → HNSW Index Search
   Each worker searches local HNSW index
   Returns top-k candidates

6. Workers → Coordinator-1
   Return local top-k results

7. Coordinator-1 → Merge Results
   Combines results from all workers
   Re-ranks and returns global top-10

8. Coordinator-1 → Application
   Final top-10 results
```

---

## 🧩 Component Architecture

### 1. Load Balancer Layer

#### HAProxy
- **Role:** L4 load balancer
- **Port:** 8008 (external), forwards to 5432 (PostgreSQL)
- **Features:**
  - Health checks every 2 seconds
  - Automatic backend failure detection
  - Round-robin load balancing
  - Master/replica routing
  - Connection limiting

#### PgBouncer
- **Role:** Connection pooler
- **Port:** 6432 (external), connects to 5432 (PostgreSQL)
- **Features:**
  - Connection reuse (session pooling)
  - Max 100 connections per pool
  - Query routing to master/replica
  - Connection queue management
  - Reduced PostgreSQL overhead

```
Connection Math:
- 1000 application connections → HAProxy
- HAProxy → 3 PgBouncer instances
- Each PgBouncer → 100 PostgreSQL connections (max)
- Total PostgreSQL connections: 300 (instead of 1000)
```

### 2. Coordinator Layer (Citus)

#### Citus Extension
- **Role:** Distributed query processing
- **Key Functions:**
  - Sharding metadata management
  - Query planning and routing
  - Distributed transaction coordination
  - Result aggregation
  - Worker health monitoring

#### Patroni
- **Role:** High availability and failover
- **Key Functions:**
  - Leader election (via etcd)
  - Automatic failover (<10s)
  - Configuration management
  - Replication monitoring
  - Backup coordination

```
Failover Scenario:
1. Coordinator-1 (master) fails
2. Patroni detects failure (5s heartbeat timeout)
3. etcd consensus initiates leader election
4. Coordinator-2 promoted to master (2-3s)
5. HAProxy detects new master (2s health check)
6. Total downtime: ~10s
```

### 3. Worker Layer

#### PostgreSQL Workers
- **Role:** Data storage and computation
- **Configuration:**
  - 4 workers × 25GB = 100GB total capacity
  - Each worker: 2 CPU, 4GB RAM (configurable)
  - RuVector 2.0 extension installed
  - HNSW indexes for vector search

#### Sharding Strategy
```sql
-- Hash-based sharding on distribution column
SELECT create_distributed_table('users', 'tenant_id');

-- Result: Data distributed across workers
-- tenant_id % 4 determines worker placement
-- Worker-1: tenant_ids ending in 0 (0, 4, 8, ...)
-- Worker-2: tenant_ids ending in 1 (1, 5, 9, ...)
-- Worker-3: tenant_ids ending in 2 (2, 6, 10, ...)
-- Worker-4: tenant_ids ending in 3 (3, 7, 11, ...)
```

### 4. Consensus Layer (etcd)

#### etcd Cluster
- **Role:** Distributed configuration and leader election
- **Configuration:**
  - 3-node cluster (quorum requires 2 of 3)
  - Raft consensus protocol
  - Stores Patroni cluster state
  - Monitors coordinator health

```
etcd Key-Value Store:
/patroni/postgres-cluster/
  ├── config (cluster configuration)
  ├── leader (current master)
  ├── members/
  │   ├── coordinator-1 (health, role)
  │   ├── coordinator-2 (health, role)
  │   └── coordinator-3 (health, role)
  └── history (failover history)
```

### 5. Monitoring Layer

#### Prometheus
- **Role:** Metrics collection and storage
- **Metrics:**
  - PostgreSQL: connections, queries, replication lag
  - Citus: shard distribution, worker health
  - Patroni: cluster state, failover events
  - System: CPU, memory, disk, network

#### Grafana
- **Role:** Visualization and dashboards
- **Dashboards:**
  - PostgreSQL Overview
  - Citus Distributed Metrics
  - Patroni HA Status
  - Connection Pool Metrics
  - System Resources

---

## 📊 Data Distribution

### Sharding Model

```
┌─────────────────────────────────────────────────────┐
│                 Distributed Table                    │
│                   (Logical View)                     │
│  ┌────────────────────────────────────────────────┐ │
│  │  users (tenant_id, name, email, created_at)    │ │
│  └────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
                        │
         ┌──────────────┼──────────────┐
         │              │              │
         ▼              ▼              ▼
  ┌──────────┐   ┌──────────┐   ┌──────────┐
  │ Shard 1  │   │ Shard 2  │   │ Shard N  │
  │ (range)  │   │ (range)  │   │ (range)  │
  └──────────┘   └──────────┘   └──────────┘
       │              │              │
       ▼              ▼              ▼
  ┌──────────┐   ┌──────────┐   ┌──────────┐
  │ Worker-1 │   │ Worker-2 │   │ Worker-N │
  │ (storage)│   │ (storage)│   │ (storage)│
  └──────────┘   └──────────┘   └──────────┘
```

### Replication Model

```
┌─────────────────────────────────────────────────────┐
│              Coordinator Replication                 │
│                  (Streaming Replication)             │
│                                                       │
│  ┌──────────────┐         ┌──────────────┐          │
│  │Coordinator-1 │────────→│Coordinator-2 │          │
│  │  (Master)    │         │  (Replica)   │          │
│  └──────────────┘    │    └──────────────┘          │
│         │            │                               │
│         │            └───→┌──────────────┐          │
│         │                 │Coordinator-3 │          │
│         │                 │  (Replica)   │          │
│         │                 └──────────────┘          │
│         │                                             │
│         └────→ Only metadata replicated               │
│                (Citus metadata tables)                │
│                                                       │
│         ┌─────────────────────────────────┐          │
│         │  Shards NOT replicated between  │          │
│         │  workers (use Patroni for HA)   │          │
│         └─────────────────────────────────┘          │
└─────────────────────────────────────────────────────┘
```

---

## 🔐 Security Architecture

### Network Security

```
┌─────────────────────────────────────────────────────┐
│                  Security Layers                     │
│                                                       │
│  Internet/WAN                                        │
│       ↓                                              │
│  ┌─────────────────────────────────────────┐        │
│  │  Firewall (iptables/ufw)                │        │
│  │  - Allow 8008 (HAProxy)                 │        │
│  │  - Deny direct PostgreSQL (5432)        │        │
│  └─────────────────────────────────────────┘        │
│       ↓                                              │
│  ┌─────────────────────────────────────────┐        │
│  │  TLS/SSL Layer                          │        │
│  │  - Certificate validation               │        │
│  │  - Encrypted connections                │        │
│  └─────────────────────────────────────────┘        │
│       ↓                                              │
│  ┌─────────────────────────────────────────┐        │
│  │  HAProxy                                │        │
│  │  - Rate limiting                        │        │
│  │  - Connection limits                    │        │
│  └─────────────────────────────────────────┘        │
│       ↓                                              │
│  ┌─────────────────────────────────────────┐        │
│  │  PostgreSQL Authentication              │        │
│  │  - Password (scram-sha-256)             │        │
│  │  - SSL certificates                     │        │
│  │  - pg_hba.conf rules                    │        │
│  └─────────────────────────────────────────┘        │
│       ↓                                              │
│  ┌─────────────────────────────────────────┐        │
│  │  Application Layer                      │        │
│  │  - Input validation                     │        │
│  │  - Parameterized queries                │        │
│  │  - SQL injection prevention             │        │
│  └─────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────┘
```

### Access Control

```
Users & Roles:
├── superuser (postgres)
│   └── Full cluster administration
├── dpg_cluster (application owner)
│   ├── Create/drop databases
│   ├── Create/modify tables
│   └── Grant permissions
├── app_readonly
│   └── SELECT on all tables
└── app_readwrite
    ├── SELECT, INSERT, UPDATE, DELETE
    └── No DDL operations
```

---

## 🚀 Scalability Patterns

### Horizontal Scaling (Add Workers)

```
Current: 4 workers × 25GB = 100GB capacity

Scale to: 8 workers × 25GB = 200GB capacity

Steps:
1. Deploy new workers (worker-5, worker-6, worker-7, worker-8)
2. Register workers with coordinator:
   SELECT citus_add_node('worker-5', 5432)
3. Rebalance shards:
   SELECT rebalance_table_shards('users')
4. Monitor rebalancing progress
5. Verify shard distribution

Downtime: 0 (online operation)
Duration: ~1-2 hours for data rebalancing
```

### Vertical Scaling (Increase Resources)

```
Current: 2 CPU, 4GB RAM per node

Scale to: 4 CPU, 8GB RAM per node

Steps:
1. Rolling restart with new resource limits
2. Update Docker service:
   docker service update --limit-cpu 4 --limit-memory 8g worker-1
3. Repeat for each worker
4. Monitor performance improvement

Downtime: 0 (rolling restart)
Duration: ~30 minutes
```

### Read Scaling (Add Replicas)

```
Add coordinator replicas for read scaling:

Current: 1 master + 2 replicas = 3 coordinators

Scale to: 1 master + 4 replicas = 5 coordinators

Steps:
1. Deploy new coordinator nodes
2. Patroni automatically replicates metadata
3. Configure HAProxy to include new replicas
4. Route read queries to replicas

Downtime: 0
Duration: ~10 minutes
```

---

## 📈 Performance Characteristics

### Latency Profile

```
Operation           | p50    | p95    | p99    | Target
--------------------|--------|--------|--------|---------
Simple SELECT       | 2ms    | 5ms    | 8ms    | <10ms
Distributed SELECT  | 5ms    | 12ms   | 18ms   | <20ms
INSERT              | 3ms    | 8ms    | 12ms   | <15ms
Vector search (k=10)| 8ms    | 15ms   | 25ms   | <30ms
```

### Throughput Targets

```
Workload               | Target     | Achieved
-----------------------|------------|----------
Simple queries         | 10,000 TPS | TBD
Distributed queries    | 5,000 TPS  | TBD
Vector searches        | 1,000 QPS  | TBD
Concurrent connections | 1,000      | TBD
```

### Scaling Limits

```
Dimension              | Limit          | Reason
-----------------------|----------------|------------------------
Max workers            | 32             | Citus coordinator limit
Max coordinators       | 10             | Diminishing returns
Max connections/worker | 100            | PostgreSQL config
Max database size      | 800GB (32×25GB)| Worker capacity
Max shard count        | 128            | Optimal balance
```

---

## 🔄 Deployment Topologies

### Development (Single Node)

```
┌────────────────────────────┐
│      Single Docker Host    │
│                            │
│  ┌──────────────────────┐  │
│  │ All-in-one Container │  │
│  │ - Coordinator        │  │
│  │ - Worker (1)         │  │
│  │ - HAProxy            │  │
│  │ - PgBouncer          │  │
│  └──────────────────────┘  │
└────────────────────────────┘

Resources: 4GB RAM, 2 CPU
Use case: Development, testing
```

### Production (Docker Swarm)

```
┌─────────────────────────────────────────────┐
│           Docker Swarm Cluster              │
│                                             │
│  ┌─────────────┐  ┌─────────────┐         │
│  │  Manager-1  │  │  Manager-2  │         │
│  │  + etcd     │  │  + etcd     │         │
│  └─────────────┘  └─────────────┘         │
│                                             │
│  ┌─────────────┐  ┌─────────────┐         │
│  │  Worker-1   │  │  Worker-2   │         │
│  │  + Coord    │  │  + Coord    │         │
│  │  + PgBouncer│  │  + PgBouncer│         │
│  └─────────────┘  └─────────────┘         │
│                                             │
│  ┌─────────────┐  ┌─────────────┐         │
│  │  Worker-3   │  │  Worker-4   │         │
│  │  + Storage  │  │  + Storage  │         │
│  └─────────────┘  └─────────────┘         │
└─────────────────────────────────────────────┘

Resources: 32GB RAM, 16 CPU total
Use case: Production, high availability
```

### Enterprise (Kubernetes)

```
┌─────────────────────────────────────────────┐
│        Kubernetes Cluster                   │
│                                             │
│  Namespace: postgres-cluster                │
│                                             │
│  ┌──────────────────────────────┐          │
│  │  StatefulSet: coordinators   │          │
│  │  - Replicas: 3               │          │
│  │  - PVC: 50GB each            │          │
│  └──────────────────────────────┘          │
│                                             │
│  ┌──────────────────────────────┐          │
│  │  StatefulSet: workers        │          │
│  │  - Replicas: 4               │          │
│  │  - PVC: 100GB each           │          │
│  └──────────────────────────────┘          │
│                                             │
│  ┌──────────────────────────────┐          │
│  │  Deployment: pgbouncer       │          │
│  │  - Replicas: 3               │          │
│  └──────────────────────────────┘          │
│                                             │
│  ┌──────────────────────────────┐          │
│  │  Service: LoadBalancer       │          │
│  │  - External IP               │          │
│  └──────────────────────────────┘          │
└─────────────────────────────────────────────┘

Resources: Autoscaling
Use case: Enterprise, cloud-native
```

---

## 🧠 Design Patterns

### 1. Command Query Responsibility Segregation (CQRS)

```
Write Path (Commands):
Application → HAProxy → Master Coordinator → Workers

Read Path (Queries):
Application → HAProxy → Replica Coordinator → Workers

Benefits:
- Read scaling independent of writes
- Reduced load on master
- Optimized read replicas
```

### 2. Circuit Breaker

```
HAProxy health checks:
- Check interval: 2 seconds
- Failure threshold: 3 consecutive failures
- Recovery: Automatic when health restored

Behavior:
- Working backend: Route traffic
- Failed backend: Stop routing (circuit open)
- Recovered backend: Resume routing (circuit closed)
```

### 3. Connection Pooling

```
Application (1000 connections)
         ↓
PgBouncer (pools to 100 connections)
         ↓
PostgreSQL (100 actual connections)

Benefits:
- Reduced PostgreSQL overhead
- Faster connection reuse
- Better resource utilization
```

### 4. Saga Pattern (Distributed Transactions)

```
For multi-shard transactions:
1. Begin distributed transaction
2. Execute on each shard
3. Prepare to commit (2PC)
4. Commit or rollback all shards

Citus handles:
- Two-phase commit protocol
- Coordinator-worker coordination
- Rollback on any failure
```

---

## 🔍 Observability

### Metrics Collection

```
┌──────────────────────────────────────────┐
│         Metrics Pipeline                 │
│                                          │
│  PostgreSQL Exporters                   │
│         ↓                                │
│  Prometheus (scrape every 15s)          │
│         ↓                                │
│  Grafana (visualization)                │
│         ↓                                │
│  Alertmanager (alerts)                  │
└──────────────────────────────────────────┘

Key Metrics:
- pg_up: Database availability
- pg_stat_database_numbackends: Active connections
- pg_stat_replication_lag_seconds: Replication lag
- citus_shard_count: Shard distribution
- patroni_master: Current master
```

### Logging Architecture

```
Components:
├── PostgreSQL logs → /var/log/postgresql/
├── Patroni logs → journald
├── HAProxy logs → /var/log/haproxy.log
├── PgBouncer logs → /var/log/pgbouncer/
└── Application logs → stdout (Docker)

Aggregation:
- Collect via Fluentd/Filebeat
- Store in Elasticsearch
- Visualize in Kibana
```

---

## 📚 Further Reading

### Deep Dives
- **[Distributed Design](architecture/distributed-postgres-design.md)** - Complete architecture details
- **[Patroni HA Design](architecture/PATRONI_HA_DESIGN.md)** - High availability deep dive
- **[DDD Domain Architecture](architecture/DDD_DOMAIN_ARCHITECTURE.md)** - Domain boundaries

### Operations
- **[Operations Guide](OPERATIONS_GUIDE.md)** - Daily operations
- **[Scaling Playbook](operations/SCALING_PLAYBOOK.md)** - Scaling procedures
- **[Failover Runbook](operations/FAILOVER_RUNBOOK.md)** - Failover handling

### Implementation
- **[Quick Start](QUICK_START.md)** - Deploy in 5 minutes
- **[Production Deployment](architecture/PRODUCTION_DEPLOYMENT.md)** - Production setup
- **[Monitoring Setup](MONITORING.md)** - Monitoring configuration

---

**Last Updated:** 2026-02-12

*For questions, see [Documentation Index](README.md)*
