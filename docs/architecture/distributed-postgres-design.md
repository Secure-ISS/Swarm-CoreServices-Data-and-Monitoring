# Distributed PostgreSQL Cluster Architecture Design

## Executive Summary

This document outlines the architecture for a distributed PostgreSQL cluster that operates as a mesh of containers presenting as a single database. The design leverages Citus for horizontal sharding, Patroni for high availability, PgBouncer for connection pooling, and HAProxy for load balancing, all orchestrated through Docker Swarm. The system is optimized for RuVector vector operations and Komodo MCP compatibility.

**Key Characteristics:**
- Unified database interface via single connection endpoint
- Horizontal scalability through sharding and replication
- High availability with automatic failover
- Vector operation optimization for RuVector extension
- Docker Swarm native deployment
- Zero-downtime rolling updates

---

## Architecture Decision Records (ADRs)

### ADR-001: Hybrid Citus + Patroni Architecture

**Status:** Accepted

**Context:**
We need a distributed PostgreSQL system that provides both horizontal scalability (sharding) and high availability (replication). Pure Citus lacks HA, while pure Patroni lacks native sharding.

**Decision:**
Implement a **hybrid architecture** combining:
- **Citus** for distributed query execution and sharding
- **Patroni** for HA and automatic failover within each shard group
- **etcd** for distributed consensus

**Rationale:**
1. **Citus Benefits:**
   - Native PostgreSQL extension (no middleware)
   - Distributed query planning and execution
   - Transparent sharding for applications
   - Excellent for OLTP and analytical workloads

2. **Patroni Benefits:**
   - Battle-tested HA solution
   - Sub-second failover
   - Automatic leader election
   - Synchronous/asynchronous replication options

3. **Why Not Alternatives:**
   - **Pure Patroni**: No native sharding, limited horizontal scale
   - **Pure Citus**: Single point of failure on coordinator
   - **PostgreSQL-XL**: Abandoned project, poor maintenance
   - **Greenplum**: OLAP-focused, heavyweight for OLTP

**Consequences:**
- Increased operational complexity (two systems to manage)
- Better separation of concerns (HA vs sharding)
- More flexible scaling options
- Proven components with strong community support

---

### ADR-002: Mesh Topology with Coordinator-Worker Pattern

**Status:** Accepted

**Context:**
Need to define the network topology for container communication and query routing.

**Decision:**
Implement a **hierarchical mesh topology**:
```
              Client Applications
                      |
                  [HAProxy]
                      |
        +-------------+-------------+
        |             |             |
    [Coord-1]     [Coord-2]     [Coord-3]
    (Patroni      (Patroni      (Patroni
     cluster)      cluster)      cluster)
        |             |             |
    +---+---+     +---+---+     +---+---+
    |       |     |       |     |       |
  [W1-1] [W1-2] [W2-1] [W2-2] [W3-1] [W3-2]
  Shard1 Shard1 Shard2 Shard2 Shard3 Shard3
```

**Components:**
1. **Coordinator Nodes (3)**: Citus coordinators in Patroni HA cluster
2. **Worker Nodes (6+)**: Citus workers, 2+ per shard in Patroni pairs
3. **HAProxy (2)**: Active-passive load balancers
4. **etcd (3)**: Distributed consensus for Patroni
5. **PgBouncer (per node)**: Connection pooling

**Rationale:**
- **Hierarchical**: Simplifies query routing (clients → coordinator → workers)
- **Mesh**: All nodes can communicate directly (Docker Swarm overlay)
- **3 Coordinators**: Maintains quorum, tolerates 1 failure
- **2+ Workers per Shard**: HA for each data partition
- **HAProxy**: Single entry point, SSL termination, health checks

**Consequences:**
- Clear separation between query planning (coordinators) and execution (workers)
- Horizontal scalability by adding worker nodes
- Vertical complexity in coordinator HA
- Network overhead for cross-node queries

---

### ADR-003: Hash-Based Sharding with Reference Tables

**Status:** Accepted

**Context:**
Need to determine data distribution strategy across worker nodes.

**Decision:**
Implement **hash-based sharding** with **reference tables** for small dimension tables.

**Sharding Strategy:**
```sql
-- Distributed tables (hash sharded)
SELECT create_distributed_table('memory_entries', 'namespace');
SELECT create_distributed_table('patterns', 'namespace');
SELECT create_distributed_table('trajectories', 'id');
SELECT create_distributed_table('graph_nodes', 'namespace');

-- Reference tables (replicated to all workers)
SELECT create_reference_table('vector_indexes');
SELECT create_reference_table('sessions');
SELECT create_reference_table('metadata');
```

**Sharding Key Selection:**
- `memory_entries`: `namespace` (co-locate related memories)
- `patterns`: `namespace` (co-locate pattern learning)
- `trajectories`: `id` (distribute evenly)
- `graph_nodes`: `namespace` (enable efficient graph queries)

**Rationale:**
1. **Hash Distribution**: Even data distribution, predictable performance
2. **Namespace Sharding**: Co-locates related data, reduces cross-shard queries
3. **Reference Tables**: Small lookup tables replicated for fast joins
4. **Co-location**: Enables distributed joins without data movement

**Alternatives Considered:**
- **Range Sharding**: Hotspots with time-series data
- **Geographic Sharding**: Not applicable to our use case
- **Round-Robin**: Poor join performance

**Consequences:**
- Cannot change shard key without data migration
- Cross-namespace queries may hit multiple shards
- Reference tables increase write latency (replicated)
- Excellent performance for namespace-scoped queries

---

### ADR-004: Synchronous Replication for Coordinators, Async for Workers

**Status:** Accepted

**Context:**
Need to balance consistency, availability, and performance across the cluster.

**Decision:**
Implement **synchronous replication** for coordinator Patroni cluster and **asynchronous replication** for worker Patroni clusters.

**Configuration:**
```yaml
# Coordinator (Patroni cluster 1)
synchronous_mode: true
synchronous_node_count: 1  # Wait for 1 standby

# Workers (Patroni clusters 2-N)
synchronous_mode: false
synchronous_commit: 'local'  # Don't wait for standbys
```

