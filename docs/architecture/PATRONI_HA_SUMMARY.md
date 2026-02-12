# Patroni High Availability Architecture - Summary

## Overview

This document summarizes the Patroni-based high availability (HA) architecture design for the Distributed PostgreSQL Cluster, including all deliverables, key design decisions, and next steps.

---

## Deliverables

### 1. Architecture Document
**Location:** `/docs/architecture/PATRONI_HA_DESIGN.md`

**Contents:**
- Executive summary with HA guarantees (99.95% uptime, <30s RTO, RPO=0)
- Logical and physical architecture diagrams
- Component design (Patroni, etcd, HAProxy, PgBouncer)
- Automatic failover workflow with detailed timeline
- Split-brain protection mechanisms
- Network topology and security
- RuVector extension support
- Monitoring and health checks
- Troubleshooting guide
- Disaster recovery procedures

**Key Features:**
- 3-node Patroni cluster (1 primary + 2 standby)
- etcd 3-node cluster for distributed consensus
- Automatic failover in 15-30 seconds
- Zero data loss with synchronous replication
- Dual-database support (project + shared)

### 2. Configuration Templates

#### Patroni Configuration
**Location:** `/config/patroni/patroni.yml`

**Highlights:**
- Bootstrap configuration for new cluster
- etcd3 integration for DCS
- Synchronous/asynchronous replication modes
- RuVector extension auto-install
- Dual-database setup (distributed_postgres_cluster, claude_flow_shared)
- PostgreSQL HA-optimized parameters
- REST API configuration for health checks
- Post-initialization scripts for users and extensions

#### etcd Configuration
**Location:** `/config/etcd/etcd.conf`

**Highlights:**
- 3-node Raft consensus configuration
- Heartbeat interval: 100ms
- Election timeout: 1000ms (1 second)
- Client API (port 2379) and peer API (port 2380)
- Snapshot and WAL configuration
- SSL/TLS support (optional)
- Metrics endpoint for monitoring

#### PostgreSQL Configuration
**Location:** `/config/postgresql/postgresql.conf`

**Highlights:**
- Memory sizing for 32GB RAM systems
- WAL configuration for streaming replication
- Synchronous/asynchronous replication settings
- SSD-optimized parameters (random_page_cost=1.1)
- RuVector and vector search optimization
- Logging and monitoring configuration
- Connection and resource limits
- Security settings (SSL, authentication)

### 3. Deployment Plan
**Location:** `/docs/deployment/PATRONI_DEPLOYMENT_PLAN.md`

**Contents:**
- Prerequisites (hardware, software, network)
- Pre-deployment checklist
- 6-phase deployment procedure:
  1. Docker Swarm initialization
  2. Network and secret setup
  3. etcd cluster deployment
  4. Patroni cluster deployment
  5. HAProxy deployment
  6. Initial data setup
- Verification and testing procedures
- Rollback strategy with multiple rollback points
- Post-deployment tasks
- Comprehensive testing checklist
- Troubleshooting guide

**Timeline:**
- Preparation: 2-3 hours
- Deployment: 1-2 hours
- Validation: 1 hour
- Total: 4-6 hours

---

## Architecture Highlights

### High Availability Features

**Automatic Failover:**
```
T=0s:   Primary fails
T=5s:   Patroni detects failure
T=7s:   New primary elected via etcd
T=10s:  New primary promoted
T=15s:  HAProxy detects change
T=15-30s: Clients reconnected

Total downtime: 15-30 seconds
Data loss: 0 (synchronous) or <5s (asynchronous)
```

**Split-Brain Protection:**
- etcd leader locking with TTL (30 seconds)
- Quorum requirement (2 of 3 etcd nodes)
- Automatic demotion of isolated primaries
- Prevents multiple writable primaries

**Replication Modes:**
| Mode | Use Case | RPO | Latency |
|------|----------|-----|---------|
| **Synchronous** | Coordinators (metadata) | 0 | +5-10ms |
| **Asynchronous** | Workers (data shards) | <5s | 0ms |

### Network Topology

