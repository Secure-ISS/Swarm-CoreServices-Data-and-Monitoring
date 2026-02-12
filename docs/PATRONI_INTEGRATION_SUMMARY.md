# Patroni HA Integration Summary

This document summarizes the Patroni High Availability integration added to the Distributed PostgreSQL Cluster project.

## Overview

The codebase now supports two operating modes:

1. **Single-Node Mode**: Traditional PostgreSQL connection pooling (default)
2. **Patroni HA Mode**: High-availability cluster with automatic failover and read/write splitting

## Files Created

### 1. `/src/db/patroni_pool.py` (648 lines)

**Purpose**: HA-aware connection pool for Patroni-managed PostgreSQL clusters.

**Key Features**:
- Dynamic primary detection via Patroni REST API
- Automatic failover on primary failure
- Read/write splitting (writes to primary, reads to replicas)
- Connection pool refresh on topology changes
- Load balancing across replicas
- Exponential backoff retry logic
- Comprehensive health checks

**Key Classes**:
- `PatroniNode`: Represents a node in the cluster
- `PatroniClusterConfig`: Configuration for Patroni cluster
- `PatroniHAPool`: Main HA-aware connection pool

**Key Methods**:
- `cursor(read_only=bool)`: Get cursor with automatic routing
- `health_check()`: Comprehensive cluster health status
- `_refresh_topology()`: Detect primary/replica changes
- `_handle_failover()`: Automatic failover handling

### 2. `/docs/MIGRATION_TO_HA.md`

**Purpose**: Step-by-step migration guide from single-node to Patroni HA.

**Contents**:
- Prerequisites and infrastructure requirements
- Zero-downtime migration procedures
- Configuration changes required
- Testing procedures with validation
- Rollback plan for safety
- Troubleshooting common issues
- Best practices for monitoring

### 3. `/docs/PATRONI_SETUP.md`

**Purpose**: Complete Patroni cluster setup guide.

**Contents**:
- Architecture overview
- Patroni and etcd installation
- Multi-node cluster initialization
- Verification procedures
- HAProxy configuration for load balancing
- Monitoring and alerting setup
- Troubleshooting guide

### 4. `/scripts/test_patroni_connection.py`

**Purpose**: Comprehensive test suite for Patroni HA functionality.

**Tests**:
1. Patroni pool initialization
2. Cluster health check (primary + replicas)
3. Write operations to primary
4. Read operations from replicas
5. Read/write split verification

## Files Modified

### 1. `/src/db/pool.py`

**Changes**:
- Added `enable_patroni` parameter to `DualDatabasePools.__init__()`
- Added `patroni_mode` attribute and `patroni_pool` instance
- Modified `project_cursor()` and `shared_cursor()` to support `read_only` parameter
- Updated `health_check()` to return Patroni cluster status in HA mode
- Updated `close()` to handle both single-node and Patroni pools

**Backward Compatibility**: Existing code continues to work without changes. HA mode is opt-in via environment variable.

### 2. `/src/db/distributed_pool.py`

**Changes**:
- Added `enable_patroni` parameter to `create_pool_from_env()`
- Added auto-detection of Patroni mode from `ENABLE_PATRONI` environment variable
- Updated `get_distributed_pool()` to support Patroni mode
- Returns `PatroniHAPool` when Patroni mode is enabled

**Backward Compatibility**: Standard distributed mode (coordinator + workers + replicas) still works as before.

### 3. `.env.example`

**Added**:
```bash
# Patroni HA Configuration
ENABLE_PATRONI=false
PATRONI_HOSTS=localhost
PATRONI_PORT=8008
PATRONI_DB=distributed_postgres_cluster
PATRONI_USER=dpg_cluster
PATRONI_PASSWORD=CHANGE_ME_TO_STRONG_PASSWORD_32_CHARS_MIN
PATRONI_MIN_CONNECTIONS=2
PATRONI_MAX_CONNECTIONS=20
PATRONI_HEALTH_CHECK_INTERVAL=30
PATRONI_SSLMODE=require
PATRONI_SSLROOTCERT=/path/to/ca-cert.pem
PATRONI_SSLCERT=/path/to/client-cert.pem
PATRONI_SSLKEY=/path/to/client-key.pem
```