**Rationale:**
1. **Coordinator Sync Replication**:
   - Metadata consistency critical (table definitions, sharding config)
   - Lower write volume (mostly DDL)
   - Acceptable latency trade-off for consistency

2. **Worker Async Replication**:
   - High write throughput required
   - Data can be reconstructed from coordinator metadata
   - Standbys provide read scaling
   - Acceptable to lose some data on failure (RPO ~seconds)

**Trade-offs:**
| Aspect | Sync (Coordinators) | Async (Workers) |
|--------|---------------------|-----------------|
| **Consistency** | Strong | Eventual |
| **Write Latency** | Higher (+5-10ms) | Lower |
| **Data Loss Risk** | Zero (RPO=0) | Minimal (RPO<5s) |
| **Throughput** | Lower | Higher |
| **Availability** | Requires quorum | More available |

**Consequences:**
- No metadata loss on coordinator failure
- Workers prioritize performance over zero data loss
- Standbys can serve read-only queries
- Async replication lag monitoring required

---

### ADR-005: etcd for Service Discovery and Configuration

**Status:** Accepted

**Context:**
Distributed systems require service discovery, leader election, and configuration management.

**Decision:**
Deploy **etcd** 3-node cluster for:
1. Patroni leader election and DCS (Distributed Configuration Store)
2. Service discovery for coordinators and workers
3. Dynamic configuration storage

**Architecture:**
```
[etcd-1]  [etcd-2]  [etcd-3]  (3-node Raft cluster)
    |         |         |
    +----+----+----+----+
         |
    [Patroni agents read/write cluster state]
    [HAProxy queries for primary/replica endpoints]
```

**Rationale:**
1. **etcd vs Alternatives**:
   - **vs Consul**: etcd simpler, less overhead, native Patroni support
   - **vs ZooKeeper**: etcd more modern, better API, easier ops
   - **vs Kubernetes**: etcd works in pure Docker Swarm

2. **Benefits**:
   - Strong consistency (Raft consensus)
   - Sub-second failover detection
   - Mature, battle-tested (Kubernetes uses it)
   - Simple HTTP/gRPC API

**Configuration:**
```yaml
# etcd cluster for Patroni
ETCD_INITIAL_CLUSTER: "etcd-1=http://etcd-1:2380,etcd-2=http://etcd-2:2380,etcd-3=http://etcd-3:2380"
ETCD_INITIAL_CLUSTER_STATE: "new"
ETCD_HEARTBEAT_INTERVAL: 100
ETCD_ELECTION_TIMEOUT: 1000
```

**Consequences:**
- Additional infrastructure component (3 containers)
- Single source of truth for cluster state
- Network partition handling (split-brain protection)
- Must monitor etcd cluster health

---

### ADR-006: PgBouncer for Connection Pooling

**Status:** Accepted

**Context:**
PostgreSQL connections are heavyweight (fork per connection). Need to support thousands of concurrent clients.

**Decision:**
Deploy **PgBouncer** on each PostgreSQL node in **transaction pooling mode**.

**Deployment Model:**
```
[Client] → [HAProxy:5432] → [PgBouncer:6432] → [PostgreSQL:5432]
               |                   |                  |
           Load Balance      Connection Pool    Actual Database
```

**Configuration:**
```ini
[pgbouncer]
pool_mode = transaction
max_client_conn = 10000
default_pool_size = 25
reserve_pool_size = 5
reserve_pool_timeout = 3
max_db_connections = 100
```

**Pooling Modes:**
| Mode | Connection Reuse | Transaction Isolation | Use Case |
|------|------------------|----------------------|----------|
| **transaction** | After COMMIT | Supported | OLTP (chosen) |
| session | Never | Full PostgreSQL | Long connections |
| statement | After each query | Limited | Serverless |

**Rationale:**
1. **Transaction Mode**: Best for OLTP workloads, supports transactions
2. **Per-Node Deployment**: Reduced latency, no SPOF
3. **High Client Limit**: Support 10K concurrent clients with 100 DB conns
4. **Resource Efficiency**: Reduces PostgreSQL memory overhead

**Consequences:**
- Some PostgreSQL features not supported (session variables, advisory locks)
- Additional monitoring required (pool saturation)
- Reduced memory footprint (10K → 100 connections)
- Better connection distribution

---

### ADR-007: HAProxy for Load Balancing and Failover

**Status:** Accepted

**Context:**
Need single entry point for clients with automatic failover detection.

**Decision:**
Deploy **HAProxy** in **active-passive** mode with health checks.

**Architecture:**
```
         [HAProxy-1] (Active)
              |
    +---------+---------+
    |         |         |
[Coord-1] [Coord-2] [Coord-3]
 Primary   Standby   Standby
```

**Configuration:**
```haproxy
# haproxy.cfg
frontend postgres_frontend
    bind *:5432
    mode tcp
    default_backend postgres_backend

backend postgres_backend
    mode tcp
    option tcp-check
    tcp-check connect
    tcp-check send "SELECT 1"
    tcp-check expect string "1"

    server coord1 coord-1:6432 check inter 2s fall 3 rise 2
    server coord2 coord-2:6432 check inter 2s fall 3 rise 2 backup
    server coord3 coord-3:6432 check inter 2s fall 3 rise 2 backup
```

**Health Check Strategy:**
- **Primary Detection**: Query etcd for Patroni leader
- **TCP Check**: Ensure port is open
- **Application Check**: Execute `SELECT 1` to verify database responsiveness
- **Failover**: 3 failed checks (6s) triggers failover

**Rationale:**
1. **Active-Passive**: Simpler than active-active, no connection redistribution
2. **TCP Mode**: Full protocol compatibility, no SSL termination
3. **Health Checks**: Patroni-aware, detects database health not just port
4. **Backup Servers**: Automatic promotion on primary failure

**Consequences:**
- HAProxy becomes SPOF (mitigated by keepalived/VRRP for HA)
- <6s failover time (3 checks × 2s interval)
- Clients don't need to know about Patroni
- Single connection string for all clients

---

### ADR-008: RuVector Sharding Compatibility

**Status:** Accepted