```
Clients
   ↓
HAProxy (Active/Passive with VIP)
   ↓
PgBouncer (per node)
   ↓
Patroni Cluster (3 nodes)
   ├── Node 1 (Primary)
   ├── Node 2 (Standby)
   └── Node 3 (Standby)
   ↓
etcd Cluster (3 nodes)
```

**Port Map:**
- 5432: PostgreSQL (internal)
- 6432: PgBouncer (client connections)
- 8008: Patroni REST API (health checks)
- 2379: etcd client API
- 2380: etcd peer API
- 8404: HAProxy stats

### Component Interactions

**Client Connection Flow:**
1. Client → HAProxy (port 5432)
2. HAProxy checks Patroni REST API (`GET /leader`)
3. HAProxy routes to current primary's PgBouncer (port 6432)
4. PgBouncer forwards to PostgreSQL (port 5432)
5. Client connected to primary database

**Write Replication Flow:**
1. Client writes to primary
2. Primary writes to WAL
3. Primary streams WAL to standbys (async or sync)
4. Standbys apply WAL and ACK (if sync)
5. Primary commits and returns to client

**Failover Decision Flow:**
1. Patroni detects primary failure (missed heartbeats)
2. etcd leader key expires (TTL timeout)
3. Standby Patroni agents race for leader key
4. Winner acquires key, promotes local PostgreSQL
5. HAProxy detects change via REST API
6. New connections routed to new primary

---

## Key Design Decisions

### ADR-001: 3-Node Cluster Topology

**Decision:** Deploy 3 Patroni nodes (1 primary + 2 standbys)

**Rationale:**
- Tolerates 1 node failure (quorum: 2 of 3)
- Minimum for HA without over-provisioning
- Supports synchronous replication to 1 standby
- Provides read scaling with 2 replicas

**Trade-offs:**
- More nodes = higher availability but increased cost
- Fewer nodes = lower cost but reduced fault tolerance
- 3 nodes is industry standard for HA databases

### ADR-002: etcd for Distributed Consensus

**Decision:** Use etcd (not Consul or ZooKeeper)

**Rationale:**
- Native Patroni support (first-class integration)
- Raft consensus protocol (proven, battle-tested)
- Simple HTTP/gRPC API
- Used by Kubernetes (mature ecosystem)
- Lower operational overhead than alternatives

**Trade-offs:**
- etcd adds 3 more containers (infrastructure cost)
- Must maintain etcd cluster health
- Network partition handling critical

### ADR-003: Synchronous Replication for Coordinators

**Decision:** Use synchronous replication for coordinator nodes

**Rationale:**
- Coordinators store critical metadata (table definitions, sharding config)
- Zero data loss acceptable trade-off for metadata
- Lower write volume (mostly DDL, not DML)
- Acceptable +5-10ms latency for consistency

**Trade-offs:**
- Higher write latency vs async
- Lower throughput vs async
- But: no metadata loss on failover

### ADR-004: HAProxy for Load Balancing

**Decision:** Use HAProxy (not pgpool-ii or custom solution)

**Rationale:**
- Patroni-aware health checks (REST API integration)
- Mature, production-proven
- Simple configuration
- Low latency (<1ms overhead)
- Supports active-passive failover

**Trade-offs:**
- HAProxy becomes potential SPOF (mitigated by active-passive)
- Additional component to manage
- But: simpler than client-side routing

---

## RuVector Extension Support

### Installation

RuVector extension is automatically installed during Patroni bootstrap:

```sql
-- On primary (propagates to standbys)
CREATE EXTENSION IF NOT EXISTS ruvector;
```

### Replication

**Vector Data:**
- Fully replicated via PostgreSQL streaming replication
- HNSW indexes rebuilt on standbys (automatic)
- No special configuration required

**Vector Search on Standbys:**
- Standbys can serve read-only vector searches
- Replication lag may cause stale results (<100ms typical)
- Ideal for load balancing read-heavy workloads

### Dual-Database Setup

Both databases are replicated:
- `distributed_postgres_cluster` (project database)
- `claude_flow_shared` (shared database)

After failover, new primary serves both databases.

---

