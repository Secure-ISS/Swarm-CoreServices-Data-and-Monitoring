# Load Testing Guide

## Overview

This document describes the comprehensive load testing suite for the distributed PostgreSQL cluster. The suite validates performance, scalability, and resilience under various load conditions.

## Test Components

### 1. Benchmark Suite (`tests/load/benchmark_suite.py`)

Python-based comprehensive benchmark suite testing:

- **Concurrent Connections**: Tests connection pool capacity (10, 25, 40, 50+ connections)
- **Read-Heavy Load**: Validates read performance under various concurrency levels
- **Write-Heavy Load**: Tests write throughput and contention handling
- **Vector Search**: Measures similarity search performance at scale
- **Mixed Workload**: Simulates realistic application usage patterns

**Key Features:**
- Detailed latency percentiles (P50, P95, P99)
- Throughput measurements (ops/sec)
- Success rate tracking
- Error collection and analysis
- Automatic report generation

### 2. Stress Tests (`tests/load/stress_test.sh`)

Bash-based stress testing suite for extreme conditions:

- **Connection Exhaustion**: Tests behavior beyond pool capacity
- **Sustained Load**: Uses pgbench for extended load testing
- **Rapid Connection Churn**: Tests connection/disconnection at high rates
- **Vector Operations Stress**: Bulk inserts and searches
- **Failover Scenarios**: Tests resilience during primary failure (Patroni mode)

**Key Features:**
- Real-world failure simulation
- PostgreSQL statistics collection
- Automated cleanup
- Comprehensive logging

### 3. Load Test Orchestrator (`scripts/benchmark/run-load-tests.sh`)

Master script that coordinates all load testing:

- Runs benchmark suite, stress tests, and scenario tests
- Validates environment and dependencies
- Generates unified summary reports
- Creates performance baseline documents
- Supports selective test execution

## Quick Start

### Prerequisites

```bash
# Install required packages
sudo apt-get install postgresql-client postgresql-contrib python3 python3-pip

# Install Python dependencies
pip3 install psycopg2-binary

# Ensure .env file is configured with database credentials
cat > .env <<EOF
RUVECTOR_HOST=localhost
RUVECTOR_PORT=5432
RUVECTOR_DB=distributed_postgres_cluster
RUVECTOR_USER=dpg_cluster
RUVECTOR_PASSWORD=dpg_cluster_2026
EOF
```

### Running Tests

```bash
# Run full test suite (all tests)
./scripts/benchmark/run-load-tests.sh

# Run only benchmark suite
./scripts/benchmark/run-load-tests.sh --benchmark-only

# Run only stress tests
./scripts/benchmark/run-load-tests.sh --stress-only

# Run only scenario tests
./scripts/benchmark/run-load-tests.sh --scenarios-only

# Run with performance graphs (requires gnuplot)
./scripts/benchmark/run-load-tests.sh --with-graphs
```

### Running Individual Tests

```bash
# Python benchmark suite
cd /home/matt/projects/Distributed-Postgress-Cluster
source .env
python3 tests/load/benchmark_suite.py

# Bash stress tests
cd /home/matt/projects/Distributed-Postgress-Cluster
source .env
./tests/load/stress_test.sh

# With failover testing (requires Patroni)
FAILOVER_TEST=true ./tests/load/stress_test.sh
```

## Test Scenarios

### Scenario 1: Peak Load Simulation

**Objective:** Validate cluster handles 100 concurrent connections for 60 seconds

```bash
# Automatic via orchestrator
./scripts/benchmark/run-load-tests.sh --scenarios-only

# Manual execution
python3 -c "
from tests.load.benchmark_suite import LoadTestRunner
import os

db_config = {
    'host': os.getenv('RUVECTOR_HOST'),
    'port': int(os.getenv('RUVECTOR_PORT')),
    'database': os.getenv('RUVECTOR_DB'),
    'user': os.getenv('RUVECTOR_USER'),
    'password': os.getenv('RUVECTOR_PASSWORD'),
}

runner = LoadTestRunner(db_config)
result = runner.test_mixed_workload(duration_seconds=60, concurrency=100)
print(result.to_dict())
"
```

**Success Criteria:**
- Success rate > 95%
- No connection pool exhaustion errors
- P95 latency < 100ms

### Scenario 2: Vector Search at Scale

**Objective:** Test similarity search with 10,000 queries

