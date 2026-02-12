# Patroni High Availability Architecture Design

## Executive Summary

This document details the Patroni-based high availability (HA) architecture for the Distributed PostgreSQL Cluster. The design provides automatic failover, self-healing capabilities, and ensures continuous database availability with minimal downtime (<30s) during failures.

**Key Features:**
- 3-node Patroni cluster (1 primary + 2 standby replicas)
- etcd-based distributed consensus for split-brain protection
- Automatic failover with <30 second recovery time
- Streaming replication with configurable synchronous/asynchronous modes
- RuVector extension support across all nodes
- Compatible with dual-database setup (project + shared databases)

**High Availability Guarantees:**
- **RPO (Recovery Point Objective):** 0 seconds (synchronous replication for coordinators)
- **RTO (Recovery Time Objective):** <30 seconds (automatic failover)
- **Availability:** 99.95% uptime (supports 1 node failure)

---

## Architecture Overview

### Logical Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         CLIENT APPLICATIONS                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │   Python     │  │ Claude Agent │  │   Web App    │              │
│  │   Clients    │  │  (MCP)       │  │              │              │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘              │
│         │                  │                  │                      │
│         └──────────────────┴──────────────────┘                      │
│                            │                                         │
└────────────────────────────┼─────────────────────────────────────────┘
                             │ postgres://cluster:5432
                             │
┌────────────────────────────┼─────────────────────────────────────────┐
│                     LOAD BALANCER LAYER                              │
│         ┌────────────────────┴────────────────────┐                  │
│         │          HAProxy (Active/Passive)        │                  │
│         │  - Patroni-aware health checks          │                  │
│         │  - Automatic primary detection           │                  │
│         │  - Connection routing to leader          │                  │
│         └────────────────────┬────────────────────┘                  │
└──────────────────────────────┼─────────────────────────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
┌─────────────┼────────────────┼────────────────┼──────────────────────┐
│         PATRONI HA CLUSTER (3 Nodes)                                 │
│             │                │                │                      │
│      ┌──────▼──────┐  ┌──────▼──────┐  ┌──────▼──────┐             │
│      │   Node 1    │  │   Node 2    │  │   Node 3    │             │
│      │  (PRIMARY)  │  │  (STANDBY)  │  │  (STANDBY)  │             │
│      │             │  │             │  │             │             │
│      │ Patroni     │  │ Patroni     │  │ Patroni     │             │
│      │ PostgreSQL  │◄─┼►PostgreSQL  │◄─┼►PostgreSQL  │             │
│      │ PgBouncer   │  │ PgBouncer   │  │ PgBouncer   │             │
│      │ RuVector    │  │ RuVector    │  │ RuVector    │             │
│      │             │  │             │  │             │             │
│      │ Streaming   │  │ Streaming   │  │ Streaming   │             │
│      │ Replication │──┼►Replica     │  │ Replica     │             │
│      │             │  │             ◄──┼─────────────┘             │
│      └─────────────┘  └─────────────┘  └─────────────┘             │
│             │                │                │                      │
│             └────────────────┼────────────────┘                      │
│                              │                                       │
│                         Leader Election                              │
│                         Health Monitoring                            │
│                         Configuration Sync                           │
└──────────────────────────────┼─────────────────────────────────────────┘
                               │
┌──────────────────────────────┼─────────────────────────────────────────┐
│              CONSENSUS & COORDINATION LAYER                          │
│         ┌────────────────────┴────────────────────┐                  │
│         │        etcd Cluster (3 nodes)           │                  │
│         │                                          │                  │
│         │  ┌──────────┐ ┌──────────┐ ┌──────────┐ │                  │
│         │  │  etcd-1  │ │  etcd-2  │ │  etcd-3  │ │                  │
│         │  │ (Leader) │ │(Follower)│ │(Follower)│ │                  │
│         │  └──────────┘ └──────────┘ └──────────┘ │                  │
│         │                                          │                  │
│         │  - Raft consensus protocol               │                  │
│         │  - Patroni DCS (Distributed Config)     │                  │
│         │  - Leader election & lock management    │                  │
│         │  - Configuration storage                │                  │
│         │  - Split-brain protection               │                  │
│         └─────────────────────────────────────────┘                  │
└──────────────────────────────────────────────────────────────────────┘
```

### Physical Topology (3-Node Cluster)

```
┌─────────────────────────────────────────────────────────────────────┐
│                          HOST 1 (Manager Node)                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │   etcd-1     │  │ Patroni Node │  │   HAProxy-1  │              │
│  │              │  │      1       │  │   (Active)   │              │
│  │   Leader     │  │   PRIMARY    │  │              │              │
│  │              │  │              │  │              │              │
│  └──────────────┘  └──────────────┘  └──────────────┘              │
│         IP: 10.0.1.10                                                │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                          HOST 2 (Manager Node)                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │   etcd-2     │  │ Patroni Node │  │  HAProxy-2   │              │
│  │              │  │      2       │  │  (Passive)   │              │
│  │  Follower    │  │   STANDBY    │  │              │              │
│  │              │  │              │  │              │              │
│  └──────────────┘  └──────────────┘  └──────────────┘              │
│         IP: 10.0.1.11                                                │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                          HOST 3 (Manager Node)                       │
│  ┌──────────────┐  ┌──────────────┐                                 │
│  │   etcd-3     │  │ Patroni Node │                                 │
│  │              │  │      3       │                                 │
│  │  Follower    │  │   STANDBY    │                                 │
│  │              │  │              │                                 │
│  └──────────────┘  └──────────────┘                                 │
│         IP: 10.0.1.12                                                │
└─────────────────────────────────────────────────────────────────────┘

