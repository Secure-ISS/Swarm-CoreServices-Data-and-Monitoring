# Claude Flow V3 Memory Access Guide

## Project: Distributed PostgreSQL Cluster

### Database Connection

**Shared PostgreSQL Database:**
- Host: localhost
- Port: 5432
- Database: qradar_vectors
- User: qradar
- Password: qradar_vectors_2026

**Project Namespace:** `distributed-postgres-cluster`

Configuration is in `.env` file.

### Access Shared Claude Flow Knowledge

The `claude-flow-v3-learnings` namespace contains 82 entries of shared Claude Flow V3 knowledge:

```bash
# List all shared knowledge
npx @claude-flow/cli@latest memory list --namespace claude-flow-v3-learnings

# Search shared knowledge
npx @claude-flow/cli@latest memory search --query "hooks" --namespace claude-flow-v3-learnings
npx @claude-flow/cli@latest memory search --query "agent types" --namespace claude-flow-v3-learnings

# Retrieve specific entry
npx @claude-flow/cli@latest memory retrieve --key "reasoningbank-api" --namespace claude-flow-v3-learnings
npx @claude-flow/cli@latest memory retrieve --key "learning-pipeline" --namespace claude-flow-v3-learnings
```

### Access Project-Specific Memory

This project stores its own memories in the `distributed-postgres-cluster` namespace:

```bash
# Store project-specific memory
npx @claude-flow/cli@latest memory store --key "cluster-config" --value "3-node setup" --namespace distributed-postgres-cluster

# Search project memories
npx @claude-flow/cli@latest memory search --query "cluster" --namespace distributed-postgres-cluster

# List all project memories
npx @claude-flow/cli@latest memory list --namespace distributed-postgres-cluster
```

### Quick Reference

**Shared Knowledge Categories:**
- API documentation (attention-coordinator, reasoningbank)
- Architecture patterns
- Configuration best practices
- Features and capabilities
- Integration guides
- RuVector intelligence
- V3 components (agents, hooks, swarm, etc.)

**Direct PostgreSQL Access:**

```sql
-- Connect to database
psql -h localhost -U qradar -d qradar_vectors

-- List project memories
SELECT key, value FROM memory_entries 
WHERE namespace = 'distributed-postgres-cluster' 
ORDER BY created_at DESC;

-- Access shared knowledge
SELECT key, value FROM memory_entries 
WHERE namespace = 'claude-flow-v3-learnings' 
ORDER BY key;
```

### System Status

```bash
# Check memory stats
npx @claude-flow/cli@latest memory stats

# Check swarm status
npx @claude-flow/cli@latest swarm status

# Check daemon status
npx @claude-flow/cli@latest daemon status

# View intelligence metrics
npx @claude-flow/cli@latest hooks metrics
```

### Next Steps

1. **Start developing** - Claude Flow is fully initialized
2. **Store learnings** - Save project-specific patterns as you work
3. **Access shared knowledge** - Reference claude-flow-v3-learnings for best practices
4. **Run health checks** - `npx @claude-flow/cli@latest doctor`
