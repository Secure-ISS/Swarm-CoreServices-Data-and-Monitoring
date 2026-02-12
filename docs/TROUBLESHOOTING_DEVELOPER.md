# Developer Troubleshooting Guide

Comprehensive troubleshooting guide for common development issues.

## Table of Contents

- [Quick Diagnostics](#quick-diagnostics)
- [Database Issues](#database-issues)
- [Connection Problems](#connection-problems)
- [RuVector Errors](#ruvector-errors)
- [Performance Problems](#performance-problems)
- [Testing Issues](#testing-issues)
- [Development Environment](#development-environment)

## Quick Diagnostics

### Run Health Check

```bash
# Comprehensive health check
python3 scripts/db_health_check.py

# Expected output:
# ========================================
# Database Health Check
# ========================================
# ✓ Docker container 'ruvector-db' is running
# ✓ Environment variables configured
# ✓ Project database connected (distributed_postgres_cluster)
# ✓ Shared database connected (claude_flow_shared)
# ✓ RuVector extension 2.0.0 installed
# ✓ Schema 'public' exists with 5 tables
# ✓ Schema 'claude_flow' exists with 8 tables
# ✓ Found 6 HNSW indexes in public schema
# ✓ Found 2 HNSW indexes in claude_flow schema
```

### Check Docker

```bash
# Is container running?
docker ps | grep ruvector-db

# Container logs
docker logs ruvector-db --tail 50

# Container stats
docker stats ruvector-db --no-stream
```

### Check Database Connectivity

```bash
# Test direct connection
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster -c "SELECT version()"

# Test connection pool
python3 -c "
from src.db import get_pools
health = get_pools().health_check()
print(health)
"
```

## Database Issues

### Issue: Database Container Won't Start

**Symptoms:**
```bash
docker start ruvector-db
Error response from daemon: driver failed programming external connectivity
```

**Causes:**
1. Port 5432 already in use
2. Container name conflict
3. Volume mount issues

**Solutions:**

```bash
# 1. Check what's using port 5432
lsof -i :5432
# OR
netstat -tulpn | grep 5432

# 2. Stop conflicting service
sudo systemctl stop postgresql
# OR kill the process using port 5432

# 3. Remove old container
docker stop ruvector-db
docker rm ruvector-db

# 4. Start fresh
./scripts/start_database.sh

# Alternative: Use different port
docker run -d \
    --name ruvector-db \
    -e POSTGRES_DB=distributed_postgres_cluster \
    -e POSTGRES_USER=dpg_cluster \
    -e POSTGRES_PASSWORD=dpg_cluster_2026 \
    -p 5433:5432 \  # Different host port
    ruvnet/ruvector-postgres:latest

# Update .env
RUVECTOR_PORT=5433
```

### Issue: Database Started But Won't Accept Connections

**Symptoms:**
```
psycopg2.OperationalError: could not connect to server: Connection refused
```

**Solutions:**

```bash
# 1. Wait for PostgreSQL to fully start (10-15 seconds)
sleep 15
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster -c "SELECT 1"

# 2. Check if PostgreSQL is actually running in container
docker exec ruvector-db pg_isready -U dpg_cluster

# 3. Check PostgreSQL logs
docker logs ruvector-db | grep "ready to accept connections"

# 4. Verify listen address
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster \
    -c "SHOW listen_addresses"
# Should show: listen_addresses = '*'

# 5. Check pg_hba.conf
docker exec ruvector-db cat /var/lib/postgresql/data/pg_hba.conf | grep host
# Should include: host all all all md5
```

### Issue: Schema Not Found

**Symptoms:**
```
psycopg2.errors.UndefinedTable: relation "memory_entries" does not exist
```

**Solutions:**

```bash
# 1. Check if schemas exist
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster \
    -c "\dn"

# 2. Check if tables exist in public schema
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster \
    -c "\dt public.*"

# 3. Initialize public schema
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster \
    -f scripts/sql/init-ruvector.sql

# 4. Initialize claude_flow schema
npx @claude-flow/cli@latest ruvector setup --password dpg_cluster_2026 > /tmp/schema.sql
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster \
    -f /tmp/schema.sql

# 5. Verify tables
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster \
    -c "SELECT schemaname, tablename FROM pg_tables WHERE schemaname IN ('public', 'claude_flow')"
```

### Issue: Out of Disk Space

**Symptoms:**
```
ERROR: could not extend file "base/16384/24576": No space left on device
```

**Solutions:**

```bash
# 1. Check Docker disk usage
docker system df

# 2. Clean unused containers/images
docker system prune -a

# 3. Check volume size
docker exec ruvector-db df -h /var/lib/postgresql/data

# 4. Vacuum database to reclaim space
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster \
    -c "VACUUM FULL ANALYZE"

# 5. Drop old data
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster <<EOF
DELETE FROM memory_entries WHERE created_at < NOW() - INTERVAL '30 days';
VACUUM FULL;
EOF
```

## Connection Problems

### Issue: Connection Pool Exhausted

**Symptoms:**
```python
psycopg2.pool.PoolError: connection pool exhausted
```

**Diagnosis:**

```python
from src.db import get_pools

pools = get_pools()

# Check pool usage
print(f"Project pool used: {pools.project_pool._used}")
print(f"Project pool max: 40")
print(f"Shared pool used: {pools.shared_pool._used}")
print(f"Shared pool max: 15")
```

**Solutions:**

```python
# 1. Ensure you're using context managers (auto-release)
# BAD - connection not released:
pools = get_pools()
conn = pools.project_pool.getconn()
cur = conn.cursor()
cur.execute("SELECT * FROM memory_entries")
# Forgot to putconn!

# GOOD - automatic release:
with pools.project_cursor() as cur:
    cur.execute("SELECT * FROM memory_entries")
# Connection automatically returned to pool

# 2. Increase pool size if needed
# Edit src/db/pool.py:
maxconn=50  # Increase from 40

# 3. Close pools between test runs
from src.db import close_pools
close_pools()

# 4. Check for connection leaks
SELECT count(*) as active_connections
FROM pg_stat_activity
WHERE datname = 'distributed_postgres_cluster';
```

### Issue: SSL/TLS Connection Fails

**Symptoms:**
```
psycopg2.OperationalError: SSL error: certificate verify failed
```

**Solutions:**

```bash
# 1. Disable SSL temporarily for testing
export RUVECTOR_SSLMODE=disable
export SHARED_KNOWLEDGE_SSLMODE=disable

# 2. Use 'prefer' mode (try SSL, fallback to non-SSL)
export RUVECTOR_SSLMODE=prefer

# 3. Use self-signed certificates in development
export RUVECTOR_SSLMODE=require
export RUVECTOR_SSLROOTCERT=

# 4. Generate self-signed cert for testing
openssl req -new -x509 -days 365 -nodes \
    -out server.crt -keyout server.key

# 5. Check SSL status
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster \
    -c "SELECT ssl, cipher FROM pg_stat_ssl WHERE pid = pg_backend_pid()"
```

### Issue: Connection Timeout

**Symptoms:**
```
psycopg2.OperationalError: timeout expired
```

**Solutions:**

```python
# 1. Increase timeout in pool config
# src/db/pool.py
conn_params = {
    ...
    "connect_timeout": 30,  # Increase from 10
}

# 2. Check network latency
ping localhost

# 3. Check PostgreSQL max_connections
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster \
    -c "SHOW max_connections"

# 4. Check for long-running queries blocking connections
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster \
    -c "SELECT pid, age(clock_timestamp(), query_start), usename, query
        FROM pg_stat_activity
        WHERE state != 'idle'
        ORDER BY query_start"
```

## RuVector Errors

### Issue: RuVector Extension Not Installed

**Symptoms:**
```
psycopg2.errors.UndefinedObject: type "ruvector" does not exist
```

**Solutions:**

```bash
# 1. Check if extension is installed
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster \
    -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'ruvector'"

# 2. Install extension
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster \
    -c "CREATE EXTENSION IF NOT EXISTS ruvector"

# 3. Verify installation
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster \
    -c "\dx ruvector"

# 4. Check extension version
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster \
    -c "SELECT ruvector_version()"
# Expected: 2.0.0
```

### Issue: Invalid Embedding Dimensions

**Symptoms:**
```python
InvalidEmbeddingError: Expected 384-dimensional embedding, got 512
```

**Solutions:**

```python
# 1. Verify embedding dimensions
embedding = generate_embedding("text")
print(f"Dimensions: {len(embedding)}")
# Must be 384

# 2. Use correct model (all-MiniLM-L6-v2 = 384 dims)
from sentence_transformers import SentenceTransformer
model = SentenceTransformer('sentence-transformers/all-MiniLM-L6-v2')
embedding = model.encode("text").tolist()
print(len(embedding))  # 384

# 3. Check database column dimensions
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster \
    -c "\d+ memory_entries"
# embedding column: ruvector(384)

# 4. Truncate or pad embeddings (NOT RECOMMENDED)
def normalize_embedding(emb, target_dim=384):
    if len(emb) > target_dim:
        return emb[:target_dim]  # Truncate
    elif len(emb) < target_dim:
        return emb + [0.0] * (target_dim - len(emb))  # Pad
    return emb
```

### Issue: HNSW Index Build Fails

**Symptoms:**
```
ERROR: could not create index "idx_memory_embedding"
DETAIL: insufficient memory
```

**Solutions:**

```bash
# 1. Increase Docker memory limit
# Docker Desktop -> Settings -> Resources -> Memory: 4GB+

# 2. Reduce HNSW build parameters
CREATE INDEX idx_memory_embedding ON memory_entries
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 8, ef_construction = 50);  # Lower values

# 3. Build index in batches
# First, create without index
ALTER TABLE memory_entries DROP INDEX IF EXISTS idx_memory_embedding;

# Insert data in batches
# Then create index
CREATE INDEX CONCURRENTLY idx_memory_embedding ON memory_entries
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 16, ef_construction = 200);

# 4. Increase PostgreSQL work_mem
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster \
    -c "ALTER SYSTEM SET work_mem = '256MB'"
docker restart ruvector-db
```

### Issue: Vector Search Returns No Results

**Symptoms:**
```python
results = search_memory(cursor, "test", embedding, limit=10)
# results = []
```

**Diagnosis:**

```python
# 1. Check if embeddings exist
with pools.project_cursor() as cur:
    cur.execute("""
        SELECT count(*) as total,
               count(embedding) as with_embedding
        FROM memory_entries
        WHERE namespace = 'test'
    """)
    print(cur.fetchone())

# 2. Check similarity threshold
with pools.project_cursor() as cur:
    cur.execute("""
        SELECT key,
               1 - (embedding <=> %s::ruvector(384)) as similarity
        FROM memory_entries
        WHERE namespace = 'test'
          AND embedding IS NOT NULL
        ORDER BY similarity DESC
        LIMIT 10
    """, (f"[{','.join(str(v) for v in embedding)}]",))
    print(cur.fetchall())
    # Check if similarities are below min_similarity threshold

# 3. Lower similarity threshold
results = search_memory(cursor, "test", embedding, min_similarity=0.0)
```

## Performance Problems

### Issue: Slow Vector Search

**Symptoms:**
```python
# Search takes >100ms
import time
start = time.time()
results = search_memory(cursor, "test", embedding)
print(f"Search took {(time.time() - start) * 1000:.2f}ms")
# 150ms (too slow!)
```

**Diagnosis:**

```sql
-- Check if HNSW index is being used
EXPLAIN ANALYZE
SELECT *
FROM memory_entries
WHERE namespace = 'test'
  AND embedding IS NOT NULL
ORDER BY embedding <=> '[...]'::ruvector(384)
LIMIT 10;

-- Should show: "Index Scan using idx_memory_embedding"
-- If shows "Seq Scan", index is not being used!
```

**Solutions:**

```bash
# 1. Ensure HNSW index exists
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster <<EOF
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'memory_entries'
  AND indexdef LIKE '%hnsw%';
EOF

# 2. Rebuild index if missing/corrupted
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster <<EOF
DROP INDEX IF EXISTS idx_memory_embedding;
CREATE INDEX idx_memory_embedding ON memory_entries
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 16, ef_construction = 200);
EOF

# 3. Update statistics
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster \
    -c "ANALYZE memory_entries"

# 4. Increase PostgreSQL shared_buffers
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster \
    -c "ALTER SYSTEM SET shared_buffers = '256MB'"
docker restart ruvector-db

# 5. Check index bloat
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster <<EOF
SELECT pg_size_pretty(pg_relation_size('idx_memory_embedding')) as index_size,
       pg_size_pretty(pg_total_relation_size('memory_entries')) as table_size;
EOF
```

### Issue: Slow Inserts

**Symptoms:**
```python
# Inserting 1000 records takes >10 seconds
```

**Solutions:**

```python
# 1. Use batch inserts instead of individual inserts
# BAD - slow:
for i in range(1000):
    with pools.project_cursor() as cur:
        store_memory(cur, "test", f"key{i}", f"value{i}", embedding)
# Takes: ~10s

# GOOD - fast:
def batch_store(entries):
    with pools.project_cursor() as cur:
        data = [
            (e['namespace'], e['key'], e['value'],
             f"[{','.join(str(v) for v in e['embedding'])}]")
            for e in entries
        ]
        cur.executemany("""
            INSERT INTO memory_entries (namespace, key, value, embedding)
            VALUES (%s, %s, %s, %s::ruvector)
            ON CONFLICT (namespace, key) DO UPDATE
            SET value = EXCLUDED.value,
                embedding = EXCLUDED.embedding
        """, data)

batch_store(entries)  # Takes: ~0.5s

# 2. Temporarily drop HNSW index during bulk insert
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster <<EOF
DROP INDEX idx_memory_embedding;
-- Insert data here
CREATE INDEX idx_memory_embedding ON memory_entries
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 16, ef_construction = 200);
EOF

# 3. Use COPY for large datasets
# Generate CSV file
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster <<EOF
\copy memory_entries(namespace, key, value, embedding)
FROM 'data.csv'
WITH (FORMAT csv, DELIMITER ',')
EOF
```

### Issue: High Memory Usage

**Symptoms:**
```bash
docker stats ruvector-db
# Memory usage: 3.5GB / 4GB (87.5%)
```

**Solutions:**

```bash
# 1. Check what's using memory
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster <<EOF
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_tables
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 10;
EOF

# 2. Vacuum to reclaim memory
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster \
    -c "VACUUM FULL ANALYZE"

# 3. Reduce shared_buffers
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster \
    -c "ALTER SYSTEM SET shared_buffers = '128MB'"
docker restart ruvector-db

# 4. Reduce connection pool size
# Edit src/db/pool.py
maxconn=20  # Reduce from 40

# 5. Delete old data
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster <<EOF
DELETE FROM memory_entries
WHERE created_at < NOW() - INTERVAL '30 days';
VACUUM;
EOF
```

## Testing Issues

### Issue: Tests Fail with "Database Not Found"

**Symptoms:**
```bash
pytest
# DatabaseConnectionError: database "distributed_postgres_cluster" does not exist
```

**Solutions:**

```bash
# 1. Start database
./scripts/start_database.sh

# 2. Create database if missing
docker exec ruvector-db psql -U dpg_cluster -d postgres \
    -c "CREATE DATABASE distributed_postgres_cluster"

# 3. Initialize schemas
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster \
    -f scripts/sql/init-ruvector.sql

# 4. Verify
python3 scripts/db_health_check.py
```

### Issue: Tests Leave Orphaned Connections

**Symptoms:**
```python
# After tests, connections still active
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster \
    -c "SELECT count(*) FROM pg_stat_activity WHERE datname = 'distributed_postgres_cluster'"
# Result: 40 (pool not closed!)
```

**Solutions:**

```python
# 1. Add cleanup fixture to tests
# conftest.py
import pytest
from src.db import close_pools

@pytest.fixture(autouse=True)
def cleanup():
    yield
    close_pools()

# 2. Close pools in tearDown
def tearDown(self):
    from src.db import close_pools
    close_pools()

# 3. Use separate test database
# .env.test
RUVECTOR_DB=test_database
```

### Issue: Flaky Tests

**Symptoms:**
```bash
# Tests pass/fail randomly
pytest
# Sometimes pass, sometimes fail
```

**Solutions:**

```python
# 1. Add delays for database operations
import time
time.sleep(0.1)  # Give database time to commit

# 2. Use fixtures for test data isolation
@pytest.fixture
def unique_namespace():
    import uuid
    return f"test_{uuid.uuid4().hex[:8]}"

def test_something(unique_namespace):
    # Use unique_namespace to avoid conflicts
    store_memory(cur, unique_namespace, "key", "value", embedding)

# 3. Clean up test data
def test_something():
    namespace = "test_flaky"
    # Test code
    # Cleanup
    with pools.project_cursor() as cur:
        cur.execute("DELETE FROM memory_entries WHERE namespace = %s", (namespace,))

# 4. Use transactions for isolation
with pools.project_cursor() as cur:
    cur.execute("BEGIN")
    # Test operations
    cur.execute("ROLLBACK")  # Undo changes
```

## Development Environment

### Issue: Import Errors

**Symptoms:**
```python
ImportError: No module named 'src'
```

**Solutions:**

```bash
# 1. Ensure virtual environment is activated
source venv/bin/activate

# 2. Install project in editable mode
pip install -e .

# 3. Add project root to PYTHONPATH
export PYTHONPATH="${PYTHONPATH}:$(pwd)"

# 4. Use absolute imports
# Instead of: from db import get_pools
# Use: from src.db import get_pools
```

### Issue: VSCode Not Finding Modules

**Solutions:**

```json
// .vscode/settings.json
{
    "python.pythonPath": "${workspaceFolder}/venv/bin/python",
    "python.analysis.extraPaths": [
        "${workspaceFolder}"
    ]
}
```

### Issue: Black/Flake8 Conflicts

**Symptoms:**
```bash
black src/
flake8 src/
# line too long (E501)
```

**Solutions:**

```ini
# setup.cfg
[flake8]
max-line-length = 100
ignore = E203, W503
exclude = .git,__pycache__,venv
```

## Getting Help

If issues persist:

1. **Check logs**: `docker logs ruvector-db`
2. **Run health check**: `python3 scripts/db_health_check.py`
3. **Search issues**: [GitHub Issues](https://github.com/REPO/issues)
4. **Ask for help**: [GitHub Discussions](https://github.com/REPO/discussions)

## Common Error Messages Reference

| Error | Cause | Solution |
|-------|-------|----------|
| `connection refused` | Database not running | `./scripts/start_database.sh` |
| `pool exhausted` | Too many connections | Use context managers |
| `relation does not exist` | Schema not initialized | Run init-ruvector.sql |
| `type "ruvector" does not exist` | Extension not installed | `CREATE EXTENSION ruvector` |
| `Expected 384-dimensional` | Wrong embedding size | Use 384-dim embeddings |
| `No space left on device` | Disk full | `docker system prune` |
| `certificate verify failed` | SSL error | Set `SSLMODE=disable` for dev |
| `timeout expired` | Network/performance issue | Increase `connect_timeout` |