Network: 10.0.1.0/24 (Docker Swarm overlay network)
VIP: 10.0.1.100 (HAProxy virtual IP via keepalived)
```

---

## Component Design

### 1. Patroni Cluster

**Purpose:** Manages PostgreSQL replication, automatic failover, and cluster coordination.

**Architecture:**
- **3 nodes:** 1 primary + 2 standby replicas
- **Replication mode:** Streaming replication (synchronous or asynchronous)
- **Watchdog:** Optional kernel watchdog for fencing
- **DCS Backend:** etcd for distributed configuration storage

**Key Features:**
- **Automatic Failover:** Detects primary failure and promotes standby within seconds
- **Leader Election:** Uses etcd for distributed consensus
- **Health Monitoring:** Continuous health checks and lag monitoring
- **Configuration Management:** Dynamic configuration updates without restart
- **REST API:** HTTP API for status, configuration, and manual operations

**High Availability Properties:**
| Property | Value | Notes |
|----------|-------|-------|
| **Cluster Size** | 3 nodes | Tolerates 1 node failure |
| **Quorum** | 2 of 3 | Requires majority for leader election |
| **Failover Time** | 10-30s | Detection (5s) + Election (5s) + Promotion (5-10s) |
| **Data Loss** | 0 (sync) or <5s (async) | Depends on replication mode |
| **Split-brain Protection** | etcd leader lock | Prevents multiple primaries |

### 2. etcd Cluster

**Purpose:** Distributed key-value store for Patroni configuration and leader election.

**Architecture:**
- **3 nodes:** 1 leader + 2 followers (Raft consensus)
- **Heartbeat interval:** 100ms
- **Election timeout:** 1000ms (1 second)
- **Snapshot interval:** 10000 transactions

**Key Responsibilities:**
1. **Leader Election:** Stores `/service/<cluster>/leader` key with TTL
2. **Configuration Storage:** Stores Patroni configuration in `/config/<cluster>/`
3. **Membership Management:** Tracks cluster members in `/members/<cluster>/`
4. **Health Status:** Stores node health and replication lag

**Failure Tolerance:**
- **Quorum:** 2 of 3 nodes required for writes
- **Network Partition:** Majority partition remains operational
- **Leader Failure:** New leader elected in ~1 second
- **Data Consistency:** Strong consistency via Raft protocol

**Port Assignments:**
- **2379:** Client API (used by Patroni)
- **2380:** Peer communication (Raft protocol)

### 3. PostgreSQL Streaming Replication

**Replication Flow:**
```
PRIMARY (Node 1)
    │
    ├──> WAL Writer: Writes transactions to WAL
    │
    ├──> WAL Sender: Streams WAL to replicas
    │         │
    │         ├──> STANDBY 1 (Node 2)
    │         │     │
    │         │     └──> WAL Receiver: Receives and applies WAL
    │         │
    │         └──> STANDBY 2 (Node 3)
    │               │
    │               └──> WAL Receiver: Receives and applies WAL
    │
    └──> Synchronous Commit: Waits for confirmation (optional)
```

**Synchronous vs Asynchronous Replication:**

| Aspect | Synchronous | Asynchronous |
|--------|-------------|--------------|
| **Commit Wait** | Waits for standby ACK | No wait |
| **Data Loss Risk** | Zero (RPO=0) | <5s (RPO<5s) |
| **Write Latency** | +5-10ms | No impact |
| **Throughput** | Lower | Higher |
| **Use Case** | Coordinators (metadata) | Workers (data shards) |

**Configuration:**
```ini
# Synchronous Replication (Coordinators)
synchronous_commit = 'on'                    # Wait for standby
synchronous_standby_names = 'ANY 1 (*)'     # Wait for any 1 standby