### 4. `.claude-flow/config.yaml`

**Added**:
```yaml
memory:
  postgresql:
    mode: single-node  # or patroni-ha

    patroni:
      enabled: false
      apiHosts:
        - localhost
      apiPort: 8008
      database: distributed_postgres_cluster
      user: dpg_cluster
      password: ${PATRONI_PASSWORD}
      minConnections: 2
      maxConnections: 20
      healthCheckInterval: 30
      failoverTimeout: 30
```

## Architecture

### Single-Node Mode (Default)

```
┌──────────────────┐
│   Application    │
└────────┬─────────┘
         │
    ┌────▼────────┐
    │  DualPools  │
    │  (project,  │
    │   shared)   │
    └────┬────────┘
         │
    ┌────▼─────────┐
    │  PostgreSQL  │
    │  Single Node │
    └──────────────┘
```

### Patroni HA Mode

```
┌──────────────────┐
│   Application    │
└────────┬─────────┘
         │
    ┌────▼────────────┐
    │  PatroniHAPool  │
    │  (auto-routing) │
    └────┬────────────┘
         │
    ┌────▼─────────────────────────┐
    │      Patroni Cluster         │
    │  ┌─────────┐   ┌──────────┐ │
    │  │ Primary │   │ Replica1 │ │
    │  │ (writes)│   │ (reads)  │ │
    │  └─────────┘   └──────────┘ │
    │      ▲              ▲        │
    │      │  ┌──────────┐│        │
    │      └──│ Replica2 ││        │
    │         │ (reads)  ││        │
    │         └──────────┘│        │
    │              ▼       ▼       │
    │        ┌─────────────┐       │
    │        │ Patroni API │       │
    │        │   (8008)    │       │
    │        └─────────────┘       │
    └──────────────────────────────┘
```

## Usage Examples

### Basic Usage (Backward Compatible)

Existing code continues to work without changes:

```python
from src.db.pool import get_pools

pools = get_pools()

# Write operation (goes to primary in HA mode)
with pools.project_cursor() as cur:
    cur.execute("INSERT INTO table VALUES (%s)", (value,))

# Read operation (may go to replica in HA mode if read_only=True is used)
with pools.project_cursor() as cur:
    cur.execute("SELECT * FROM table")
```

### Explicit Read/Write Splitting (Patroni HA)

Optimize performance by routing reads to replicas:

```python
from src.db.pool import get_pools

pools = get_pools()

# Write to primary
with pools.project_cursor(read_only=False) as cur:
    cur.execute("INSERT INTO users (name) VALUES (%s)", ("Alice",))

# Read from replica (load balanced across replicas)
with pools.project_cursor(read_only=True) as cur:
    cur.execute("SELECT * FROM users WHERE name = %s", ("Alice",))
```

### Health Check

```python
from src.db.pool import get_pools

pools = get_pools()
health = pools.health_check()

# Single-node mode
if health["mode"] == "single-node":
    print(f"Project DB: {health['project']['status']}")
    print(f"Shared DB: {health['shared']['status']}")

# Patroni HA mode
elif health["mode"] == "patroni":
    cluster = health["ha_cluster"]
    print(f"Primary: {cluster['primary']['host']}:{cluster['primary']['port']}")
    print(f"Replicas: {len(cluster['replicas'])} healthy")
    print(f"Failovers: {cluster['statistics']['failovers']}")
```

## Configuration

### Enable Patroni HA Mode

**Method 1: Environment Variable (Recommended)**

```bash
# In .env file
ENABLE_PATRONI=true
PATRONI_HOSTS=node1,node2,node3
PATRONI_PORT=8008
PATRONI_DB=distributed_postgres_cluster
PATRONI_USER=dpg_cluster
PATRONI_PASSWORD=your_password
```

