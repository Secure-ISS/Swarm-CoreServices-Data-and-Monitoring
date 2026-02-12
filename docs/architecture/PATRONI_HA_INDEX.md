# Patroni High Availability Architecture - Documentation Index

## Quick Navigation

This document provides a complete index of all Patroni HA architecture documentation, configuration files, and deployment resources.

---

## Documentation Hierarchy

```
docs/
├── architecture/
│   ├── PATRONI_HA_DESIGN.md          ← Architecture design document
│   ├── PATRONI_HA_SUMMARY.md         ← Executive summary
│   ├── PATRONI_HA_INDEX.md           ← This document
│   └── distributed-postgres-design.md ← Original distributed design
│
├── deployment/
│   └── PATRONI_DEPLOYMENT_PLAN.md    ← Step-by-step deployment guide
│
config/
├── patroni/
│   └── patroni.yml                   ← Patroni configuration
├── etcd/
│   └── etcd.conf                     ← etcd configuration
└── postgresql/
    └── postgresql.conf               ← PostgreSQL HA configuration
```

---

## Document Summaries

### 1. PATRONI_HA_DESIGN.md (Comprehensive Design Document)

**Location:** `/docs/architecture/PATRONI_HA_DESIGN.md`

**Sections:**
1. **Executive Summary** - HA guarantees, key characteristics
2. **Architecture Overview** - Logical and physical diagrams
3. **Component Design** - Patroni, etcd, HAProxy, PgBouncer
4. **Automatic Failover Workflow** - Timeline and process
5. **Split-Brain Protection** - Mechanisms and safeguards
6. **Network Topology** - Overlay networks, ports, firewall rules
7. **Component Interactions** - Connection flows, replication, failover
8. **RuVector Extension Support** - Vector operations, replication
9. **Performance Characteristics** - Throughput, latency, failover times
10. **Monitoring and Health Checks** - Metrics, alerts, REST API
11. **Security Considerations** - Authentication, encryption, secrets
12. **Operational Procedures** - Switchover, backup, restore, scaling
13. **Disaster Recovery** - Failure scenarios and recovery

**Use Cases:**
- Understanding the overall architecture
- Designing integrations
- Planning capacity
- Troubleshooting issues
- Training operations team

**Length:** ~150 pages (printed)

---

### 2. PATRONI_HA_SUMMARY.md (Executive Summary)

**Location:** `/docs/architecture/PATRONI_HA_SUMMARY.md`

**Sections:**
1. **Overview** - Deliverables and key features
2. **Architecture Highlights** - HA features, topology, interactions
3. **Key Design Decisions** - ADRs with rationale
4. **RuVector Extension Support** - Installation, replication
5. **Performance Characteristics** - Targets and metrics
6. **Security Considerations** - Authentication, network, secrets
7. **Monitoring and Alerting** - Key metrics and alert rules
8. **Operational Procedures** - Common tasks
9. **Disaster Recovery** - Scenarios and recovery
10. **Next Steps** - Pre-deployment, deployment, production readiness
11. **Support and Resources** - Documentation, external links
12. **Glossary** - Terms and definitions

**Use Cases:**
- Quick overview for stakeholders
- Reference guide for operations
- Onboarding new team members
- Review of key decisions

**Length:** ~25 pages (printed)

---

### 3. PATRONI_DEPLOYMENT_PLAN.md (Deployment Guide)

**Location:** `/docs/deployment/PATRONI_DEPLOYMENT_PLAN.md`

**Sections:**
1. **Executive Summary** - Timeline, strategy
2. **Prerequisites** - Hardware, software, network, checklist
3. **Deployment Procedure**
   - Phase 1: Docker Swarm Initialization
   - Phase 2: Network and Secret Setup
   - Phase 3: etcd Cluster Deployment
   - Phase 4: Patroni Cluster Deployment
   - Phase 5: HAProxy Deployment
   - Phase 6: Initial Data Setup
4. **Verification and Testing** - 6 verification stages
5. **Rollback Strategy** - Rollback points and procedures
6. **Post-Deployment Tasks** - Monitoring, backup, documentation
7. **Testing Checklist** - Functional, HA, performance, data integrity
8. **Troubleshooting Guide** - Common issues and resolutions

**Use Cases:**
- Step-by-step deployment execution
- Verification and validation
- Rollback planning
- Troubleshooting deployment issues

**Length:** ~40 pages (printed)

**Estimated Time:** 4-6 hours (first deployment)

---

### 4. Configuration Files

#### patroni.yml (Patroni Configuration)

**Location:** `/config/patroni/patroni.yml`

