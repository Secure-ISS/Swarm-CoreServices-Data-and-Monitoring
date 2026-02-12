# Migration Guide: Single-Node to Patroni HA Mode

This guide provides step-by-step instructions for migrating from single-node PostgreSQL to Patroni High Availability mode.

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Migration Steps](#migration-steps)
4. [Configuration Changes](#configuration-changes)
5. [Testing Procedures](#testing-procedures)
6. [Rollback Plan](#rollback-plan)
7. [Troubleshooting](#troubleshooting)

## Overview

The Distributed PostgreSQL Cluster project supports two operating modes:

- **Single-Node Mode**: Traditional single PostgreSQL instance
- **Patroni HA Mode**: High-availability cluster with automatic failover

This migration guide covers transitioning from single-node to Patroni HA mode with zero downtime.

## Prerequisites

### Infrastructure Requirements

1. **Patroni Cluster**: A functional Patroni cluster with:
   - 1 primary node
   - 2+ replica nodes (recommended)
   - Patroni REST API enabled on all nodes (default port 8008)

2. **Network Connectivity**: Application servers must be able to reach:
   - All PostgreSQL nodes (port 5432)
   - All Patroni REST API endpoints (port 8008)

3. **Database Schema**: Ensure RuVector extension is installed on all nodes:
   ```sql
   CREATE EXTENSION IF NOT EXISTS ruvector;
   ```

### Software Requirements

1. **Python Dependencies**:
   ```bash
   pip install requests  # For Patroni REST API calls
   ```

2. **Patroni Version**: 2.0+ recommended

## Migration Steps

### Step 1: Verify Patroni Cluster Health

Before migration, ensure your Patroni cluster is healthy:

```bash
# Check cluster status on any Patroni node
patronictl -c /etc/patroni.yml list

# Expected output:
# + Cluster: postgres-cluster (7234567890123456789) ---+----+-----------+
# | Member  | Host        | Role    | State   | TL | Lag in MB |
# +---------+-------------+---------+---------+----+-----------+
# | node1   | 10.0.1.10   | Leader  | running |  1 |           |
# | node2   | 10.0.1.11   | Replica | running |  1 |         0 |
# | node3   | 10.0.1.12   | Replica | running |  1 |         0 |
# +---------+-------------+---------+---------+----+-----------+
```

Verify Patroni REST API is accessible:

```bash
# Test Patroni API
curl http://node1:8008/cluster
curl http://node2:8008/cluster
curl http://node3:8008/cluster
```

### Step 2: Update Environment Variables

Update your `.env` file with Patroni configuration:

```bash
# Copy example file if needed
cp .env.example .env

# Edit .env and add Patroni settings
```

**Required Variables:**

```bash
# Enable Patroni mode
ENABLE_PATRONI=true

# Patroni REST API endpoints (comma-separated)
# Use hostnames or IPs of your Patroni nodes
PATRONI_HOSTS=node1,node2,node3
PATRONI_PORT=8008

# Database credentials (same as used by Patroni)
PATRONI_DB=distributed_postgres_cluster
PATRONI_USER=dpg_cluster
PATRONI_PASSWORD=your_secure_password_here

# Connection pool settings
PATRONI_MIN_CONNECTIONS=2
PATRONI_MAX_CONNECTIONS=20
PATRONI_HEALTH_CHECK_INTERVAL=30
```

**Optional SSL/TLS Settings:**

```bash
# SSL/TLS Configuration
PATRONI_SSLMODE=require
PATRONI_SSLROOTCERT=/path/to/ca-cert.pem
PATRONI_SSLCERT=/path/to/client-cert.pem
PATRONI_SSLKEY=/path/to/client-key.pem
```

### Step 3: Update Configuration Files

Update `.claude-flow/config.yaml`:

```yaml
memory:
  postgresql:
    # Change mode from single-node to patroni-ha
    mode: patroni-ha

    patroni:
      enabled: true
      apiHosts:
        - node1
        - node2
        - node3
      apiPort: 8008
      database: distributed_postgres_cluster
      user: dpg_cluster
      password: ${PATRONI_PASSWORD}
      minConnections: 2
      maxConnections: 20
      healthCheckInterval: 30
```

### Step 4: Test Configuration

Before switching over, test the Patroni connection:

```python
from src.db.pool import DualDatabasePools

# Test Patroni pool initialization
try:
    pools = DualDatabasePools(enable_patroni=True)
    health = pools.health_check()
    print("Health check:", health)
    pools.close()
    print("✓ Patroni configuration is valid")
except Exception as e:
    print(f"✗ Configuration error: {e}")
```

Run the test script:

```bash
python scripts/test_patroni_connection.py
```

### Step 5: Perform Zero-Downtime Migration

#### Option A: Rolling Restart (Recommended)

If you have multiple application instances:

1. Update configuration on all instances
2. Restart instances one at a time
3. Each instance will connect to Patroni cluster on startup

```bash
# On each application server
systemctl restart your-application
# Wait for health check to pass before proceeding to next instance
```

#### Option B: Configuration Reload

If your application supports configuration reload:

1. Update environment variables
2. Send reload signal to application
3. Application reconnects with new Patroni pool

```bash
# Example reload command
kill -HUP $(cat /var/run/application.pid)
```

### Step 6: Verify Migration

After migration, verify the application is using Patroni HA mode:

```python
from src.db.pool import get_pools

pools = get_pools()
health = pools.health_check()

# Should show mode: "patroni"
print(f"Mode: {health.get('mode')}")
print(f"Primary: {health.get('ha_cluster', {}).get('primary')}")
print(f"Replicas: {health.get('ha_cluster', {}).get('replicas')}")
```

Expected output:

```json
{
  "mode": "patroni",
  "ha_cluster": {
    "cluster_topology": "healthy",
    "primary": {
      "status": "healthy",
      "host": "node1",
      "port": 5432,
      "in_recovery": false
    },
    "replicas": [
      {
        "node": "node2:5432",
        "status": "healthy",
        "in_recovery": true
      },
      {
        "node": "node3:5432",
        "status": "healthy",
        "in_recovery": true
      }
    ],
    "statistics": {
      "failovers": 0,
      "topology_refreshes": 1,
      "reads": 0,
      "writes": 0,
      "errors": 0
    }
  }
}
```

## Configuration Changes

### Code Changes Required

**None!** The migration is transparent to application code. Existing code using `project_cursor()` and `shared_cursor()` will automatically use Patroni HA mode.

### Read/Write Splitting (Optional)

To leverage read replicas for read-only queries:

**Before (single-node):**
```python
with pools.project_cursor() as cur:
    cur.execute("SELECT * FROM table")
```

**After (with read/write splitting):**
```python
# Read from replica
with pools.project_cursor(read_only=True) as cur:
    cur.execute("SELECT * FROM table")

# Write to primary
with pools.project_cursor(read_only=False) as cur:
    cur.execute("INSERT INTO table VALUES (%s)", (value,))
```

## Testing Procedures

### Test 1: Basic Connectivity

```bash
python scripts/test_patroni_connection.py
```

Expected: All tests pass, no errors.

### Test 2: Read/Write Splitting

```python
from src.db.pool import get_pools

pools = get_pools()

# Test write to primary
with pools.project_cursor(read_only=False) as cur:
    cur.execute("INSERT INTO test_table (data) VALUES (%s) RETURNING id", ("test",))
    insert_id = cur.fetchone()["id"]
    print(f"Inserted ID: {insert_id}")

# Test read from replica
with pools.project_cursor(read_only=True) as cur:
    cur.execute("SELECT * FROM test_table WHERE id = %s", (insert_id,))
    result = cur.fetchone()
    print(f"Read result: {result}")
```

### Test 3: Failover Simulation

Simulate primary failure to test automatic failover:

```bash
# On current primary node, stop PostgreSQL
sudo systemctl stop postgresql

# Watch application logs - should see failover messages:
# "Handling failover - detecting new primary..."
# "✓ Failover complete - new primary: node2:5432"
```

Application should continue working with new primary.

### Test 4: Load Testing

Run load test to verify performance under Patroni HA:

```bash
python scripts/load_test_patroni.py --duration 60 --concurrency 10
```

Monitor:
- Query latency (should be similar to single-node)
- Connection pool usage
- Read/write split ratio

## Rollback Plan

If issues occur, rollback to single-node mode:

### Step 1: Stop Application

```bash
systemctl stop your-application
```

### Step 2: Update Configuration

```bash
# In .env
ENABLE_PATRONI=false

# In .claude-flow/config.yaml
memory:
  postgresql:
    mode: single-node
```

### Step 3: Verify Single-Node Connection

```python
from src.db.pool import DualDatabasePools

pools = DualDatabasePools(enable_patroni=False)
health = pools.health_check()
print(f"Mode: {health.get('mode')}")  # Should be "single-node"
pools.close()
```

### Step 4: Restart Application

```bash
systemctl start your-application
```

## Troubleshooting

### Issue: "Failed to discover topology from all Patroni hosts"

**Cause**: Cannot reach Patroni REST API.

**Solution**:
1. Verify Patroni REST API is running:
   ```bash
   curl http://node1:8008/cluster
   ```
2. Check firewall rules allow port 8008
3. Verify `PATRONI_HOSTS` environment variable is correct

### Issue: "No primary node found in cluster"

**Cause**: Patroni cluster has no leader.

**Solution**:
1. Check Patroni cluster status:
   ```bash
   patronictl -c /etc/patroni.yml list
   ```
2. If no leader, trigger manual failover:
   ```bash
   patronictl -c /etc/patroni.yml failover
   ```

### Issue: "Database operation failed: connection refused"

**Cause**: Cannot connect to PostgreSQL on primary.

**Solution**:
1. Verify PostgreSQL is running on primary node
2. Check `pg_hba.conf` allows connections from application servers
3. Verify credentials in `PATRONI_USER` and `PATRONI_PASSWORD`

### Issue: High read latency after migration

**Cause**: Reads may be going to geographically distant replicas.

**Solution**:
1. Ensure `read_only=True` is used for read queries
2. Configure Patroni node tags for geographic affinity:
   ```yaml
   # In patroni.yml
   tags:
     datacenter: us-east
     rack: 1
   ```
3. Update application to prefer local replicas

### Issue: Failover takes longer than expected

**Cause**: Default failover timeout may be too long.

**Solution**:
Reduce failover timeout in `.env`:
```bash
PATRONI_FAILOVER_TIMEOUT=15  # Reduce from 30s to 15s
```

## Best Practices

### 1. Monitoring

Monitor these metrics:

- **Failover count**: `pools.patroni_pool.get_statistics()["failovers"]`
- **Topology refresh count**: Should increase periodically
- **Read/write split ratio**: Aim for 70-80% reads from replicas
- **Replication lag**: Via Patroni API or `pg_stat_replication`

### 2. Connection Pool Sizing

Adjust pool sizes based on workload:

```bash
# For read-heavy workloads
PATRONI_MAX_CONNECTIONS=30  # More connections for read replicas

# For write-heavy workloads
PATRONI_MAX_CONNECTIONS=15  # Fewer connections, focus on primary
```

### 3. Health Checks

Run regular health checks:

```python
import schedule

def health_check_job():
    pools = get_pools()
    health = pools.health_check()
    if health["ha_cluster"]["primary"]["status"] != "healthy":
        alert("Primary is unhealthy!")

schedule.every(60).seconds.do(health_check_job)
```

### 4. Backup Strategy

Continue regular backups from primary or replicas:

```bash
# Backup from replica to avoid primary load
pg_basebackup -h replica-node -D /backup/location -Fp -Xs -P
```

## Summary

This migration guide covers:

- ✓ Prerequisites and infrastructure requirements
- ✓ Step-by-step migration process
- ✓ Zero-downtime migration strategies
- ✓ Testing procedures and validation
- ✓ Rollback plan for safety
- ✓ Troubleshooting common issues

For additional support, refer to:
- Patroni documentation: https://patroni.readthedocs.io/
- Project documentation: `/docs`
- Error handling guide: `/docs/ERROR_HANDLING.md`
