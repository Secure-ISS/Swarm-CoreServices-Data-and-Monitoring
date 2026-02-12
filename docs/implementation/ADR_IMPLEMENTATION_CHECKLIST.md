# ADR Implementation Checklists (1-13)

Ultra-concise action-oriented guide for implementing all 13 ADRs. Each section: steps, validation, success criteria, effort.

---

## ADR-001: Hybrid Citus + Patroni Architecture

**Objective**: Combine Citus (sharding) + Patroni (HA) + etcd (consensus)

### Implementation Steps
1. Deploy etcd 3-node cluster (DCS for Patroni)
2. Initialize 3 Patroni-managed PostgreSQL instances (coordinators)
3. Install Citus extension on all nodes
4. Configure Citus for distributed mode (coordinators + workers)
5. Setup replication between coordinator replicas (sync mode)
6. Initialize worker nodes (6+) with Citus worker configuration
7. Create distributed tables (`memory_entries`, `patterns`, `trajectories`, `graph_nodes`)
8. Create reference tables (`vector_indexes`, `sessions`, `metadata`)

### Validation Commands
```bash
# Verify Citus master node
psql -h coord-1 -c "SELECT * FROM citus_version();"

# Check distributed tables
psql -h coord-1 -c "SELECT * FROM citus_tables;"

# Verify Patroni leader
etcdctl --endpoints etcd-1:2379 get /service/postgres/leader

# Test distributed query
psql -h coord-1 -c "SELECT count(*) FROM memory_entries;"
```

### Success Criteria
- Citus shows master + 6 workers
- Distributed tables display sharding info
- Patroni leader elected in etcd
- Cross-shard query returns correct results
- Failover completes in <10s

### Estimated Effort
**8-12 hours**: etcd setup (2h), Citus config (3h), Patroni HA (3h), table setup (2h), testing (2h)

---

## ADR-002: Hierarchical Mesh Topology

**Objective**: 3 coordinators + 6 workers in hierarchical mesh, HAProxy load balancing

### Implementation Steps
1. Create Docker Swarm cluster (3+ managers + workers)
2. Create overlay networks: `coordinator-net`, `worker-net`, `admin-net`
3. Deploy 3 coordinator replicas (max_replicas_per_node: 1)
4. Deploy 6+ worker replicas (max_replicas_per_node: 2)
5. Deploy HAProxy active-passive pair
6. Configure HAProxy backend servers (3 coordinators)
7. Setup health checks (TCP + SELECT 1)
8. Test failover behavior (kill primary, verify HAProxy switches)

### Validation Commands
```bash
# Check service placement
docker service ls --filter name=coordinator
docker service ps --filter "name=coordinator" --no-trunc

# Verify overlay network
docker network inspect coordinator-net

# Test HAProxy
nc -zv haproxy 5432
psql -h haproxy -c "SELECT pg_is_in_recovery();"  # Should be false (primary)

# Kill primary coordinator, verify failover
docker kill <coordinator-1-container>
# Wait 6s, verify HAProxy switches to coord-2
```

### Success Criteria
- All 3 coordinators deployed on separate hosts
- All 6 workers deployed (max 2 per host)
- HAProxy routes to primary only
- Failover completes in <10s
- Network latency <2ms between nodes

### Estimated Effort
**6-10 hours**: Swarm setup (2h), networking (1h), service config (2h), HAProxy setup (2h), testing (1-2h)

---

## ADR-003: Hash-Based Sharding

**Objective**: Distribute tables via hash on `namespace` (memory_entries, patterns, graph_nodes), even split

### Implementation Steps
1. Create distributed table: `memory_entries` on `namespace`
2. Create distributed table: `patterns` on `namespace`
3. Create distributed table: `graph_nodes` on `namespace`
4. Create distributed table: `trajectories` on `id`
5. Create reference tables: `vector_indexes`, `sessions`, `metadata`
6. Verify shard distribution with `get_shard_id_for_distribution_column()`
7. Insert test data across namespaces, verify co-location
8. Test cross-shard query performance (should be slow)

### Validation Commands
```bash
# View shard distribution
psql -c "SELECT get_shard_id_for_distribution_column('memory_entries', 'test-ns');"

# Check shard placement
psql -c "SELECT * FROM citus_shards WHERE relation_name = 'memory_entries';"

# Test co-location
INSERT INTO memory_entries (namespace, key, embedding) VALUES ('ns1', 'k1', '[...]'::ruvector);
INSERT INTO patterns (namespace, pattern_id, data) VALUES ('ns1', 'p1', '...');
# Both should hit same shard

# Test reference table replication
SELECT count(*) FROM pg_dist_placement WHERE shardid IN (SELECT shardid FROM pg_dist_shard WHERE logicalrelid = 'sessions'::regclass);
```

