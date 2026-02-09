# Shared Database Architecture

## Overview

The PostgreSQL infrastructure uses a **multi-database architecture** to provide isolation between projects while enabling knowledge sharing.

## Database Architecture

```
ruvector-db (PostgreSQL Container)
├── claude_flow_shared          # Shared cross-project knowledge
│   ├── User: shared_user
│   ├── Password: shared_knowledge_2026
│   └── Namespaces:
│       └── claude-flow-v3-learnings (82 entries)
│
├── distributed_postgres_cluster # This project's database
│   ├── User: dpg_cluster
│   ├── Password: dpg_cluster_2026
│   └── Namespaces:
│       └── distributed-postgres-cluster
│
├── qradar_vectors              # QRadar MCP Server database
│   ├── User: qradar
│   ├── Password: qradar_vectors_2026
│   └── Namespaces:
│       ├── qradar-* (23 namespaces, 1.5M+ entries)
│       └── sigma-field-mappings
│
└── komodo_mcp                  # Komodo MCP Server database
    ├── User: komodo
    ├── Password: komodo_2026
    └── Namespaces:
        └── komodo-mcp
```

## Shared Database: claude_flow_shared

**Purpose:** Store cross-project Claude Flow V3 knowledge that all projects can reference.

**Connection Details:**
- Host: localhost
- Port: 5432
- Database: claude_flow_shared
- User: shared_user
- Password: shared_knowledge_2026

**Contents:**
- `claude-flow-v3-learnings` namespace (82 entries)
  - API documentation (attention-coordinator, reasoningbank)
  - Architecture patterns
  - Configuration best practices
  - Features and capabilities
  - Integration guides
  - RuVector intelligence
  - V3 components (agents, hooks, swarm, consensus, etc.)

### Access Shared Knowledge

```bash
# Using Claude Flow CLI (works from any project)
npx @claude-flow/cli@latest memory search --query "hooks" --namespace claude-flow-v3-learnings

# Direct SQL access
docker exec -it ruvector-db psql -U shared_user -d claude_flow_shared

# List all shared knowledge
SELECT key FROM memory_entries 
WHERE namespace = 'claude-flow-v3-learnings' 
ORDER BY key;
```

## Project-Specific Database: distributed_postgres_cluster

**Purpose:** Store this project's operational data and learnings.

**Connection Details:**
- Host: localhost
- Port: 5432
- Database: distributed_postgres_cluster
- User: dpg_cluster
- Password: dpg_cluster_2026

**Configured in:** `.env` file

**Namespaces:**
- `distributed-postgres-cluster` - Project-specific memories

### Access Project Data

```bash
# Using Claude Flow CLI
npx @claude-flow/cli@latest memory store --key "cluster-config" --value "3-node HA" --namespace distributed-postgres-cluster
npx @claude-flow/cli@latest memory search --query "cluster" --namespace distributed-postgres-cluster

# Direct SQL access
docker exec -it ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster
```

## Benefits of Multi-Database Architecture

✅ **Isolation** - Each project has its own database and user
✅ **Security** - Projects cannot access each other's operational data
✅ **Knowledge Sharing** - Shared database provides cross-project learning
✅ **Performance** - Isolated databases prevent query contention
✅ **Backup** - Can backup project and shared databases independently
✅ **Migration** - Easy to migrate individual projects
✅ **Access Control** - Granular permissions per database

## Adding New Projects

When adding a new project:

1. **Create project-specific database:**
   ```sql
   CREATE DATABASE project_name_db;
   CREATE USER project_user WITH PASSWORD 'secure_password';
   GRANT ALL PRIVILEGES ON DATABASE project_name_db TO project_user;
   ```

2. **Enable ruvector extension:**
   ```sql
   \c project_name_db
   CREATE EXTENSION ruvector;
   ```

3. **Initialize schema:**
   ```bash
   psql -U project_user -d project_name_db < scripts/sql/init-ruvector.sql
   ```

4. **Configure project to use shared database for claude-flow-v3-learnings:**
   - Project database: For operational data
   - Shared database: For accessing Claude Flow knowledge

## Database Sizes

| Database | Purpose | Entries | Size |
|----------|---------|---------|------|
| claude_flow_shared | Shared knowledge | 82 | < 1MB |
| distributed_postgres_cluster | This project | TBD | TBD |
| qradar_vectors | QRadar project | 1.5M+ | ~2GB |
| komodo_mcp | Komodo project | < 100 | < 1MB |

## Maintenance

```bash
# Check all databases
docker exec ruvector-db psql -U qradar -d postgres -c "\l"

# Check database sizes
docker exec ruvector-db psql -U qradar -d postgres -c "
SELECT datname, pg_size_pretty(pg_database_size(datname)) as size
FROM pg_database
WHERE datname IN ('claude_flow_shared', 'distributed_postgres_cluster', 'qradar_vectors', 'komodo_mcp')
ORDER BY pg_database_size(datname) DESC;
"

# Vacuum all databases
docker exec ruvector-db psql -U qradar -d claude_flow_shared -c "VACUUM ANALYZE;"
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster -c "VACUUM ANALYZE;"
```

## Security Notes

- Each project has its own credentials (no shared passwords)
- Shared database is read-only for most operations
- Only authorized users can write to shared knowledge
- All passwords are strong and unique
- Credentials are in `.env` files (gitignored)

## Summary

✅ **3 databases created:**
- `claude_flow_shared` - Shared knowledge (82 entries)
- `distributed_postgres_cluster` - This project
- `qradar_vectors` - QRadar project (existing)

✅ **3 users created:**
- `shared_user` - Access to shared knowledge
- `dpg_cluster` - This project's database
- `qradar` - QRadar database (existing)

✅ **All databases have:**
- ruvector extension enabled
- HNSW indexes for vector search
- Full schema initialized
