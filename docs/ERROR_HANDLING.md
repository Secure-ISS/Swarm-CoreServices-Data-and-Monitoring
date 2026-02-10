# Error Handling Guide

## Overview

The database modules include comprehensive error handling to catch and handle common failure scenarios gracefully.

## Custom Exceptions

### Database Pool Errors (`src/db/pool.py`)

| Exception | When Raised | Recovery |
|-----------|-------------|----------|
| `DatabaseConnectionError` | Cannot connect to PostgreSQL | Check if database is running, verify credentials |
| `DatabaseConfigurationError` | Missing required environment variables | Check `.env` file exists and has all required vars |

### Vector Operations Errors (`src/db/vector_ops.py`)

| Exception | When Raised | Recovery |
|-----------|-------------|----------|
| `VectorOperationError` | Database operation fails during vector operations | Check database connectivity, verify table schemas |
| `InvalidEmbeddingError` | Embedding dimensions != 384 | Ensure embeddings are 384-dimensional vectors |

## Common Error Scenarios

### 1. Database Not Running

**Error:**
```
DatabaseConnectionError: Cannot connect to project database at localhost:5432.
Ensure PostgreSQL is running. Error: connection refused
```

**Fix:**
```bash
# Start the database
./scripts/start_database.sh

# Or manually
docker start ruvector-db
```

### 2. Missing Environment Variables

**Error:**
```
DatabaseConfigurationError: Missing required environment variables: RUVECTOR_DB, RUVECTOR_USER
```

**Fix:**
```bash
# Ensure .env file exists with required variables
cat .env

# Required variables:
# RUVECTOR_DB=distributed_postgres_cluster
# RUVECTOR_USER=dpg_cluster
# RUVECTOR_PASSWORD=dpg_cluster_2026
# ... (see .env for full list)
```

### 3. Invalid Embedding Dimensions

**Error:**
```
InvalidEmbeddingError: Expected 384-dimensional embedding, got 512
```

**Fix:**
```python
# Use the correct embedding model (all-MiniLM-L6-v2 = 384 dims)
from transformers import AutoTokenizer, AutoModel

model_name = "sentence-transformers/all-MiniLM-L6-v2"
model = AutoModel.from_pretrained(model_name)

# Generate embeddings - will be 384 dimensions
```

### 4. Schema Missing

**Error:**
```
psycopg2.errors.UndefinedTable: relation "memory_entries" does not exist
```

**Fix:**
```bash
# Initialize the database schema
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster -f scripts/sql/init-ruvector.sql

# For claude_flow schema
npx @claude-flow/cli@latest ruvector setup --password dpg_cluster_2026 > /tmp/claude_flow_schema.sql
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster -f /tmp/claude_flow_schema.sql
```

### 5. RuVector Extension Missing

**Error:**
```
psycopg2.errors.UndefinedObject: type "ruvector" does not exist
```

**Fix:**
```bash
# Install RuVector extension in database
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "CREATE EXTENSION IF NOT EXISTS ruvector;"
```

## Error Handling Best Practices

### 1. Always Use Context Managers

```python
from src.db.pool import DualDatabasePools

pools = DualDatabasePools()

# ✓ Good - automatic transaction handling
with pools.project_cursor() as cur:
    cur.execute("SELECT * FROM memory_entries LIMIT 10")
    results = cur.fetchall()
# Commit happens automatically on success, rollback on error

# ✗ Bad - manual connection management
conn = pools.project_pool.getconn()
cur = conn.cursor()
cur.execute("SELECT * FROM memory_entries LIMIT 10")
results = cur.fetchall()
pools.project_pool.putconn(conn)  # Easy to forget!
```

### 2. Catch Specific Exceptions

```python
from src.db.pool import DatabaseConnectionError, DatabaseConfigurationError
from src.db.vector_ops import VectorOperationError, InvalidEmbeddingError

try:
    pools = DualDatabasePools()
    with pools.project_cursor() as cur:
        store_memory(cur, "test", "key1", "value", embedding=[...])

except DatabaseConfigurationError as e:
    # Configuration error - likely missing env vars
    print(f"Check .env file: {e}")

except DatabaseConnectionError as e:
    # Connection error - database likely not running
    print(f"Start database: {e}")

except InvalidEmbeddingError as e:
    # Wrong embedding dimensions
    print(f"Use 384-dimensional embeddings: {e}")

except VectorOperationError as e:
    # Database operation failed
    print(f"Database error: {e}")
```

### 3. Validate Inputs Early

```python
from src.db.vector_ops import store_memory

# ✓ Good - validate before calling
if not namespace or not key:
    raise ValueError("namespace and key required")

if embedding and len(embedding) != 384:
    raise ValueError(f"Expected 384 dims, got {len(embedding)}")

store_memory(cursor, namespace, key, value, embedding)

# ✗ Bad - let database catch errors
store_memory(cursor, "", "", value, embedding)  # Will fail in DB
```

### 4. Use Health Checks

```python
from src.db.pool import DualDatabasePools

pools = DualDatabasePools()

# Check health before operations
health = pools.health_check()

if health['project']['status'] != 'healthy':
    print(f"Project DB error: {health['project']['error']}")
    # Don't proceed with operations

if health['shared']['status'] != 'healthy':
    print(f"Shared DB error: {health['shared']['error']}")
```

## Logging

All errors are logged with the Python `logging` module:

```python
import logging

# Configure logging level
logging.basicConfig(level=logging.INFO)  # Or DEBUG for verbose

# Errors are automatically logged
from src.db.pool import DualDatabasePools

try:
    pools = DualDatabasePools()
except DatabaseConnectionError:
    # Error details are already logged
    pass
```

## Health Check Script

Run the comprehensive health check:

```bash
python3 scripts/db_health_check.py
```

Output includes:
- Docker container status
- Environment configuration validation
- Database connection health
- Schema verification
- HNSW index counts

## Recovery Procedures

### Full Recovery from Scratch

```bash
# 1. Stop and remove existing container
docker stop ruvector-db
docker rm ruvector-db

# 2. Start fresh database
./scripts/start_database.sh

# 3. Initialize schemas
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster -f scripts/sql/init-ruvector.sql

# 4. Run health check
python3 scripts/db_health_check.py

# 5. Run tests
python3 src/test_vector_ops.py
```

### Backup and Restore

```bash
# Backup
docker exec ruvector-db pg_dump -U dpg_cluster distributed_postgres_cluster > backup.sql

# Restore
cat backup.sql | docker exec -i ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster
```

## Monitoring

### Connection Pool Metrics

```python
pools = DualDatabasePools()

# Check pool status
print(f"Project pool: {pools.project_pool._used} used, {pools.project_pool._pool} available")
print(f"Shared pool: {pools.shared_pool._used} used, {pools.shared_pool._pool} available")
```

### Query Performance

All vector searches are logged with timing:

```python
import logging
logging.basicConfig(level=logging.DEBUG)

# Will log: "Search found 5 results in test_namespace"
results = search_memory(cursor, "test_namespace", embedding)
```

## Support

For issues:
1. Check logs: `docker logs ruvector-db`
2. Run health check: `python3 scripts/db_health_check.py`
3. Review this guide for common errors
4. Check memory file: `~/.claude/projects/-home-matt-projects-Distributed-Postgress-Cluster/memory/MEMORY.md`
