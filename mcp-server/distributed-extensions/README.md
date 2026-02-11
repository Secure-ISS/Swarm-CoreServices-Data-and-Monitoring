# Distributed PostgreSQL Cluster Extensions for postgres-mcp

This directory contains custom MCP tools for managing the distributed PostgreSQL cluster with Citus, Patroni, and HAProxy.

## Overview

The base `postgres-mcp` server provides core PostgreSQL management capabilities. These extensions add distributed cluster-specific tools:

- **Citus Management** - Shard distribution, rebalancing, distributed query analysis
- **Patroni Integration** - Cluster status, replication lag, failover management
- **HAProxy Monitoring** - Backend health, connection pooling stats
- **Multi-Database Modes** - Manage distributed, reference, and local tables

## Architecture

```
┌─────────────────────────────────────────────┐
│     postgres-mcp (Base Server)              │
│  - Index tuning                             │
│  - EXPLAIN plans                            │
│  - Health checks                            │
│  - Safe SQL execution                       │
└────────────────┬────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────┐
│  Distributed Extensions (This Directory)    │
│  - citus-tools.py                           │
│  - patroni-tools.py                         │
│  - haproxy-tools.py                         │
│  - database-mode-tools.py                   │
└─────────────────────────────────────────────┘
```

## Custom Tools

### Citus Tools (`citus-tools.py`)

| Tool | Description |
|------|-------------|
| `citus_shard_distribution` | Show shard placement across workers |
| `citus_rebalance_shards` | Rebalance shards across worker nodes |
| `citus_distributed_query_stats` | Analyze distributed query performance |
| `citus_worker_health` | Check worker node health and connectivity |

### Patroni Tools (`patroni-tools.py`)

| Tool | Description |
|------|-------------|
| `patroni_cluster_status` | Get cluster topology and health |
| `patroni_replication_lag` | Check replication lag across nodes |
| `patroni_failover` | Trigger manual failover (with confirmation) |
| `patroni_member_list` | List all cluster members |

### HAProxy Tools (`haproxy-tools.py`)

| Tool | Description |
|------|-------------|
| `haproxy_backend_health` | Check HAProxy backend pool health |
| `haproxy_connection_stats` | Get connection pooling statistics |

### Database Mode Tools (`database-mode-tools.py`)

| Tool | Description |
|------|-------------|
| `list_table_types` | Show distributed vs reference vs local tables |
| `convert_to_distributed` | Convert local table to distributed |
| `create_reference_table` | Create replicated reference table |

## Usage

### From Claude Desktop

```typescript
// Query shard distribution
User: "Show me how shards are distributed across workers"
MCP: citus_shard_distribution()

// Rebalance shards
User: "Rebalance shards by disk size"
MCP: citus_rebalance_shards(strategy="by_disk_size")

// Check cluster health
User: "What's the Patroni cluster status?"
MCP: patroni_cluster_status()
```

### From Python

```python
from mcp import ClientSession
from mcp.client.stdio import stdio_client

async with stdio_client(["python", "-m", "postgres_mcp"]) as (read, write):
    async with ClientSession(read, write) as session:
        # Check shard distribution
        result = await session.call_tool(
            "citus_shard_distribution",
            arguments={}
        )
        print(result)
```

## Configuration

See `config.example.json` for connection configuration:

```json
{
  "postgres": {
    "coordinator_url": "postgresql://admin:password@haproxy:5432/distributed_postgres_cluster",
    "direct_coordinator_url": "postgresql://admin:password@coordinator-1:5432/postgres"
  },
  "patroni": {
    "api_url": "http://coordinator-1:8008"
  },
  "haproxy": {
    "stats_url": "http://haproxy:8404/stats;csv"
  }
}
```

## Development

```bash
# Install dependencies
cd mcp-server/postgres-mcp
uv pip install -e .

# Run tests
pytest tests/

# Run MCP server with extensions
python -m postgres_mcp --config ../distributed-extensions/config.json
```

## Deployment

See `../docker-compose.mcp.yml` for Docker deployment configuration.

## Security

- All tools respect read-only mode when configured
- Destructive operations (failover, rebalancing) require explicit confirmation
- Credentials stored in Docker secrets
- TLS encryption for all database connections

## References

- [postgres-mcp Base Server](../postgres-mcp/README.md)
- [Citus Documentation](https://docs.citusdata.com/)
- [Patroni Documentation](https://patroni.readthedocs.io/)
- [Model Context Protocol Specification](https://modelcontextprotocol.io/)