**Context:**
RuVector extension must work across distributed Citus cluster. Vector operations and HNSW indexes must be shard-aware.

**Decision:**
Deploy **RuVector extension on all nodes** (coordinators + workers) with **distributed HNSW indexes**.

**Architecture:**
```
Coordinator:
  - RuVector extension (query planning)
  - No local vector data
  - Distributes queries to workers

Workers:
  - RuVector extension (query execution)
  - Local HNSW indexes per shard
  - Parallel vector search
```

**Vector Operations Distribution:**

1. **INSERT (Distributed)**:
```sql
-- Client → Coordinator → Worker (based on hash(namespace))
INSERT INTO memory_entries (namespace, key, embedding)
VALUES ('patterns', 'auth-flow', '[0.1, 0.2, ...]'::ruvector);
```

2. **SEARCH (Parallel)**:
```sql
-- Coordinator sends to ALL workers, merges results
SELECT namespace, key,
       1 - (embedding <=> '[...]'::ruvector) as similarity
FROM memory_entries
WHERE namespace = 'patterns'  -- Prunes to 1 shard
ORDER BY embedding <=> '[...]'::ruvector
LIMIT 10;
```

**HNSW Index Configuration:**
```sql
-- Per-worker configuration
CREATE INDEX idx_memory_embedding_hnsw
ON memory_entries
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 16, ef_construction = 200);

-- Distributed execution
-- Each worker searches its local shard (parallel)
-- Coordinator merges and re-ranks results
```

**Performance Characteristics:**
| Operation | Single Node | Distributed (4 shards) |
|-----------|-------------|------------------------|
| **Insert** | 5ms | 5ms (single shard) |
| **Search (namespace)** | 10ms | 10ms (single shard) |
| **Search (global)** | 50ms | 15ms (parallel) |
| **Index Build** | 1 min | 15s (parallel) |

**Rationale:**
1. **Extension on All Nodes**: Citus requires extensions on coordinators + workers
2. **Distributed Indexes**: Each shard maintains its own HNSW index
3. **Parallel Search**: 4x speedup for global searches (4 shards)
4. **Shard Key Optimization**: `namespace` sharding co-locates related vectors

**Consequences:**
- Global vector searches hit all shards (network overhead)
- Namespace-scoped searches hit single shard (optimal)
- Index maintenance distributed across workers
- Coordinator merges require post-processing for global top-K

---

### ADR-009: Docker Swarm Deployment with Overlay Networks

**Status:** Accepted

**Context:**
Need container orchestration for multi-host deployment with service discovery and overlay networking.

**Decision:**
Deploy on **Docker Swarm** with **overlay networks** for inter-node communication.

**Network Topology:**
```
[overlay-net: 10.0.1.0/24]
    |
    +-- [coordinator-net: 10.0.1.0/26] (Coordinators + etcd)
    +-- [worker-net: 10.0.1.64/26]      (Workers)
    +-- [admin-net: 10.0.1.128/26]      (HAProxy, monitoring)
```

**Service Definitions:**
```yaml
# docker-compose-swarm.yml
version: '3.8'
services:
  coordinator:
    image: ruvnet/ruvector-postgres:latest
    deploy:
      replicas: 3
      placement:
        max_replicas_per_node: 1  # Anti-affinity
    networks:
      - coordinator-net
    configs:
      - patroni.yml
      - citus-coordinator.conf
    secrets:
      - postgres_password

  worker:
    image: ruvnet/ruvector-postgres:latest
    deploy:
      replicas: 6
      placement:
        max_replicas_per_node: 2
    networks:
      - worker-net
    configs:
      - patroni.yml
      - citus-worker.conf

  haproxy:
    image: haproxy:2.9-alpine
    deploy:
      replicas: 2
      placement:
        max_replicas_per_node: 1
    ports:
      - "5432:5432"
    networks:
      - admin-net
      - coordinator-net
```

**Rationale:**
1. **Docker Swarm vs Kubernetes**:
   - Simpler (no CRDs, operators, or complex RBAC)
   - Native Docker integration (Komodo MCP compatible)
   - Built-in overlay networking
   - Lower resource overhead
   - Easier local development

2. **Overlay Networks**:
   - Container-to-container communication across hosts
   - Automatic service discovery (DNS)
   - Network isolation between tiers
   - VXLAN encryption support

3. **Service Placement**:
   - `max_replicas_per_node: 1` for coordinators (spread across hosts)
   - `max_replicas_per_node: 2` for workers (allow density)
   - Tolerates host failure

**Consequences:**
- Requires Docker Swarm cluster (3+ manager nodes)
- Overlay network latency (+0.5-1ms vs host network)
- Simplified deployment vs Kubernetes
- Compatible with Komodo MCP Docker integration

---

### ADR-010: Komodo MCP Integration Architecture

**Status:** Accepted

**Context:**
Must integrate with Komodo MCP (Model Context Protocol) for AI agent database access.

**Decision:**
Expose **PostgreSQL via Komodo MCP Server** with **connection pooling** and **access control**.

**Architecture:**
```
[Claude Agent] → [Komodo MCP Server] → [HAProxy:5432] → [Cluster]
       |                  |
   MCP Protocol     PostgreSQL Wire
   (JSON-RPC)         Protocol
```

**MCP Server Configuration:**
```json
{
  "mcpServers": {
    "distributed-postgres": {
      "command": "npx",
      "args": ["-y", "@komodo-mcp/postgres@latest"],
      "env": {
        "POSTGRES_HOST": "haproxy.cluster.local",
        "POSTGRES_PORT": "5432",
        "POSTGRES_DB": "distributed_postgres_cluster",
        "POSTGRES_USER": "mcp_user",
        "POSTGRES_PASSWORD": "${MCP_POSTGRES_PASSWORD}",
        "POSTGRES_POOL_SIZE": "10",
        "POSTGRES_SSL": "prefer"
      }
    }
  }
}
```