## Performance Characteristics

### Throughput Targets

| Operation | Single Node | HA Cluster (3 nodes) |
|-----------|-------------|----------------------|
| **Writes (sync)** | 10,000 TPS | 5,000 TPS |
| **Writes (async)** | 10,000 TPS | 10,000 TPS |
| **Reads (primary)** | 50,000 TPS | 50,000 TPS |
| **Reads (replicas)** | - | 100,000 TPS (2 replicas) |

### Latency Targets

| Operation | p50 | p95 | p99 |
|-----------|-----|-----|-----|
| **Write (sync)** | 8ms | 15ms | 25ms |
| **Write (async)** | 3ms | 6ms | 12ms |
| **Read (primary)** | 2ms | 4ms | 8ms |
| **Vector search** | 6ms | 12ms | 20ms |

### Failover Metrics

| Metric | Target | Measured |
|--------|--------|----------|
| **Detection** | 5s | Patroni heartbeat interval |
| **Election** | 2-5s | etcd Raft election |
| **Promotion** | 3-5s | pg_ctl promote |
| **HAProxy** | 6s | 3 failed checks × 2s |
| **Total RTO** | 15-30s | End-to-end |

---

## Security Considerations

### Authentication

**PostgreSQL:**
- Password authentication (md5 or scram-sha-256)
- SSL/TLS for client connections (optional)
- Separate users for replication, applications, MCP

**etcd:**
- Client certificate authentication (optional)
- Peer certificate authentication (optional)
- Network isolation (internal only)

### Network Security

**Firewall Rules:**
```bash
# Allow PostgreSQL from HAProxy only
iptables -A INPUT -p tcp --dport 6432 -s 10.0.1.128/26 -j ACCEPT

# Allow etcd from Patroni only
iptables -A INPUT -p tcp --dport 2379 -s 10.0.1.0/26 -j ACCEPT

# Allow replication between Patroni nodes
iptables -A INPUT -p tcp --dport 5432 -s 10.0.1.0/26 -j ACCEPT
```

### Secret Management

**Docker Swarm Secrets:**
```bash
# Passwords stored as Docker secrets
echo "$PASSWORD" | docker secret create postgres_password -

# Referenced in Patroni config
postgresql:
  authentication:
    superuser:
      password: /run/secrets/postgres_password
```

---

## Monitoring and Alerting

### Key Metrics

**PostgreSQL:**
- `pg_stat_replication.replay_lag` - Replication lag (bytes)
- `pg_stat_database.tup_inserted` - Write throughput
- `pg_stat_database.tup_fetched` - Read throughput

**Patroni:**
- `patroni_postgres_running` - Database health (0/1)
- `patroni_postgres_timeline` - Failover count
- Replication lag via REST API (`/patroni`)

**etcd:**
- `etcd_server_has_leader` - Leader election status
- `etcd_server_proposals_failed_total` - Consensus failures

**HAProxy:**
- `haproxy_backend_status` - Backend health
- `haproxy_backend_connections_total` - Connection count

### Alert Rules

**Critical Alerts:**
- Primary database down (>30s)
- etcd quorum lost (<2 nodes)
- Replication lag high (>100MB)
- Synchronous replication broken

**Warning Alerts:**
- Replication lag elevated (>10MB)
- HAProxy backend degraded
- Patroni leader election frequency high

---

## Operational Procedures

### Manual Switchover (Planned Maintenance)

```bash
# Graceful switchover to standby
patronictl -c /etc/patroni.yml switchover postgres-cluster

# Interactive prompt:
# Master [node-1]:
# Candidate ['node-2', 'node-3'] []: node-2
# When should the switchover take place? [now]: now

# Result: ~2-5s downtime, no data loss
```

### Adding a New Standby

```bash
# Scale Patroni service
docker service scale patroni-cluster_patroni=4

# New node automatically bootstraps from primary
# Joins cluster as standby
```

### Backup and Restore

**Continuous WAL Archiving:**
```yaml
# patroni.yml
postgresql:
  parameters:
    archive_mode: 'on'
    archive_command: 's3cmd put %p s3://backups/wal/%f'
```