# Asynchronous Replication (Workers)
synchronous_commit = 'local'                 # Don't wait for standby
```

### 4. HAProxy Load Balancer

**Purpose:** Routes client connections to the current Patroni primary.

**Health Check Strategy:**
```haproxy
# Check 1: TCP connectivity
tcp-check connect

# Check 2: Patroni REST API (leader detection)
http-check send meth GET uri /leader
http-check expect status 200

# Check 3: PostgreSQL query
tcp-check send "SELECT 1"
tcp-check expect string "1"
```

**Failover Behavior:**
- **Primary Failure Detection:** 3 failed checks (6 seconds with 2s interval)
- **Automatic Rerouting:** Promotes backup server to primary
- **Connection Handling:** Existing connections terminated (clients reconnect)
- **Health Recovery:** 2 successful checks (4s) before routing restored

**Active-Passive Configuration:**
- **Active HAProxy:** Routes all traffic
- **Passive HAProxy:** Standby, takes over on failure
- **Virtual IP:** Shared via keepalived (VRRP protocol)

### 5. PgBouncer Connection Pooling

**Deployment:** One PgBouncer instance per Patroni node.

**Configuration:**
```ini
[databases]
* = host=127.0.0.1 port=5432

[pgbouncer]
pool_mode = transaction              # Best for OLTP
max_client_conn = 10000              # Support many clients
default_pool_size = 25               # Connections per DB
reserve_pool_size = 5                # Reserve for bursts
```

**Benefits:**
- Reduces PostgreSQL connection overhead (10K → 25 connections)
- Transparent to clients (same connection string)
- Survives failover (reconnects to new primary automatically)

---

## Automatic Failover Workflow

### Normal Operation State

```
CLIENT ──> HAProxy ──> PgBouncer ──> PRIMARY (Node 1)
                                      │
                                      ├──> WAL ──> STANDBY (Node 2)
                                      │
                                      └──> WAL ──> STANDBY (Node 3)

etcd: /service/cluster/leader = "node-1"
```

### Failover Timeline

```
T=0s:  Primary (Node 1) crashes
       │
       ├──> PostgreSQL process dies or host failure
       │
T=2s:  Patroni on Node 1 fails to update leader key in etcd
       │
       ├──> Leader key TTL expires (TTL=30s, last update 30s ago)
       │
T=3s:  Patroni agents on Node 2 and Node 3 detect leader absence
       │
       ├──> Both attempt to acquire leader key
       │    Node 2 wins race condition (first to write)
       │
T=5s:  Node 2 acquires leader lock in etcd
       │
       ├──> Node 2: "I am the new primary"
       │    etcd: /service/cluster/leader = "node-2"
       │
T=7s:  Node 2 promotes itself to primary
       │
       ├──> pg_ctl promote (stops replication, accepts writes)
       │    Timeline incremented (TL 1 → TL 2)
       │
T=10s: Node 3 detects timeline change
       │
       ├──> Node 3 reconnects to Node 2 (new primary)
       │    Starts replicating from Node 2
       │
T=12s: HAProxy detects Node 1 failure (3 failed health checks)
       │
       ├──> HAProxy marks Node 1 as DOWN
       │    HAProxy starts routing to Node 2
       │
T=15s: New connections routed to Node 2 (new primary)
       │
       └──> Existing connections fail, clients reconnect
              Failover complete

Total Downtime: ~10-15 seconds
Data Loss: 0 (synchronous) or <5s (asynchronous)
```

### Post-Failover State

```
CLIENT ──> HAProxy ──> PgBouncer ──> PRIMARY (Node 2)
                                      │
                                      └──> WAL ──> STANDBY (Node 3)

Node 1: DOWN (manual recovery required)
etcd: /service/cluster/leader = "node-2"
```

### Node 1 Recovery

```bash
# When Node 1 comes back online:
# 1. Patroni detects current primary is Node 2
# 2. Node 1 rewinds to match Node 2's timeline
# 3. Node 1 joins as standby, starts replicating from Node 2

# Manual recovery (if needed):
docker exec patroni-node-1 patronictl reinit postgres-cluster node-1
```

---

## Split-Brain Protection

**Problem:** Network partition could allow multiple primaries (split-brain).

**Solution:** etcd-based leader locking with TTL.

### How It Works

```
Normal State:
    Node 1 (Primary): Holds /service/cluster/leader key
                      Updates key every 10s (TTL=30s)
    Node 2 (Standby): Watches leader key
    Node 3 (Standby): Watches leader key

