# End-to-End Test Suite

Comprehensive end-to-end testing for the distributed PostgreSQL cluster system.

## Overview

This test suite validates the entire distributed system from deployment to production operations including:

- **Complete Deployment**: Deploy full stack, verify health, run smoke tests
- **Data Flow**: Write/read operations, replication, cache coherence, vector search
- **Failover**: Simulate failures, verify automatic failover, check data integrity
- **Scaling**: Add/remove nodes, rebalance shards, verify distribution
- **Backup/Restore**: Full backups, disaster recovery, data integrity
- **Performance**: Baseline benchmarks, regression detection
- **Security**: SSL/TLS, authentication, authorization, audit logs

## Test Architecture

```
tests/e2e/
├── test_full_stack.py      # Complete E2E test suite
├── __init__.py
├── pytest.ini              # Pytest configuration
├── README.md               # This file
└── last_run_report.html    # Latest test report (generated)
```

## Prerequisites

### Required
- Python 3.8+
- pytest
- psycopg2
- Docker
- Environment variables configured in `.env`

### Optional
- redis-py (for cache tests)
- psutil (for system metrics)
- pytest-asyncio (for async tests)
- pytest-cov (for coverage reports)

Install all:
```bash
pip install pytest pytest-asyncio psutil psycopg2-binary redis
```

## Running Tests

### Quick Start

Run all tests:
```bash
./scripts/e2e/run-e2e-tests.sh
```

### Run Specific Test Suites

```bash
# Deployment tests only
./scripts/e2e/run-e2e-tests.sh deployment

# Data flow tests
./scripts/e2e/run-e2e-tests.sh data_flow

# Failover tests (requires Patroni)
ENABLE_PATRONI=true ./scripts/e2e/run-e2e-tests.sh failover

# Performance tests
./scripts/e2e/run-e2e-tests.sh performance

# Security tests
./scripts/e2e/run-e2e-tests.sh security
```

### Using pytest Directly

```bash
# Run all E2E tests
pytest tests/e2e/test_full_stack.py -v

# Run specific test class
pytest tests/e2e/test_full_stack.py::TestCompleteDeployment -v

# Run specific test
pytest tests/e2e/test_full_stack.py::TestDataFlow::test_01_write_to_primary -v

# Use markers
pytest tests/e2e/ -m deployment
pytest tests/e2e/ -m "not slow"
pytest tests/e2e/ -m requires_patroni
```

## Environment Variables

### Test Control
- `RUN_FAILOVER_TESTS=true|false` - Enable/disable failover tests (default: true)
- `RUN_SCALING_TESTS=true|false` - Enable/disable scaling tests (default: true)
- `RUN_BACKUP_TESTS=true|false` - Enable/disable backup tests (default: true)
- `RUN_PERFORMANCE_TESTS=true|false` - Enable/disable performance tests (default: true)
- `RUN_SECURITY_TESTS=true|false` - Enable/disable security tests (default: true)

### Service Control
- `SKIP_SERVICE_START=true|false` - Skip automatic service startup (default: false)
- `CLEANUP_SERVICES=true|false` - Cleanup services on exit (default: true)

### System Configuration
- `ENABLE_PATRONI=true|false` - Enable Patroni HA mode (default: false)
- `RUVECTOR_DB`, `RUVECTOR_USER`, etc. - Database configuration (required)
- `CITUS_COORDINATOR_HOST`, `CITUS_WORKER_HOSTS` - Citus configuration (optional)

## Test Reports

### HTML Report

After running tests, an HTML report is generated at:
- `/tmp/dpg_e2e_report.html` (temporary)
- `tests/e2e/last_run_report.html` (persistent)

The report includes:
- Test summary with pass/fail counts
- Individual test results with timing
- Performance metrics and charts
- System metrics captured during tests
- Error details and stack traces

### Logs

Test logs are saved to `/tmp/dpg_e2e_logs/`:
- `startup.log` - Service startup logs
- `*_tests.log` - Individual test suite logs
- `system_state_before_tests.log` - System state before tests
- `system_state_after_tests.log` - System state after tests
- `summary.txt` - Test summary

Logs are archived to `/tmp/dpg_e2e_logs_TIMESTAMP.tar.gz` on exit.

## Test Configuration

Edit `TEST_CONFIG` in `test_full_stack.py` to customize:

```python
TEST_CONFIG = {
    "deployment_timeout": 300,         # seconds
    "health_check_interval": 5,        # seconds
    "replication_lag_threshold": 100,  # ms
    "failover_timeout": 60,            # seconds
    "backup_path": Path("/tmp/dpg_e2e_backup"),
    "test_data_size": 1000,            # rows
    "performance_baseline": {
        "write_latency_p95": 10,       # ms
        "read_latency_p95": 5,         # ms
        "vector_search_latency_p95": 50,  # ms
        "replication_lag_p95": 100,    # ms
    },
}
```

## Test Scenarios

### 1. Complete Deployment Test

**Steps:**
1. Clean state (stop services, remove containers)
2. Deploy full stack using `start-dev-stack.sh`
3. Wait for all services to become healthy
4. Verify database connections and schemas
5. Run smoke tests (basic CRUD operations)
6. Tear down cleanly

**Expected Result:** All services running and healthy, basic operations work

### 2. Data Flow Test

