# Connection Guide for Claude Instances

## Overview

This guide provides connection instructions for Claude instances working on other projects to access the shared Claude Flow V3 knowledge database.

---

## Quick Reference Card

```
Database:  claude_flow_shared
Host:      localhost
Port:      5432
User:      shared_user
Password:  shared_knowledge_2026
Namespace: claude-flow-v3-learnings
Entries:   82 entries of Claude Flow V3 knowledge
```

---

## Method 1: Direct PostgreSQL Connection (Fastest)

### Via Python (psycopg2)

```python
import psycopg2
from psycopg2.extras import RealDictCursor

# Connect to shared knowledge database
conn = psycopg2.connect(
    host="localhost",
    port=5432,
    database="claude_flow_shared",
    user="shared_user",
    password="shared_knowledge_2026"
)

# Search for knowledge
with conn.cursor(cursor_factory=RealDictCursor) as cur:
    cur.execute("""
        SELECT key, value, metadata
        FROM memory_entries
        WHERE namespace = 'claude-flow-v3-learnings'
          AND value ILIKE %s
        ORDER BY key
        LIMIT 10
    """, ('%hooks%',))

    for row in cur.fetchall():
        print(f"{row['key']}: {row['value'][:100]}...")

conn.close()
```

### Via psql Command Line

```bash
# Connect to database
docker exec -it ruvector-db psql -U shared_user -d claude_flow_shared

# Or from host (if psql installed)
PGPASSWORD=shared_knowledge_2026 psql -h localhost -U shared_user -d claude_flow_shared
```

### Common SQL Queries

```sql
-- List all available knowledge keys
SELECT key, length(value) as size
FROM memory_entries
WHERE namespace = 'claude-flow-v3-learnings'
ORDER BY key;

-- Search for specific topic
SELECT key, value
FROM memory_entries
WHERE namespace = 'claude-flow-v3-learnings'
  AND (value ILIKE '%hooks%' OR key ILIKE '%hooks%')
ORDER BY key;

-- Get specific entry
SELECT key, value, metadata
FROM memory_entries
WHERE namespace = 'claude-flow-v3-learnings'
  AND key = 'reasoningbank-api';

-- Get all entries by category (from metadata)
SELECT key, value, metadata->>'_original_namespace' as category
FROM memory_entries
WHERE namespace = 'claude-flow-v3-learnings'
  AND metadata->>'_original_namespace' LIKE 'v3-hooks%'
ORDER BY key;

-- Vector similarity search (if you have embeddings)
SELECT key, value,
       1 - (embedding <=> '[your 384-dim embedding]'::ruvector) as similarity
FROM memory_entries
WHERE namespace = 'claude-flow-v3-learnings'
  AND embedding IS NOT NULL
ORDER BY embedding <=> '[your 384-dim embedding]'::ruvector
LIMIT 10;
```

---

## Method 2: Claude Flow CLI (Recommended)

### Installation

```bash
# Install globally
npm install -g @claude-flow/cli@latest

# Or use npx (no install needed)
npx @claude-flow/cli@latest --version
```

### Environment Setup

Create `.env` in your project:

```bash
# Shared Knowledge Database Access
RUVECTOR_HOST=localhost
RUVECTOR_PORT=5432
RUVECTOR_DB=claude_flow_shared
RUVECTOR_USER=shared_user
RUVECTOR_PASSWORD=shared_knowledge_2026
```

### CLI Commands

```bash
# List all available knowledge
npx @claude-flow/cli@latest memory list --namespace claude-flow-v3-learnings

# Search for specific topics
npx @claude-flow/cli@latest memory search --query "hooks" --namespace claude-flow-v3-learnings
npx @claude-flow/cli@latest memory search --query "agent types" --namespace claude-flow-v3-learnings
npx @claude-flow/cli@latest memory search --query "swarm coordination" --namespace claude-flow-v3-learnings

# Retrieve specific entries
npx @claude-flow/cli@latest memory retrieve --key "reasoningbank-api" --namespace claude-flow-v3-learnings
npx @claude-flow/cli@latest memory retrieve --key "learning-pipeline" --namespace claude-flow-v3-learnings
npx @claude-flow/cli@latest memory retrieve --key "hook-pre-task" --namespace claude-flow-v3-learnings

# Get memory statistics
npx @claude-flow/cli@latest memory stats
```