### Success Criteria
- Memory entries distributed evenly across shards
- Namespace-scoped queries hit single shard
- Reference tables replicated to all workers
- Shard rebalance time <5 min

### Estimated Effort
**4-6 hours**: Table creation (1h), shard config (1h), data setup (1h), validation (1-2h)

---

## ADR-004: Sync Replication (Coordinators), Async (Workers)

**Objective**: Coordinators sync (0 RPO), workers async (RPO <5s)

### Implementation Steps
1. Edit `/patroni.yml` for coordinators: `synchronous_mode: true`, `synchronous_node_count: 1`
2. Edit `/patroni.yml` for workers: `synchronous_mode: false`, `synchronous_commit: 'local'`
3. Reload Patroni on all nodes
4. Verify sync mode active: `SHOW synchronous_commit;`
5. Measure write latency (should increase ~5-10ms for coordinators)
6. Test data loss scenario: kill coordinator primary, verify no committed data lost

### Validation Commands
```bash
# Check replication mode
psql -h coord-1 -c "SHOW synchronous_commit;"  # Should be 'on' (sync)
psql -h worker-1 -c "SHOW synchronous_commit;" # Should be 'local' (async)

# Verify replica status
psql -h coord-1 -c "SELECT * FROM pg_stat_replication;"

# Measure write latency
time psql -h coord-1 -c "INSERT INTO test_table VALUES (1);" # Should be +5-10ms

# Data durability test
psql -h coord-1 -c "BEGIN; INSERT INTO critical_table VALUES (1); COMMIT;"
# Kill primary, verify insert survived
```

### Success Criteria
- Coordinators show sync replication in `pg_stat_replication`
- Workers show async (asynchronous flag)
- No committed data lost on coordinator failover
- Write latency increase acceptable (<15ms)

### Estimated Effort
**2-4 hours**: Config edit (30min), Patroni reload (30min), testing (1-2h), tuning (30min)

---

## ADR-005: etcd for Service Discovery & Configuration

**Objective**: Deploy etcd 3-node cluster, configure as Patroni DCS

### Implementation Steps
1. Create etcd service definitions (docker-compose or Swarm)
2. Deploy 3 etcd instances with proper peer URLs
3. Configure Patroni DCS endpoints to etcd
4. Initialize Patroni cluster state in etcd
5. Verify leader election works (kill etcd node, observe new election)
6. Monitor etcd cluster health

### Validation Commands
```bash
# Check etcd cluster health
etcdctl --endpoints etcd-1:2379,etcd-2:2379,etcd-3:2379 member list

# Query Patroni state from etcd
etcdctl --endpoints etcd-1:2379 get /service/postgres/ --prefix

# Verify leader election
etcdctl --endpoints etcd-1:2379 get /service/postgres/leader
# Kill node, wait 1s, query again - should show different leader

# Check etcd metrics
curl -s http://etcd-1:2379/metrics | grep etcd_server_has_leader
```

### Success Criteria
- etcd cluster shows 3 healthy members
- Patroni leader appears in etcd
- Failover takes <3s
- etcd HA handles node loss (2/3 still operational)

### Estimated Effort
**3-5 hours**: Deployment (1h), Patroni integration (1h), failover testing (1-2h), monitoring (1h)

---

## ADR-006: PgBouncer Connection Pooling

**Objective**: Deploy PgBouncer on each node, transaction mode, 100 DB / 10K client conns

### Implementation Steps
1. Install PgBouncer on all coordinator/worker nodes
2. Create `pgbouncer.ini`: `pool_mode = transaction`, `default_pool_size = 25`
3. Configure max_client_conn = 10000, max_db_connections = 100
4. Setup PgBouncer statistics database (shadow db)
5. Test connection limits: spawn 5K clients, verify pooling
6. Monitor pool saturation with `show stats;`

### Validation Commands
```bash
# Connect to PgBouncer admin console
psql -h localhost -p 6432 -U pgbouncer pgbouncer

# Show pool statistics
SHOW POOLS;
SHOW STATS;
SHOW CLIENTS;
SHOW SERVERS;

# Stress test (spawn 5K connections)
for i in {1..5000}; do psql -h localhost -p 6432 -c "SELECT 1" &; done
# Check pool stats - should not exceed 100 server connections

# Verify transaction isolation
BEGIN; UPDATE table SET col = col + 1; COMMIT;  # Should work in transaction mode
```

