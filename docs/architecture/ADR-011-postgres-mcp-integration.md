# ADR-011: PostgreSQL MCP Server Integration for Cluster Management

**Date:** 2026-02-11
**Status:** Proposed
**Deciders:** Architecture Team
**Technical Story:** Integration of Model Context Protocol server for AI-assisted cluster management

---

## Context and Problem Statement

The distributed PostgreSQL cluster requires management tools for:
- Citus shard distribution and rebalancing
- Patroni cluster health monitoring and failover
- HAProxy backend health checks
- Distributed query performance analysis
- Multi-database mode management (distributed, reference, local tables)

Traditional database management tools require manual SQL queries and lack:
- Natural language interface for cluster operations
- AI-assisted query optimization and index tuning
- Integrated health monitoring across all components
- Safe execution with transaction management

**How can we provide an intelligent, AI-powered interface for managing the distributed cluster?**

---

## Decision Drivers

1. **Natural Language Interface** - Enable AI assistants to manage cluster via conversation
2. **Safety** - Prevent accidental destructive operations in production
3. **Citus Integration** - Support shard management, distributed queries, and rebalancing
4. **Patroni Integration** - Monitor cluster health, replication lag, and failover status
5. **Multi-Component Visibility** - Unified view of PostgreSQL, Citus, Patroni, HAProxy, PgBouncer
6. **Extensibility** - Easy to add new tools specific to distributed architecture
7. **Performance Analysis** - EXPLAIN plans, index recommendations, query optimization
8. **Standard Protocol** - Use Model Context Protocol (MCP) for interoperability

---

## Considered Options

### Option 1: Custom REST API
Build custom REST API for cluster management.

**Pros:**
- Full control over API design
- Can optimize for specific use cases
- No external dependencies

**Cons:**
- High development effort (weeks of work)
- No standard protocol (vendor lock-in)
- No natural language interface
- Requires custom client implementation
- No AI integration out of the box

---

### Option 2: pgAdmin / phpPgAdmin
Use existing PostgreSQL management tools.

**Pros:**
- Mature, battle-tested tools
- Comprehensive PostgreSQL features
- Visual interface

**Cons:**
- No Citus-specific features
- No Patroni integration
- No AI/natural language interface
- Web UI only (no programmatic access)
- Not designed for distributed clusters

---

### Option 3: Official @modelcontextprotocol/server-postgres
Use official Anthropic MCP server for PostgreSQL.

**Pros:**
- Official implementation
- Wide adoption (20K weekly downloads)
- Standard MCP protocol

**Cons:**
- ❌ **ARCHIVED** by Anthropic in May 2025
- ❌ **UNPATCHED SQL injection vulnerability**
- ❌ Read-only (cannot manage cluster)
- No Citus/Patroni extensions
- No active development

**Verdict:** ❌ Not suitable due to security and maintenance concerns

---

### Option 4: crystaldba/postgres-mcp ✅ **SELECTED**
Use postgres-mcp with custom distributed cluster extensions.

**Pros:**
- ✅ Active development and maintenance
- ✅ Performance analysis (EXPLAIN, index tuning)
- ✅ Read/write access with transaction safety
- ✅ Configurable safety controls
- ✅ Extensible architecture for Citus/Patroni tools
- ✅ Standard MCP protocol
- ✅ Python-based (easy to extend)
- ✅ Health monitoring built-in

**Cons:**
- Newer project (less battle-tested than official)
- Requires custom extensions for Citus/Patroni

**Verdict:** ✅ **BEST FIT** for distributed cluster management

---

## Decision Outcome

**Chosen option:** "Option 4: crystaldba/postgres-mcp with distributed extensions"

We will integrate postgres-mcp as a git submodule and extend it with custom tools for:
1. **Citus Management** - Shard distribution, rebalancing, worker health
2. **Patroni Integration** - Cluster status, replication lag, failover
3. **HAProxy Monitoring** - Backend health, connection stats
4. **Database Mode Tools** - Manage distributed, reference, and local tables

---

## Architecture

### System Architecture

```
┌─────────────────────────────────────────────────────────┐
│              Traefik Reverse Proxy                      │
│            (mcp.postgres.local:443)                     │
└────────────────────┬────────────────────────────────────┘
                     │ HTTPS
                     ▼
┌─────────────────────────────────────────────────────────┐
│           postgres-mcp Server (Port 3000)               │
│  ┌────────────────────────────────────────────────────┐ │
│  │  Core postgres-mcp Features                        │ │
│  │  - Index tuning & recommendations                  │ │
│  │  - EXPLAIN plan analysis                           │ │
│  │  - Schema intelligence                             │ │
│  │  - Safe SQL execution                              │ │
│  │  - Health checks                                   │ │
│  └────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────┐ │
│  │  Distributed Cluster Extensions                    │ │
│  │  - citus_shard_distribution()                      │ │
│  │  - citus_rebalance_shards()                        │ │
│  │  - patroni_cluster_status()                        │ │
│  │  - haproxy_backend_health()                        │ │
│  └────────────────────────────────────────────────────┘ │
└────────────────────┬────────────────────────────────────┘
                     │ PostgreSQL Protocol
        ┌────────────┼────────────┐
        ▼            ▼            ▼
┌─────────────┐ ┌─────────┐ ┌──────────┐
│ Coordinator │ │ Patroni │ │ HAProxy  │
│  (Queries)  │ │  API    │ │   Stats  │
└─────────────┘ └─────────┘ └──────────┘
```