---

## Method 3: Python with RuVectorPool (If using QRadar codebase)

```python
import sys
import os

# Add QRadar project to path
sys.path.insert(0, '/home/matt/projects/QRadar-MCP-Server')

# Configure environment
os.environ['RUVECTOR_HOST'] = 'localhost'
os.environ['RUVECTOR_PORT'] = '5432'
os.environ['RUVECTOR_DB'] = 'claude_flow_shared'
os.environ['RUVECTOR_USER'] = 'shared_user'
os.environ['RUVECTOR_PASSWORD'] = 'shared_knowledge_2026'

from src.db.pg_pool import RuVectorPool

# Connect and query
pool = RuVectorPool()

with pool.cursor() as cur:
    # Get all knowledge keys
    cur.execute("""
        SELECT key FROM memory_entries
        WHERE namespace = 'claude-flow-v3-learnings'
        ORDER BY key
    """)

    keys = [row['key'] for row in cur.fetchall()]
    print(f"Available knowledge: {len(keys)} entries")
    for key in keys[:10]:
        print(f"  - {key}")

pool.close()
```

---

## Method 4: Docker Exec (Direct Access)

```bash
# Execute queries directly
docker exec ruvector-db psql -U shared_user -d claude_flow_shared -c "
SELECT key, substring(value, 1, 80) as preview
FROM memory_entries
WHERE namespace = 'claude-flow-v3-learnings'
ORDER BY key
LIMIT 5;
"

# Export all knowledge to JSON
docker exec ruvector-db psql -U shared_user -d claude_flow_shared -t -c "
SELECT json_agg(row_to_json(t))
FROM (
    SELECT key, value, metadata
    FROM memory_entries
    WHERE namespace = 'claude-flow-v3-learnings'
) t;
" > claude_flow_knowledge.json
```

---

## Available Knowledge Categories

The `claude-flow-v3-learnings` namespace contains 82 entries organized by category:

### API Documentation (2 entries)
- `attention-coordinator-api` - AttentionCoordinator API reference
- `reasoningbank-api` - ReasoningBank API reference

### Architecture (9 entries)
- `claude-flow-architecture` - Overall system architecture
- `v3-architecture` - V3 specific architecture
- `v3-adr-006-unified` - Architecture Decision Record #6
- `v3-adr-009-hybrid` - Architecture Decision Record #9
- etc.

### Configuration (6 entries)
- `config-embedding-generation` - How to generate embeddings
- `config-hnsw-params` - HNSW index parameters
- `config-memory-cli` - Memory CLI usage
- etc.

### Features (10 entries)
- `feature-hnsw-indexing` - HNSW vector indexing
- `feature-pattern-learning` - Pattern learning system
- `feature-session-persistence` - Cross-session memory
- etc.

### Integration (2 entries)
- `learning-pipeline` - 4-step learning pipeline (RETRIEVE, JUDGE, DISTILL, CONSOLIDATE)
- `v3-tech-stack` - Complete V3 technology stack

### V3 Components (48 entries)
- `v3-agents` (6) - Agent types and coordination
- `v3-hooks` (8) - Hook system documentation
- `v3-swarm` (6) - Swarm coordination patterns
- `v3-intelligence` (6) - RuVector intelligence
- `v3-consensus` (4) - Byzantine, Raft, CRDT, Gossip
- `v3-performance` (5) - Performance targets
- `v3-memory` (4) - Memory architecture
- etc.

### Patterns (1 entry)
- `review-quality-calculation` - Quality scoring formula

---

## Connection Verification

### Quick Test (Bash)

```bash
# Test connection
docker exec ruvector-db psql -U shared_user -d claude_flow_shared -c "SELECT COUNT(*) FROM memory_entries WHERE namespace = 'claude-flow-v3-learnings';"

# Expected output: 82
```

### Quick Test (Python)