Network Partition Scenario:
    Partition A: Node 1, etcd-1
    Partition B: Node 2, Node 3, etcd-2, etcd-3

    T=0s: Network partition occurs

    T=10s: Node 1 attempts to update leader key
           ├──> Cannot reach etcd (only 1 of 3 nodes)
           ├──> etcd-1 loses quorum (1 of 3)
           └──> Leader key update FAILS

    T=30s: Leader key expires in etcd cluster
           ├──> etcd-2 and etcd-3 maintain quorum (2 of 3)
           ├──> Node 2 detects expired leader key
           └──> Node 2 acquires new leader key

    T=35s: Node 1 realizes it lost leader lock
           ├──> Node 1 demotes itself to read-only
           ├──> Node 1 stops accepting writes
           └──> No split-brain: only Node 2 is writable

Result: Only Partition B (with quorum) has a writable primary
```

**Key Protections:**
1. **Quorum Requirement:** etcd requires 2 of 3 nodes for writes
2. **TTL Expiration:** Leader key expires if not refreshed
3. **Watchdog:** Patroni can use kernel watchdog for hard fencing
4. **Automatic Demotion:** Primary without leader lock becomes read-only

---

## Network Topology

### Docker Swarm Overlay Networks

```
┌──────────────────────────────────────────────────────────────┐
│              coordinator-net (10.0.1.0/26)                   │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌─────────┐  │
│  │ Patroni-1 │  │ Patroni-2 │  │ Patroni-3 │  │ etcd-*  │  │
│  └───────────┘  └───────────┘  └───────────┘  └─────────┘  │
└──────────────────────────────────────────────────────────────┘
                            │
┌──────────────────────────────────────────────────────────────┐
│               admin-net (10.0.1.128/26)                      │
│  ┌───────────┐  ┌───────────┐  ┌────────────┐              │
│  │ HAProxy-1 │  │ HAProxy-2 │  │ Prometheus │              │
│  └───────────┘  └───────────┘  └────────────┘              │
└──────────────────────────────────────────────────────────────┘
```

**Port Mappings:**

| Service | Port | Protocol | Access |
|---------|------|----------|--------|
| PostgreSQL | 5432 | TCP | Internal only |
| PgBouncer | 6432 | TCP | Via HAProxy |
| Patroni REST API | 8008 | HTTP | HAProxy health checks |
| etcd Client API | 2379 | TCP | Patroni agents |
| etcd Peer API | 2380 | TCP | etcd cluster only |
| HAProxy Frontend | 5432 | TCP | External clients |
| HAProxy Stats | 8404 | HTTP | Monitoring |

### Firewall Rules (iptables)

```bash
# Allow PostgreSQL from HAProxy only
iptables -A INPUT -p tcp --dport 6432 -s 10.0.1.128/26 -j ACCEPT
iptables -A INPUT -p tcp --dport 6432 -j DROP

# Allow Patroni REST API from HAProxy
iptables -A INPUT -p tcp --dport 8008 -s 10.0.1.128/26 -j ACCEPT

# Allow etcd client API from Patroni nodes
iptables -A INPUT -p tcp --dport 2379 -s 10.0.1.0/26 -j ACCEPT

# Allow etcd peer communication (etcd cluster only)
iptables -A INPUT -p tcp --dport 2380 -s 10.0.1.0/26 -j ACCEPT

# Allow replication traffic between Patroni nodes
iptables -A INPUT -p tcp --dport 5432 -s 10.0.1.0/26 -j ACCEPT
```

---

## Component Interactions

### 1. Client Connection Flow

```
┌────────┐    ┌─────────┐    ┌──────────┐    ┌───────────┐
│ Client │───>│ HAProxy │───>│PgBouncer │───>│PostgreSQL │
└────────┘    └─────────┘    └──────────┘    │ (Primary) │
                   │                          └───────────┘
                   │
                   ├──> Query etcd: GET /service/cluster/leader
                   │    Response: "node-2"
                   │
                   └──> Route to node-2:6432
```

**Steps:**
1. Client connects to HAProxy VIP (10.0.1.100:5432)
2. HAProxy queries Patroni REST API: `GET http://node-1:8008/leader`
3. Patroni returns 200 if primary, 503 if standby
4. HAProxy routes to primary node's PgBouncer (port 6432)
5. PgBouncer forwards to local PostgreSQL (port 5432)
6. Client receives connection to primary database

### 2. Write Operation (INSERT)

```
Client
  │
  └──> HAProxy ──> PgBouncer ──> PRIMARY
                                    │
                                    ├──> Write to WAL
                                    │
                                    ├──> Send WAL to STANDBY-1 (async)
                                    │
                                    ├──> Send WAL to STANDBY-2 (async)
                                    │
                                    └──> If synchronous_commit='on':
                                         Wait for 1 standby ACK
                                         Then COMMIT

Latency:
  - Async: ~3ms (no wait)
  - Sync:  ~8ms (wait for 1 standby)
```