### MCP Transport

- **Protocol:** Server-Sent Events (SSE) over HTTP
- **Port:** 3000 (internal), exposed via Traefik
- **Authentication:** PostgreSQL user authentication + Traefik middleware
- **Encryption:** TLS via Traefik

### Connection Strategy

```python
# Read-only queries and analysis (mcp_user)
POSTGRES_URL = "postgresql://mcp_user@pg-coordinator:5432/distributed_postgres_cluster"

# Cluster management operations (dpg_cluster admin user)
POSTGRES_ADMIN_URL = "postgresql://dpg_cluster@pg-coordinator:5432/distributed_postgres_cluster"
```

**Two-tier access model:**
1. **mcp_user** - Read-only + limited write (index recommendations, EXPLAIN)
2. **dpg_cluster** - Full admin (shard rebalancing, failover, schema changes)

---

## Custom Tools Implementation

### Citus Tools

```python
# mcp-server/distributed-extensions/citus-tools.py

async def citus_shard_distribution():
    """Show shard distribution across workers."""
    return await db.fetch("""
        SELECT nodename, COUNT(*) as shard_count,
               pg_size_pretty(SUM(shard_size)) as total_size
        FROM citus_shards
        GROUP BY nodename
        ORDER BY shard_count DESC
    """)

async def citus_rebalance_shards(strategy="by_shard_count"):
    """Rebalance shards across worker nodes."""
    return await db.fetch("""
        SELECT citus_rebalance_start(
            rebalance_strategy => $1::citus_rebalance_strategy
        )
    """, strategy)
```

### Patroni Tools

```python
# mcp-server/distributed-extensions/patroni-tools.py

async def patroni_cluster_status():
    """Get Patroni cluster health and topology."""
    response = await httpx.get("http://coordinator-1:8008/cluster")
    return response.json()

async def patroni_replication_lag():
    """Check replication lag across all nodes."""
    return await db.fetch("""
        SELECT application_name, state,
               pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes,
               EXTRACT(EPOCH FROM replay_lag) AS lag_seconds
        FROM pg_stat_replication
    """)
```

---

## Deployment

### Docker Stack Integration

```yaml
services:
  postgres-mcp:
    build: ../../mcp-server
    networks:
      - postgres_mesh
    ports:
      - "3000:3000"
    environment:
      POSTGRES_URL: "postgresql://mcp_user@pg-coordinator:5432/distributed_postgres_cluster"
      POSTGRES_ADMIN_URL: "postgresql://dpg_cluster@pg-coordinator:5432/distributed_postgres_cluster"
      MCP_TRANSPORT: sse
      MCP_READ_ONLY: "false"
      ENABLE_CITUS_TOOLS: "true"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.postgres-mcp.rule=Host(`mcp.postgres.local`)"
    deploy:
      placement:
        constraints: [node.role == manager]
```

### Traefik Integration

```yaml
# labels for postgres-mcp service
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.postgres-mcp.rule=Host(`mcp.postgres.local`)"
  - "traefik.http.routers.postgres-mcp.entrypoints=websecure"
  - "traefik.http.routers.postgres-mcp.tls.certresolver=letsencrypt"
  - "traefik.http.services.postgres-mcp.loadbalancer.server.port=3000"
  # Optional: Add authentication middleware
  - "traefik.http.routers.postgres-mcp.middlewares=mcp-auth"
```

---

## Security Considerations

### 1. Access Control

- **Read-Only Mode:** Configurable via `MCP_READ_ONLY` environment variable
- **Role-Based Access:** Separate `mcp_user` (read) and `dpg_cluster` (admin) credentials
- **SQL Parsing:** Safe SQL execution with transaction management
- **Confirmation Required:** Destructive operations (failover, rebalancing) require explicit confirmation

### 2. Authentication

```sql
-- Create MCP user with limited permissions
CREATE ROLE mcp_user WITH LOGIN PASSWORD 'secure_password';

-- Read access to all tables
GRANT CONNECT ON DATABASE distributed_postgres_cluster TO mcp_user;
GRANT USAGE ON SCHEMA public TO mcp_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO mcp_user;

-- Allow EXPLAIN (for query analysis)
GRANT EXECUTE ON FUNCTION pg_stat_statements TO mcp_user;

-- Allow index recommendations (hypothetical indexes)
GRANT CREATE ON SCHEMA public TO mcp_user;  -- For temp tables in index recommendations
```

### 3. Network Security