**Method 2: Configuration File**

```yaml
# In .claude-flow/config.yaml
memory:
  postgresql:
    mode: patroni-ha
    patroni:
      enabled: true
      apiHosts:
        - node1
        - node2
        - node3
      # ... other settings
```

**Method 3: Programmatic**

```python
from src.db.pool import DualDatabasePools

# Force Patroni mode
pools = DualDatabasePools(enable_patroni=True)
```

## Features

### Automatic Failover

When primary fails:

1. Application detects connection failure on write operation
2. `PatroniHAPool._handle_failover()` is triggered
3. Pool queries Patroni REST API to discover new primary
4. Connection pools are refreshed with new topology
5. Write operation is retried on new primary
6. User sees transparent failover (operation succeeds)

**Timeout**: Default 30 seconds (configurable via `PATRONI_FAILOVER_TIMEOUT`)

### Read/Write Splitting

- **Writes**: Always routed to primary node
- **Reads (default)**: Routed to primary node
- **Reads (read_only=True)**: Load balanced across healthy replicas

**Load Balancing**: Simple round-robin across replica pools

### Topology Refresh

Cluster topology is automatically refreshed:

- **Interval**: Every 30 seconds (configurable via `PATRONI_HEALTH_CHECK_INTERVAL`)
- **On Demand**: Before every operation via `_maybe_refresh_topology()`
- **On Failure**: Immediately when failover is detected

### Connection Retry

Operations are retried with exponential backoff:

- **Max Retries**: 3 (configurable)
- **Initial Backoff**: 0.1s
- **Max Backoff**: 10s
- **Backoff Multiplier**: 2.0
- **Jitter**: Enabled (prevents thundering herd)

### SSL/TLS Support

Full SSL/TLS support via environment variables:

```bash
PATRONI_SSLMODE=require        # disable|allow|prefer|require|verify-ca|verify-full
PATRONI_SSLROOTCERT=/path/to/ca-cert.pem
PATRONI_SSLCERT=/path/to/client-cert.pem
PATRONI_SSLKEY=/path/to/client-key.pem
```

## Performance Considerations

### Connection Pool Sizing

**Single-Node Mode**:
- Project pool: 2-40 connections (default: 40)
- Shared pool: 1-15 connections (default: 15)

**Patroni HA Mode**:
- Primary pool: 2-20 connections per node (default: 20)
- Replica pools: 2-20 connections per node (default: 20)

**Recommendations**:
- Set `PATRONI_MAX_CONNECTIONS` based on workload
- Monitor connection usage: `pools.patroni_pool.get_statistics()`
- For read-heavy workloads, increase replica connections

### Latency Impact

- **Topology Refresh**: <50ms (cached for 30s)
- **Failover Detection**: 30-60s (configurable)
- **Retry Overhead**: <200ms per retry (with backoff)

**Optimization**:
- Use `read_only=True` for read queries to leverage replicas
- Increase `PATRONI_HEALTH_CHECK_INTERVAL` to reduce API calls
- Deploy replicas close to application servers

### Statistics

Monitor these metrics:

```python
stats = pools.patroni_pool.get_statistics()
print(f"Failovers: {stats['failovers']}")
print(f"Topology Refreshes: {stats['topology_refreshes']}")
print(f"Reads: {stats['reads']}")
print(f"Writes: {stats['writes']}")
print(f"Errors: {stats['errors']}")
```

## Testing

### Run Test Suite

```bash
# Configure Patroni in .env
ENABLE_PATRONI=true
PATRONI_HOSTS=node1,node2,node3

# Run tests
python scripts/test_patroni_connection.py
```

**Expected Output**:
```
============================================================
TEST SUMMARY
============================================================
✓ PASS: health_check
✓ PASS: write_to_primary
✓ PASS: read_from_replica
✓ PASS: read_write_split

Total: 4/4 tests passed

🎉 All tests passed! Patroni HA mode is working correctly.
```

### Manual Testing

**Test Failover**:

