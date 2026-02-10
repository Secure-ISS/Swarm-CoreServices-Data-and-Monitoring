# Distributed PostgreSQL Connection Pool - Examples

This directory contains comprehensive examples demonstrating the distributed PostgreSQL connection pooling system.

## Running the Examples

### Run All Examples

```bash
python examples/distributed-connection-example.py
```

### Import Individual Examples

```python
from examples.distributed_connection_example import (
    example_1_basic_setup,
    example_2_read_write_splitting,
    example_3_shard_aware_routing,
    example_4_distributed_transaction,
    example_5_health_monitoring,
    example_6_retry_and_failover,
    example_7_environment_config
)

# Run specific example
example_1_basic_setup()
```

## Example Overview

### Example 1: Basic Setup
- Single coordinator node
- Basic read/write operations
- Table creation and queries
- Pool cleanup

### Example 2: Read/Write Splitting
- Coordinator + replica configuration
- Automatic routing of reads to replicas
- Writes directed to coordinator
- Query statistics tracking

### Example 3: Shard-Aware Routing
- Multi-shard configuration
- Consistent hashing for shard selection
- Automatic query routing based on shard key
- Cross-shard data distribution

### Example 4: Distributed Transactions
- Two-phase commit (2PC) demonstration
- Cross-shard money transfer
- Transaction consistency guarantees
- Automatic rollback on failure

### Example 5: Health Monitoring
- Cluster health checks
- Node status monitoring
- Query statistics collection
- Performance metrics

### Example 6: Retry and Failover
- Automatic retry configuration
- Exponential backoff demonstration
- Connection failure handling
- Resilience testing

### Example 7: Environment Configuration
- Environment-based pool setup
- Configuration file usage
- Production deployment patterns
- Best practices

## Prerequisites

1. PostgreSQL database running
2. Environment variables configured (`.env` file)
3. Python dependencies installed (`pip install -r requirements.txt`)

## Environment Setup

Create a `.env` file:

```bash
# Coordinator (required)
COORDINATOR_HOST=localhost
COORDINATOR_PORT=5432
COORDINATOR_DB=distributed_postgres_cluster
COORDINATOR_USER=dpg_cluster
COORDINATOR_PASSWORD=dpg_cluster_2026

# Workers (optional)
WORKER_HOSTS=worker-0.example.com,worker-1.example.com
WORKER_PORTS=5432,5432
WORKER_DBS=shard_0,shard_1
WORKER_USERS=dpg_cluster,dpg_cluster
WORKER_PASSWORDS=secret1,secret2
WORKER_SHARD_IDS=0,1

# Replicas (optional)
REPLICA_HOSTS=replica-1.example.com
REPLICA_PORTS=5432
REPLICA_DBS=distributed_postgres_cluster
REPLICA_USERS=dpg_cluster
REPLICA_PASSWORDS=secret3
```

## Expected Output

```
======================================================================
Distributed PostgreSQL Connection Pool Examples
======================================================================

Available examples:
  1. Basic Setup
  2. Read/Write Splitting
  3. Shard-Aware Routing
  4. Distributed Transactions
  5. Health Monitoring
  6. Retry and Failover
  7. Environment Configuration

Running all examples...

=== Example 1: Basic Setup ===

✓ Created example_users table
✓ Inserted user with id=1
✓ Retrieved 1 users
  - Alice Johnson (alice@example.com)

✓ Pool closed

... (more examples)

======================================================================
All examples completed!
======================================================================
```

## Troubleshooting

### Database Connection Error

```
✗ Failed to initialize distributed pool: Cannot connect to localhost:5432
```

**Solution**: Ensure PostgreSQL is running and environment variables are correct.

```bash
# Check database status
./scripts/db_health_check.py

# Or manually
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster
```

### Import Error

```
ModuleNotFoundError: No module named 'src.db.distributed_pool'
```

**Solution**: Run from project root directory.

```bash
cd /home/matt/projects/Distributed-Postgress-Cluster
python examples/distributed-connection-example.py
```

### Permission Error

```
PermissionError: [Errno 13] Permission denied: 'examples/distributed-connection-example.py'
```

**Solution**: Make the file executable.

```bash
chmod +x examples/distributed-connection-example.py
```

## Next Steps

1. Review the [Quick Start Guide](../docs/DISTRIBUTED_CONNECTION_QUICKSTART.md)
2. Read the [Architecture Documentation](../docs/architecture/connection-architecture.md)
3. Run the [Integration Tests](../tests/test_distributed_pool.py)
4. Deploy your own distributed cluster

## Additional Resources

- **Full Documentation**: `/docs/architecture/connection-architecture.md`
- **API Reference**: See docstrings in `/src/db/distributed_pool.py`
- **Test Suite**: `/tests/test_distributed_pool.py`
- **Configuration**: `/config/pgbouncer.ini`
