# Distributed Connection Pool - Quick Start Guide

## Overview

This guide provides quick examples for using the distributed PostgreSQL connection pooling system.

## Installation

No additional dependencies needed beyond existing project requirements:

```bash
pip install -r requirements.txt
```

For PgBouncer (optional network-level pooling):

```bash
# Ubuntu/Debian
sudo apt-get install pgbouncer

# macOS
brew install pgbouncer

# CentOS/RHEL
sudo yum install pgbouncer
```

## Quick Start Examples

### 1. Basic Single-Node Setup

```python
from src.db.distributed_pool import (
    DistributedDatabasePool,
    DatabaseNode,
    NodeRole,
    QueryType
)

# Create coordinator node
coordinator = DatabaseNode(
    host='localhost',
    port=5432,
    database='distributed_postgres_cluster',
    user='dpg_cluster',
    password='dpg_cluster_2026',
    role=NodeRole.COORDINATOR
)

# Create pool
pool = DistributedDatabasePool(coordinator_node=coordinator)

# Execute queries
with pool.cursor(QueryType.READ) as cur:
    cur.execute("SELECT * FROM users")
    users = cur.fetchall()

with pool.cursor(QueryType.WRITE) as cur:
    cur.execute("INSERT INTO users (name) VALUES (%s)", ("Alice",))

# Cleanup
pool.close()
```

### 2. Environment-Based Configuration

Set up `.env`:

```bash
COORDINATOR_HOST=localhost
COORDINATOR_PORT=5432
COORDINATOR_DB=distributed_postgres_cluster
COORDINATOR_USER=dpg_cluster
COORDINATOR_PASSWORD=dpg_cluster_2026
```

Use in code:

```python
from src.db.distributed_pool import create_pool_from_env

# Automatically reads from environment
pool = create_pool_from_env()

with pool.cursor(QueryType.READ) as cur:
    cur.execute("SELECT current_database()")
    print(cur.fetchone())

pool.close()
```

### 3. Read/Write Splitting with Replicas

```python
coordinator = DatabaseNode(
    host='db-primary.example.com',
    port=5432,
    database='mydb',
    user='myuser',
    password='mypass',
    role=NodeRole.COORDINATOR
)

replica_1 = DatabaseNode(
    host='db-replica-1.example.com',
    port=5432,
    database='mydb',
    user='myuser',
    password='mypass',
    role=NodeRole.REPLICA
)

replica_2 = DatabaseNode(
    host='db-replica-2.example.com',
    port=5432,
    database='mydb',
    user='myuser',
    password='mypass',
    role=NodeRole.REPLICA
)

pool = DistributedDatabasePool(
    coordinator_node=coordinator,
    replica_nodes=[replica_1, replica_2]
)

# Writes go to coordinator
with pool.cursor(QueryType.WRITE) as cur:
    cur.execute("UPDATE accounts SET balance = balance + 100")

# Reads load-balanced across replicas
with pool.cursor(QueryType.READ) as cur:
    cur.execute("SELECT * FROM accounts")
```

### 4. Shard-Aware Routing

```python
coordinator = DatabaseNode(...)

worker_0 = DatabaseNode(
    host='shard-0.example.com',
    port=5432,
    database='shard_0',
    user='myuser',
    password='mypass',
    role=NodeRole.WORKER,
    shard_id=0
)

worker_1 = DatabaseNode(
    host='shard-1.example.com',
    port=5432,
    database='shard_1',
    user='myuser',
    password='mypass',
    role=NodeRole.WORKER,
    shard_id=1
)

pool = DistributedDatabasePool(
    coordinator_node=coordinator,
    worker_nodes=[worker_0, worker_1]
)

# Query automatically routes to correct shard
user_id = 12345

with pool.cursor(QueryType.WRITE, shard_key=user_id) as cur:
    cur.execute(
        "UPDATE users SET last_login = NOW() WHERE id = %s",
        (user_id,)
    )
```

### 5. Distributed Transactions (2PC)