1. Start application with Patroni enabled
2. Monitor logs: `tail -f application.log`
3. Stop primary node: `sudo systemctl stop patroni` (on primary)
4. Observe failover in logs:
   ```
   Handling failover - detecting new primary...
   ✓ Failover complete - new primary: node2:5432
   ```
5. Verify application continues working

**Test Read/Write Split**:

```python
# Instrument code to see which nodes are used
import logging
logging.basicConfig(level=logging.DEBUG)

from src.db.pool import get_pools
pools = get_pools()

# Should see "Creating primary pool for node1:5432" in logs
with pools.project_cursor(read_only=False) as cur:
    cur.execute("SELECT 1")

# Should see "Creating replica-node2:5432 pool" in logs
with pools.project_cursor(read_only=True) as cur:
    cur.execute("SELECT 1")
```

## Migration Checklist

- [ ] Patroni cluster is operational (3+ nodes)
- [ ] RuVector extension installed on all nodes
- [ ] Patroni REST API accessible from application servers
- [ ] Environment variables configured in `.env`
- [ ] Test script passes: `python scripts/test_patroni_connection.py`
- [ ] Application code reviewed for `read_only=True` opportunities
- [ ] Monitoring configured (failovers, lag, errors)
- [ ] Rollback plan tested
- [ ] Zero-downtime migration planned
- [ ] Team trained on Patroni operations

## Troubleshooting

### "Failed to discover topology from all Patroni hosts"

**Check**:
1. Patroni REST API is running: `curl http://node1:8008/cluster`
2. Firewall allows port 8008
3. `PATRONI_HOSTS` is correct

### "Database operation failed: connection refused"

**Check**:
1. PostgreSQL is running on primary
2. `pg_hba.conf` allows application connections
3. Credentials are correct

### "No primary node found in cluster"

**Check**:
1. Cluster status: `patronictl list`
2. etcd is healthy: `etcdctl member list`
3. Trigger manual failover if needed: `patronictl failover`

### High Read Latency

**Solutions**:
1. Use `read_only=True` for read queries
2. Deploy replicas closer to application
3. Check replication lag: `SELECT pg_last_xact_replay_timestamp()`

## Security Considerations

### Network Security

- Use SSL/TLS for PostgreSQL connections (`PATRONI_SSLMODE=require`)
- Restrict Patroni REST API access via firewall
- Use strong passwords (32+ characters)
- Enable `pg_hba.conf` IP restrictions

### Credentials Management

- Store passwords in secure vault (e.g., HashiCorp Vault)
- Use environment variables, not hardcoded passwords
- Rotate passwords regularly
- Use separate users for application vs. replication

### Audit Logging

Enable PostgreSQL audit logging:

```sql
ALTER SYSTEM SET log_connections = on;
ALTER SYSTEM SET log_disconnections = on;
ALTER SYSTEM SET log_duration = on;
SELECT pg_reload_conf();
```

## Future Enhancements

Potential improvements:

1. **Geographic Affinity**: Route reads to closest replica based on datacenter tags
2. **Connection Pooling**: Integrate with PgBouncer for connection pooling
3. **Metrics Export**: Export Patroni metrics to Prometheus
4. **Automated Testing**: Add CI/CD tests for failover scenarios
5. **Dynamic Replica Selection**: Choose replica based on current lag
6. **Quorum Reads**: Read from multiple replicas for consistency

## References

- **Patroni Documentation**: https://patroni.readthedocs.io/
- **PostgreSQL Replication**: https://www.postgresql.org/docs/current/high-availability.html
- **etcd Documentation**: https://etcd.io/docs/
- **HAProxy Configuration**: http://www.haproxy.org/

## Support

For issues or questions:
- Review `/docs/MIGRATION_TO_HA.md`
- Review `/docs/PATRONI_SETUP.md`
- Review `/docs/ERROR_HANDLING.md`
- Check project issues on GitHub

---

**Document Version**: 1.0
**Last Updated**: 2026-02-12
**Author**: Claude (Code Implementation Agent)