**Steps:**
1. Write 100 test entries to primary database
2. Verify replication to replica nodes
3. Check Redis cache updates
4. Read from replicas with `read_only=True`
5. Perform vector similarity search

**Expected Result:** Data flows correctly through all layers, vector search works

### 3. Failover Test (Patroni Mode)

**Steps:**
1. Stop primary database node
2. Wait for automatic failover (max 60s)
3. Verify new primary is elected
4. Check no data loss occurred
5. Perform read/write operations on new primary
6. Restart old primary and verify it rejoins as replica

**Expected Result:** Automatic failover in <60s, zero data loss, service continues

### 4. Scaling Test

**Steps:**
1. Add new worker node to cluster
2. Trigger shard rebalancing
3. Verify data distribution across workers
4. Remove a worker node
5. Verify automatic rebalancing

**Expected Result:** Cluster scales horizontally, data distributes evenly

### 5. Backup/Restore Test

**Steps:**
1. Create full cluster backup
2. Destroy primary database
3. Restore from backup
4. Verify data integrity
5. Verify RuVector HNSW indexes intact

**Expected Result:** Complete recovery from backup, zero data loss

### 6. Performance Regression Test

**Steps:**
1. Run 100 write operations, measure p95 latency
2. Run 100 read operations, measure p95 latency
3. Run 100 vector searches, measure p95 latency
4. Compare against baseline thresholds
5. Generate performance report

**Expected Result:** All metrics within baseline thresholds

### 7. Security Test

**Steps:**
1. Verify SSL/TLS encryption is enabled
2. Test authentication (wrong password should fail)
3. Check role-based authorization
4. Validate audit logging configuration

**Expected Result:** All security features enabled and working

## Debugging Failed Tests

### View Logs
```bash
# All logs
ls -lh /tmp/dpg_e2e_logs/

# Specific test suite
cat /tmp/dpg_e2e_logs/failover_tests.log

# System state before tests
cat /tmp/dpg_e2e_logs/system_state_before_tests.log
```

### Check Service Status
```bash
# Docker containers
docker ps -a --filter "name=dpg-"

# Database health
python3 scripts/db_health_check.py

# Logs from specific container
docker logs dpg-patroni-primary
```

### Rerun Single Test
```bash
# With verbose output
pytest tests/e2e/test_full_stack.py::TestFailover::test_01_simulate_primary_failure -vv

# With debug logging
pytest tests/e2e/test_full_stack.py::TestFailover -vv --log-cli-level=DEBUG
```

### Manual Service Control
```bash
# Start services manually
./scripts/dev/start-dev-stack.sh

# Run tests without starting services
SKIP_SERVICE_START=true ./scripts/e2e/run-e2e-tests.sh

# Keep services running after tests
CLEANUP_SERVICES=false ./scripts/e2e/run-e2e-tests.sh
```

## CI/CD Integration

### GitHub Actions Example

```yaml
name: E2E Tests

on: [push, pull_request]

jobs:
  e2e-tests:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v2

      - name: Set up Python
        uses: actions/setup-python@v2
        with:
          python-version: '3.9'

      - name: Install dependencies
        run: |
          pip install -r requirements.txt
          pip install pytest pytest-asyncio psutil

      - name: Run E2E tests
        env:
          RUVECTOR_PASSWORD: ${{ secrets.RUVECTOR_PASSWORD }}
          SHARED_KNOWLEDGE_PASSWORD: ${{ secrets.SHARED_KNOWLEDGE_PASSWORD }}
        run: ./scripts/e2e/run-e2e-tests.sh

      - name: Upload test report
        if: always()
        uses: actions/upload-artifact@v2
        with:
          name: e2e-report
          path: /tmp/dpg_e2e_report.html

      - name: Upload logs
        if: always()
        uses: actions/upload-artifact@v2
        with:
          name: e2e-logs
          path: /tmp/dpg_e2e_logs_*.tar.gz
```

## Performance Baselines

Current performance targets (p95 latencies):

| Operation | Target | Description |
|-----------|--------|-------------|
| Write | <10ms | Single row insert with vector |
| Read | <5ms | Single row retrieval by key |
| Vector Search | <50ms | k=10 similarity search with HNSW |
| Replication Lag | <100ms | Primary to replica delay |

Update these in `TEST_CONFIG["performance_baseline"]` as the system evolves.

## Contributing

When adding new E2E tests:

1. Add test method to appropriate test class
2. Follow naming convention: `test_NN_descriptive_name`
3. Update test results dict for reporting
4. Capture metrics at key points
5. Add appropriate pytest markers
6. Update this README with new scenarios
7. Ensure cleanup in fixtures

## Troubleshooting

### Tests Timeout
- Increase `deployment_timeout` or `failover_timeout` in `TEST_CONFIG`
- Check system resources (CPU, memory, disk)
- Review service logs for errors

### Connection Errors
- Verify `.env` file is correctly configured
- Check Docker containers are running: `docker ps`
- Run health check: `python3 scripts/db_health_check.py`

### Performance Tests Fail
- Check system load (other processes consuming resources)
- Verify disk I/O is not saturated
- Review baseline thresholds in `TEST_CONFIG`

### Patroni Tests Fail
- Ensure `ENABLE_PATRONI=true` is set
- Verify etcd is running and accessible
- Check Patroni configuration in `config/patroni/`

## License

MIT License - See LICENSE file for details
