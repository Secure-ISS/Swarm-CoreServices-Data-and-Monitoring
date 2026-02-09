# Memory Architecture - Understanding the Two Systems

**Date:** 2026-02-09
**Status:** ✅ All systems operational

---

## 🏗️ Two-Tier Memory Architecture

Your project uses **two separate but complementary memory systems**:

### 1. Claude Flow CLI Internal Memory (sql.js)
**Purpose:** CLI operations and command-line tooling
**Backend:** sql.js + HNSW (SQLite in WASM)
**Location:** `.claude-flow/data/`, `.swarm/memory.db`
**Used by:** `npx @claude-flow/cli@latest memory` commands

**Characteristics:**
- ✅ Lightweight and portable
- ✅ No external dependencies
- ✅ Good for CLI operations
- ⚠️ Limited to CLI scope
- ⚠️ Not shared across processes

### 2. PostgreSQL + RuVector Production Memory
**Purpose:** Production application data and vector operations
**Backend:** PostgreSQL 16 + RuVector 2.0.0
**Location:** Docker container `ruvector-db:5432`
**Used by:** Your application code via connection pools

**Characteristics:**
- ✅ Production-grade ACID compliance
- ✅ High-performance HNSW vector search (<2ms)
- ✅ Multi-database architecture (project + shared)
- ✅ Shared across all processes
- ✅ 82 shared knowledge entries
- ✅ Full CRUD operations with connection pooling

---

## 📊 Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    Your Application                          │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌────────────────┐              ┌────────────────────┐     │
│  │  CLI Commands  │              │  Application Code  │     │
│  │                │              │                    │     │
│  │  npx claude-   │              │  Python/Node.js    │     │
│  │  flow memory   │              │  with db/pool.py   │     │
│  └────────┬───────┘              └─────────┬──────────┘     │
│           │                                │                │
│           │                                │                │
│  ┌────────▼───────┐              ┌─────────▼──────────┐     │
│  │  sql.js WASM   │              │  PostgreSQL +      │     │
│  │  SQLite        │              │  RuVector 2.0.0    │     │
│  │                │              │                    │     │
│  │  For CLI ops   │              │  Production DB     │     │
│  └────────────────┘              │  - 5 HNSW indexes  │     │
│                                  │  - 1.84ms search   │     │
│                                  │  - 82 shared KB    │     │
│                                  └────────────────────┘     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## ✅ Current Status

### CLI Memory (sql.js)
```bash
$ npx @claude-flow/cli@latest memory stats

Backend: sql.js + HNSW ✅
Version: 3.0.0 ✅
Location: .claude-flow/data/ ✅
```

### Production Memory (PostgreSQL + RuVector)
```bash
$ python3 src/test_vector_ops.py

✅ Connection Health - Both databases healthy
✅ HNSW Indexes - 5 indexes operational
✅ Vector Storage & Retrieval - Working
✅ Vector Similarity Search - 1.84ms (27x faster!)
✅ Shared Knowledge Access - 82 entries
```

---

## 🚀 When to Use Which System

### Use CLI Memory (npx commands) for:
- ❌ **Don't use for production** - It's isolated to CLI scope
- ❌ **Don't use for application code** - Use PostgreSQL instead
- ✅ Quick CLI testing
- ✅ CLI-based automation

### Use PostgreSQL + RuVector for:
- ✅ **Production application code** (REQUIRED)
- ✅ **Vector similarity search** (1.84ms performance)
- ✅ **Multi-process data sharing**
- ✅ **ACID transactions**
- ✅ **Knowledge graph operations**
- ✅ **Pattern learning**
- ✅ **Cross-session persistence**

---

## 💻 How to Use PostgreSQL Memory (Production)

### Python Application Code

```python
from dotenv import load_dotenv
from db.pool import get_pools
from db.vector_ops import store_memory, search_memory

load_dotenv()
pools = get_pools()

# Store data
with pools.project_cursor() as cur:
    store_memory(
        cur,
        namespace="distributed-postgres-cluster",
        key="cluster-config-001",
        value="PostgreSQL cluster configuration",
        embedding=[0.1] * 384,  # 384-dim vector
        metadata={"type": "config", "version": "1.0"}
    )

# Search with HNSW (blazing fast!)
with pools.project_cursor() as cur:
    results = search_memory(
        cur,
        namespace="distributed-postgres-cluster",
        query_embedding=[0.1] * 384,
        limit=10,
        min_similarity=0.7
    )

    for result in results:
        print(f"{result['key']}: {result['similarity']:.4f}")
```

### Access Shared Knowledge

```python
# Query the 82 shared knowledge entries
with pools.shared_cursor() as cur:
    results = search_memory(
        cur,
        namespace="claude-flow-v3-learnings",
        query_embedding=your_embedding,
        limit=10
    )

    for result in results:
        print(f"Knowledge: {result['value']}")
```

---

## 🔧 Configuration Files

### YAML Config (Active)
**Location:** `.claude-flow/config.yaml`
**Format:** YAML
**Status:** ✅ Valid (no warnings)

Contains PostgreSQL connection settings:
```yaml
memory:
  backend: postgresql
  postgresql:
    project:
      host: localhost
      database: distributed_postgres_cluster
      user: dpg_cluster
    shared:
      host: localhost
      database: claude_flow_shared
      user: shared_user
```

### JSON Config (Backup)
**Location:** `claude-flow.config.json.backup`
**Status:** Renamed to backup (was causing warnings)

### Environment Variables
**Location:** `.env`
**Contains:**
- Project database credentials
- Shared database credentials
- Memory configuration

---

## 🎯 Key Takeaways

1. **CLI Memory is for CLI only** - Don't use it in production code
2. **PostgreSQL is your production memory** - Use connection pools
3. **Both systems work correctly** - They just serve different purposes
4. **No warnings anymore** - Configuration is clean ✅
5. **Vector operations tested** - All 5/5 tests passing ✅
6. **Performance excellent** - 1.84ms search (27x target) ✅

---

## 📝 Quick Reference

### Files to Use
✅ `src/db/pool.py` - Connection pools
✅ `src/db/vector_ops.py` - Vector operations
✅ `.claude-flow/config.yaml` - Configuration
✅ `.env` - Database credentials

### Files to Ignore
❌ `claude-flow.config.json.backup` - Old JSON config
❌ `.swarm/memory.db` - CLI internal database
❌ `.claude-flow/data/` - CLI data directory

### Commands for Production
```python
# Python application code
from db.pool import get_pools
pools = get_pools()
```

### Commands for CLI (Testing Only)
```bash
# CLI operations (isolated)
npx @claude-flow/cli@latest memory stats
```

---

## ✨ Summary

**Your production memory system (PostgreSQL + RuVector) is:**
- ✅ Fully operational
- ✅ Performance tested (1.84ms search)
- ✅ Connection pooled
- ✅ HNSW indexed
- ✅ Production ready

**The CLI memory (sql.js) is:**
- ✅ Working for CLI operations
- ⚠️ Not for production use
- ✅ No configuration warnings

**Use the PostgreSQL system via connection pools for all production code!**

---

**Last Updated:** 2026-02-09
**Configuration:** ✅ Valid (no warnings)
**Production System:** ✅ PostgreSQL + RuVector 2.0.0
**CLI System:** ✅ sql.js (for CLI only)