### 3. Read Operation (SELECT)

**Primary Read:**
```
Client ──> HAProxy ──> PgBouncer ──> PRIMARY
                                      │
                                      └──> Read from primary
                                           (always fresh data)
```

**Replica Read (Load Balancing):**
```
Client ──> HAProxy ──> PgBouncer ──> STANDBY
           (read      (port 6433)     │
            replica                    └──> Read from replica
            endpoint)                      (may have replication lag)
```

**HAProxy Configuration for Read Replicas:**
```haproxy
# Separate frontend for read replicas
frontend postgres_replica
    bind *:5433
    default_backend postgres_replica_backend

backend postgres_replica_backend
    balance roundrobin
    server standby1 node-2:6432 check
    server standby2 node-3:6432 check
```

### 4. Patroni Health Monitoring

```
Patroni Agent (Node 1)
    │
    ├──> Check local PostgreSQL health
    │    - Process running?
    │    - Accepting connections?
    │    - Replication lag?
    │
    ├──> Update member key in etcd
    │    PUT /members/cluster/node-1
    │    {
    │      "role": "primary",
    │      "state": "running",
    │      "xlog_location": "0/123456789",
    │      "timeline": 1
    │    }
    │
    ├──> Refresh leader lock (if primary)
    │    PUT /service/cluster/leader (TTL=30s)
    │    "node-1"
    │
    └──> Sleep 10s, repeat
```

### 5. Failover Decision Process

```
Patroni Watchdog (Node 2 - Standby)
    │
    ├──> Query etcd: GET /service/cluster/leader
    │    Response: "node-1"
    │
    ├──> Wait 10s
    │
    ├──> Query etcd: GET /service/cluster/leader
    │    Response: Key expired (404 or TTL=0)
    │
    ├──> Decision: Primary is DOWN
    │
    ├──> Attempt leader election
    │    PUT /service/cluster/leader (ifNotExist)
    │    Value: "node-2"
    │
    ├──> Success! I am the new primary
    │
    ├──> Promote local PostgreSQL
    │    pg_ctl promote
    │
    └──> Update member key
         PUT /members/cluster/node-2
         {"role": "primary", "state": "running"}
```

---

## RuVector Extension Support

### Extension Installation

All Patroni nodes require RuVector extension for vector operations.

**Installation:**
```sql
-- Run on primary (propagates to standbys via replication)
CREATE EXTENSION IF NOT EXISTS ruvector;

-- Verify on standbys
SELECT * FROM pg_extension WHERE extname = 'ruvector';
```

### Vector Data Replication

**Write Operations:**
```sql
-- Insert on primary
INSERT INTO memory_entries (namespace, key, embedding)
VALUES ('patterns', 'auth-flow', '[0.1, 0.2, 0.3]'::ruvector);

-- Replication flow:
PRIMARY
  │
  ├──> WAL: INSERT with ruvector data
  │
  ├──> STANDBY-1: Applies WAL, rebuilds HNSW index
  │
  └──> STANDBY-2: Applies WAL, rebuilds HNSW index
```

**HNSW Index Replication:**
- **Index Structure:** HNSW indexes are PostgreSQL indexes, fully replicated
- **Index Build:** Standbys rebuild indexes when applying WAL
- **Latency Impact:** Index rebuild on standbys is asynchronous (no write latency)

**Vector Search on Standbys:**
```sql
-- Reads can be served from standbys (eventual consistency)
SELECT namespace, key,
       1 - (embedding <=> '[0.1, 0.2, 0.3]'::ruvector) as similarity
FROM memory_entries
WHERE namespace = 'patterns'
ORDER BY embedding <=> '[0.1, 0.2, 0.3]'::ruvector
LIMIT 10;

-- Note: Replication lag may cause stale results
-- Typical lag: <100ms for async replication
```

### Dual-Database Setup

**Project Database:** `distributed_postgres_cluster`
**Shared Database:** `claude_flow_shared`

Both databases are replicated across all Patroni nodes:

```sql
-- On primary, both databases are writable:
\c distributed_postgres_cluster
INSERT INTO memory_entries (...);  -- Success

\c claude_flow_shared
INSERT INTO memory_entries (...);  -- Success

-- On standby, both databases are read-only:
\c distributed_postgres_cluster
SELECT * FROM memory_entries;      -- Success
INSERT INTO memory_entries (...);  -- Error: read-only

\c claude_flow_shared
SELECT * FROM memory_entries;      -- Success
INSERT INTO memory_entries (...);  -- Error: read-only
```