**Manual Backup:**
```bash
# pg_basebackup from standby (no primary impact)
pg_basebackup -h node-2 -U replicator -D /backup -F tar -z -P
```

---

## Disaster Recovery

### Scenario 1: Complete Cluster Failure

**Recovery:**
1. Bring up all 3 nodes
2. Patroni automatically elects most advanced node as primary
3. Other nodes replicate from primary
4. Cluster operational in <2 minutes

### Scenario 2: etcd Cluster Failure

**Recovery:**
1. Restore etcd from backup snapshot
2. Restart etcd cluster
3. Patroni reconnects automatically

**Or:**
1. Bootstrap new etcd cluster
2. Patroni may require manual intervention

### Scenario 3: Data Corruption

**Recovery:**
1. Identify healthy standby
2. Promote healthy standby to primary
3. Reinitialize corrupted node from new primary

---

## Next Steps

### Pre-Deployment

1. **Review Configuration Files**
   - Customize hostnames, IPs in `/config/patroni/patroni.yml`
   - Adjust resource limits in `/config/postgresql/postgresql.conf`
   - Review etcd settings in `/config/etcd/etcd.conf`

2. **Prepare Infrastructure**
   - Provision 3 hosts (physical or virtual)
   - Install Docker Engine 24.0+
   - Configure network (ports 2377, 7946, 4789)
   - Synchronize system clocks (chrony/NTP)

3. **Security Setup**
   - Generate SSL certificates (if using SSL)
   - Create secure passwords
   - Configure firewall rules

### Deployment

1. **Follow Deployment Plan**
   - Execute phases 1-6 in order
   - Verify each phase before proceeding
   - Use rollback points if issues occur

2. **Validation**
   - Run all tests in testing checklist
   - Verify automatic failover
   - Test backup and restore
   - Validate performance metrics

3. **Post-Deployment**
   - Set up monitoring (Prometheus, Grafana)
   - Configure alerting
   - Document cluster topology
   - Train operations team

### Production Readiness

- [ ] All tests passing (functional, HA, performance)
- [ ] Monitoring and alerting configured
- [ ] Backup/restore procedures validated
- [ ] Runbooks documented
- [ ] Security hardening complete
- [ ] Operations team trained
- [ ] Disaster recovery plan tested

---

## Support and Resources

### Documentation

- **Architecture Design:** `/docs/architecture/PATRONI_HA_DESIGN.md`
- **Deployment Plan:** `/docs/deployment/PATRONI_DEPLOYMENT_PLAN.md`
- **Configuration Files:** `/config/patroni/`, `/config/etcd/`, `/config/postgresql/`

### External Resources

- **Patroni Documentation:** https://patroni.readthedocs.io/
- **etcd Documentation:** https://etcd.io/docs/
- **PostgreSQL Replication:** https://www.postgresql.org/docs/current/high-availability.html
- **RuVector Extension:** https://github.com/ruvnet/ruvector
- **Docker Swarm:** https://docs.docker.com/engine/swarm/

### Community

- **Patroni GitHub:** https://github.com/zalando/patroni
- **PostgreSQL Mailing Lists:** https://www.postgresql.org/list/
- **RuVector Issues:** https://github.com/ruvnet/ruvector/issues

---

## Glossary

| Term | Definition |
|------|------------|
| **DCS** | Distributed Configuration Store (etcd) |
| **HA** | High Availability |
| **RPO** | Recovery Point Objective (acceptable data loss) |
| **RTO** | Recovery Time Objective (acceptable downtime) |
| **WAL** | Write-Ahead Log (PostgreSQL transaction log) |
| **Quorum** | Minimum nodes required for consensus (2 of 3) |
| **Split-Brain** | Multiple primaries due to network partition |
| **Replication Lag** | Time/bytes standby is behind primary |
| **Failover** | Automatic promotion of standby to primary |
| **Switchover** | Manual promotion of standby to primary |

---

**Document Version:** 1.0
**Last Updated:** 2026-02-12
**Author:** System Architecture Designer
**Status:** Complete and Ready for Deployment