```python
# Transfer money between users on different shards
user_from = 1001
user_to = 2002
amount = 100.00

with pool.distributed_transaction([user_from, user_to]) as cursors:
    # Deduct from sender
    for shard_id, cur in cursors.items():
        if shard_id == pool._get_shard_for_key(user_from):
            cur.execute(
                "UPDATE wallets SET balance = balance - %s WHERE user_id = %s",
                (amount, user_from)
            )

    # Add to receiver
    for shard_id, cur in cursors.items():
        if shard_id == pool._get_shard_for_key(user_to):
            cur.execute(
                "UPDATE wallets SET balance = balance + %s WHERE user_id = %s",
                (amount, user_to)
            )

# Transaction auto-commits using 2PC
```

### 6. Health Monitoring

```python
# Check cluster health
health = pool.health_check()

print(f"Coordinator: {health['coordinator']['healthy']}")

for worker in health['workers']:
    print(f"Shard {worker['shard_id']}: {worker['healthy']}")

for replica in health['replicas']:
    print(f"Replica {replica['host']}: {replica['healthy']}")

# Get query statistics
stats = pool.get_statistics()
print(f"Total queries: {stats['total']}")
print(f"Read queries: {stats['reads']}")
print(f"Write queries: {stats['writes']}")
print(f"Errors: {stats['errors']}")
```

### 7. Custom Retry Configuration

```python
from src.db.distributed_pool import RetryConfig

retry_config = RetryConfig(
    max_retries=5,
    initial_backoff=0.1,      # 100ms
    max_backoff=10.0,         # 10 seconds
    backoff_multiplier=2.0,   # Double each retry
    jitter=True               # Add randomness
)

pool = DistributedDatabasePool(
    coordinator_node=coordinator,
    retry_config=retry_config
)
```

## Using PgBouncer

### Start PgBouncer

```bash
./scripts/start_pgbouncer.sh
```

### Connect via PgBouncer

```python
import psycopg2

# Connect through PgBouncer (port 6432) instead of PostgreSQL (port 5432)
conn = psycopg2.connect(
    host='localhost',
    port=6432,  # PgBouncer port
    database='distributed_postgres_cluster',
    user='dpg_cluster',
    password='dpg_cluster_2026'
)

with conn.cursor() as cur:
    cur.execute("SELECT 1")
```

### PgBouncer Admin Console

```bash
# Connect to admin console
psql -h localhost -p 6432 -U postgres pgbouncer

# View pool status
SHOW POOLS;

# View active connections
SHOW CLIENTS;
SHOW SERVERS;

# View statistics
SHOW STATS;

# Reload configuration
RELOAD;

# Pause connections
PAUSE;

# Resume connections
RESUME;
```

## Common Patterns

### Pattern 1: Simple CRUD Operations

```python
# Create
with pool.cursor(QueryType.WRITE) as cur:
    cur.execute(
        "INSERT INTO products (name, price) VALUES (%s, %s) RETURNING id",
        ("Widget", 19.99)
    )
    product_id = cur.fetchone()['id']

# Read
with pool.cursor(QueryType.READ) as cur:
    cur.execute("SELECT * FROM products WHERE id = %s", (product_id,))
    product = cur.fetchone()

# Update
with pool.cursor(QueryType.WRITE) as cur:
    cur.execute(
        "UPDATE products SET price = %s WHERE id = %s",
        (24.99, product_id)
    )

# Delete
with pool.cursor(QueryType.WRITE) as cur:
    cur.execute("DELETE FROM products WHERE id = %s", (product_id,))
```

### Pattern 2: Batch Operations

```python
# Batch insert
items = [
    ("Item 1", 10.00),
    ("Item 2", 20.00),
    ("Item 3", 30.00)
]

with pool.cursor(QueryType.WRITE) as cur:
    for name, price in items:
        cur.execute(
            "INSERT INTO products (name, price) VALUES (%s, %s)",
            (name, price)
        )
```

### Pattern 3: Pagination

