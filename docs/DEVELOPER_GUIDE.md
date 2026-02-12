# Developer Guide

Complete guide for setting up a development environment and working with the Distributed PostgreSQL Cluster codebase.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Development Environment Setup](#development-environment-setup)
- [Architecture Overview](#architecture-overview)
- [Code Organization](#code-organization)
- [Local Development](#local-development)
- [Testing](#testing)
- [Debugging](#debugging)
- [Common Development Tasks](#common-development-tasks)
- [Performance Optimization](#performance-optimization)
- [Troubleshooting](#troubleshooting)

## Prerequisites

### Required Software

| Software | Minimum Version | Purpose |
|----------|----------------|---------|
| Python | 3.9 | Primary language |
| Docker | 20.10 | Database container |
| PostgreSQL | 14 | Database knowledge |
| Git | 2.30 | Version control |
| Node.js | 20 | CLI tools |

### Recommended Tools

- **IDE**: VSCode with Python extension
- **Python Tools**: `black`, `flake8`, `mypy`, `pytest`
- **Database Tools**: `pgcli`, `pgAdmin`, DBeaver
- **Docker Tools**: Docker Desktop, Portainer

### Knowledge Requirements

- Python 3.9+ (async, type hints, context managers)
- PostgreSQL (SQL, indexes, connection pooling)
- Vector databases (embeddings, similarity search)
- Docker basics
- Git workflow

## Development Environment Setup

### 1. Clone Repository

```bash
# Clone your fork
git clone https://github.com/YOUR_USERNAME/Distributed-Postgress-Cluster.git
cd Distributed-Postgress-Cluster

# Add upstream remote
git remote add upstream https://github.com/ORIGINAL/Distributed-Postgress-Cluster.git
```

### 2. Python Environment

```bash
# Create virtual environment
python3 -m venv venv

# Activate virtual environment
source venv/bin/activate  # Linux/Mac
# OR
.\venv\Scripts\activate  # Windows

# Upgrade pip
pip install --upgrade pip

# Install dependencies
pip install -r requirements.txt

# Install development dependencies
pip install -r requirements-dev.txt
```

#### requirements.txt

```
psycopg2-binary==2.9.9
python-dotenv==1.0.0
```

#### requirements-dev.txt

```
pytest==7.4.3
pytest-cov==4.1.0
pytest-asyncio==0.21.1
black==23.12.0
flake8==6.1.0
mypy==1.7.1
isort==5.13.2
```

### 3. Environment Configuration

```bash
# Copy environment template
cp .env.example .env

# Edit .env with your configuration
nano .env
```

#### .env Configuration

```bash
# Project Database (RuVector)
RUVECTOR_HOST=localhost
RUVECTOR_PORT=5432
RUVECTOR_DB=distributed_postgres_cluster
RUVECTOR_USER=dpg_cluster
RUVECTOR_PASSWORD=dpg_cluster_2026
RUVECTOR_SSLMODE=prefer

# Shared Knowledge Database
SHARED_KNOWLEDGE_HOST=localhost
SHARED_KNOWLEDGE_PORT=5432
SHARED_KNOWLEDGE_DB=claude_flow_shared
SHARED_KNOWLEDGE_USER=shared_user
SHARED_KNOWLEDGE_PASSWORD=shared_knowledge_2026

# Optional: Patroni HA Mode
ENABLE_PATRONI=false
PATRONI_ENDPOINTS=localhost:8008,localhost:8009,localhost:8010

# Connection Pool Settings
PROJECT_POOL_MIN=2
PROJECT_POOL_MAX=40
SHARED_POOL_MIN=1
SHARED_POOL_MAX=15

# Logging
LOG_LEVEL=INFO
```

### 4. Database Setup

```bash
# Start PostgreSQL with RuVector
./scripts/start_database.sh

# Wait for database to be ready (5-10 seconds)
sleep 10

# Initialize public schema
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster \
     -f scripts/sql/init-ruvector.sql

# Initialize claude_flow schema
npx @claude-flow/cli@latest ruvector setup \
     --password dpg_cluster_2026 > /tmp/claude_flow_schema.sql
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster \
     -f /tmp/claude_flow_schema.sql

# Verify setup
python3 scripts/db_health_check.py
```

### 5. IDE Setup (VSCode)

#### .vscode/settings.json

```json
{
    "python.pythonPath": "${workspaceFolder}/venv/bin/python",
    "python.linting.enabled": true,
    "python.linting.flake8Enabled": true,
    "python.linting.mypyEnabled": true,
    "python.formatting.provider": "black",
    "python.formatting.blackArgs": ["--line-length", "100"],
    "editor.formatOnSave": true,
    "editor.rulers": [100],
    "files.exclude": {
        "**/__pycache__": true,
        "**/*.pyc": true,
        "**/.pytest_cache": true
    }
}
```

#### .vscode/launch.json

```json
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "Python: Current File",
            "type": "python",
            "request": "launch",
            "program": "${file}",
            "console": "integratedTerminal",
            "envFile": "${workspaceFolder}/.env"
        },
        {
            "name": "Python: Test Vector Ops",
            "type": "python",
            "request": "launch",
            "program": "${workspaceFolder}/src/test_vector_ops.py",
            "console": "integratedTerminal",
            "envFile": "${workspaceFolder}/.env"
        },
        {
            "name": "Python: pytest",
            "type": "python",
            "request": "launch",
            "module": "pytest",
            "args": ["-v", "--cov=src"],
            "console": "integratedTerminal",
            "envFile": "${workspaceFolder}/.env"
        }
    ]
}
```

### 6. Verify Installation

```bash
# Run health check
python3 scripts/db_health_check.py

# Expected output:
# ✓ Docker container 'ruvector-db' is running
# ✓ Environment variables configured
# ✓ Project database connected
# ✓ Shared database connected
# ✓ RuVector extension 2.0.0 installed

# Run tests
python3 src/test_vector_ops.py

# Expected output:
# test_store_and_retrieve: PASS
# test_search_by_embedding: PASS
# test_list_and_count: PASS
# test_delete_memory: PASS
# test_invalid_embedding_dimensions: PASS
```

## Architecture Overview

### Component Diagram

```
┌─────────────────────────────────────────────────┐
│           Application Layer                     │
│  (Your code using pools and vector_ops)        │
└─────────────────────┬───────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────┐
│         Database Layer (src/db/)                │
│  ┌────────────────┐      ┌──────────────────┐  │
│  │ pool.py        │◄────►│ vector_ops.py    │  │
│  │ - Connection   │      │ - CRUD ops       │  │
│  │ - Health check │      │ - Search         │  │
│  │ - Patroni HA   │      │ - Validation     │  │
│  └────────┬───────┘      └──────────────────┘  │
└───────────┼──────────────────────────────────────┘
            │
┌───────────▼──────────────────────────────────────┐
│      PostgreSQL with RuVector 2.0.0              │
│  ┌────────────────┐      ┌──────────────────┐   │
│  │ public schema  │      │ claude_flow      │   │
│  │ - memory_entry │      │ - embeddings     │   │
│  │ - patterns     │      │ - patterns       │   │
│  │ - trajectories │      │ - agents         │   │
│  └────────────────┘      └──────────────────┘   │
└──────────────────────────────────────────────────┘
```

### Database Architecture

#### Schema: `public`

Core tables with HNSW indexes:

```sql
-- Memory storage
memory_entries (
    id SERIAL,
    namespace VARCHAR(255),
    key VARCHAR(255),
    value TEXT,
    embedding ruvector(384),  -- HNSW indexed
    metadata JSONB,
    tags TEXT[],
    created_at TIMESTAMP,
    updated_at TIMESTAMP
)

-- HNSW index for fast similarity search
CREATE INDEX idx_memory_embedding ON memory_entries
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 16, ef_construction = 200);
```

#### Schema: `claude_flow`

CLI-compatible tables:

```sql
-- Vector embeddings
embeddings (
    id SERIAL,
    content TEXT,
    embedding ruvector(384),
    metadata JSONB
)

-- Pattern storage
patterns (
    id SERIAL,
    pattern_type VARCHAR(100),
    data JSONB
)
```

### Connection Pool Architecture

```python
# Dual pool design
DualDatabasePools
├── project_pool (40 connections)
│   ├── Used for: Application-specific data
│   └── Schema: public
└── shared_pool (15 connections)
    ├── Used for: Shared knowledge
    └── Schema: claude_flow
```

**Design Decisions:**

1. **Thread-safe**: Uses `psycopg2.pool.ThreadedConnectionPool`
2. **Context managers**: Automatic connection/transaction handling
3. **SSL/TLS support**: Configurable encryption
4. **Health checks**: Built-in connection monitoring
5. **Patroni ready**: Supports HA deployments

## Code Organization

```
Distributed-Postgress-Cluster/
├── src/                        # Source code
│   ├── db/                     # Database modules
│   │   ├── __init__.py        # Module exports
│   │   ├── pool.py            # Connection pools
│   │   ├── vector_ops.py      # Vector operations
│   │   └── patroni_pool.py    # HA connection pool
│   ├── test_vector_ops.py     # Integration tests
│   └── __init__.py
├── scripts/                    # Utility scripts
│   ├── sql/
│   │   └── init-ruvector.sql  # Schema initialization
│   ├── start_database.sh      # Database startup
│   ├── db_health_check.py     # Health monitoring
│   └── test_pool_capacity.py  # Load testing
├── docs/                       # Documentation
│   ├── architecture/          # Architecture docs
│   ├── planning/              # Project planning
│   ├── requirements/          # Requirements
│   ├── ERROR_HANDLING.md      # Error handling guide
│   └── POOL_CAPACITY.md       # Pool capacity docs
├── examples/                   # Code examples
├── deployment/                 # Deployment configs
├── .env                       # Environment config
├── .env.example               # Environment template
├── requirements.txt           # Dependencies
└── CONTRIBUTING.md            # Contributing guide
```

### Module Dependencies

```python
# Dependency graph
src/db/__init__.py
    └── Exports: get_pools, DualDatabasePools

src/db/pool.py
    ├── Imports: psycopg2, dotenv
    └── Exports: DualDatabasePools, get_pools

src/db/vector_ops.py
    ├── Imports: psycopg2
    └── Functions: store_memory, search_memory, retrieve_memory

src/db/patroni_pool.py
    ├── Imports: psycopg2, requests
    └── Exports: PatroniConnectionPool
```

## Local Development

### Development Workflow

```bash
# 1. Start development session
source venv/bin/activate
source .env  # Load environment variables

# 2. Start database
./scripts/start_database.sh

# 3. Run health check
python3 scripts/db_health_check.py

# 4. Make code changes
nano src/db/vector_ops.py

# 5. Run tests
python3 src/test_vector_ops.py

# 6. Format code
black src/
isort src/

# 7. Check style
flake8 src/
mypy src/

# 8. Commit changes
git add .
git commit -m "feat(vector): add new search feature"
```

### Hot Reload Development

For rapid development, use this pattern:

```python
# dev_test.py
import importlib
import sys

# Enable auto-reload
def reload_modules():
    if 'src.db.pool' in sys.modules:
        importlib.reload(sys.modules['src.db.pool'])
    if 'src.db.vector_ops' in sys.modules:
        importlib.reload(sys.modules['src.db.vector_ops'])

# Your test code
from src.db import get_pools
from src.db.vector_ops import store_memory

reload_modules()

pools = get_pools()
with pools.project_cursor() as cur:
    store_memory(cur, "test", "key", "value", embedding)
```

### Interactive Development

```bash
# Start Python REPL with environment
source .env
python3

>>> from src.db import get_pools
>>> pools = get_pools()
>>> pools.health_check()
{
    'mode': 'single-node',
    'project': {'status': 'healthy', ...},
    'shared': {'status': 'healthy', ...}
}

>>> from src.db.vector_ops import store_memory, search_memory
>>> import random
>>> embedding = [random.random() for _ in range(384)]
>>> with pools.project_cursor() as cur:
...     store_memory(cur, "test", "key1", "test value", embedding)
>>> with pools.project_cursor() as cur:
...     results = search_memory(cur, "test", embedding, limit=10)
>>> len(results)
1
```

## Testing

### Test Structure

```
src/
├── test_vector_ops.py          # Integration tests
└── tests/                       # Full test suite
    ├── unit/                    # Unit tests
    │   ├── test_pool.py        # Pool tests
    │   └── test_vector_ops.py  # Vector op tests
    ├── integration/             # Integration tests
    │   ├── test_end_to_end.py  # E2E tests
    │   └── test_patroni_ha.py  # HA tests
    └── performance/             # Performance tests
        └── test_benchmark.py    # Benchmarks
```

### Running Tests

```bash
# Run all tests
pytest

# Run specific test file
pytest src/test_vector_ops.py

# Run with coverage
pytest --cov=src --cov-report=html

# Run specific test function
pytest src/test_vector_ops.py::test_store_and_retrieve

# Run with verbose output
pytest -v

# Run only failed tests
pytest --lf

# Run tests matching pattern
pytest -k "search"
```

### Writing Tests

#### Unit Test Example

```python
# tests/unit/test_pool.py
import unittest
from unittest.mock import Mock, patch
from src.db.pool import DualDatabasePools, DatabaseConnectionError

class TestDatabasePools(unittest.TestCase):
    """Test suite for connection pools."""

    @patch.dict('os.environ', {
        'RUVECTOR_DB': 'test_db',
        'RUVECTOR_USER': 'test_user',
        'RUVECTOR_PASSWORD': 'test_pass',
        'SHARED_KNOWLEDGE_DB': 'shared_db',
        'SHARED_KNOWLEDGE_USER': 'shared_user',
        'SHARED_KNOWLEDGE_PASSWORD': 'shared_pass',
    })
    def test_pool_initialization(self):
        """Test that pools initialize correctly with env vars."""
        pools = DualDatabasePools()
        self.assertIsNotNone(pools.project_pool)
        self.assertIsNotNone(pools.shared_pool)

    def test_missing_env_vars_raises_error(self):
        """Test that missing env vars raise configuration error."""
        with patch.dict('os.environ', {}, clear=True):
            with self.assertRaises(DatabaseConfigurationError):
                DualDatabasePools()

if __name__ == '__main__':
    unittest.main()
```

#### Integration Test Example

```python
# tests/integration/test_end_to_end.py
import pytest
from src.db import get_pools
from src.db.vector_ops import store_memory, search_memory, retrieve_memory

@pytest.fixture
def pools():
    """Fixture to provide database pools."""
    pools = get_pools()
    yield pools
    pools.close()

@pytest.fixture
def sample_embedding():
    """Fixture to provide sample 384-dim embedding."""
    import random
    return [random.random() for _ in range(384)]

def test_complete_workflow(pools, sample_embedding):
    """Test complete workflow: store -> search -> retrieve."""
    namespace = "test_workflow"
    key = "test_key"
    value = "test value"

    # Store
    with pools.project_cursor() as cur:
        store_memory(cur, namespace, key, value, sample_embedding)

    # Search
    with pools.project_cursor() as cur:
        results = search_memory(cur, namespace, sample_embedding, limit=10)
        assert len(results) >= 1
        assert any(r['key'] == key for r in results)

    # Retrieve
    with pools.project_cursor() as cur:
        result = retrieve_memory(cur, namespace, key)
        assert result is not None
        assert result['value'] == value
```

### Performance Testing

```python
# tests/performance/test_benchmark.py
import time
import pytest
from src.db import get_pools
from src.db.vector_ops import search_memory

@pytest.mark.performance
def test_search_performance():
    """Test that vector search completes within 50ms."""
    pools = get_pools()
    embedding = [0.1] * 384

    # Warmup
    with pools.project_cursor() as cur:
        search_memory(cur, "test", embedding, limit=10)

    # Benchmark
    iterations = 100
    start = time.time()
    for _ in range(iterations):
        with pools.project_cursor() as cur:
            search_memory(cur, "test", embedding, limit=10)
    duration = (time.time() - start) / iterations * 1000

    assert duration < 50, f"Average search time: {duration:.2f}ms (max 50ms)"
    print(f"✓ Average search time: {duration:.2f}ms")
```

## Debugging

### Enable Debug Logging

```python
import logging

# Set logging level to DEBUG
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)

# Now all database operations will be logged
from src.db import get_pools
pools = get_pools()

# Output:
# 2026-02-12 10:00:00 - src.db.pool - INFO - Operating in single-node mode
# 2026-02-12 10:00:00 - src.db.pool - INFO - ✓ Project database pool initialized
```

### Using Python Debugger

```python
# Add breakpoint in code
def search_memory(cursor, namespace, embedding, limit=10):
    breakpoint()  # Execution will pause here
    cursor.execute(query, (namespace, limit))
    return cursor.fetchall()

# When script runs:
# (Pdb) p namespace
# 'test'
# (Pdb) p len(embedding)
# 384
# (Pdb) n  # Next line
# (Pdb) c  # Continue
```

### VSCode Debugging

1. Set breakpoint by clicking left of line number
2. Press F5 to start debugging
3. Use Debug Console to inspect variables

### Database Query Debugging

```sql
-- Enable query logging in PostgreSQL
ALTER SYSTEM SET log_statement = 'all';
SELECT pg_reload_conf();

-- View logs
docker exec ruvector-db tail -f /var/log/postgresql/postgresql-14-main.log

-- Explain query plan
EXPLAIN ANALYZE
SELECT *
FROM memory_entries
WHERE namespace = 'test'
    AND embedding IS NOT NULL
ORDER BY embedding <=> '[0.1,0.2,...]'::ruvector(384)
LIMIT 10;
```

### Connection Pool Debugging

```python
# Check pool status
pools = get_pools()

# Project pool status
print(f"Project pool - used: {pools.project_pool._used}")
print(f"Project pool - available: {len(pools.project_pool._pool)}")

# Shared pool status
print(f"Shared pool - used: {pools.shared_pool._used}")
print(f"Shared pool - available: {len(pools.shared_pool._pool)}")
```

## Common Development Tasks

### Adding a New Vector Operation

```python
# 1. Add function to src/db/vector_ops.py
def update_memory(
    cursor,
    namespace: str,
    key: str,
    value: str,
    embedding: Optional[List[float]] = None,
) -> bool:
    """Update an existing memory entry.

    Args:
        cursor: Database cursor
        namespace: Memory namespace
        key: Memory key
        value: New value
        embedding: Optional new embedding

    Returns:
        True if updated, False if not found

    Raises:
        VectorOperationError: If update fails
    """
    # Validation
    if not namespace or not key:
        raise ValueError("namespace and key required")

    embedding_str = None
    if embedding:
        if len(embedding) != 384:
            raise InvalidEmbeddingError(
                f"Expected 384 dims, got {len(embedding)}"
            )
        embedding_str = f"[{','.join(str(v) for v in embedding)}]"

    try:
        cursor.execute(
            """
            UPDATE memory_entries
            SET value = %s,
                embedding = COALESCE(%s::ruvector, embedding),
                updated_at = NOW()
            WHERE namespace = %s AND key = %s
            RETURNING id
            """,
            (value, embedding_str, namespace, key),
        )

        updated = cursor.fetchone() is not None
        if updated:
            logger.debug(f"Updated memory: {namespace}/{key}")
        return updated

    except DatabaseError as e:
        logger.error(f"Update failed: {e}")
        raise VectorOperationError(f"Update failed: {e}") from e

# 2. Add test to src/test_vector_ops.py
def test_update_memory(self):
    """Test updating existing memory."""
    with self.pools.project_cursor() as cur:
        # Store initial
        store_memory(cur, "test", "key1", "value1", self.embedding)

        # Update
        updated = update_memory(cur, "test", "key1", "value2")
        self.assertTrue(updated)

        # Verify
        result = retrieve_memory(cur, "test", "key1")
        self.assertEqual(result['value'], "value2")

# 3. Export from src/db/__init__.py
from .vector_ops import (
    store_memory,
    search_memory,
    retrieve_memory,
    update_memory,  # Add this
)

# 4. Add to examples/
# examples/update_memory.py
from src.db import get_pools, update_memory

pools = get_pools()

with pools.project_cursor() as cur:
    success = update_memory(
        cur,
        namespace="examples",
        key="doc1",
        value="Updated content"
    )
    print(f"Update {'succeeded' if success else 'failed'}")
```

### Adding Database Migration

```bash
# 1. Create migration SQL file
# scripts/sql/migrations/001_add_metadata_field.sql

-- Add new column
ALTER TABLE memory_entries
ADD COLUMN priority INTEGER DEFAULT 0;

-- Create index
CREATE INDEX idx_memory_priority
ON memory_entries (priority);

-- Update existing rows
UPDATE memory_entries
SET priority = 1
WHERE tags @> ARRAY['important'];

# 2. Create rollback SQL
# scripts/sql/migrations/001_add_metadata_field_rollback.sql

DROP INDEX IF EXISTS idx_memory_priority;
ALTER TABLE memory_entries DROP COLUMN IF EXISTS priority;

# 3. Apply migration
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster \
     -f scripts/sql/migrations/001_add_metadata_field.sql

# 4. Verify
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster \
     -c "\d memory_entries"
```

### Adding Health Check

```python
# Add to src/db/pool.py health_check method

def health_check(self) -> Dict[str, Any]:
    """Check health of both database connections."""
    results = {}

    # Existing checks...

    # Add new check
    try:
        with self.project_cursor() as cur:
            # Check connection pool capacity
            cur.execute("""
                SELECT count(*) as active_connections
                FROM pg_stat_activity
                WHERE datname = current_database()
            """)
            conn_count = cur.fetchone()['active_connections']

            results['project']['active_connections'] = conn_count
            results['project']['pool_capacity'] = 40
            results['project']['pool_utilization'] = f"{(conn_count/40)*100:.1f}%"
    except Exception as e:
        results['project']['connection_check'] = str(e)

    return results
```

## Performance Optimization

### Query Optimization

#### Use EXPLAIN ANALYZE

```sql
-- Bad query - sequential scan
SELECT * FROM memory_entries WHERE value LIKE '%search%';

-- Check execution plan
EXPLAIN ANALYZE
SELECT * FROM memory_entries WHERE value LIKE '%search%';

-- Output shows sequential scan - slow!

-- Good query - use full-text search
ALTER TABLE memory_entries ADD COLUMN value_tsv tsvector;
UPDATE memory_entries SET value_tsv = to_tsvector('english', value);
CREATE INDEX idx_memory_fts ON memory_entries USING gin(value_tsv);

SELECT * FROM memory_entries WHERE value_tsv @@ to_tsquery('search');
```

#### Optimize Vector Search

```python
# Configure HNSW parameters for your workload

# High accuracy, slower build
CREATE INDEX idx_memory_embedding ON memory_entries
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 32, ef_construction = 400);

# Fast build, lower accuracy
CREATE INDEX idx_memory_embedding ON memory_entries
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 8, ef_construction = 50);

# Balanced (recommended)
CREATE INDEX idx_memory_embedding ON memory_entries
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 16, ef_construction = 200);
```

### Connection Pool Tuning

```python
# Monitor pool usage
import time

def monitor_pool(pools, duration=60):
    """Monitor connection pool usage."""
    start = time.time()
    while time.time() - start < duration:
        project_used = pools.project_pool._used
        project_total = 40
        shared_used = pools.shared_pool._used
        shared_total = 15

        print(f"Project: {project_used}/{project_total} "
              f"({project_used/project_total*100:.1f}%)")
        print(f"Shared: {shared_used}/{shared_total} "
              f"({shared_used/shared_total*100:.1f}%)")
        time.sleep(5)

# If consistently hitting limits, increase pool size
# in src/db/pool.py
```

### Batch Operations

```python
# Bad - individual inserts
for i in range(1000):
    with pools.project_cursor() as cur:
        store_memory(cur, "test", f"key{i}", f"value{i}", embedding)
# Takes: ~10 seconds

# Good - batch insert
def batch_store_memories(cursor, entries):
    """Store multiple memories in one transaction."""
    query = """
        INSERT INTO memory_entries
            (namespace, key, value, embedding)
        VALUES (%s, %s, %s, %s::ruvector)
        ON CONFLICT (namespace, key) DO UPDATE
        SET value = EXCLUDED.value,
            embedding = EXCLUDED.embedding
    """

    data = [
        (e['namespace'], e['key'], e['value'],
         f"[{','.join(str(v) for v in e['embedding'])}]")
        for e in entries
    ]

    cursor.executemany(query, data)

with pools.project_cursor() as cur:
    batch_store_memories(cur, entries)
# Takes: ~0.5 seconds (20x faster!)
```

## Troubleshooting

See [TROUBLESHOOTING_DEVELOPER.md](TROUBLESHOOTING_DEVELOPER.md) for detailed troubleshooting guide.

### Quick Fixes

#### Database Won't Start

```bash
# Check if container exists
docker ps -a | grep ruvector-db

# If not running, start it
docker start ruvector-db

# If doesn't exist, create it
./scripts/start_database.sh

# Check logs
docker logs ruvector-db
```

#### Connection Errors

```bash
# Verify environment variables
source .env
echo $RUVECTOR_DB
echo $RUVECTOR_USER

# Test connection directly
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster -c "SELECT version()"

# Check connection pool health
python3 -c "from src.db import get_pools; print(get_pools().health_check())"
```

#### Tests Failing

```bash
# Reset database
docker stop ruvector-db
docker rm ruvector-db
./scripts/start_database.sh
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster -f scripts/sql/init-ruvector.sql

# Reinstall dependencies
pip install --force-reinstall -r requirements.txt

# Clear Python cache
find . -type d -name __pycache__ -exec rm -rf {} +
find . -type f -name "*.pyc" -delete

# Run tests
python3 src/test_vector_ops.py
```

## Additional Resources

- [API Reference](API_REFERENCE.md)
- [Contributing Guide](../CONTRIBUTING.md)
- [Error Handling Guide](ERROR_HANDLING.md)
- [Troubleshooting](TROUBLESHOOTING_DEVELOPER.md)
- [Examples](../examples/)

## Getting Help

- Check [docs/](.) directory for documentation
- Search [GitHub Issues](https://github.com/REPO/issues)
- Ask in [GitHub Discussions](https://github.com/REPO/discussions)

Happy coding!
