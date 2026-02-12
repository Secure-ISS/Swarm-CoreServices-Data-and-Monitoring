#!/ Integration Test Suite for Distributed PostgreSQL Cluster

Comprehensive integration tests for the distributed PostgreSQL cluster with RuVector, Patroni HA, Citus sharding, and Redis caching.

## Test Structure

```
tests/integration/
├── __init__.py                      # Package initialization
├── conftest.py                      # Pytest fixtures and configuration
├── test_distributed_cluster.py     # Core distributed cluster tests
├── test_citus_sharding.py          # Citus sharding and distributed queries
├── test_ha_failover.py             # Patroni HA failover scenarios
├── test_cache_coherence.py         # Redis caching layer tests
└── README.md                        # This file
```

## Test Categories

### 1. Distributed Cluster Tests (`test_distributed_cluster.py`)

Tests core distributed functionality:
- **Connection Management**: Pool capacity, concurrent connections, recovery
- **Data Distribution**: Insert/retrieve, bulk operations, vector search
- **Transaction Management**: ACID properties, rollback, commit
- **Error Handling**: Invalid inputs, constraint violations, timeouts
- **Performance**: Query performance, vector search optimization

**Run with:**
```bash
pytest tests/integration/test_distributed_cluster.py -v
```

### 2. Citus Sharding Tests (`test_citus_sharding.py`)

Tests Citus distributed database features:
- **Cluster Setup**: Extension verification, worker nodes, table distribution
- **Shard Distribution**: Data placement, co-location, shard counts
- **Distributed Queries**: Cross-shard operations, aggregations, vector search
- **Reference Tables**: Replication, JOINs with distributed tables
- **Transactions**: Two-phase commit, distributed rollback
- **Performance**: Parallel query execution

**Requirements:**
- Citus coordinator node
- Multiple worker nodes
- Configured distributed tables

**Run with:**
```bash
# Requires Citus cluster setup
pytest tests/integration/test_citus_sharding.py -v -m citus
```

### 3. HA Failover Tests (`test_ha_failover.py`)

Tests high-availability and failover:
- **Patroni Cluster**: Health checks, leader election, replica management
- **Read/Write Splitting**: Primary writes, replica reads via HAProxy
- **Replication**: Lag monitoring, replication status
- **Failover**: Automatic failover, split-brain prevention
- **Graceful Degradation**: Read-only mode, connection retry

**Requirements:**
- Patroni cluster (3+ nodes recommended)
- HAProxy load balancer
- Etcd or Consul for consensus

**Run with:**
```bash
# Requires Patroni HA cluster
pytest tests/integration/test_ha_failover.py -v -m patroni
```

### 4. Cache Coherence Tests (`test_cache_coherence.py`)

Tests Redis caching layer:
- **Cache Operations**: Set/get, TTL, expiration, multi-key operations
- **Cache Coherence**: Sync with database, invalidation on update
- **Performance**: Cache vs database speed, throughput benchmarks
- **Caching Strategies**: Write-through, cache-aside patterns

**Requirements:**
- Redis server

**Run with:**
```bash
# Requires Redis
pytest tests/integration/test_cache_coherence.py -v -m redis
```

## Setup and Configuration

### Environment Variables

```bash
# PostgreSQL (single-node or coordinator)
export RUVECTOR_HOST=localhost
export RUVECTOR_PORT=5432
export RUVECTOR_DB=distributed_postgres_cluster
export RUVECTOR_USER=dpg_cluster
export RUVECTOR_PASSWORD=dpg_cluster_2026

# Redis
export REDIS_HOST=localhost
export REDIS_PORT=6379

# Patroni (optional - for HA tests)
export ENABLE_PATRONI=true
export PATRONI_HOSTS=node1,node2,node3
export PATRONI_PORT=8008

# Citus (optional - for sharding tests)
export ENABLE_CITUS=true
export CITUS_COORDINATOR=localhost:5432
export CITUS_WORKERS=worker1:5432,worker2:5432,worker3:5432

# HAProxy (optional)
export HAPROXY_PRIMARY_PORT=5432
export HAPROXY_REPLICA_PORT=5433
```

### Prerequisites

1. **Python 3.12+**
2. **PostgreSQL with RuVector extension**
3. **Redis server**
4. **Python packages:**
   ```bash
   pip install pytest pytest-cov pytest-timeout pytest-xdist
   pip install psycopg2-binary redis requests numpy
   ```

### Database Initialization

```bash
# Initialize single-node database
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster -f scripts/sql/init-ruvector.sql

# For Citus cluster
psql -h coordinator -U dpg_cluster -d distributed_postgres_cluster -f docs/architecture/configs/init-citus-cluster.sql
```

## Running Tests

### Run All Integration Tests

```bash
pytest tests/integration/ -v
```

### Run Specific Test Suites

```bash
# Basic distributed cluster tests
pytest tests/integration/test_distributed_cluster.py -v

# Cache tests only
pytest tests/integration/test_cache_coherence.py -v -m redis

# Citus tests only (requires Citus setup)
pytest tests/integration/test_citus_sharding.py -v -m citus

# Patroni HA tests only (requires Patroni cluster)
pytest tests/integration/test_ha_failover.py -v -m patroni
```

