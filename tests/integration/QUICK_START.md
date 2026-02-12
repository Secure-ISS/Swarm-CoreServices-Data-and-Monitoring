# Quick Start - Integration Tests

## 🚀 Run Tests in 3 Steps

### Step 1: Start Services

```bash
# Start PostgreSQL + Redis
docker compose -f docker-compose.dev.yml up -d

# Wait for services to be ready
sleep 10
```

### Step 2: Set Environment

```bash
export RUVECTOR_HOST=localhost
export RUVECTOR_PORT=5432
export RUVECTOR_DB=distributed_postgres_cluster
export RUVECTOR_USER=dpg_cluster
export RUVECTOR_PASSWORD=dpg_cluster_2026
export REDIS_HOST=localhost
export REDIS_PORT=6379
```

### Step 3: Run Tests

```bash
# Run all basic tests
./tests/integration/run_integration_tests.sh basic

# Or run with pytest directly
pytest tests/integration/test_distributed_cluster.py -v
```

## 🎯 Common Test Commands

```bash
# All basic integration tests
./tests/integration/run_integration_tests.sh basic

# Cache tests
./tests/integration/run_integration_tests.sh cache

# Fast tests only (skip slow tests)
./tests/integration/run_integration_tests.sh fast

# With coverage report
./tests/integration/run_integration_tests.sh coverage

# Specific test class
pytest tests/integration/test_distributed_cluster.py::TestConnectionManagement -v

# Single test function
pytest tests/integration/test_distributed_cluster.py::TestConnectionManagement::test_basic_connection -v
```

## 📊 What Gets Tested

### ✅ Basic Tests (Always Available)
- Database connectivity and pooling
- RuVector vector operations
- CRUD operations and transactions
- Error handling
- Performance benchmarks

### ✅ Redis Cache Tests (Requires Redis)
- Cache operations (set/get/delete)
- Cache invalidation
- Performance comparisons
- Caching strategies

### ⏳ Citus Tests (Requires Citus Cluster)
- Distributed sharding
- Cross-shard queries
- Reference tables

### ⏳ Patroni HA Tests (Requires HA Cluster)
- Automatic failover
- Replication monitoring
- Split-brain prevention

## 🔍 Test Results

```bash
# After running tests, view coverage report
open htmlcov/index.html

# Or view in terminal
pytest tests/integration/ -v --cov=src --cov-report=term-missing
```

## 🐛 Troubleshooting

**Database not accessible:**
```bash
# Check if PostgreSQL is running
docker ps | grep postgres

# Test connection
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster -c "SELECT 1"
```

**Redis not accessible:**
```bash
# Check if Redis is running
docker ps | grep redis

# Test connection
redis-cli ping
```

**Tests skipped:**
```bash
# Install missing dependencies
pip install pytest pytest-cov psycopg2-binary redis requests numpy

# Check environment variables
env | grep -E "(RUVECTOR|REDIS)"
```

## 📚 More Information

- Full documentation: `tests/integration/README.md`
- Implementation summary: `tests/integration/INTEGRATION_TEST_SUMMARY.md`
- CI/CD pipeline: `.github/workflows/integration-tests.yml`

## 💡 Pro Tips

1. **Parallel execution**: Add `-n 4` to run tests in parallel
2. **Stop on first failure**: Add `-x` flag
3. **Verbose output**: Add `-v` or `-vv` for more details
4. **Filter by marker**: Add `-m marker_name` (e.g., `-m redis`)
5. **Show print statements**: Add `-s` flag

Happy testing! 🎉