```python
def get_users_page(page=1, page_size=20):
    offset = (page - 1) * page_size

    with pool.cursor(QueryType.READ) as cur:
        # Get total count
        cur.execute("SELECT COUNT(*) as count FROM users")
        total = cur.fetchone()['count']

        # Get page
        cur.execute(
            "SELECT * FROM users ORDER BY id LIMIT %s OFFSET %s",
            (page_size, offset)
        )
        users = cur.fetchall()

    return {
        'users': users,
        'total': total,
        'page': page,
        'page_size': page_size,
        'total_pages': (total + page_size - 1) // page_size
    }
```

### Pattern 4: Error Handling

```python
from src.db.distributed_pool import DistributedConnectionError

try:
    with pool.cursor(QueryType.WRITE) as cur:
        cur.execute("INSERT INTO users (email) VALUES (%s)", ("test@example.com",))

except DistributedConnectionError as e:
    print(f"Connection error: {e}")
    # Handle connection failure

except Exception as e:
    print(f"Query error: {e}")
    # Handle query failure
```

## Running Examples and Tests

### Run Example Code

```bash
# Run all examples
python examples/distributed-connection-example.py

# Or run specific example functions
```

### Run Integration Tests

```bash
# Run all tests
python tests/test_distributed_pool.py

# Run specific test class
python -m unittest tests.test_distributed_pool.TestDistributedPoolBasic

# Run with verbose output
python tests/test_distributed_pool.py -v
```

## Environment Variables Reference

| Variable | Description | Default |
|----------|-------------|---------|
| `COORDINATOR_HOST` | Coordinator hostname | `localhost` |
| `COORDINATOR_PORT` | Coordinator port | `5432` |
| `COORDINATOR_DB` | Coordinator database name | `distributed_postgres_cluster` |
| `COORDINATOR_USER` | Coordinator username | `dpg_cluster` |
| `COORDINATOR_PASSWORD` | Coordinator password | Required |
| `WORKER_HOSTS` | Comma-separated worker hosts | Empty |
| `WORKER_PORTS` | Comma-separated worker ports | Empty |
| `WORKER_DBS` | Comma-separated worker databases | Empty |
| `WORKER_USERS` | Comma-separated worker usernames | Empty |
| `WORKER_PASSWORDS` | Comma-separated worker passwords | Empty |
| `WORKER_SHARD_IDS` | Comma-separated shard IDs | Empty |
| `REPLICA_HOSTS` | Comma-separated replica hosts | Empty |
| `REPLICA_PORTS` | Comma-separated replica ports | Empty |
| `REPLICA_DBS` | Comma-separated replica databases | Empty |
| `REPLICA_USERS` | Comma-separated replica usernames | Empty |
| `REPLICA_PASSWORDS` | Comma-separated replica passwords | Empty |

## Best Practices

1. **Use environment variables** for configuration in production
2. **Use QueryType.READ** for SELECT queries to leverage replicas
3. **Provide shard_key** for distributed writes to ensure correct routing
4. **Monitor pool statistics** regularly to detect issues
5. **Configure appropriate pool sizes** based on workload
6. **Use distributed transactions** sparingly (overhead)
7. **Enable health checks** for automatic failover
8. **Use PgBouncer** for connection reuse in multi-instance deployments

## Troubleshooting

### Pool exhausted

```python
# Increase pool size
coordinator = DatabaseNode(..., max_connections=50)
```

### Connection failures

```python
# Configure aggressive retry
retry_config = RetryConfig(max_retries=5, initial_backoff=0.5)
pool = DistributedDatabasePool(..., retry_config=retry_config)
```

### Slow queries

```python
# Check routing
stats = pool.get_statistics()
print(f"Reads: {stats['reads']}, Writes: {stats['writes']}")

# Verify reads go to replicas
health = pool.health_check()
```

## Next Steps

- Review [Connection Architecture Documentation](architecture/connection-architecture.md)
- Explore [PgBouncer Configuration](../config/pgbouncer.ini)
- Run [Integration Tests](../tests/test_distributed_pool.py)
- Deploy distributed cluster (see deployment guides)

## Support

- Documentation: `/docs/architecture/connection-architecture.md`
- Examples: `/examples/distributed-connection-example.py`
- Tests: `/tests/test_distributed_pool.py`
