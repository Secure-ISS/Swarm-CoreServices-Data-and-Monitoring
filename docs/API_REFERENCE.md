# API Reference

Complete reference for all Python APIs, database schemas, and CLI commands.

## Table of Contents

- [Python Client API](#python-client-api)
- [Database Schema](#database-schema)
- [RuVector Operations](#ruvector-operations)
- [SQL Functions](#sql-functions)
- [CLI Commands](#cli-commands)
- [Environment Variables](#environment-variables)

## Python Client API

### Connection Management

#### `DualDatabasePools`

Main class for managing database connections to both project and shared databases.

```python
from src.db import DualDatabasePools

class DualDatabasePools:
    """Manages connection pools for project and shared databases."""

    def __init__(self, enable_patroni: bool = None):
        """Initialize database pools.

        Args:
            enable_patroni: Enable Patroni HA mode. If None, auto-detect
                          from ENABLE_PATRONI environment variable.

        Raises:
            DatabaseConnectionError: If connection fails
            DatabaseConfigurationError: If config is invalid
        """

    def project_cursor(self, read_only: bool = False):
        """Get cursor from project database pool (context manager).

        Args:
            read_only: Route to replica if in Patroni mode

        Yields:
            psycopg2.extras.RealDictCursor

        Example:
            >>> pools = DualDatabasePools()
            >>> with pools.project_cursor() as cur:
            ...     cur.execute("SELECT * FROM memory_entries LIMIT 10")
            ...     results = cur.fetchall()
        """

    def shared_cursor(self, read_only: bool = False):
        """Get cursor from shared database pool (context manager).

        Args:
            read_only: Route to replica if in Patroni mode

        Yields:
            psycopg2.extras.RealDictCursor

        Example:
            >>> with pools.shared_cursor() as cur:
            ...     cur.execute("SELECT count(*) FROM embeddings")
            ...     count = cur.fetchone()['count']
        """

    def health_check(self) -> Dict[str, Any]:
        """Check health of database connections.

        Returns:
            Dict with health status for both databases

        Example:
            >>> health = pools.health_check()
            >>> print(health['project']['status'])
            'healthy'
        """

    def close(self):
        """Close all pool connections."""
```

#### Helper Functions

```python
def get_pools() -> DualDatabasePools:
    """Get or create global database pools instance (singleton).

    Returns:
        DualDatabasePools instance

    Example:
        >>> from src.db import get_pools
        >>> pools = get_pools()
        >>> with pools.project_cursor() as cur:
        ...     # Use cursor
    """

def close_pools():
    """Close all database pools and reset singleton."""
```

### Vector Operations

#### `store_memory`

```python
def store_memory(
    cursor,
    namespace: str,
    key: str,
    value: str,
    embedding: Optional[List[float]] = None,
    metadata: Optional[Dict] = None,
    tags: Optional[List[str]] = None,
) -> None:
    """Store memory entry with optional vector embedding.

    Performs INSERT ... ON CONFLICT UPDATE to upsert entries.

    Args:
        cursor: Database cursor from pool.project_cursor()
        namespace: Namespace for organizing memories (e.g., "user_prefs")
        key: Unique key within namespace (e.g., "user_123")
        value: Content to store (text)
        embedding: Optional 384-dimensional vector [0.1, 0.2, ...]
        metadata: Optional JSON metadata {"source": "api", "version": 1}
        tags: Optional tags ["important", "archived"]

    Raises:
        ValueError: If namespace/key/value is empty
        InvalidEmbeddingError: If embedding dimensions != 384
        VectorOperationError: If database operation fails

    Example:
        >>> from src.db import get_pools
        >>> from src.db.vector_ops import store_memory
        >>> import random
        >>>
        >>> pools = get_pools()
        >>> embedding = [random.random() for _ in range(384)]
        >>> metadata = {"source": "api", "confidence": 0.95}
        >>> tags = ["important"]
        >>>
        >>> with pools.project_cursor() as cur:
        ...     store_memory(
        ...         cur,
        ...         namespace="docs",
        ...         key="doc_123",
        ...         value="Document content here",
        ...         embedding=embedding,
        ...         metadata=metadata,
        ...         tags=tags
        ...     )
    """
```

#### `search_memory`

```python
def search_memory(
    cursor,
    namespace: str,
    query_embedding: List[float],
    limit: int = 10,
    min_similarity: float = 0.7,
) -> List[Dict[str, Any]]:
    """Search memories by vector similarity using HNSW index.

    Uses cosine distance via RuVector's <=> operator with HNSW index
    for fast approximate nearest neighbor search.

    Args:
        cursor: Database cursor
        namespace: Namespace to search within
        query_embedding: 384-dimensional query vector
        limit: Maximum results to return (1-1000)
        min_similarity: Minimum cosine similarity threshold (0-1)

    Returns:
        List of dicts with keys:
            - namespace: str
            - key: str
            - value: str
            - metadata: dict
            - tags: List[str]
            - similarity: float (0-1, higher is more similar)
            - created_at: datetime

    Raises:
        ValueError: If namespace empty or limit/similarity out of range
        InvalidEmbeddingError: If query_embedding dimensions != 384
        VectorOperationError: If search operation fails

    Performance:
        Typical: <5ms for 100K entries
        HNSW index parameters: m=16, ef_construction=200

    Example:
        >>> import random
        >>> query = [random.random() for _ in range(384)]
        >>>
        >>> with pools.project_cursor() as cur:
        ...     results = search_memory(
        ...         cur,
        ...         namespace="docs",
        ...         query_embedding=query,
        ...         limit=5,
        ...         min_similarity=0.8
        ...     )
        ...
        >>> for result in results:
        ...     print(f"{result['key']}: {result['similarity']:.3f}")
        doc_123: 0.925
        doc_456: 0.847
    """
```

#### `retrieve_memory`

```python
def retrieve_memory(
    cursor,
    namespace: str,
    key: str,
) -> Optional[Dict[str, Any]]:
    """Retrieve specific memory entry by namespace and key.

    Args:
        cursor: Database cursor
        namespace: Memory namespace
        key: Memory key

    Returns:
        Dict with memory data if found, None if not found:
            - namespace: str
            - key: str
            - value: str
            - metadata: dict
            - tags: List[str]
            - created_at: datetime
            - updated_at: datetime

    Raises:
        ValueError: If namespace or key is empty
        VectorOperationError: If database operation fails

    Example:
        >>> with pools.project_cursor() as cur:
        ...     memory = retrieve_memory(cur, "docs", "doc_123")
        ...     if memory:
        ...         print(f"Value: {memory['value']}")
        ...         print(f"Tags: {memory['tags']}")
    """
```

#### `list_memories`

```python
def list_memories(
    cursor,
    namespace: str,
    limit: int = 100,
    offset: int = 0,
) -> List[Dict[str, Any]]:
    """List memory entries in a namespace (paginated).

    Args:
        cursor: Database cursor
        namespace: Namespace to list
        limit: Maximum entries to return (default 100)
        offset: Offset for pagination (default 0)

    Returns:
        List of memory entry dicts (ordered by created_at DESC)

    Example:
        >>> # Get first page
        >>> with pools.project_cursor() as cur:
        ...     page1 = list_memories(cur, "docs", limit=10, offset=0)
        ...
        >>> # Get second page
        >>> with pools.project_cursor() as cur:
        ...     page2 = list_memories(cur, "docs", limit=10, offset=10)
    """
```

#### `delete_memory`

```python
def delete_memory(
    cursor,
    namespace: str,
    key: str,
) -> bool:
    """Delete a memory entry.

    Args:
        cursor: Database cursor
        namespace: Memory namespace
        key: Memory key

    Returns:
        True if deleted, False if not found

    Raises:
        ValueError: If namespace or key is empty
        VectorOperationError: If database operation fails

    Example:
        >>> with pools.project_cursor() as cur:
        ...     deleted = delete_memory(cur, "docs", "doc_123")
        ...     print(f"Deleted: {deleted}")
        Deleted: True
    """
```

#### `count_memories`

```python
def count_memories(
    cursor,
    namespace: Optional[str] = None,
) -> int:
    """Count memory entries, optionally filtered by namespace.

    Args:
        cursor: Database cursor
        namespace: Optional namespace filter (None = count all)

    Returns:
        Count of matching entries

    Example:
        >>> with pools.project_cursor() as cur:
        ...     total = count_memories(cur)
        ...     docs_count = count_memories(cur, "docs")
        ...     print(f"Total: {total}, Docs: {docs_count}")
    """
```

### Exceptions

```python
class DatabaseConnectionError(Exception):
    """Raised when database connection fails.

    Example:
        >>> try:
        ...     pools = DualDatabasePools()
        ... except DatabaseConnectionError as e:
        ...     print(f"Cannot connect: {e}")
        ...     # Check if database is running
    """

class DatabaseConfigurationError(Exception):
    """Raised when database configuration is invalid.

    Example:
        >>> try:
        ...     pools = DualDatabasePools()
        ... except DatabaseConfigurationError as e:
        ...     print(f"Config error: {e}")
        ...     # Check .env file
    """

class VectorOperationError(Exception):
    """Raised when vector operation fails.

    Example:
        >>> try:
        ...     results = search_memory(cur, "test", embedding)
        ... except VectorOperationError as e:
        ...     print(f"Search failed: {e}")
    """

class InvalidEmbeddingError(Exception):
    """Raised when embedding dimensions are invalid.

    Example:
        >>> try:
        ...     store_memory(cur, "test", "key", "value", [0.1] * 512)
        ... except InvalidEmbeddingError as e:
        ...     print(f"Wrong dimensions: {e}")
        ...     # Must be 384 dimensions
    """
```

## Database Schema

### Table: `memory_entries` (public schema)

Primary table for storing memories with vector embeddings.

```sql
CREATE TABLE memory_entries (
    id SERIAL PRIMARY KEY,
    namespace VARCHAR(255) NOT NULL,
    key VARCHAR(255) NOT NULL,
    value TEXT NOT NULL,
    embedding ruvector(384),  -- RuVector 384-dimensional vector
    metadata JSONB DEFAULT '{}'::jsonb,
    tags TEXT[],
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    CONSTRAINT uq_memory_namespace_key UNIQUE (namespace, key)
);

-- HNSW index for fast similarity search
CREATE INDEX idx_memory_embedding ON memory_entries
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 16, ef_construction = 200);

-- Standard indexes
CREATE INDEX idx_memory_namespace ON memory_entries (namespace);
CREATE INDEX idx_memory_created ON memory_entries (created_at DESC);
CREATE INDEX idx_memory_tags ON memory_entries USING gin (tags);
```

**Columns:**

| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL | Auto-incrementing primary key |
| `namespace` | VARCHAR(255) | Logical grouping (e.g., "user_prefs", "docs") |
| `key` | VARCHAR(255) | Unique identifier within namespace |
| `value` | TEXT | The content being stored |
| `embedding` | ruvector(384) | 384-dim vector for similarity search |
| `metadata` | JSONB | Flexible JSON metadata |
| `tags` | TEXT[] | Array of tag strings |
| `created_at` | TIMESTAMP | Creation time |
| `updated_at` | TIMESTAMP | Last update time |

**Indexes:**

- **Primary Key**: `(id)`
- **Unique**: `(namespace, key)` - prevents duplicates
- **HNSW**: `(embedding)` - fast vector similarity search
- **B-tree**: `(namespace)` - namespace filtering
- **B-tree**: `(created_at DESC)` - time-based queries
- **GIN**: `(tags)` - tag containment queries

### Table: `patterns` (public schema)

```sql
CREATE TABLE patterns (
    id SERIAL PRIMARY KEY,
    pattern_type VARCHAR(100) NOT NULL,
    pattern_name VARCHAR(255) NOT NULL,
    pattern_data JSONB NOT NULL,
    embedding ruvector(384),
    usage_count INTEGER DEFAULT 0,
    success_rate FLOAT DEFAULT 0.0,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_patterns_type ON patterns (pattern_type);
CREATE INDEX idx_patterns_name ON patterns (pattern_name);
CREATE INDEX idx_patterns_embedding ON patterns
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 16, ef_construction = 200);
```

### Table: `embeddings` (claude_flow schema)

```sql
CREATE TABLE claude_flow.embeddings (
    id SERIAL PRIMARY KEY,
    content TEXT NOT NULL,
    embedding ruvector(384),
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_cf_embeddings ON claude_flow.embeddings
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 16, ef_construction = 200);
```

## RuVector Operations

### Vector Type

```sql
-- RuVector type: ruvector(N) where N is dimensions
-- For this project: ruvector(384)

-- Create vector from array
SELECT '[0.1, 0.2, 0.3]'::ruvector(3);

-- Create vector from string
SELECT '0.1,0.2,0.3'::ruvector(3);
```

### Distance Operators

```sql
-- Cosine distance (0 = identical, 2 = opposite)
-- Used by HNSW index for fast ANN search
SELECT embedding <=> '[0.1, 0.2, ...]'::ruvector(384)
FROM memory_entries;

-- L2 (Euclidean) distance
SELECT embedding <-> '[0.1, 0.2, ...]'::ruvector(384)
FROM memory_entries;

-- Inner product (negative)
SELECT embedding <#> '[0.1, 0.2, ...]'::ruvector(384)
FROM memory_entries;
```

### Similarity Search Query

```sql
-- Find top 10 most similar vectors using HNSW index
-- Converts distance to similarity: similarity = 1 - distance
SELECT
    namespace,
    key,
    value,
    1 - (embedding <=> '[0.1,0.2,...]'::ruvector(384)) as similarity
FROM memory_entries
WHERE namespace = 'docs'
  AND embedding IS NOT NULL
  AND (1 - (embedding <=> '[0.1,0.2,...]'::ruvector(384))) >= 0.7
ORDER BY embedding <=> '[0.1,0.2,...]'::ruvector(384)
LIMIT 10;
```

### Index Management

```sql
-- Create HNSW index
CREATE INDEX idx_memory_embedding ON memory_entries
USING hnsw (embedding ruvector_cosine_ops)
WITH (
    m = 16,              -- Max connections per layer (higher = more accurate, slower)
    ef_construction = 200 -- Build quality (higher = better index, slower build)
);

-- Drop index
DROP INDEX idx_memory_embedding;

-- Rebuild index
REINDEX INDEX idx_memory_embedding;

-- Check index size
SELECT pg_size_pretty(pg_relation_size('idx_memory_embedding'));
```

### HNSW Parameters

| Parameter | Description | Recommended Values |
|-----------|-------------|-------------------|
| `m` | Max connections per layer | 8 (fast), 16 (balanced), 32 (accurate) |
| `ef_construction` | Build quality | 50 (fast), 200 (balanced), 400 (accurate) |

**Performance Impact:**

- **m=16, ef_construction=200**: Balanced (recommended)
  - Build time: ~1-2 seconds per 10K vectors
  - Search time: <5ms
  - Recall: >95%

## SQL Functions

### Search Function

```sql
-- Search with filters
CREATE OR REPLACE FUNCTION search_memories(
    p_namespace VARCHAR,
    p_query_embedding ruvector,
    p_limit INTEGER DEFAULT 10,
    p_min_similarity FLOAT DEFAULT 0.7,
    p_tags TEXT[] DEFAULT NULL
) RETURNS TABLE (
    namespace VARCHAR,
    key VARCHAR,
    value TEXT,
    similarity FLOAT,
    metadata JSONB,
    tags TEXT[]
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        m.namespace,
        m.key,
        m.value,
        (1 - (m.embedding <=> p_query_embedding))::FLOAT as similarity,
        m.metadata,
        m.tags
    FROM memory_entries m
    WHERE m.namespace = p_namespace
      AND m.embedding IS NOT NULL
      AND (1 - (m.embedding <=> p_query_embedding)) >= p_min_similarity
      AND (p_tags IS NULL OR m.tags @> p_tags)
    ORDER BY m.embedding <=> p_query_embedding
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- Usage
SELECT * FROM search_memories(
    'docs',
    '[0.1,0.2,...]'::ruvector(384),
    10,
    0.8,
    ARRAY['important']
);
```

### Batch Insert Function

```sql
CREATE OR REPLACE FUNCTION batch_store_memories(
    entries JSONB
) RETURNS INTEGER AS $$
DECLARE
    entry JSONB;
    inserted_count INTEGER := 0;
BEGIN
    FOR entry IN SELECT * FROM jsonb_array_elements(entries)
    LOOP
        INSERT INTO memory_entries (namespace, key, value, embedding, metadata, tags)
        VALUES (
            entry->>'namespace',
            entry->>'key',
            entry->>'value',
            (entry->>'embedding')::ruvector(384),
            (entry->'metadata')::jsonb,
            ARRAY(SELECT jsonb_array_elements_text(entry->'tags'))
        )
        ON CONFLICT (namespace, key) DO UPDATE
        SET value = EXCLUDED.value,
            embedding = EXCLUDED.embedding,
            metadata = EXCLUDED.metadata,
            tags = EXCLUDED.tags,
            updated_at = NOW();

        inserted_count := inserted_count + 1;
    END LOOP;

    RETURN inserted_count;
END;
$$ LANGUAGE plpgsql;
```

## CLI Commands

### Database Management

```bash
# Start database
./scripts/start_database.sh

# Health check
python3 scripts/db_health_check.py

# Initialize schema
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster \
     -f scripts/sql/init-ruvector.sql
```

### RuVector CLI

```bash
# Check RuVector status
npx @claude-flow/cli@latest ruvector status

# Setup schema
npx @claude-flow/cli@latest ruvector setup --password PASSWORD

# Benchmark
npx @claude-flow/cli@latest ruvector benchmark --vectors 10000
```

### Memory CLI

```bash
# Store memory
npx @claude-flow/cli@latest memory store \
    --key "test-key" \
    --value "test value" \
    --namespace "test"

# Search memory
npx @claude-flow/cli@latest memory search \
    --query "search terms" \
    --namespace "test" \
    --limit 10

# List memories
npx @claude-flow/cli@latest memory list --namespace "test"

# Retrieve specific memory
npx @claude-flow/cli@latest memory retrieve \
    --key "test-key" \
    --namespace "test"
```

## Environment Variables

### Required Variables

```bash
# Project Database
RUVECTOR_HOST=localhost
RUVECTOR_PORT=5432
RUVECTOR_DB=distributed_postgres_cluster
RUVECTOR_USER=dpg_cluster
RUVECTOR_PASSWORD=dpg_cluster_2026

# Shared Database
SHARED_KNOWLEDGE_HOST=localhost
SHARED_KNOWLEDGE_PORT=5432
SHARED_KNOWLEDGE_DB=claude_flow_shared
SHARED_KNOWLEDGE_USER=shared_user
SHARED_KNOWLEDGE_PASSWORD=shared_knowledge_2026
```

### Optional Variables

```bash
# SSL/TLS Configuration
RUVECTOR_SSLMODE=prefer  # disable, allow, prefer, require, verify-ca, verify-full
RUVECTOR_SSLROOTCERT=/path/to/ca-cert.pem
RUVECTOR_SSLCERT=/path/to/client-cert.pem
RUVECTOR_SSLKEY=/path/to/client-key.pem

# Shared DB SSL
SHARED_KNOWLEDGE_SSLMODE=prefer
SHARED_KNOWLEDGE_SSLROOTCERT=/path/to/ca-cert.pem
SHARED_KNOWLEDGE_SSLCERT=/path/to/client-cert.pem
SHARED_KNOWLEDGE_SSLKEY=/path/to/client-key.pem

# Connection Pooling
PROJECT_POOL_MIN=2
PROJECT_POOL_MAX=40
SHARED_POOL_MIN=1
SHARED_POOL_MAX=15

# Patroni HA
ENABLE_PATRONI=false
PATRONI_ENDPOINTS=node1:8008,node2:8008,node3:8008

# Logging
LOG_LEVEL=INFO  # DEBUG, INFO, WARNING, ERROR
```

## Usage Examples

See [examples/](../examples/) directory for complete examples:

- [examples/basic_usage.py](../examples/basic_usage.py) - Basic CRUD operations
- [examples/vector_search.py](../examples/vector_search.py) - Vector similarity search
- [examples/batch_operations.py](../examples/batch_operations.py) - Batch inserts
- [examples/connection_pooling.py](../examples/connection_pooling.py) - Pool management

## Performance Benchmarks

| Operation | Latency | Throughput |
|-----------|---------|------------|
| Store (no vector) | <1ms | 10,000+ ops/s |
| Store (with vector) | 1-2ms | 5,000+ ops/s |
| Retrieve by key | <1ms | 20,000+ ops/s |
| Vector search (10K entries) | <5ms | 200+ searches/s |
| Vector search (100K entries) | 5-10ms | 100+ searches/s |
| Batch insert (100 items) | 10-20ms | 5,000+ items/s |

**Test Environment:**
- PostgreSQL 14 on Docker
- RuVector 2.0.0
- HNSW index: m=16, ef_construction=200
- Connection pool: 40 connections

## Support

- [Developer Guide](DEVELOPER_GUIDE.md)
- [Troubleshooting](TROUBLESHOOTING_DEVELOPER.md)
- [Error Handling](ERROR_HANDLING.md)
- [GitHub Issues](https://github.com/REPO/issues)