- **Internal Network Only:** MCP server runs on `postgres_mesh` overlay network
- **Traefik Proxy:** External access only through Traefik (TLS, authentication)
- **No Direct Exposure:** Port 3000 not exposed on host (only via Traefik)

---

## Usage Examples

### From Claude Desktop

User: *"Show me how shards are distributed across workers"*

MCP Server → `citus_shard_distribution()`

```
| nodename        | shard_count | total_size |
|-----------------|-------------|------------|
| pg-worker-1     | 12          | 4.2 GB     |
| pg-worker-2     | 11          | 3.9 GB     |
| pg-worker-3     | 11          | 4.0 GB     |
```

User: *"What's the Patroni cluster status?"*

MCP Server → `patroni_cluster_status()`

```json
{
  "members": [
    {"name": "coordinator-1", "role": "leader", "state": "running", "lag": "0"},
    {"name": "coordinator-2", "role": "replica", "state": "running", "lag": "0"},
    {"name": "coordinator-3", "role": "replica", "state": "running", "lag": "0"}
  ]
}
```

User: *"Recommend indexes for slow queries"*

MCP Server → `analyze_slow_queries()` + `recommend_indexes()`

```sql
-- Recommended indexes based on query patterns:

CREATE INDEX CONCURRENTLY idx_memory_entries_namespace_embedding
  ON memory_entries USING hnsw (embedding ruvector_cosine_ops)
  WHERE namespace = 'production';

-- Impact: 10x speedup for namespace-scoped vector searches
```

---

## Integration with CI/CD

```bash
# In deployment pipeline

# 1. Deploy MCP server
docker stack deploy -c deployment/docker-swarm/stack.yml postgres-cluster

# 2. Wait for MCP server to be ready
curl --retry 10 --retry-delay 5 https://mcp.postgres.local/health

# 3. Run post-deployment health check via MCP
curl -X POST https://mcp.postgres.local/tools/citus_worker_health

# 4. Verify shard distribution
curl -X POST https://mcp.postgres.local/tools/citus_shard_distribution
```

---

## Monitoring and Observability

### Health Checks

```bash
# MCP server health endpoint
curl http://postgres-mcp:3000/health

# Response:
{
  "status": "healthy",
  "postgres_connection": "ok",
  "citus_extension": "loaded",
  "uptime_seconds": 3600
}
```

### Metrics

MCP server exposes metrics for:
- Query execution time
- Tool invocation counts
- Connection pool utilization
- Error rates

---

## Maintenance and Upgrades

### Updating postgres-mcp

```bash
# Update submodule to latest version
cd mcp-server/postgres-mcp
git pull origin main
cd ../..
git commit -am "Update postgres-mcp to latest version"

# Rebuild and redeploy
docker build -t postgres-mcp:latest mcp-server/
docker stack deploy -c stack.yml postgres-cluster
```

### Adding New Tools

```python
# mcp-server/distributed-extensions/custom-tools.py

async def custom_tool():
    """New custom tool for cluster management."""
    pass

# Register tool in MCP server
CUSTOM_TOOLS = [
    {
        "name": "custom_tool",
        "description": "Custom cluster management tool",
        "inputSchema": {...}
    }
]
```

---

## Consequences

### Positive

- ✅ Natural language interface for cluster management
- ✅ AI-assisted query optimization and index tuning
- ✅ Unified management of PostgreSQL, Citus, Patroni, HAProxy
- ✅ Safe execution with transaction management and confirmation
- ✅ Standard MCP protocol (interoperable with Claude, other AI tools)
- ✅ Extensible architecture for future tools
- ✅ Active development and security updates

### Negative

- ⚠️ Additional service to deploy and monitor
- ⚠️ Learning curve for MCP protocol
- ⚠️ Depends on crystaldba/postgres-mcp project maintenance
- ⚠️ Custom extensions need to be maintained

### Neutral

- Git submodule requires explicit update (`git submodule update`)
- Traefik proxy required for external access (already in architecture)

---

## Related Decisions

- **ADR-001:** Hybrid Citus + Patroni Architecture (enables distributed management)
- **ADR-007:** HAProxy Load Balancing (MCP connects through HAProxy)
- **ADR-010:** Komodo MCP Integration (similar MCP usage pattern)

---

## References

- [postgres-mcp GitHub Repository](https://github.com/crystaldba/postgres-mcp)
- [Model Context Protocol Specification](https://modelcontextprotocol.io/)
- [Citus Distributed Query Guide](https://docs.citusdata.com/)
- [Patroni REST API Documentation](https://patroni.readthedocs.io/en/latest/rest_api.html)
- [Traefik Reverse Proxy Documentation](https://doc.traefik.io/traefik/)

---

**Status:** Proposed
**Next Steps:**
1. Create MCP user with limited permissions
2. Test custom Citus tools on staging cluster
3. Configure Traefik routing for MCP server
4. Document usage examples for common cluster operations
5. Add MCP server to monitoring (Prometheus/Grafana)