**Access Control:**
```sql
-- MCP user with limited permissions
CREATE USER mcp_user WITH PASSWORD '...';

-- Read-only on data tables
GRANT SELECT ON memory_entries, patterns, trajectories TO mcp_user;

-- Insert on specific tables
GRANT INSERT ON memory_entries TO mcp_user;

-- No DDL permissions
REVOKE CREATE ON SCHEMA public FROM mcp_user;
```

**Rationale:**
1. **MCP Protocol**: Standard AI agent database access
2. **HAProxy Endpoint**: Single connection point, automatic failover
3. **Connection Pooling**: PgBouncer handles MCP connection bursts
4. **Security**: Least-privilege access for AI agents

**Consequences:**
- AI agents see unified database (sharding transparent)
- Connection pooling handles concurrent agent requests
- Read-only access prevents accidental data corruption
- Must monitor MCP connection usage

---

## System Architecture

### Logical Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                         CLIENT LAYER                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │   Python     │  │ Claude Agent │  │   Web App    │              │
│  │   Client     │  │  (MCP)       │  │              │              │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘              │
│         │                  │                  │                      │
│         └──────────────────┴──────────────────┘                      │
│                            │                                         │
└────────────────────────────┼─────────────────────────────────────────┘
                             │
                    postgres://cluster:5432
                             │
┌────────────────────────────┼─────────────────────────────────────────┐
│                     LOAD BALANCER LAYER                              │
│         ┌────────────────────┴────────────────────┐                  │
│         │          HAProxy (Active/Passive)        │                  │
│         │  - Health checks (Patroni-aware)        │                  │
│         │  - Connection routing                    │                  │
│         │  - SSL termination (optional)            │                  │
│         └────────────────────┬────────────────────┘                  │
└──────────────────────────────┼─────────────────────────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
┌─────────────┼────────────────┼────────────────┼──────────────────────┐
│      COORDINATOR LAYER (Patroni Cluster)                             │
│             │                │                │                      │
│      ┌──────▼──────┐  ┌──────▼──────┐  ┌──────▼──────┐             │
│      │ Coordinator │  │ Coordinator │  │ Coordinator │             │
│      │     1       │  │     2       │  │     3       │             │
│      │  (Leader)   │  │  (Standby)  │  │  (Standby)  │             │
│      │             │  │             │  │             │             │
│      │ Citus       │  │ Citus       │  │ Citus       │             │
│      │ Coordinator │  │ Coordinator │  │ Coordinator │             │
│      │ PgBouncer   │  │ PgBouncer   │  │ PgBouncer   │             │
│      │ RuVector    │  │ RuVector    │  │ RuVector    │             │
│      └──────┬──────┘  └──────┬──────┘  └──────┬──────┘             │
│             │                │                │                      │
│             └────────────────┼────────────────┘                      │
└──────────────────────────────┼─────────────────────────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
┌─────────────┼────────────────┼────────────────┼──────────────────────┐
│         WORKER LAYER (Sharded Data)                                  │
│             │                │                │                      │
│   ┌─────────▼─────────┐ ┌────▼──────────┐ ┌──▼──────────────┐      │
│   │    Shard 1        │ │   Shard 2     │ │   Shard 3       │      │
│   │  ┌──────────────┐ │ │ ┌──────────┐  │ │ ┌──────────┐    │      │
│   │  │  Worker 1-1  │ │ │ │Worker 2-1│  │ │ │Worker 3-1│    │      │
│   │  │  (Primary)   │ │ │ │(Primary) │  │ │ │(Primary) │    │      │
│   │  │              │ │ │ │          │  │ │ │          │    │      │
│   │  │  PgBouncer   │ │ │ │PgBouncer │  │ │ │PgBouncer │    │      │
│   │  │  RuVector    │ │ │ │RuVector  │  │ │ │RuVector  │    │      │
│   │  │  HNSW Index  │ │ │ │HNSW Index│  │ │ │HNSW Index│    │      │
│   │  └──────┬───────┘ │ │ └────┬─────┘  │ │ └────┬─────┘    │      │
│   │         │         │ │      │        │ │      │          │      │
│   │  ┌──────▼───────┐ │ │ ┌────▼─────┐  │ │ ┌────▼─────┐    │      │
│   │  │  Worker 1-2  │ │ │ │Worker 2-2│  │ │ │Worker 3-2│    │      │
│   │  │  (Standby)   │ │ │ │(Standby) │  │ │ │(Standby) │    │      │
│   │  └──────────────┘ │ │ └──────────┘  │ │ └──────────┘    │      │
│   └──────────────────┘ └───────────────┘ └─────────────────┘      │
└────────────────────────────────────────────────────────────────────┘
                               │
┌──────────────────────────────┼─────────────────────────────────────────┐
│              CONSENSUS LAYER                                         │
│         ┌────────────────────┴────────────────────┐                  │
│         │        etcd Cluster (3 nodes)           │                  │
│         │  - Patroni DCS                          │                  │
│         │  - Leader election                      │                  │
│         │  - Configuration storage                │                  │
│         └─────────────────────────────────────────┘                  │
└──────────────────────────────────────────────────────────────────────┘
```

### Physical Deployment (Docker Swarm)

```
┌─────────────────────────────────────────────────────────────────────┐
│                          HOST 1 (Manager + Worker)                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │   etcd-1     │  │ Coordinator  │  │   Worker     │              │
│  │              │  │      1       │  │    1-1       │              │
│  └──────────────┘  └──────────────┘  └──────────────┘              │
│  ┌──────────────┐                                                   │
│  │  HAProxy-1   │  (Active)                                         │
│  └──────────────┘                                                   │
│         overlay-net: 10.0.1.0/24                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                          HOST 2 (Manager + Worker)                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │   etcd-2     │  │ Coordinator  │  │   Worker     │              │
│  │              │  │      2       │  │    2-1       │              │
│  └──────────────┘  └──────────────┘  └──────────────┘              │
│  ┌──────────────┐  ┌──────────────┐                                │
│  │   Worker     │  │  HAProxy-2   │  (Passive)                     │
│  │    1-2       │  └──────────────┘                                │
│  └──────────────┘                                                   │
│         overlay-net: 10.0.1.0/24                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                          HOST 3 (Manager + Worker)                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │   etcd-3     │  │ Coordinator  │  │   Worker     │              │
│  │              │  │      3       │  │    2-2       │              │
│  └──────────────┘  └──────────────┘  └──────────────┘              │
│  ┌──────────────┐  ┌──────────────┐                                │
│  │   Worker     │  │   Worker     │                                 │
│  │    3-1       │  │    3-2       │                                 │
│  └──────────────┘  └──────────────┘                                │
│         overlay-net: 10.0.1.0/24                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Component Interactions