**Key Sections:**
- `scope` - Cluster identifier
- `restapi` - REST API configuration
- `etcd3` - etcd connection settings
- `bootstrap` - Initial cluster setup
  - `dcs` - DCS configuration (TTL, retry)
  - `postgresql.parameters` - PostgreSQL settings
  - `pg_hba` - Authentication rules
  - `initdb` - Database initialization
  - `post_init` - Post-initialization script
- `postgresql` - Instance configuration
  - `data_dir`, `bin_dir` - Paths
  - `authentication` - User credentials
  - `create_replica_methods` - Replication setup
  - `parameters` - Runtime parameters
  - `callbacks` - Event scripts
- `tags` - Node customization
- `log` - Logging configuration

**Customization Points:**
- Node name (`name: node-1`)
- Node addresses (`connect_address`)
- Replication mode (`synchronous_commit`)
- Resource limits (`shared_buffers`, `work_mem`)
- Extension installation (`post_init`)

**Usage:**
```bash
# Deploy with Docker config
docker config create patroni-config config/patroni/patroni.yml

# Or mount directly
docker run -v /path/to/patroni.yml:/etc/patroni.yml ...
```

---

#### etcd.conf (etcd Configuration)

**Location:** `/config/etcd/etcd.conf`

**Key Sections:**
- `name` - Node name (etcd-1, etcd-2, etcd-3)
- `data-dir` - Data storage path
- `heartbeat-interval` - 100ms
- `election-timeout` - 1000ms (1 second)
- `initial-advertise-peer-urls` - Peer communication URL
- `listen-peer-urls` - Peer listener
- `initial-advertise-client-urls` - Client API URL
- `listen-client-urls` - Client listener
- `initial-cluster` - All cluster members
- `initial-cluster-state` - 'new' or 'existing'
- `initial-cluster-token` - Cluster identifier

**Customization Points:**
- Node name (`name: etcd-1`)
- Node URLs (per-node customization)
- Storage paths
- SSL/TLS certificates (optional)

**Usage:**
```bash
# Deploy with Docker config
docker config create etcd-config config/etcd/etcd.conf

# Or via environment variables
docker run -e ETCD_NAME=etcd-1 ...
```

---

#### postgresql.conf (PostgreSQL Configuration)

**Location:** `/config/postgresql/postgresql.conf`

**Key Sections:**
- **Connections:** `max_connections`, `superuser_reserved_connections`
- **Memory:** `shared_buffers`, `work_mem`, `effective_cache_size`
- **WAL:** `wal_level`, `max_wal_senders`, `wal_keep_size`
- **Replication:** `synchronous_commit`, `synchronous_standby_names`
- **Query Tuning:** `random_page_cost`, `effective_io_concurrency`
- **Logging:** `log_min_duration_statement`, `log_checkpoints`
- **Autovacuum:** `autovacuum`, `autovacuum_naptime`
- **Statistics:** `shared_preload_libraries`, `pg_stat_statements`

**Customization Points:**
- Memory sizing (based on available RAM)
- Replication mode (sync vs async)
- Storage type (SSD vs HDD parameters)
- Logging verbosity

**Usage:**
```bash
# Deploy with Docker config
docker config create postgresql-config config/postgresql/postgresql.conf

# Referenced in patroni.yml
postgresql:
  parameters:
    config_file: /etc/postgresql/postgresql.conf
```

---

## Quick Reference Guide

### Architecture Quick Facts

| Metric | Value |
|--------|-------|
| **Nodes** | 3 (1 primary + 2 standby) |
| **Quorum** | 2 of 3 |
| **Failover Time** | 15-30 seconds |
| **RPO (Sync)** | 0 seconds (no data loss) |
| **RPO (Async)** | <5 seconds |
| **Availability** | 99.95% (1 node failure tolerance) |

### Component Ports

| Component | Port | Protocol | Purpose |
|-----------|------|----------|---------|
| PostgreSQL | 5432 | TCP | Database connections |
| PgBouncer | 6432 | TCP | Pooled connections |
| Patroni REST | 8008 | HTTP | Health checks |
| etcd Client | 2379 | TCP | Patroni DCS |
| etcd Peer | 2380 | TCP | Raft consensus |
| HAProxy | 5432 | TCP | Client frontend |
| HAProxy Stats | 8404 | HTTP | Statistics |

### Key Commands

**Patroni:**
```bash
# Cluster status
patronictl -c /etc/patroni.yml list postgres-cluster

# Manual switchover
patronictl -c /etc/patroni.yml switchover postgres-cluster

# Reinitialize node
patronictl -c /etc/patroni.yml reinit postgres-cluster node-1
```

**etcd:**
```bash
# Cluster health
etcdctl endpoint health --endpoints=http://etcd-1:2379,http://etcd-2:2379,http://etcd-3:2379

# Member list
etcdctl member list

# Get Patroni leader
etcdctl get /service/postgres-cluster/leader
```