### Success Criteria
- PgBouncer shows 100 server connections max
- 10K+ client connections supported
- Transaction mode preserves ACID
- Pool utilization >90% under load
- Failover transparent to clients

### Estimated Effort
**4-6 hours**: Installation (1h), config (1h), testing (2h), tuning (1-2h)

---

## ADR-007: HAProxy Load Balancing & Failover

**Objective**: Active-passive HAProxy, health checks, <6s failover

### Implementation Steps
1. Create `haproxy.cfg` with TCP mode, 3 coordinators as backends
2. Configure health check: `tcp-check connect`, `SELECT 1`
3. Deploy HAProxy as active-passive (Keepalived/VRRP optional)
4. Setup logging (syslog)
5. Test failover: kill primary coordinator
6. Monitor HAProxy stats (`:8404/stats`)

### Validation Commands
```bash
# Test HAProxy endpoint
psql -h haproxy -p 5432 -c "SELECT 1;"

# Check HAProxy stats
curl -s http://localhost:8404/stats | grep postgres_backend

# Verify primary detection
curl -s http://localhost:8404/stats | grep "coord-1.*UP"

# Kill primary, test failover
docker kill coordinator-1
sleep 6
psql -h haproxy -c "SELECT 1;"  # Should still work (switched to coord-2)

# Monitor response time
time psql -h haproxy -c "SELECT 1;"  # Should be <2ms overhead
```

### Success Criteria
- HAProxy routes to primary coordinator
- Health checks detect dead nodes in <6s
- Automatic failover to standby
- Response time overhead <2ms
- Stats page shows live metrics

### Estimated Effort
**3-5 hours**: Config (1h), testing (1-2h), Keepalived setup (1h), monitoring (1h)

---

## ADR-008: RuVector Sharding Compatibility

**Objective**: RuVector on all nodes, distributed HNSW indexes, namespace-scoped search

### Implementation Steps
1. Install RuVector extension on all coordinators + workers: `CREATE EXTENSION ruvector;`
2. Create HNSW index on coordinators: `CREATE INDEX idx_embedding_hnsw ON memory_entries USING hnsw (embedding ruvector_cosine_ops);`
3. Distributed index automatically created on workers
4. Verify shard-aware vector search
5. Benchmark global vs namespace-scoped search
6. Tune HNSW parameters (m=16, ef_construction=200)

### Validation Commands
```bash
# Verify extension on all nodes
psql -h coord-1 -c "SELECT * FROM pg_extension WHERE extname = 'ruvector';"
psql -h worker-1 -c "SELECT * FROM pg_extension WHERE extname = 'ruvector';"

# Create test index
psql -h coord-1 -c "CREATE INDEX idx_test_hnsw ON memory_entries USING hnsw (embedding ruvector_cosine_ops) WITH (m = 16, ef_construction = 200);"

# Verify distributed index
psql -h coord-1 -c "SELECT * FROM citus_shards WHERE relation_name = 'memory_entries';" | xargs -I{} psql -h <worker> -c "SELECT * FROM pg_indexes WHERE indexname LIKE 'idx_test_hnsw_%';"

# Test vector search (namespace scoped)
psql -h coord-1 -c "SELECT namespace, key, 1 - (embedding <=> '[...]'::ruvector) as sim FROM memory_entries WHERE namespace = 'patterns' ORDER BY embedding <=> '[...]'::ruvector LIMIT 10;"

# Benchmark (should be <10ms for namespace, <50ms global)
time psql -h coord-1 -c "SELECT COUNT(*) FROM memory_entries WHERE namespace = 'test' AND embedding <=> '[...]'::ruvector < 0.5;"
```

### Success Criteria
- RuVector extension on all nodes
- HNSW indexes built on all shards
- Namespace-scoped search: <10ms
- Global search (all shards): <50ms
- Index size balanced across workers

### Estimated Effort
**4-6 hours**: Extension install (1h), index creation (1h), tuning (1-2h), benchmarking (1-2h)

---

## ADR-009: Docker Swarm Deployment

**Objective**: Docker Swarm cluster with overlay networks, anti-affinity placement

### Implementation Steps
1. Initialize Docker Swarm: `docker swarm init` on manager-1
2. Add 2+ worker nodes: `docker swarm join`
3. Create overlay networks: `coordinator-net`, `worker-net`, `admin-net`
4. Create docker-compose-swarm.yml with placement constraints
5. Deploy stack: `docker stack deploy -c docker-compose-swarm.yml postgres-cluster`
6. Verify service replicas on separate hosts
7. Monitor network connectivity