**Failover:** After failover, new primary serves both databases.

---

## Performance Characteristics

### Replication Lag

**Asynchronous Replication:**
| Metric | Target | Notes |
|--------|--------|-------|
| **Typical Lag** | <100ms | Under normal load |
| **Max Lag** | <5s | During heavy writes |
| **Monitoring** | `pg_stat_replication.replay_lag` | Bytes behind primary |

**Synchronous Replication:**
| Metric | Target | Notes |
|--------|--------|-------|
| **Lag** | 0 bytes | No lag (wait for ACK) |
| **Write Latency** | +5-10ms | Network RTT to standby |

### Failover Times

| Metric | Target | Description |
|--------|--------|-------------|
| **Detection Time** | 5-10s | Patroni detects primary failure |
| **Election Time** | 2-5s | New primary elected via etcd |
| **Promotion Time** | 3-5s | PostgreSQL promotion (pg_ctl promote) |
| **HAProxy Failover** | 6s | 3 failed health checks × 2s interval |
| **Total RTO** | 15-30s | End-to-end failover time |

### Throughput Impact

**Write Operations:**
| Replication Mode | Throughput | Latency | Use Case |
|------------------|------------|---------|----------|
| **Async** | 10,000 TPS | 3ms | Worker shards (data) |
| **Sync (1 standby)** | 5,000 TPS | 8ms | Coordinators (metadata) |
| **Sync (2 standbys)** | 2,000 TPS | 15ms | Critical data only |

**Read Operations:**
| Target | Throughput | Notes |
|--------|------------|-------|
| **Primary** | 50,000 TPS | All reads from primary |
| **Replicas** | 100,000 TPS | Distribute reads across 2 standbys |

---

## Monitoring and Health Checks

### Patroni REST API Endpoints

```bash
# Check if node is primary
curl http://node-1:8008/leader
# 200 OK → Primary
# 503 Service Unavailable → Standby

# Check if node is replica
curl http://node-1:8008/replica
# 200 OK → Replica
# 503 Service Unavailable → Primary

# Check replication lag
curl http://node-1:8008/patroni | jq '.replication[].lag'

# Full cluster status
curl http://node-1:8008/cluster | jq
```

### Key Metrics

**PostgreSQL Metrics:**
```sql
-- Replication lag (primary)
SELECT client_addr, application_name, state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes,
       replay_lag
FROM pg_stat_replication;

-- Standby lag (replica)
SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS replay_lag_bytes;

-- Timeline (detects failover)
SELECT timeline_id FROM pg_control_checkpoint();
```

**etcd Metrics:**
```bash
# etcd cluster health
etcdctl --endpoints=http://etcd-1:2379,http://etcd-2:2379,http://etcd-3:2379 endpoint health

# Check leader
etcdctl --endpoints=http://etcd-1:2379 endpoint status --write-out=table

# Watch Patroni leader key
etcdctl get /service/postgres-cluster/leader --prefix
```

**Alerts:**
```yaml
# Prometheus alert rules
- alert: PatroniPrimaryDown
  expr: patroni_postgres_running{role="primary"} == 0
  for: 30s
  severity: critical

- alert: PatroniReplicationLagHigh
  expr: patroni_replication_lag_bytes > 100000000  # 100MB
  for: 5m
  severity: warning

- alert: EtcdQuorumLost
  expr: etcd_server_has_leader == 0
  for: 1m
  severity: critical

- alert: PatroniSyncReplicationBroken
  expr: patroni_postgres_streaming_replicas{sync="sync"} == 0
  for: 1m
  severity: critical
```

---

## Security Considerations

### 1. Authentication

**PostgreSQL Authentication:**
```
# pg_hba.conf
# TYPE  DATABASE        USER            ADDRESS         METHOD

# Replication connections
hostssl replication     replicator      10.0.1.0/26     md5

# Local connections
local   all             postgres                        peer
host    all             all             127.0.0.1/32    md5

# Client connections via HAProxy
hostssl all             all             10.0.1.128/26   md5

# Deny all other
host    all             all             0.0.0.0/0       reject
```

**etcd Authentication:**
```bash
# Enable client authentication
etcd --client-cert-auth \
     --trusted-ca-file=/etc/etcd/ca.crt \
     --cert-file=/etc/etcd/server.crt \
     --key-file=/etc/etcd/server.key
```

### 2. Encryption