### Run with Coverage

```bash
pytest tests/integration/ -v --cov=src --cov-report=html --cov-report=term-missing
```

### Run Slow Tests (Performance)

```bash
pytest tests/integration/ -v -m slow
```

### Parallel Execution

```bash
# Run tests in parallel (4 workers)
pytest tests/integration/ -v -n 4
```

### Skip Specific Test Categories

```bash
# Skip Citus tests
pytest tests/integration/ -v -m "not citus"

# Skip destructive tests
pytest tests/integration/ -v -m "not destructive"
```

## Test Markers

Tests are marked with pytest markers for selective execution:

- `@pytest.mark.citus` - Requires Citus distributed database
- `@pytest.mark.patroni` - Requires Patroni HA cluster
- `@pytest.mark.redis` - Requires Redis cache
- `@pytest.mark.haproxy` - Requires HAProxy load balancer
- `@pytest.mark.slow` - Long-running tests (>5 seconds)
- `@pytest.mark.destructive` - Tests that may disrupt services (failover, etc.)

## CI/CD Integration

Integration tests are automatically run via GitHub Actions:

- **Push/PR**: Basic integration tests + Redis cache tests
- **Nightly**: All tests including performance benchmarks
- **Manual**: Can trigger specific test suites via workflow_dispatch

See `.github/workflows/integration-tests.yml` for configuration.

## Local Development Environments

### 1. Development Mode (Single Node + Redis)

```bash
# Start services
docker compose -f docker-compose.dev.yml up -d

# Run tests
pytest tests/integration/test_distributed_cluster.py -v
pytest tests/integration/test_cache_coherence.py -v -m redis
```

### 2. Citus Cluster Mode

```bash
# Start Citus cluster (if docker-compose.citus.yml exists)
docker compose -f docker-compose.citus.yml up -d

# Wait for cluster initialization
sleep 30

# Run Citus tests
pytest tests/integration/test_citus_sharding.py -v -m citus
```

### 3. Patroni HA Mode

```bash
# Start Patroni cluster (requires docker-compose.patroni.yml or manual setup)
# See docs/deployment/patroni-setup.md

# Run HA tests
pytest tests/integration/test_ha_failover.py -v -m patroni
```

## Performance Benchmarks

Expected performance targets:

| Metric | Target | Test |
|--------|--------|------|
| Simple query | <100ms | `test_query_performance_simple` |
| Vector search (1K vectors) | <50ms | `test_vector_search_performance` |
| Bulk insert (1K records) | <10s | `test_bulk_insert_performance` |
| Cache read | <5ms | `test_cache_vs_database_performance` |
| Cache throughput | >1000 ops/sec | `test_cache_throughput` |
| Concurrent connections | 40+ | `test_connection_pool_capacity` |
| Replication lag | <5s | `test_replication_lag_acceptable` |

## Troubleshooting

### Common Issues

**1. Connection Refused**
```bash
# Check if PostgreSQL is running
docker ps | grep postgres

# Check connectivity
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster -c "SELECT 1"
```

**2. RuVector Extension Not Found**
```bash
# Verify extension
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'ruvector'"

# Reinstall if needed
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster -c "CREATE EXTENSION IF NOT EXISTS ruvector"
```

**3. Redis Connection Failed**
```bash
# Check Redis
docker ps | grep redis
redis-cli ping
```

**4. Test Fixtures Failing**
```bash
# Run with verbose output
pytest tests/integration/ -v -s

# Check fixture setup
pytest tests/integration/conftest.py --fixtures
```

**5. Citus Tests Skipped**
```bash
# Verify Citus is enabled
export ENABLE_CITUS=true

# Check Citus extension
psql -h coordinator -U dpg_cluster -c "SELECT * FROM citus_get_active_worker_nodes()"
```

## Best Practices

1. **Clean Up Test Data**: All tests use unique namespaces and clean up after themselves
2. **Isolation**: Tests are independent and can run in any order
3. **Timeouts**: Long-running tests have explicit timeouts
4. **Markers**: Use markers to skip tests that require unavailable infrastructure
5. **Fixtures**: Reuse fixtures for common setup (database connections, test data)
6. **Error Messages**: Assert messages include context for debugging

## Contributing

When adding new integration tests:

1. Use appropriate test markers (`@pytest.mark.citus`, etc.)
2. Add docstrings explaining what is being tested
3. Clean up test data in fixtures or teardown
4. Follow naming convention: `test_<feature>_<scenario>`
5. Add performance assertions where relevant
6. Update this README with new test categories

## Related Documentation

- [Database Setup Guide](../../docs/setup/database-setup.md)
- [Citus Configuration](../../docs/architecture/distributed-postgres-design.md)
- [Patroni HA Setup](../../docs/deployment/patroni-setup.md)
- [Error Handling](../../docs/ERROR_HANDLING.md)
- [Performance Tuning](../../docs/performance/distributed-optimization.md)

## Support

For issues or questions:
- Check [docs/](../../docs/) for architecture and setup guides
- Review [tests/ha/](../ha/) for existing HA test patterns
- See [scripts/](../../scripts/) for database utilities
