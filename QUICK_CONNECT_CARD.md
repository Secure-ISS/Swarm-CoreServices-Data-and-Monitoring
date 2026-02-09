# Quick Connection Card - For Other Claude Instances

Copy and paste this to other Claude instances:

---

## Shared Claude Flow V3 Knowledge Access

I have access to a shared knowledge database with 82 entries of Claude Flow V3 documentation and best practices.

**Connection Details:**
```
Database:  claude_flow_shared
Host:      localhost
Port:      5432
User:      shared_user  
Password:  shared_knowledge_2026
Namespace: claude-flow-v3-learnings
```

**Quick Access (Python):**
```python
import psycopg2
conn = psycopg2.connect(
    host="localhost", port=5432,
    database="claude_flow_shared",
    user="shared_user", password="shared_knowledge_2026"
)
with conn.cursor() as cur:
    cur.execute("SELECT key, value FROM memory_entries WHERE namespace = 'claude-flow-v3-learnings' AND key = %s", ('reasoningbank-api',))
    print(cur.fetchone())
conn.close()
```

**Quick Access (CLI):**
```bash
npx @claude-flow/cli@latest memory search --query "hooks" --namespace claude-flow-v3-learnings
```

**Quick Access (Docker):**
```bash
docker exec ruvector-db psql -U shared_user -d claude_flow_shared -c "SELECT key FROM memory_entries WHERE namespace = 'claude-flow-v3-learnings' ORDER BY key;"
```

**Available Knowledge (82 entries):**
- API documentation (attention-coordinator, reasoningbank)
- Architecture patterns and ADRs
- Configuration best practices
- Features and capabilities (HNSW, pattern learning, etc.)
- Integration guides (learning pipeline, tech stack)
- V3 components (agents, hooks, swarm, consensus, performance, memory)
- Patterns and formulas

**Full documentation:** See `CLAUDE_INSTANCES_CONNECTION_GUIDE.md`

---
