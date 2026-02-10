# Distributed PostgreSQL Cluster - Architecture Diagrams

## Table of Contents

1. [System Overview](#system-overview)
2. [Network Topology](#network-topology)
3. [Component Interaction](#component-interaction)
4. [Data Flow](#data-flow)
5. [Failover Sequence](#failover-sequence)
6. [Deployment Architecture](#deployment-architecture)

---

## System Overview

### High-Level Architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│                              CLIENT LAYER                                   │
│                                                                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │  Python  │  │  Node.js │  │  Claude  │  │  Web App │  │   CLI    │   │
│  │  Client  │  │  Client  │  │  Agent   │  │          │  │  psql    │   │
│  └─────┬────┘  └─────┬────┘  └─────┬────┘  └─────┬────┘  └─────┬────┘   │
│        │             │             │             │             │          │
│        └─────────────┴─────────────┴─────────────┴─────────────┘          │
│                              │                                              │
│                   postgresql://cluster:5432                                 │
└──────────────────────────────┼──────────────────────────────────────────────┘
                               │
┌──────────────────────────────┼──────────────────────────────────────────────┐
│                        LOAD BALANCER LAYER                                  │
│                              │                                               │
│         ┌────────────────────┴────────────────────┐                         │
│         │          HAProxy (Active/Passive)        │                         │
│         │  ┌────────────────────────────────────┐ │                         │
│         │  │  Port 5432: Primary (writes)       │ │                         │
│         │  │  Port 5433: Replicas (reads)       │ │                         │
│         │  │  Port 8404: Stats dashboard        │ │                         │
│         │  └────────────────────────────────────┘ │                         │
│         │  Health checks: Patroni REST API        │                         │
│         │  Failover: <6s                          │                         │
│         └────────────────────┬────────────────────┘                         │
└──────────────────────────────┼──────────────────────────────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
┌─────────────┼────────────────┼────────────────┼──────────────────────────────┐
│       COORDINATOR LAYER (Patroni Cluster)                                    │
│             │                │                │                              │
│      ┌──────▼──────┐  ┌──────▼──────┐  ┌──────▼──────┐                     │
│      │Coordinator 1│  │Coordinator 2│  │Coordinator 3│                     │
│      │  (Leader)   │  │  (Standby)  │  │  (Standby)  │                     │
│      │             │  │             │  │             │                     │
│      │  Citus      │  │  Citus      │  │  Citus      │                     │
│      │  RuVector   │  │  RuVector   │  │  RuVector   │                     │
│      │  PgBouncer  │  │  PgBouncer  │  │  PgBouncer  │                     │
│      │  Port: 5432 │  │  Port: 5432 │  │  Port: 5432 │                     │
│      └──────┬──────┘  └──────┬──────┘  └──────┬──────┘                     │
│             │                │                │                              │
│             │  Synchronous replication (RPO=0)│                              │
│             └────────────────┼────────────────┘                              │
│                              │                                               │
│                    Query Planning & Routing                                  │
└──────────────────────────────┼──────────────────────────────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
┌─────────────┼────────────────┼────────────────┼──────────────────────────────┐
│         WORKER LAYER (Sharded Data)                                          │
│             │                │                │                              │
│   ┌─────────▼─────────┐ ┌────▼──────────┐ ┌──▼──────────────┐              │
│   │    Shard 1        │ │   Shard 2     │ │   Shard 3       │              │
│   │  ┌──────────────┐ │ │ ┌──────────┐  │ │ ┌──────────┐    │              │
│   │  │  Worker 1-1  │ │ │ │Worker 2-1│  │ │ │Worker 3-1│    │              │
│   │  │  (Primary)   │ │ │ │(Primary) │  │ │ │(Primary) │    │              │
│   │  │              │ │ │ │          │  │ │ │          │    │              │
│   │  │  Citus       │ │ │ │  Citus   │  │ │ │  Citus   │    │              │
│   │  │  RuVector    │ │ │ │  RuVector│  │ │ │  RuVector│    │              │
│   │  │  HNSW Index  │ │ │ │  HNSW    │  │ │ │  HNSW    │    │              │
│   │  │  PgBouncer   │ │ │ │PgBouncer │  │ │ │PgBouncer │    │              │
│   │  └──────┬───────┘ │ │ └────┬─────┘  │ │ └────┬─────┘    │              │
│   │         │ Async   │ │      │ Async  │ │      │ Async    │              │
│   │  ┌──────▼───────┐ │ │ ┌────▼─────┐  │ │ ┌────▼─────┐    │              │
│   │  │  Worker 1-2  │ │ │ │Worker 2-2│  │ │ │Worker 3-2│    │              │
│   │  │  (Standby)   │ │ │ │(Standby) │  │ │ │(Standby) │    │              │
│   │  └──────────────┘ │ │ └──────────┘  │ │ └──────────┘    │              │
│   └──────────────────┘ └───────────────┘ └─────────────────┘              │
│                                                                              │
│              Data Storage & Parallel Query Execution                         │
└──────────────────────────────┼──────────────────────────────────────────────┘
                               │
┌──────────────────────────────┼──────────────────────────────────────────────┐
│              CONSENSUS LAYER                                                 │
│                              │                                               │
│         ┌────────────────────┴────────────────────┐                         │
│         │        etcd Cluster (3 nodes)           │                         │
│         │  ┌────────────────────────────────────┐ │                         │
│         │  │  Patroni DCS                       │ │                         │
│         │  │  Leader election                   │ │                         │
│         │  │  Service discovery                 │ │                         │
│         │  │  Configuration storage             │ │                         │
│         │  │  Raft consensus (quorum = 2/3)     │ │                         │
│         │  └────────────────────────────────────┘ │                         │
│         └─────────────────────────────────────────┘                         │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Network Topology

### Docker Swarm Overlay Networks

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                         DOCKER SWARM CLUSTER                                  │
│                                                                                │
│  ┌─────────────────────── overlay-net ────────────────────────┐              │
│  │                                                              │              │
│  │  ┌────────────── coordinator-net (10.0.1.0/26) ──────────┐ │              │
│  │  │                                                         │ │              │
│  │  │  ┌─────────┐  ┌─────────┐  ┌─────────┐               │ │              │
│  │  │  │ Coord-1 │  │ Coord-2 │  │ Coord-3 │               │ │              │
│  │  │  └─────────┘  └─────────┘  └─────────┘               │ │              │
│  │  │                                                         │ │              │
│  │  │  ┌─────────┐  ┌─────────┐  ┌─────────┐               │ │              │
│  │  │  │  etcd-1 │  │  etcd-2 │  │  etcd-3 │               │ │              │
│  │  │  └─────────┘  └─────────┘  └─────────┘               │ │              │
│  │  └─────────────────────────────────────────────────────┘ │              │
│  │                                                              │              │
│  │  ┌────────────── worker-net (10.0.1.64/26) ─────────────┐ │              │
│  │  │                                                         │ │              │
│  │  │  ┌──────────┐  ┌──────────┐  ┌──────────┐            │ │              │
│  │  │  │Worker1-1 │  │Worker1-2 │  │Worker2-1 │            │ │              │
│  │  │  └──────────┘  └──────────┘  └──────────┘            │ │              │
│  │  │                                                         │ │              │
│  │  │  ┌──────────┐  ┌──────────┐  ┌──────────┐            │ │              │
│  │  │  │Worker2-2 │  │Worker3-1 │  │Worker3-2 │            │ │              │
│  │  │  └──────────┘  └──────────┘  └──────────┘            │ │              │
│  │  └─────────────────────────────────────────────────────┘ │              │
│  │                                                              │              │
│  │  ┌────────────── admin-net (10.0.1.128/26) ──────────────┐ │              │
│  │  │                                                         │ │              │
│  │  │  ┌─────────┐  ┌─────────┐  ┌─────────────┐           │ │              │
│  │  │  │HAProxy-1│  │HAProxy-2│  │ Prometheus  │           │ │              │
│  │  │  └─────────┘  └─────────┘  └─────────────┘           │ │              │
│  │  │                                                         │ │              │
│  │  │  ┌─────────┐                                           │ │              │
│  │  │  │ Grafana │                                           │ │              │
│  │  │  └─────────┘                                           │ │              │
│  │  └─────────────────────────────────────────────────────┘ │              │
│  └──────────────────────────────────────────────────────────┘              │
│                                                                                │
│  External Access:                                                             │
│  - Port 5432 → HAProxy → Coordinators (writes)                              │
│  - Port 5433 → HAProxy → Coordinators (reads)                               │
│  - Port 8404 → HAProxy stats                                                 │
│  - Port 3000 → Grafana (monitoring)                                          │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Interaction

### Write Operation Flow

```
┌────────┐     ┌─────────┐     ┌───────────┐     ┌──────────┐     ┌──────────┐
│ Client │────>│ HAProxy │────>│PgBouncer  │────>│Coordinator│────>│ Worker   │
└────────┘     └─────────┘     └───────────┘     │ (Leader)  │     │ (Shard)  │
                                                  └───────────┘     └──────────┘

Step 1: Client sends INSERT query
        INSERT INTO memory_entries (namespace, key, value, embedding)
        VALUES ('claude-flow', 'pattern-1', 'data', '[0.1,0.2,...]'::ruvector);

Step 2: HAProxy routes to primary coordinator
        - Checks etcd for Patroni leader
        - Routes to leader endpoint

Step 3: PgBouncer gets connection from pool
        - Reuses existing PostgreSQL connection
        - Transaction pooling mode

Step 4: Coordinator (Citus) parses and routes query
        - Computes shard: hash('claude-flow') % 32 = 7
        - Identifies worker node for shard 7
        - Routes to Worker-1-1 (shard 7 primary)

Step 5: Worker executes INSERT
        - Inserts row into local table
        - Updates HNSW index
        - Asynchronously replicates to Worker-1-2

Step 6: Worker returns success
        - Coordinator receives result
        - Returns to client via PgBouncer → HAProxy
        - Total latency: ~4-8ms

Failure Handling:
  - Worker down → Coordinator routes to standby (Worker-1-2)
  - Coordinator down → HAProxy fails over to new leader (<6s)
  - Connection exhaustion → PgBouncer queues request
```

---

### Vector Search Flow (Distributed)

```
┌────────┐     ┌───────────┐     ┌──────────┐
│ Client │────>│Coordinator│────>│Worker 1-1│ (Shard 1)
└────────┘     │ (Citus)   │     └──────────┘
               └───────────┘            │
                    │        ────>│Worker 2-1│ (Shard 2)
                    │             └──────────┘
                    │        ────>│Worker 3-1│ (Shard 3)
                    │             └──────────┘

Step 1: Client sends vector search query
        SELECT namespace, key, value,
               1 - (embedding <=> '[0.1,0.2,...]'::ruvector) as similarity
        FROM memory_entries
        ORDER BY embedding <=> '[0.1,0.2,...]'::ruvector
        LIMIT 10;

Step 2: Coordinator broadcasts to ALL shards (parallel)
        - No namespace filter → must search all shards
        - Sends sub-query to each worker

Step 3: Workers perform HNSW search (concurrent)
        - Worker 1-1: Search local shard (5ms) → Top 10 results
        - Worker 2-1: Search local shard (5ms) → Top 10 results
        - Worker 3-1: Search local shard (5ms) → Top 10 results
        - Total wall-clock time: 5ms (parallel execution)

Step 4: Coordinator merges results
        - Collects 30 results (10 per shard)
        - Re-ranks by similarity score
        - Returns top 10 to client

Step 5: Client receives results
        - Total latency: 5ms (search) + 1ms (merge) = 6ms
        - 3x faster than sequential (15ms)

Optimization:
  - Add namespace filter → single shard query (10ms → 5ms)
    WHERE namespace = 'claude-flow'
  - Uses HNSW index (m=16, ef_search=40)
  - Index stored in shared_buffers (memory)
```

---

## Data Flow

### Data Distribution Strategy

```
                        Hash-Based Sharding

Input: INSERT INTO memory_entries (namespace, key, value)
       VALUES ('agents', 'coder-1', 'Agent data...');

┌────────────────────────────────────────────────────────────────────┐
│                         COORDINATOR                                 │
│                                                                      │
│  1. Compute shard ID:                                               │
│     shard_id = hash_fn('agents') % 32                              │
│                                                                      │
│  2. Result: shard_id = 7                                            │
│                                                                      │
│  3. Lookup shard placement:                                         │
│     Shard 7 → Worker-1-1 (primary), Worker-1-2 (standby)          │
│                                                                      │
│  4. Route query to Worker-1-1                                       │
└────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
        ┌──────────────────────┴──────────────────────┐
        │                                              │
┌───────▼────────┐      ┌───────────────┐      ┌──────────────┐
│   Worker 1-1   │      │  Worker 2-1   │      │ Worker 3-1   │
│  (Shard 1-10)  │      │ (Shard 11-21) │      │(Shard 22-32) │
│                │      │               │      │              │
│ Shard 7 ✓      │      │               │      │              │
│ - namespace:   │      │ Different     │      │ Different    │
│   'agents'     │      │ namespaces    │      │ namespaces   │
│   'configs'    │      │               │      │              │
│   'memory'     │      │               │      │              │
└────────────────┘      └───────────────┘      └──────────────┘

Co-location Benefits:
  - Queries within namespace hit single shard
  - Related data stored together:
    • memory_entries WHERE namespace='agents'
    • patterns WHERE namespace='agents'
    • graph_nodes WHERE namespace='agents'
  - Efficient joins and aggregations
  - No cross-shard network traffic

Reference Tables (Replicated to ALL workers):
  - vector_indexes (small, frequent joins)
  - sessions (session management)
  - metadata (cluster metadata)
```

---

### Replication Flow

```
          Synchronous Replication (Coordinators)

┌──────────────┐         ┌──────────────┐         ┌──────────────┐
│ Coordinator  │  WAL    │ Coordinator  │  WAL    │ Coordinator  │
│      1       │─────────>│      2       │─────────>│      3       │
│  (Primary)   │Replicate│  (Standby)   │Replicate│  (Standby)   │
└──────────────┘         └──────────────┘         └──────────────┘
       │                        │
       │ COMMIT                 │
       │                        │
       │<───────────────────────┘
       │   ACK (must wait for at least 1 standby)
       │
       └─────> Return to client (RPO = 0)

Timeline: +5-10ms latency (network RTT + write)


          Asynchronous Replication (Workers)

┌──────────────┐         ┌──────────────┐
│  Worker 1-1  │  WAL    │  Worker 1-2  │
│  (Primary)   │─────────>│  (Standby)   │
└──────────────┘Replicate└──────────────┘
       │            (async)      │
       │ COMMIT                  │
       │                         │
       └─────> Return to client  │
                                 │
                          (catches up later)
                          Typical lag: <100ms
                          Max RPO: ~5s

Timeline: No additional latency for client
```

---

## Failover Sequence

### Coordinator Failover (Automatic)

```
T=0s:  Coordinator-1 (primary) crashes
       │
       ├──> Patroni heartbeat missed (loop_wait=10s)
       │    Last heartbeat at T=-10s
       │
T=2s:  etcd detects missing heartbeats
       │
       ├──> Patroni agents on Coordinator-2 and Coordinator-3
       │    notice leader key expired in etcd
       │
T=3s:  Leader election race
       │
       ├──> Coordinator-2 acquires leader key first
       │    (first to write to etcd wins)
       │
T=4s:  Coordinator-2 promotes itself
       │
       ├──> Stops replication from Coordinator-1
       ├──> Triggers promotion (pg_ctl promote)
       ├──> Updates etcd leader key
       ├──> Starts accepting write connections
       │
T=6s:  HAProxy detects Coordinator-1 failure
       │
       ├──> 3 failed health checks (3 × 2s interval)
       ├──> Marks Coordinator-1 as DOWN
       ├──> Updates backend to route to Coordinator-2
       │
T=8s:  New connections route to Coordinator-2
       │
       ├──> Existing connections to Coordinator-1 fail
       ├──> Clients reconnect (auto-retry in most drivers)
       └──> Cluster fully operational

Total Downtime: 6-10s
Data Loss: 0 bytes (synchronous replication)
Client Impact: Existing connections fail, new connections succeed

Recovery:
  1. Fix Coordinator-1 (or provision new node)
  2. Patroni auto-reattaches as standby
  3. Replicates from new primary (Coordinator-2)
  4. Cluster back to 3 nodes (full HA)
```

---

### Worker Failover (Automatic)

```
T=0s:  Worker-1-1 (Shard 1 primary) crashes
       │
       ├──> Patroni heartbeat missed
       │
T=2s:  Worker-1-2 detects primary failure
       │
       ├──> Patroni on Worker-1-2 notices leader key expired
       │
T=3s:  Worker-1-2 promotes itself
       │
       ├──> Acquires leader key for shard-1 scope
       ├──> Triggers promotion (pg_ctl promote)
       ├──> Starts accepting write connections
       │
T=4s:  Coordinator detects worker metadata change
       │
       ├──> Citus notices shard placement change
       ├──> Updates internal routing tables
       ├──> Redirects queries to Worker-1-2
       │
T=5s:  Queries automatically routed to Worker-1-2
       │
       └──> Transparent to clients (coordinator handles routing)

Total Downtime: 2-4s (per shard)
Data Loss: <5s of writes (async replication lag)
Client Impact: Transparent (coordinator retries failed queries)

Recovery:
  1. Fix Worker-1-1 (or provision new node)
  2. Patroni reattaches as standby
  3. Replicates from Worker-1-2
  4. Shard back to HA state (2 replicas)

Note: Other shards (2, 3) unaffected during failover
```

---

## Deployment Architecture

### Physical Host Deployment (3 Hosts)

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          HOST 1 (Manager + Worker)                        │
│  IP: 10.0.0.10                                                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                   │
│  │   etcd-1     │  │ Coordinator  │  │   Worker     │                   │
│  │              │  │      1       │  │    1-1       │                   │
│  │  Port: 2379  │  │  Port: 5432  │  │  Port: 5432  │                   │
│  │  Volume:     │  │  Volume:     │  │  Volume:     │                   │
│  │  etcd-1-data │  │  coord-1-data│  │  worker-1-1  │                   │
│  └──────────────┘  └──────────────┘  └──────────────┘                   │
│  ┌──────────────┐                                                        │
│  │  HAProxy-1   │  (Active)                                              │
│  │  Port: 5432  │                                                        │
│  │  VIP: 10.0.0.100 (keepalived)                                         │
│  └──────────────┘                                                        │
│         overlay-net: 10.0.1.0/24                                          │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│                          HOST 2 (Manager + Worker)                        │
│  IP: 10.0.0.11                                                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                   │
│  │   etcd-2     │  │ Coordinator  │  │   Worker     │                   │
│  │              │  │      2       │  │    2-1       │                   │
│  │  Port: 2379  │  │  Port: 5432  │  │  Port: 5432  │                   │
│  └──────────────┘  └──────────────┘  └──────────────┘                   │
│  ┌──────────────┐  ┌──────────────┐                                     │
│  │   Worker     │  │  HAProxy-2   │  (Passive)                          │
│  │    1-2       │  │  Port: 5432  │                                     │
│  │  Port: 5432  │  └──────────────┘                                     │
│  └──────────────┘                                                        │
│         overlay-net: 10.0.1.0/24                                          │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│                          HOST 3 (Manager + Worker)                        │
│  IP: 10.0.0.12                                                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                   │
│  │   etcd-3     │  │ Coordinator  │  │   Worker     │                   │
│  │              │  │      3       │  │    2-2       │                   │
│  │  Port: 2379  │  │  Port: 5432  │  │  Port: 5432  │                   │
│  └──────────────┘  └──────────────┘  └──────────────┘                   │
│  ┌──────────────┐  ┌──────────────┐                                     │
│  │   Worker     │  │   Worker     │                                     │
│  │    3-1       │  │    3-2       │                                     │
│  │  Port: 5432  │  │  Port: 5432  │                                     │
│  └──────────────┘  └──────────────┘                                     │
│         overlay-net: 10.0.1.0/24                                          │
└──────────────────────────────────────────────────────────────────────────┘

Placement Strategy:
  - etcd: 1 per host (quorum = 2/3)
  - Coordinators: 1 per host (spread anti-affinity)
  - Workers: 2-3 per host (allows density)
  - HAProxy: 2 total (active-passive via keepalived)

Failure Tolerance:
  - Lose 1 host: Cluster remains operational
  - Lose 2 hosts: etcd loses quorum, cluster read-only
  - Lose 3 hosts: Complete outage
```

---

### Container Resource Allocation

```
┌───────────────────────────────────────────────────────────────────────┐
│                     RESOURCE ALLOCATION PER NODE                       │
├───────────────┬────────┬────────┬─────────┬────────────────────────────┤
│  Component    │  CPU   │  RAM   │ Storage │  Notes                     │
├───────────────┼────────┼────────┼─────────┼────────────────────────────┤
│ Coordinator   │  2     │  8GB   │  100GB  │ Query planning, metadata   │
│ Worker        │  4     │  16GB  │  500GB  │ Data storage, HNSW indexes │
│ etcd          │  0.5   │  1GB   │  10GB   │ Consensus, config storage  │
│ HAProxy       │  1     │  512MB │  1GB    │ Load balancing, stats      │
│ PgBouncer     │  0.5   │  256MB │  -      │ (included in PG container) │
│ Prometheus    │  1     │  2GB   │  50GB   │ Metrics storage            │
│ Grafana       │  0.5   │  1GB   │  5GB    │ Dashboards                 │
├───────────────┼────────┼────────┼─────────┼────────────────────────────┤
│ TOTAL/Host    │  8+    │  32GB+ │  500GB+ │ Minimum for 3-host cluster │
└───────────────┴────────┴────────┴─────────┴────────────────────────────┘

Scaling Examples:
  - 6 Workers: 24 CPU, 96GB RAM, 3TB storage (data tier)
  - 9 Workers: 36 CPU, 144GB RAM, 4.5TB storage
  - Add workers in pairs (HA per shard)
```

---

**Document Version:** 1.0
**Last Updated:** 2026-02-10
**Author:** System Architecture Designer (Claude)