### Validation Commands
```bash
# Check Swarm status
docker node ls

# Verify network
docker network ls | grep postgres

# Check service placement
docker service ps coordinator --no-trunc
docker service ps worker --no-trunc

# Test overlay connectivity
docker run --net coordinator-net alpine ping coordinator.coordinator-net

# Monitor resource usage
docker stats

# Simulate node failure
docker node update --availability drain <node-id>
# Services should reschedule
```

### Success Criteria
- Swarm cluster healthy (all nodes up)
- Services spread across nodes (anti-affinity works)
- Overlay network latency <2ms
- Automatic restart on node failure
- Resource limits respected

### Estimated Effort
**5-8 hours**: Swarm init (1h), networking (1h), docker-compose (1h), deployment (1h), failover testing (1-2h), monitoring (1h)

---

## ADR-010: Komodo MCP Integration

**Objective**: Expose PostgreSQL via Komodo MCP Server, connection pooling, read-only access

### Implementation Steps
1. Install Komodo MCP package: `npm install -g @komodo-mcp/postgres`
2. Create `claude_desktop_config.json` with Komodo server config
3. Configure HAProxy connection string, credentials
4. Create `mcp_user` with READ + INSERT on memory_entries
5. Test MCP server connectivity
6. Implement connection pooling (PgBouncer handles this)

### Validation Commands
```bash
# Test MCP server
curl -X POST http://localhost:3000 -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"query","params":{"sql":"SELECT 1"}}'

# Verify user permissions
psql -h haproxy -U mcp_user -c "SELECT COUNT(*) FROM memory_entries;"  # Should work
psql -h haproxy -U mcp_user -c "CREATE TABLE test (id INT);"  # Should fail

# Monitor MCP connections
psql -h haproxy -c "SELECT * FROM pg_stat_activity WHERE usename = 'mcp_user';"

# Load test (100 concurrent requests)
ab -n 100 -c 10 -p request.json http://localhost:3000
```

### Success Criteria
- MCP server listens on port 3000
- Claude agents can query via MCP
- Connection pooling limits to 10 MCP connections
- Read-only access enforced (no writes to system tables)
- Latency <100ms per query

### Estimated Effort
**3-4 hours**: Package setup (30min), config (30min), user/permissions (30min), testing (1-2h)

---

## ADR-011: Lazy Loading & Context Saving

**Objective**: Reduce memory 50-75%, startup <5s, support 35+ concurrent agents

### Implementation Steps
1. Create `LazyDatabasePool` class with property-based init
2. Implement `ContextManager` for saving/restoring state
3. Lazy-load HNSW indexes (on first search only)
4. Lazy-load Redis connections
5. Lazy-load embeddings models
6. Add context saving for: DB state, index metadata, benchmark results, agent decisions
7. Implement context TTL + cleanup
8. Test cold-start + warm-start scenarios
9. Measure memory reduction, startup time, agent capacity

### Validation Commands
```bash
# Measure memory baseline
ps aux | grep python | grep cluster

# Measure startup time
time python -c "from cluster import init_cluster; init_cluster()"

# Test lazy loading
python << 'EOF'
from db import LazyDatabasePool
pool = LazyDatabasePool(config)
assert pool._pool is None  # Not initialized
_ = pool.pool  # First access
assert pool._pool is not None  # Initialized
EOF

# Test context persistence
python << 'EOF'
from context import ContextManager
ctx = ContextManager()
ctx.save_context('test_key', {'foo': 'bar'})
ctx2 = ContextManager()
assert ctx2.get_context('test_key') == {'foo': 'bar'}
EOF

# Stress test (35 concurrent agents)
pytest tests/test_lazy_loading.py -n 35 --tb=short
```

### Success Criteria
- Memory baseline <1GB (vs 2-4GB)
- Startup time <5s (vs 15-30s)
- Support 35+ concurrent agents
- Context hit rate >80%
- No cold-start performance degradation on hot paths

### Estimated Effort
**12-16 hours**: LazyDatabasePool (2h), ContextManager (2h), lazy-load all components (4h), testing (2h), benchmarking (2h), tuning (2h)

---

## ADR-012: LLM-First Skills Interface

**Objective**: Create Claude Code Skills for autonomous cluster management

### Implementation Steps
1. Create skill structure: `/skills/{category}/{operation}.py`
2. Implement cluster operations skill: status, backup, scale, failover
3. Implement vector operations skill: search, insert, index, benchmark
4. Implement maintenance skill: optimize, vacuum, analyze, reindex
5. Implement monitoring skill: health, performance, alerts, logs
6. Implement security skill: audit, rotate, encrypt, compliance
7. Add skill self-documentation (auto-generate help/docs)
8. Test skill execution via Claude Code