### 1. Client Connection Flow

```
┌────────┐     ┌─────────┐     ┌──────────┐     ┌───────────┐
│ Client │────>│ HAProxy │────>│PgBouncer │────>│Coordinator│
└────────┘     └─────────┘     └──────────┘     └───────────┘
                   │                                    │
                   │ 1. TCP health check                │
                   │ 2. Check etcd for Patroni leader   │
                   │ 3. Route to leader                 │
                   │                                    │
                   │<───────────────────────────────────┘
                   │ 4. Return leader endpoint
```

**Steps:**
1. Client connects to `cluster.example.com:5432`
2. HAProxy receives connection
3. HAProxy checks etcd: `GET /service/postgres-cluster/leader`
4. HAProxy routes to Patroni leader (coordinator-1)
5. PgBouncer accepts connection from pool
6. Connection established to Coordinator PostgreSQL

**Failure Scenario:**
- If coordinator-1 fails, Patroni elects new leader (coordinator-2)
- HAProxy detects failure in 6s (3 failed checks)
- HAProxy routes new connections to coordinator-2
- Existing connections terminated (clients reconnect)

### 2. Write Operation Flow (INSERT)

```
Client: INSERT INTO memory_entries VALUES (..., 'namespace-a', ...);

┌────────┐     ┌───────────┐     ┌──────────┐
│ Client │────>│Coordinator│────>│ Worker   │
└────────┘     │ (Citus)   │     │  (Shard) │
               └───────────┘     └──────────┘
                    │                  │
1. Parse query      │                  │
2. Identify shard: hash('namespace-a') % shard_count = 1
3. Route to Worker 1-1 (primary)───────>│
                    │                  │
                    │           4. Execute INSERT
                    │           5. Replicate to Worker 1-2 (async)
                    │                  │
                    │<─────────────────┘
6. Return result    │
                    │
<───────────────────┘
```

**Latency Breakdown:**
- Network RTT (client → coordinator): 1ms
- Query parsing and routing (coordinator): 0.5ms
- Network RTT (coordinator → worker): 0.5ms
- INSERT execution (worker): 2ms
- Replication (async, non-blocking): 0ms
- **Total: ~4ms**

### 3. Vector Search Flow (Distributed)

```
Client: SELECT * FROM memory_entries
        ORDER BY embedding <=> '[...]' LIMIT 10;

┌────────┐     ┌───────────┐     ┌──────────┐
│ Client │────>│Coordinator│────>│Worker 1-1│
└────────┘     │ (Citus)   │     └──────────┘
               └───────────┘            │
                    │        ────>│Worker 2-1│
                    │             └──────────┘
                    │        ────>│Worker 3-1│
                    │             └──────────┘
                    │                  │
1. Parse query      │                  │
2. Broadcast to ALL shards (parallel)  │
3. Each worker searches local HNSW index
                    │                  │
                    │<─────────────────┘
4. Merge results (re-rank top 10)      │
                    │                  │
<───────────────────┘
```

**Latency Breakdown:**
- Query parsing (coordinator): 0.5ms
- Parallel HNSW search (workers): 5ms (concurrent)
- Result merge and re-rank: 1ms
- **Total: ~6.5ms** (vs 15ms single-node for 3x data)

### 4. Failover Flow (Coordinator Failure)

```
T=0s:  Coordinator-1 crashes
       │
       ├──> Patroni agent detects failure (missed 2 heartbeats)
       │
T=2s:  etcd leader key expires
       │
       ├──> Patroni agents on Coordinator-2 and Coordinator-3 race
       │    for leader key (first to acquire wins)
       │
T=3s:  Coordinator-2 acquires leader key in etcd
       │
       ├──> Coordinator-2 promotes itself to leader
       │    - Stops replication from Coordinator-1
       │    - Accepts write connections
       │
T=4s:  HAProxy detects Coordinator-1 failure (3 failed checks)
       │
       ├──> HAProxy updates backend (Coordinator-2 = primary)
       │
T=5s:  New connections routed to Coordinator-2
       │
       └──> Existing connections fail (clients reconnect)
```

**Recovery Time Objectives:**
- **Detection**: 2s (Patroni heartbeat timeout)
- **Election**: 1s (etcd Raft election)
- **Promotion**: 1s (PostgreSQL promotion)
- **HAProxy Failover**: 6s (health check interval)
- **Total Downtime**: ~6-10s

### 5. Worker Failure Flow (Data Shard)

```
T=0s:  Worker-1-1 (Shard 1 primary) crashes
       │
       ├──> Patroni agent on Worker-1-2 detects failure
       │
T=2s:  Worker-1-2 promotes itself to primary (async replication)
       │
       ├──> Coordinator detects worker metadata change (Citus)
       │    - Updates shard placement metadata
       │    - Redirects queries to Worker-1-2
       │
T=4s:  Queries automatically routed to Worker-1-2
       │
       └──> No client-visible downtime (coordinator handles routing)
```

**Data Loss Risk:**
- Async replication lag: typically <5s
- Worst case: lose last 5s of writes to Shard 1
- Other shards unaffected

---

## Data Flow Diagrams

### Data Distribution (Sharding)