```python
import psycopg2

try:
    conn = psycopg2.connect(
        host="localhost",
        port=5432,
        database="claude_flow_shared",
        user="shared_user",
        password="shared_knowledge_2026"
    )
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM memory_entries WHERE namespace = 'claude-flow-v3-learnings'")
        count = cur.fetchone()[0]
        print(f"✓ Connected successfully! Found {count} knowledge entries.")
    conn.close()
except Exception as e:
    print(f"✗ Connection failed: {e}")
```

---

## Example: Search for Hook Documentation

### Via SQL
```sql
SELECT key, value
FROM memory_entries
WHERE namespace = 'claude-flow-v3-learnings'
  AND key LIKE 'hook-%'
ORDER BY key;
```

### Via CLI
```bash
npx @claude-flow/cli@latest memory search --query "hook" --namespace claude-flow-v3-learnings
```

### Via Python
```python
import psycopg2
from psycopg2.extras import RealDictCursor

conn = psycopg2.connect(
    host="localhost", port=5432,
    database="claude_flow_shared",
    user="shared_user", password="shared_knowledge_2026"
)

with conn.cursor(cursor_factory=RealDictCursor) as cur:
    cur.execute("""
        SELECT key, value
        FROM memory_entries
        WHERE namespace = 'claude-flow-v3-learnings'
          AND key LIKE 'hook-%'
        ORDER BY key
    """)

    hooks = cur.fetchall()
    for hook in hooks:
        print(f"\n{hook['key']}:")
        print(f"{hook['value'][:200]}...")

conn.close()
```

---

## Security Notes

- **Read-Only Access:** The `shared_user` credentials provide read access to shared knowledge
- **No Write Access:** Cannot modify or delete shared knowledge (intentional)
- **Isolated Databases:** Other projects' operational data is in separate databases
- **Credentials:** Store in `.env` files (add to `.gitignore`)

---

## Troubleshooting

### Connection Refused
```bash
# Check if container is running
docker ps | grep ruvector

# Check PostgreSQL is listening
docker exec ruvector-db pg_isready
```

### Authentication Failed
```bash
# Verify user exists
docker exec ruvector-db psql -U qradar -d postgres -c "\du shared_user"

# Verify database exists
docker exec ruvector-db psql -U qradar -d postgres -c "\l claude_flow_shared"
```

### No Data Found
```bash
# Check namespace
docker exec ruvector-db psql -U shared_user -d claude_flow_shared -c "
SELECT DISTINCT namespace FROM memory_entries;
"

# Should return: claude-flow-v3-learnings
```

---

## For Claude Instances

### Quick Setup for New Project

1. **Add to your project's `.env`:**
   ```bash
   SHARED_KNOWLEDGE_DB=claude_flow_shared
   SHARED_KNOWLEDGE_USER=shared_user
   SHARED_KNOWLEDGE_PASSWORD=shared_knowledge_2026
   SHARED_KNOWLEDGE_NAMESPACE=claude-flow-v3-learnings
   ```

2. **Query from code:**
   ```python
   import os
   import psycopg2

   conn = psycopg2.connect(
       host="localhost",
       port=5432,
       database=os.getenv('SHARED_KNOWLEDGE_DB'),
       user=os.getenv('SHARED_KNOWLEDGE_USER'),
       password=os.getenv('SHARED_KNOWLEDGE_PASSWORD')
   )

   # Query shared knowledge
   with conn.cursor() as cur:
       cur.execute(
           "SELECT value FROM memory_entries WHERE namespace = %s AND key = %s",
           (os.getenv('SHARED_KNOWLEDGE_NAMESPACE'), 'reasoningbank-api')
       )
       knowledge = cur.fetchone()[0]
       print(knowledge)

   conn.close()
   ```

3. **Tell Claude:**
   > "I have access to a shared Claude Flow V3 knowledge database at localhost:5432/claude_flow_shared.
   > Use the connection details in `.env` to access 82 entries of Claude Flow documentation and best practices
   > in the 'claude-flow-v3-learnings' namespace."

---

## Summary

✅ **Database:** `claude_flow_shared`  
✅ **User:** `shared_user`  
✅ **Password:** `shared_knowledge_2026`  
✅ **Namespace:** `claude-flow-v3-learnings`  
✅ **Entries:** 82 knowledge entries  
✅ **Access Methods:** SQL, CLI, Python, Docker  

**Ready to access shared Claude Flow V3 knowledge from any project!**