**PostgreSQL:**
```bash
# Replication status
psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# Check if replica
psql -U postgres -c "SELECT pg_is_in_recovery();"

# Replication lag
psql -U postgres -c "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) FROM pg_stat_replication;"
```

**Docker:**
```bash
# Service status
docker stack services patroni-cluster

# Container logs
docker service logs patroni-cluster_patroni-node-1

# Scale services
docker service scale patroni-cluster_patroni=4
```

---

## Deployment Workflow

### High-Level Steps

```
1. Prerequisites Check
   ├── Hardware: 3 hosts, 32GB RAM, 8 CPUs
   ├── Software: Docker 24.0+, Ubuntu 22.04
   └── Network: Ports open, time sync

2. Swarm Setup
   ├── Initialize on Host 1
   ├── Join Host 2 and Host 3
   └── Label nodes

3. Network & Secrets
   ├── Create overlay networks
   └── Create Docker secrets

4. etcd Deployment
   ├── Deploy 3-node etcd cluster
   └── Verify cluster health

5. Patroni Deployment
   ├── Deploy 3-node Patroni cluster
   └── Verify replication

6. HAProxy Deployment
   ├── Deploy HAProxy
   └── Verify routing

7. Data Setup
   ├── Create databases
   ├── Install RuVector
   └── Create users

8. Validation
   ├── Run test suite
   └── Verify failover
```

**Timeline:** 4-6 hours (first deployment)

---

## Testing Checklist Summary

### Functional Tests (8 tests)
- [ ] All services running
- [ ] etcd cluster healthy
- [ ] Patroni cluster formed
- [ ] Replication working
- [ ] HAProxy routing
- [ ] Client connections
- [ ] RuVector working
- [ ] Databases accessible

### HA Tests (5 tests)
- [ ] Primary failover
- [ ] Automatic rejoin
- [ ] Split-brain protection
- [ ] etcd leader failure
- [ ] HAProxy failover

### Performance Tests (5 tests)
- [ ] Write throughput (5,000 TPS)
- [ ] Read throughput (50,000 TPS)
- [ ] Replication lag (<100ms)
- [ ] Failover time (<30s)
- [ ] Vector search (<10ms)

### Data Integrity Tests (4 tests)
- [ ] Write/read consistency
- [ ] Failover data preservation
- [ ] Replication consistency
- [ ] Vector index replication

**Total:** 22 tests

---

## Troubleshooting Quick Reference

### Common Issues

**Issue:** Patroni not starting
- **Check:** etcd connectivity (`curl http://etcd-1:2379/health`)
- **Check:** PostgreSQL port availability (`netstat -tuln | grep 5432`)
- **Fix:** Restart etcd, check Patroni logs

**Issue:** Replication lag high
- **Check:** Network latency (`ping node-2`)
- **Check:** Disk I/O (`iostat -x 1 10`)
- **Fix:** Increase `wal_keep_size`, optimize disk

**Issue:** HAProxy not routing
- **Check:** Patroni REST API (`curl http://node-1:8008/leader`)
- **Check:** HAProxy logs (`docker service logs haproxy`)
- **Fix:** Verify HAProxy config, restart service

**Issue:** Split-brain detected
- **Check:** etcd leader (`etcdctl get /service/postgres-cluster/leader`)
- **Check:** Network connectivity between nodes
- **Fix:** Force failover to correct primary

---

## Related Documentation

### Existing Architecture Documents

- **`distributed-postgres-design.md`** - Original distributed design with Citus
- **`connection-architecture.md`** - Connection pooling and routing
- **`DEPLOYMENT_GUIDE.md`** - General deployment guide
- **ADR documents** - Architecture decision records

### Integration Points

**Patroni HA integrates with:**
1. **RuVector Extension** - Vector operations and HNSW indexes
2. **Dual-Database Setup** - Project + shared databases
3. **Docker Swarm** - Container orchestration
4. **Citus (Future)** - Distributed sharding layer
5. **Komodo MCP** - AI agent database access

---

## Version History

| Version | Date | Changes | Author |
|---------|------|---------|--------|
| 1.0 | 2026-02-12 | Initial design and deployment plan | System Architecture Designer |

---

## Support

### Internal Resources
- Architecture team contact: [email]
- Operations team contact: [email]
- On-call rotation: [link]

### External Resources
- Patroni documentation: https://patroni.readthedocs.io/
- etcd documentation: https://etcd.io/docs/
- PostgreSQL HA: https://www.postgresql.org/docs/current/high-availability.html

---

**Document Version:** 1.0
**Last Updated:** 2026-02-12
**Maintained By:** System Architecture Designer