**SSL/TLS for PostgreSQL:**
```ini
# postgresql.conf
ssl = on
ssl_ca_file = '/etc/ssl/certs/ca.crt'
ssl_cert_file = '/etc/ssl/certs/server.crt'
ssl_key_file = '/etc/ssl/private/server.key'
ssl_ciphers = 'HIGH:!aNULL:!MD5'
ssl_prefer_server_ciphers = on
```

**etcd Peer Encryption:**
```bash
etcd --peer-client-cert-auth \
     --peer-trusted-ca-file=/etc/etcd/ca.crt \
     --peer-cert-file=/etc/etcd/peer.crt \
     --peer-key-file=/etc/etcd/peer.key
```

### 3. Secret Management

```bash
# Docker Swarm secrets
echo "strong_replication_password" | docker secret create patroni_replication_password -
echo "strong_superuser_password" | docker secret create patroni_superuser_password -

# Reference in Patroni config
postgresql:
  authentication:
    replication:
      password: /run/secrets/patroni_replication_password
    superuser:
      password: /run/secrets/patroni_superuser_password
```

---

## Operational Procedures

### 1. Manual Failover (Switchover)

**Planned maintenance on primary:**
```bash
# Initiate switchover (graceful)
patronictl -c /etc/patroni.yml switchover postgres-cluster

# Interactive prompt:
# Master [node-1]:
# Candidate ['node-2', 'node-3'] []: node-2
# When should the switchover take place (e.g. 2024-02-12T10:00 )  [now]: now

# Result:
# - Node 1: Demotes to standby
# - Node 2: Promotes to primary
# - No data loss, minimal downtime (~2-5s)
```

### 2. Adding a New Standby

```bash
# 1. Deploy new Patroni node
docker service scale postgres-cluster_patroni=4

# 2. Wait for node to bootstrap
docker service ps postgres-cluster_patroni

# 3. Verify replication
patronictl -c /etc/patroni.yml list postgres-cluster

# Expected:
# | Member   | Host     | Role    | State   | TL | Lag in MB |
# |----------|----------|---------|---------|----+-----------|
# | node-1   | node-1   | Leader  | running | 1  |           |
# | node-2   | node-2   | Replica | running | 1  | 0         |
# | node-3   | node-3   | Replica | running | 1  | 0         |
# | node-4   | node-4   | Replica | running | 1  | 0         |
```

### 3. Removing a Standby

```bash
# 1. Remove from Patroni cluster
patronictl -c /etc/patroni.yml remove postgres-cluster node-4

# 2. Stop service
docker service scale postgres-cluster_patroni=3

# 3. Clean up member key in etcd
etcdctl del /members/postgres-cluster/node-4
```

### 4. Reinitializing a Failed Node

```bash
# When node data is corrupted or severely lagging:

# 1. Stop node (if running)
docker stop patroni-node-1

# 2. Remove data directory
docker exec patroni-node-1 rm -rf /var/lib/postgresql/data/*

# 3. Reinitialize from primary
patronictl -c /etc/patroni.yml reinit postgres-cluster node-1

# Patroni will:
# - Detect empty data directory
# - Run pg_basebackup from primary
# - Start replication
# - Join cluster as standby
```

### 5. Backup and Restore

**Continuous WAL Archiving:**
```yaml
# patroni.yml
postgresql:
  parameters:
    archive_mode: 'on'
    archive_command: 's3cmd put %p s3://backups/wal/%f'
    archive_timeout: 300  # 5 minutes
```

**Manual Backup (from standby):**
```bash
# pg_basebackup (doesn't impact primary)
docker exec patroni-node-2 pg_basebackup \
  -h node-2 \
  -U replicator \
  -D /backup/basebackup-$(date +%Y%m%d) \
  -F tar \
  -z \
  -P \
  -X stream
```

**Point-in-Time Recovery (PITR):**
```bash
# 1. Restore base backup
tar -xzf basebackup-20260212.tar.gz -C /var/lib/postgresql/data/

# 2. Create recovery.signal
touch /var/lib/postgresql/data/recovery.signal

# 3. Configure restore_command
echo "restore_command = 's3cmd get s3://backups/wal/%f %p'" >> /var/lib/postgresql/data/postgresql.conf

# 4. Set recovery target
echo "recovery_target_time = '2026-02-12 10:30:00'" >> /var/lib/postgresql/data/postgresql.conf

# 5. Start PostgreSQL
pg_ctl start

# PostgreSQL will replay WAL up to target time
```

---

## Troubleshooting

### Issue 1: Patroni Not Starting

**Symptoms:**
- Patroni container exits immediately
- Logs show "Failed to initialize DCS"

**Diagnosis:**
```bash
# Check etcd connectivity
docker exec patroni-node-1 curl http://etcd-1:2379/health

# Check Patroni logs
docker logs patroni-node-1
```