```bash
python3 -c "
from tests.load.benchmark_suite import LoadTestRunner
import os

db_config = {
    'host': os.getenv('RUVECTOR_HOST'),
    'port': int(os.getenv('RUVECTOR_PORT')),
    'database': os.getenv('RUVECTOR_DB'),
    'user': os.getenv('RUVECTOR_USER'),
    'password': os.getenv('RUVECTOR_PASSWORD'),
}

runner = LoadTestRunner(db_config)
result = runner.test_vector_search_performance(num_searches=10000, top_k=10)
print(f'Throughput: {result.ops_per_second:.2f} ops/sec')
print(f'P95 Latency: {result.latency_p95:.2f}ms')
"
```

**Success Criteria:**
- Throughput > 500 searches/sec
- P95 latency < 50ms
- P99 latency < 100ms

### Scenario 3: Write-Heavy Batch Processing

**Objective:** Test bulk insert performance with 1,000 writes

```bash
python3 -c "
from tests.load.benchmark_suite import LoadTestRunner
import os

db_config = {
    'host': os.getenv('RUVECTOR_HOST'),
    'port': int(os.getenv('RUVECTOR_PORT')),
    'database': os.getenv('RUVECTOR_DB'),
    'user': os.getenv('RUVECTOR_USER'),
    'password': os.getenv('RUVECTOR_PASSWORD'),
}

runner = LoadTestRunner(db_config)
result = runner.test_write_heavy_load(num_operations=1000, concurrency=20)
print(f'Throughput: {result.ops_per_second:.2f} ops/sec')
print(f'P95 Latency: {result.latency_p95:.2f}ms')
"
```

**Success Criteria:**
- Throughput > 500 writes/sec
- P95 latency < 50ms
- No lock contention errors

## Performance Baselines

### Connection Pool

| Metric | Target | Current |
|--------|--------|---------|
| Max concurrent connections | 40 | ✅ Verified |
| Success rate at capacity | >95% | ✅ 100% |
| Pool exhaustion point | >40 | ✅ 51+ |

### Vector Search

| Metric | Target | Measured |
|--------|--------|----------|
| Search P50 latency | <20ms | TBD |
| Search P95 latency | <50ms | TBD |
| Search P99 latency | <100ms | TBD |
| Throughput (10 concurrent) | >500 ops/sec | TBD |

### Read Operations

| Metric | Target | Measured |
|--------|--------|----------|
| Read P95 latency | <10ms | TBD |
| Throughput (20 concurrent) | >1000 ops/sec | TBD |
| Success rate | >99% | TBD |

### Write Operations

| Metric | Target | Measured |
|--------|--------|----------|
| Write P95 latency | <50ms | TBD |
| Throughput (10 concurrent) | >500 ops/sec | TBD |
| Success rate | >99% | TBD |

### Mixed Workload

| Metric | Target | Measured |
|--------|--------|----------|
| Mixed ops throughput | >800 ops/sec | TBD |
| Success rate | >99% | TBD |

## Results and Reporting

### Automatic Reports

All test runs generate:

1. **Summary Report** (`SUMMARY.md`): High-level overview of all tests
2. **Performance Baseline** (`PERFORMANCE_BASELINE.md`): Detailed metrics and targets
3. **Benchmark Report** (`benchmark/report.md`): Detailed benchmark results with latency percentiles
4. **Test Logs**: Individual logs for each test component

### Results Directory Structure

```
tests/load/results/YYYYMMDD_HHMMSS/
├── SUMMARY.md                    # Overall summary
├── PERFORMANCE_BASELINE.md       # Performance baselines
├── benchmark/
│   ├── report.md                # Detailed benchmark report
│   └── output.log               # Raw benchmark output
├── stress/
│   ├── connection_exhaustion_*.log
│   ├── sustained_load_*.log
│   ├── rapid_connections_*.log
│   ├── vector_stress_*.log
│   ├── failover_*.log
│   └── stress_test_summary_*.md
├── scenarios/
│   ├── peak_load.log
│   ├── vector_search_scale.log
│   └── batch_writes.log
└── graphs/                       # Performance graphs (optional)
```

### Reading Results

**Benchmark Report Format:**

```markdown
| Test | Operations | Success Rate | Ops/sec | P50 (ms) | P95 (ms) | P99 (ms) |
|------|-----------|--------------|---------|----------|----------|----------|
| concurrent_connections_40 | 40 | 100.0% | 88.97 | 102.45 | 115.32 | 120.18 |
| vector_search_1000ops_top10 | 1000 | 100.0% | 532.11 | 18.23 | 42.67 | 68.91 |
```