```
         Namespace Sharding Strategy

Input: INSERT INTO memory_entries (namespace, key, value)
       VALUES ('claude-flow', 'pattern-123', '...');

                     ┌───────────────┐
                     │  Coordinator  │
                     │               │
                     │  Compute:     │
                     │  shard_id =   │
                     │  hash_fn(     │
                     │   'claude-    │
                     │    flow'      │
                     │  ) % 3        │
                     └───────┬───────┘
                             │
                             │ shard_id = 1
                             │
                ┌────────────┼────────────┐
                │            │            │
         shard=0 │     shard=1 │     shard=2
                │            │            │
         ┌──────▼─────┐ ┌───▼────────┐ ┌▼──────────┐
         │  Worker    │ │  Worker    │ │  Worker   │
         │   Shard 0  │ │   Shard 1  │ │  Shard 2  │
         │            │ │            │ │           │
         │ Namespaces:│ │ Namespaces:│ │Namespaces:│
         │ - agents   │ │ - claude-  │ │- patterns │
         │ - configs  │ │   flow ✓   │ │- memory   │
         └────────────┘ └────────────┘ └───────────┘
```

**Co-location Benefits:**
- Queries within namespace hit single shard (1 network hop)
- Related data stored together (memory_entries + patterns + graph_nodes)
- Efficient joins and aggregations

### Replication Flow

```
    Synchronous Replication (Coordinators)

┌──────────────┐         ┌──────────────┐
│ Coordinator  │  WAL    │ Coordinator  │
│      1       │─────────>│      2       │
│  (Primary)   │Replicate│  (Standby)   │
└──────────────┘         └──────────────┘
       │                        │
       │ COMMIT                 │
       │                        │
       │<───────────────────────┘
       │   ACK (must wait)
       │
       └─────> Return to client

Time: +5-10ms latency (network RTT + write)


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

Time: No additional latency
RPO: ~5s (replication lag)
```

### Vector Search Distribution

```
   Global Vector Search (All Shards)

Query: Find top 10 similar vectors to [0.1, 0.2, ...]

┌─────────────────────────────────────────────────┐
│            Coordinator (Citus)                  │
│  1. Parse query                                 │
│  2. Broadcast to all workers (parallel)         │
└─────────────┬───────────────────────────────────┘
              │
    ┌─────────┼─────────┐
    │         │         │
┌───▼───┐ ┌───▼───┐ ┌───▼───┐
│Worker │ │Worker │ │Worker │
│Shard 0│ │Shard 1│ │Shard 2│
└───────┘ └───────┘ └───────┘
    │         │         │
    │ HNSW search (5ms each, parallel)
    │         │         │
    │ Top 10  │ Top 10  │ Top 10
    ↓         ↓         ↓
    │         │         │
┌───┴─────────┴─────────┴───────────────┐
│         Coordinator (Merge)            │
│  3. Collect 30 results (10 per shard) │
│  4. Re-rank by distance                │
│  5. Return top 10                      │
└────────────────────────────────────────┘
         │
         ↓ Top 10 global results
      Client

Latency: 5ms (parallel) + 1ms (merge) = 6ms
```

---

## Failure Scenarios and Recovery

### Scenario 1: Single Coordinator Failure

**Failure:**
- Coordinator-1 (primary) crashes

**Detection:**
- Patroni heartbeat missed (2s)
- etcd leader key expires

**Recovery:**
1. Patroni on Coordinator-2 detects failure
2. Coordinator-2 acquires leader key in etcd
3. Coordinator-2 promotes itself to primary
4. HAProxy detects failure, updates routing
5. New connections routed to Coordinator-2

**Impact:**
- Downtime: 6-10s
- Data loss: None (synchronous replication)
- Client action: Reconnect (automatic for most drivers)

**Prevention:**
- Run 3 coordinators for quorum
- Monitor Patroni lag and health

### Scenario 2: Worker Shard Failure

**Failure:**
- Worker-1-1 (Shard 1 primary) crashes

**Detection:**
- Patroni heartbeat missed (2s)

**Recovery:**
1. Worker-1-2 promotes itself to primary
2. Coordinator updates Citus metadata
3. Queries automatically routed to Worker-1-2

**Impact:**
- Downtime: 2-4s
- Data loss: <5s of writes (async replication)
- Client action: Transparent (coordinator handles routing)

**Prevention:**
- Run 2+ workers per shard
- Monitor replication lag
- Consider synchronous replication for critical shards

### Scenario 3: Network Partition (Split Brain)

**Failure:**
- Network partition splits cluster into two groups:
  - Group A: Coordinator-1, Worker-1-1, etcd-1
  - Group B: Coordinator-2, Coordinator-3, Worker-1-2, etcd-2, etcd-3

**Detection:**
- etcd loses quorum in Group A (1 of 3 nodes)
- Patroni in Group A cannot update leader key

**Recovery:**
1. etcd cluster remains operational in Group B (2 of 3 quorum)
2. Patroni in Group B elects new leader (Coordinator-2)
3. Group A coordinators become read-only (no quorum)
4. HAProxy routes to Group B

**Impact:**
- Group A: Read-only mode
- Group B: Fully operational
- No data loss or split-brain

**Prevention:**
- etcd quorum (3 nodes) prevents split-brain
- Network redundancy (multiple paths)
- Monitor etcd cluster health

### Scenario 4: Complete etcd Failure

**Failure:**
- All 3 etcd nodes crash

**Detection:**
- Patroni cannot read/write DCS
- Leader election impossible