**Resolution:**
```bash
# Verify etcd cluster is healthy
etcdctl --endpoints=http://etcd-1:2379,http://etcd-2:2379,http://etcd-3:2379 endpoint health

# Restart Patroni
docker restart patroni-node-1
```

### Issue 2: Split-Brain (Multiple Primaries)

**Symptoms:**
- `patronictl list` shows 2+ primaries
- Conflicting writes on different nodes

**Diagnosis:**
```bash
# Check leader key in etcd
etcdctl get /service/postgres-cluster/leader

# Check Patroni state
patronictl -c /etc/patroni.yml list postgres-cluster
```

**Resolution:**
```bash
# Force demotion of false primary
patronictl -c /etc/patroni.yml failover postgres-cluster --force

# Choose correct primary
# Demote false primary manually if needed:
docker exec patroni-node-X pg_ctl promote
```

### Issue 3: Replication Lag

**Symptoms:**
- Standby significantly behind primary
- `pg_stat_replication.replay_lag` > 10s

**Diagnosis:**
```sql
-- On primary
SELECT client_addr, state, sync_state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes,
       replay_lag
FROM pg_stat_replication;
```

**Resolution:**
```bash
# 1. Check network latency
docker exec patroni-node-1 ping -c 5 node-2

# 2. Check standby disk I/O
docker exec patroni-node-2 iostat -x 1 10

# 3. Increase max_wal_senders (if needed)
# In patroni.yml:
postgresql:
  parameters:
    max_wal_senders: 10
    wal_keep_size: 1GB

# 4. Restart standby (if severely lagging)
patronictl -c /etc/patroni.yml reinit postgres-cluster node-2
```

### Issue 4: HAProxy Not Routing

**Symptoms:**
- Clients cannot connect
- HAProxy shows all backends as DOWN

**Diagnosis:**
```bash
# Check HAProxy stats
curl http://haproxy:8404/stats

# Check Patroni REST API
curl http://node-1:8008/leader
curl http://node-2:8008/leader
curl http://node-3:8008/leader
```

**Resolution:**
```bash
# Verify Patroni REST API is accessible
docker exec haproxy nc -zv node-1 8008

# Check HAProxy configuration
docker exec haproxy cat /usr/local/etc/haproxy/haproxy.cfg

# Restart HAProxy
docker restart haproxy
```

---

## Disaster Recovery

### Scenario 1: Complete Cluster Failure

**All 3 nodes down simultaneously (data center failure):**

```bash
# 1. Bring up nodes in any order
docker start patroni-node-1 patroni-node-2 patroni-node-3

# 2. Patroni will:
#    - Detect no leader in etcd
#    - Most advanced node (highest LSN) becomes primary
#    - Other nodes replicate from primary

# 3. Verify cluster state
patronictl -c /etc/patroni.yml list postgres-cluster

# If manual intervention needed:
patronictl -c /etc/patroni.yml reinit postgres-cluster node-X
```

### Scenario 2: etcd Cluster Failure

**All etcd nodes down:**

```bash
# Option 1: Restore etcd from backup
# 1. Stop all etcd nodes
docker stop etcd-1 etcd-2 etcd-3

# 2. Restore snapshot
etcdctl snapshot restore /backup/etcd-snapshot.db \
  --data-dir /var/lib/etcd \
  --initial-cluster=etcd-1=http://etcd-1:2380,etcd-2=http://etcd-2:2380,etcd-3=http://etcd-3:2380 \
  --initial-advertise-peer-urls=http://etcd-1:2380

# 3. Start etcd nodes
docker start etcd-1 etcd-2 etcd-3

# Option 2: Bootstrap new etcd cluster
# (WARNING: Patroni will lose state, may require manual recovery)
```

### Scenario 3: Data Corruption on Primary

**Primary has corrupted data, standbys are healthy:**

```bash
# 1. Promote a healthy standby
patronictl -c /etc/patroni.yml failover postgres-cluster \
  --candidate node-2 \
  --force

# 2. Reinitialize corrupted node
patronictl -c /etc/patroni.yml reinit postgres-cluster node-1

# 3. Verify replication
patronictl -c /etc/patroni.yml list postgres-cluster
```

---

## Configuration Files Summary

All configuration templates are provided in:
- `/config/patroni/patroni.yml` - Patroni configuration
- `/config/etcd/etcd.conf` - etcd cluster configuration
- `/config/postgresql/postgresql.conf` - HA-optimized PostgreSQL settings

See next sections for detailed configuration templates.

---

**Document Version:** 1.0
**Last Updated:** 2026-02-12
**Author:** System Architecture Designer
**Status:** Ready for Review