**Key Metrics:**
- **Ops/sec**: Throughput (higher is better)
- **P50/P95/P99**: Latency percentiles (lower is better)
- **Success Rate**: Percentage of successful operations (should be >99%)

## Troubleshooting

### Common Issues

#### 1. Connection Pool Exhaustion

**Symptoms:**
```
FATAL: remaining connection slots are reserved
FATAL: too many connections for database
```

**Solutions:**
- Increase PostgreSQL `max_connections`
- Increase application pool size (`maxconn` in `pool.py`)
- Implement connection pooling (PgBouncer)

#### 2. Slow Vector Searches

**Symptoms:**
- P95 latency > 100ms
- Throughput < 100 ops/sec

**Solutions:**
- Verify HNSW index exists: `\d claude_flow.embeddings`
- Rebuild index with higher `m` or `ef_construction`
- Increase `work_mem` for complex queries
- Check table statistics: `ANALYZE claude_flow.embeddings`

#### 3. Write Contention

**Symptoms:**
- Write latency spikes
- Deadlock errors
- Lock wait timeouts

**Solutions:**
- Use batch inserts with COPY instead of individual INSERTs
- Reduce index count on embeddings table
- Increase `max_locks_per_transaction`
- Partition table by namespace

#### 4. Memory Issues

**Symptoms:**
```
ERROR: out of memory
ERROR: could not resize shared memory segment
```

**Solutions:**
- Increase `shared_buffers` (25% of RAM)
- Reduce `work_mem` per connection
- Limit concurrent connections
- Monitor with: `SELECT * FROM pg_stat_activity`

## Advanced Configuration

### pgbench Custom Scripts

For realistic workload simulation, create custom pgbench scripts:

```sql
-- read_heavy.sql
\set namespace random(1, 100)
SELECT * FROM claude_flow.embeddings WHERE namespace = :namespace LIMIT 10;

-- write_heavy.sql
\set text_id random(1, 1000000)
INSERT INTO claude_flow.embeddings (text, embedding, metadata, namespace)
VALUES ('bench_' || :text_id, array_fill(random()::float8, ARRAY[384])::ruvector, '{}'::jsonb, 'bench')
ON CONFLICT DO NOTHING;
```

Run with:
```bash
pgbench -f read_heavy.sql -c 20 -j 4 -T 60 $DB_NAME
```

### Monitoring During Tests

```bash
# Watch active connections
watch -n 1 "psql -c \"SELECT count(*), state FROM pg_stat_activity GROUP BY state\""

# Monitor query performance
psql -c "SELECT query, mean_exec_time, calls FROM pg_stat_statements ORDER BY mean_exec_time DESC LIMIT 10"

# Check table bloat
psql -c "SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) FROM pg_tables WHERE schemaname = 'claude_flow'"
```

## Continuous Performance Testing

### Integration with CI/CD

Add to `.github/workflows/performance.yml`:

```yaml
name: Performance Tests

on:
  schedule:
    - cron: '0 2 * * *'  # Daily at 2 AM
  workflow_dispatch:

jobs:
  performance:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v3

      - name: Set up PostgreSQL
        run: |
          docker run -d --name postgres \
            -e POSTGRES_PASSWORD=test \
            -p 5432:5432 \
            ruvnet/ruvector-postgres

      - name: Run Load Tests
        run: ./scripts/benchmark/run-load-tests.sh

      - name: Upload Results
        uses: actions/upload-artifact@v3
        with:
          name: performance-results
          path: tests/load/results/
```

### Performance Regression Detection

Compare results across runs:

```bash
# Extract key metrics from reports
./scripts/benchmark/compare-results.sh \
  tests/load/results/20260211_120000/ \
  tests/load/results/20260212_120000/
```

## Related Documentation

- [Connection Pool Capacity](/home/matt/projects/Distributed-Postgress-Cluster/docs/POOL_CAPACITY.md)
- [Error Handling](/home/matt/projects/Distributed-Postgress-Cluster/docs/ERROR_HANDLING.md)
- [Database Health Check](/home/matt/projects/Distributed-Postgress-Cluster/scripts/db_health_check.py)

## Support

For issues or questions:
1. Review test logs in `tests/load/results/`
2. Check database health: `python3 scripts/db_health_check.py`
3. Verify PostgreSQL logs: `docker logs ruvector-db`
4. Open an issue with test results and environment details