### Validation Commands
```bash
# List available skills
ls -la /skills/*/*.py

# Test skill execution (manual)
python /skills/operations/cluster_status.py

# Test skill via Claude Code (programmatic)
# Configure skill in .claude-flow/config.yaml
# Invoke skill and verify output

# Verify skill documentation
python -c "from skills.operations.cluster_status import get_skill_docs; print(get_skill_docs())"

# Monitor skill execution logs
tail -f .logs/skills/*.log
```

### Success Criteria
- All 6 skill categories implemented
- Each skill has clear input/output specs
- Skills can be invoked autonomously by Claude
- Skill documentation auto-generated
- Skills handle errors gracefully

### Estimated Effort
**16-20 hours**: Design (2h), implement 6 skill categories (12h), docs (2h), testing (2h), CI/CD (2h)

---

## ADR-013: Integration Domain Design

**Objective**: DDD-based integration layer, API gateway, protocol translation, unified observability

### Implementation Steps
1. Define Integration Domain aggregates: MCPIntegration, APIGateway, ExternalAdapter
2. Implement APIGateway with route registry, load balancer, rate limiting
3. Implement MCPIntegration with request/response handling
4. Implement ExternalAdapter for protocol translation (Prometheus → domain model)
5. Create adapter implementations: PrometheusAdapter, GrafanaAdapter
6. Integrate with health check system
7. Test cross-protocol communication

### Validation Commands
```bash
# Test API gateway routing
curl http://api-gateway:8080/api/memory -H "Content-Type: application/json"

# Test MCP integration
python << 'EOF'
from integration import MCPIntegration
mcp = MCPIntegration(server_name="postgres")
response = mcp.handle_request({"query": "SELECT 1"})
assert response.status == "ok"
EOF

# Test external adapter
python << 'EOF'
from integration.adapters import PrometheusAdapter
adapter = PrometheusAdapter()
metrics = adapter.translate_request({"metric": "pg_stat_activity"})
assert metrics.database_name == "distributed_postgres_cluster"
EOF

# Load test API gateway (1000 req/s)
ab -n 10000 -c 100 http://api-gateway:8080/api/memory

# Monitor gateway metrics
curl http://api-gateway:8080/metrics | grep http_requests_total
```

### Success Criteria
- API gateway routes all request types correctly
- Protocol translation <5ms overhead
- External adapters translate metrics to domain models
- Rate limiting enforced (100 req/s per client)
- Gateway handles 10K concurrent connections
- 99.99% uptime over 24h

### Estimated Effort
**20-24 hours**: Domain modeling (2h), APIGateway impl (4h), adapters (6h), integration (4h), testing (4h), monitoring (2h), performance tuning (2h)

---

## Summary Table

| ADR | Title | Hours | Complexity | Dependencies |
|-----|-------|-------|-----------|--------------|
| 001 | Hybrid Citus + Patroni | 8-12 | High | None |
| 002 | Hierarchical Mesh Topology | 6-10 | High | ADR-001 |
| 003 | Hash-Based Sharding | 4-6 | Medium | ADR-001 |
| 004 | Sync/Async Replication | 2-4 | Low | ADR-001 |
| 005 | etcd Service Discovery | 3-5 | Medium | None |
| 006 | PgBouncer Pooling | 4-6 | Medium | ADR-001 |
| 007 | HAProxy Load Balancing | 3-5 | Medium | ADR-002 |
| 008 | RuVector Sharding | 4-6 | Medium | ADR-001, ADR-003 |
| 009 | Docker Swarm Deployment | 5-8 | High | ADR-001 through ADR-007 |
| 010 | Komodo MCP Integration | 3-4 | Medium | ADR-001, ADR-006, ADR-007 |
| 011 | Lazy Loading & Context | 12-16 | High | All infrastructure |
| 012 | LLM-First Skills | 16-20 | High | All operational |
| 013 | Integration Domain Design | 20-24 | Very High | All domains |

**Total: 90-125 hours** (3-4 weeks)

---

## Implementation Order

**Phase 1 (Infrastructure)**: ADR-001, 005 → ADR-002, 006, 007 → ADR-009 (12-25 hours)
**Phase 2 (Features)**: ADR-003, 004, 008 → ADR-010 (15-22 hours)
**Phase 3 (Optimization)**: ADR-011 → ADR-012, 013 (48-60 hours)