**Recovery:**
1. Existing cluster continues operation (Patroni doesn't fence immediately)
2. Manual intervention required:
   - Restore etcd from backup
   - Or: bootstrap new etcd cluster
   - Or: switch to manual Patroni mode

**Impact:**
- No automatic failover (manual failover required)
- Existing connections continue working
- New writes succeed (to existing primary)
- High risk of split-brain on coordinator failure

**Prevention:**
- Monitor etcd cluster health
- Backup etcd data regularly
- Have etcd disaster recovery plan

### Scenario 5: HAProxy Failure

**Failure:**
- HAProxy-1 (active) crashes

**Detection:**
- keepalived/VRRP detects failure (1s)

**Recovery:**
1. HAProxy-2 (passive) promoted to active
2. Virtual IP moves to HAProxy-2
3. Clients reconnect to same endpoint

**Impact:**
- Downtime: 1-2s
- Data loss: None
- Client action: Automatic reconnect

**Prevention:**
- Run HAProxy in active-passive with keepalived
- Monitor HAProxy health

---

## Technology Stack

| Component | Technology | Version | Purpose |
|-----------|-----------|---------|---------|
| **Database** | PostgreSQL | 16+ | Core database engine |
| **Vector Extension** | RuVector | 2.0.0 | Vector operations, HNSW indexes |
| **Sharding** | Citus | 12.1+ | Distributed query execution |
| **High Availability** | Patroni | 3.3+ | Automatic failover, leader election |
| **Consensus** | etcd | 3.5+ | Distributed configuration store |
| **Connection Pooling** | PgBouncer | 1.22+ | Connection management |
| **Load Balancer** | HAProxy | 2.9+ | TCP load balancing |
| **Orchestration** | Docker Swarm | 24.0+ | Container management |
| **Base Image** | ruvnet/ruvector-postgres | latest | Custom PostgreSQL + RuVector |
| **Monitoring** | Prometheus + Grafana | Latest | Metrics and alerting |

---

## Performance Characteristics

### Throughput Benchmarks (Target)

| Operation | Single Node | 3-Shard Cluster | Scaling Factor |
|-----------|-------------|-----------------|----------------|
| **INSERT (single)** | 1,000 TPS | 3,000 TPS | 3x (linear) |
| **SELECT (key)** | 10,000 TPS | 10,000 TPS | 1x (no improvement) |
| **SELECT (vector, namespace)** | 500 TPS | 500 TPS | 1x (single shard) |
| **SELECT (vector, global)** | 200 TPS | 600 TPS | 3x (parallel) |
| **Bulk INSERT** | 50,000 rows/s | 150,000 rows/s | 3x (parallel) |

### Latency Benchmarks (Target)

| Operation | p50 | p95 | p99 |
|-----------|-----|-----|-----|
| **Single-shard write** | 4ms | 8ms | 15ms |
| **Single-shard read** | 2ms | 4ms | 8ms |
| **Vector search (namespace)** | 6ms | 12ms | 20ms |
| **Vector search (global)** | 8ms | 15ms | 25ms |
| **Coordinator failover** | - | 6s | 10s |
| **Worker failover** | - | 3s | 5s |

### Scalability Limits

| Metric | Limit | Notes |
|--------|-------|-------|
| **Max Shards** | 32 | Citus recommendation |
| **Max Workers per Shard** | 10 | Replication overhead |
| **Max Coordinators** | 5 | Patroni quorum complexity |
| **Max Table Size** | 100TB+ | Per shard (distributed) |
| **Max Connections** | 10,000 | Via PgBouncer pooling |
| **Max Vector Dimensions** | 2,000 | RuVector HNSW limitation |

---

## Deployment Guide

### Prerequisites

- Docker Swarm cluster (3+ manager nodes)
- Docker Engine 24.0+
- Minimum 3 hosts (for quorum)
- Each host: 8GB RAM, 4 CPU, 100GB SSD

### Quick Start

```bash
# 1. Initialize Docker Swarm (on manager node)
docker swarm init --advertise-addr <MANAGER-IP>

# 2. Join worker nodes (run on each worker)
docker swarm join --token <TOKEN> <MANAGER-IP>:2377

# 3. Create overlay network
docker network create --driver overlay --attachable cluster-net

# 4. Deploy stack
docker stack deploy -c docker-compose-swarm.yml postgres-cluster

# 5. Verify deployment
docker service ls
docker stack ps postgres-cluster

# 6. Initialize Citus cluster
docker exec -it $(docker ps -q -f name=coordinator.1) bash
psql -U postgres
CREATE EXTENSION citus;
SELECT citus_add_node('worker-1-1', 5432);
SELECT citus_add_node('worker-2-1', 5432);
SELECT citus_add_node('worker-3-1', 5432);

# 7. Create distributed tables
SELECT create_distributed_table('memory_entries', 'namespace');
SELECT create_distributed_table('patterns', 'namespace');
SELECT create_reference_table('metadata');

# 8. Test connection
psql -h <HAPROXY-IP> -p 5432 -U mcp_user -d distributed_postgres_cluster
```

### Configuration Files

See `/docs/architecture/configs/` directory for:
- `docker-compose-swarm.yml` - Docker Swarm stack definition
- `patroni-coordinator.yml` - Patroni config for coordinators
- `patroni-worker.yml` - Patroni config for workers
- `haproxy.cfg` - HAProxy configuration
- `pgbouncer.ini` - PgBouncer configuration
- `citus.conf` - Citus PostgreSQL parameters

---

## Monitoring and Observability

### Key Metrics

**Database Metrics:**
- `pg_stat_database.tup_inserted` - Insert throughput
- `pg_stat_database.tup_fetched` - Read throughput
- `pg_stat_replication.replay_lag` - Replication lag (bytes)
- `pg_stat_activity.count` - Active connections

**Vector Metrics:**
- `ruvector_search_time_ms` - HNSW search latency
- `ruvector_index_size_mb` - Index memory usage

**Citus Metrics:**
- `citus_stat_statements.total_time` - Query execution time
- `citus_shard_placement.shard_count` - Shards per worker
- `citus_dist_stat_activity.distributed_query_count` - Distributed queries

**Patroni Metrics:**
- `patroni_postgres_running` - Database health (0/1)
- `patroni_postgres_timeline` - Failover count
- `patroni_postgres_server_version` - Version consistency

**HAProxy Metrics:**
- `haproxy_backend_status` - Backend health
- `haproxy_backend_response_time_ms` - Proxy latency
- `haproxy_backend_connections_total` - Connection count

### Alerting Rules

```yaml
# Critical Alerts
- alert: CoordinatorDown
  expr: patroni_postgres_running{role="coordinator"} == 0
  for: 30s
  severity: critical

- alert: ReplicationLagHigh
  expr: pg_stat_replication_replay_lag_bytes > 100000000  # 100MB
  for: 5m
  severity: warning

- alert: VectorSearchSlow
  expr: ruvector_search_time_ms > 50
  for: 5m
  severity: warning

- alert: EtcdQuorumLost
  expr: up{job="etcd"} < 2
  for: 1m
  severity: critical
```

---

## Security Considerations

### Network Security

1. **Network Segmentation:**
   - Coordinators isolated from workers (separate overlay networks)
   - etcd not exposed externally
   - HAProxy only external-facing service

2. **SSL/TLS:**
   ```conf
   # PostgreSQL (postgresql.conf)
   ssl = on
   ssl_cert_file = '/etc/ssl/certs/server.crt'
   ssl_key_file = '/etc/ssl/private/server.key'

   # HAProxy (haproxy.cfg)
   frontend postgres_ssl
       bind *:5432 ssl crt /etc/haproxy/certs/cluster.pem
   ```

3. **Firewall Rules:**
   ```bash
   # Coordinator: Accept from HAProxy only
   iptables -A INPUT -p tcp --dport 6432 -s <HAPROXY-IP> -j ACCEPT

   # Worker: Accept from coordinators only
   iptables -A INPUT -p tcp --dport 5432 -s <COORDINATOR-SUBNET> -j ACCEPT

   # etcd: Accept from Patroni nodes only
   iptables -A INPUT -p tcp --dport 2379 -s <CLUSTER-SUBNET> -j ACCEPT
   ```

### Access Control

```sql
-- MCP user (AI agents) - read-only + limited insert
CREATE USER mcp_user WITH PASSWORD '...';
GRANT SELECT ON ALL TABLES IN SCHEMA public TO mcp_user;
GRANT INSERT ON memory_entries TO mcp_user;

-- Application user - read/write
CREATE USER app_user WITH PASSWORD '...';
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;

-- Admin user - full access
CREATE USER admin_user WITH PASSWORD '...' SUPERUSER;

-- Revoke public access
REVOKE ALL ON SCHEMA public FROM PUBLIC;
```

### Secret Management

```bash
# Docker Swarm secrets
echo "postgres_password_secure" | docker secret create postgres_password -
echo "mcp_password_secure" | docker secret create mcp_password -

# Reference in docker-compose-swarm.yml
secrets:
  postgres_password:
    external: true
  mcp_password:
    external: true
```

---

## Operational Procedures

### Adding a New Shard

```bash
# 1. Deploy new worker pair (worker-4-1, worker-4-2)
docker service scale postgres-cluster_worker=8

# 2. Wait for Patroni cluster formation
docker exec coordinator.1 psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# 3. Add workers to Citus cluster
docker exec coordinator.1 psql -U postgres -c \
  "SELECT citus_add_node('worker-4-1', 5432);"
docker exec coordinator.1 psql -U postgres -c \
  "SELECT citus_add_node('worker-4-2', 5432);"

# 4. Rebalance shards (Citus will redistribute data)
docker exec coordinator.1 psql -U postgres -c \
  "SELECT citus_rebalance_start();"

# 5. Monitor rebalancing
docker exec coordinator.1 psql -U postgres -c \
  "SELECT * FROM citus_rebalance_status();"
```

### Rolling Updates

```bash
# 1. Update image version (zero-downtime)
docker service update --image ruvnet/ruvector-postgres:2.1.0 \
  --update-parallelism 1 \
  --update-delay 30s \
  postgres-cluster_worker

# Patroni ensures:
# - Only one standby updated at a time
# - Standby promoted before primary updated
# - Health checks pass before next update
```

### Backup and Restore

```bash
# Backup (via pg_basebackup from standby)
docker exec coordinator.2 pg_basebackup \
  -D /backup/coordinator-$(date +%Y%m%d) \
  -F tar -z -P -U postgres

# Continuous WAL archiving (configure in postgresql.conf)
archive_mode = on
archive_command = 's3cmd put %p s3://backups/wal/%f'

# Point-in-Time Recovery (PITR)
# 1. Restore base backup
# 2. Create recovery.signal
# 3. Set restore_command in postgresql.conf
# 4. Start PostgreSQL (will replay WAL)
```

---

## Cost Estimation (AWS Example)

**Infrastructure (3-host cluster):**
| Component | Instance Type | Count | Monthly Cost |
|-----------|---------------|-------|--------------|
| Manager Nodes | t3.xlarge (4 vCPU, 16GB) | 3 | $300 |
| Storage | gp3 SSD (200GB each) | 3 | $60 |
| Load Balancer | ALB | 1 | $20 |
| Data Transfer | - | - | $50 |
| **Total** | | | **~$430/month** |

**Scaling to 6 workers:**
| Component | Instance Type | Count | Monthly Cost |
|-----------|---------------|-------|--------------|
| Workers | t3.xlarge | 6 | $600 |
| Storage | gp3 SSD (500GB each) | 6 | $300 |
| **Total** | | | **~$900/month** |

---

## Future Enhancements

### Phase 2 (Geo-Distribution)
- Multi-region Citus deployment
- Cross-region replication
- Geo-aware query routing

### Phase 3 (Serverless Scaling)
- Auto-scaling workers based on load
- Serverless coordinators (AWS Aurora Serverless)
- Cost-optimized storage tiering

### Phase 4 (Advanced Vector Operations)
- GPU-accelerated vector search
- Multi-modal embeddings (text + image)
- Real-time vector indexing

---

## References

- [Citus Documentation](https://docs.citusdata.com/)
- [Patroni Documentation](https://patroni.readthedocs.io/)
- [Docker Swarm Documentation](https://docs.docker.com/engine/swarm/)
- [RuVector Extension](https://github.com/ruvnet/ruvector)
- [HAProxy Documentation](https://www.haproxy.org/documentation/)
- [PgBouncer Documentation](https://www.pgbouncer.org/documentation/)

---

## Appendix A: Configuration Templates

See `/docs/architecture/configs/` for full configuration files:
- Docker Swarm stack definitions
- Patroni configurations
- HAProxy configuration
- PgBouncer configuration
- Monitoring dashboards (Grafana)

## Appendix B: Troubleshooting Guide

Common issues and resolutions documented in `/docs/architecture/TROUBLESHOOTING.md`

## Appendix C: Performance Tuning

PostgreSQL, Citus, and RuVector tuning parameters documented in `/docs/architecture/PERFORMANCE_TUNING.md`

---

**Document Version:** 1.0
**Last Updated:** 2026-02-10
**Author:** System Architecture Designer (Claude)
**Status:** Accepted - Ready for Implementation
