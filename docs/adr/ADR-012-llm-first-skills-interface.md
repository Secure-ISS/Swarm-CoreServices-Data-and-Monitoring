# ADR-012: LLM-First Skills and Interface Design

**Status**: Accepted
**Date**: 2026-02-11
**Decision Makers**: System Architecture Team
**Related ADRs**: ADR-011 (Lazy Loading), ADR-006 (Unified Memory)

## Context

The Distributed PostgreSQL Cluster is a sophisticated system with complex operations:
- Vector database management with RuVector
- HNSW index optimization
- Connection pool management
- Health monitoring and alerting
- Performance benchmarking
- Security auditing

**Problem**: Currently, these operations require:
1. Deep PostgreSQL expertise
2. Manual intervention for maintenance
3. Human understanding of system state
4. Custom scripts for each operation
5. Context switching between different tools

**Opportunity**: LLMs like Claude can manage and maintain database systems autonomously if provided with the right interfaces.

## Decision

We adopt an **LLM-First Design Philosophy**: Build Claude Code Skills alongside every system feature to enable autonomous LLM operation and maintenance.

### Core Principles

1. **Skills-First Development**: For every feature implemented, create a corresponding Claude Code Skill
2. **Autonomous Operation**: LLMs should be able to operate the system without human intervention
3. **Self-Maintenance**: LLMs should be able to diagnose and fix issues
4. **Progressive Disclosure**: Skills provide simple interfaces that hide complexity
5. **Learning System**: Skills should learn from operations and improve over time

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Claude Code (LLM)                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │   Cluster    │  │   Vector     │  │  Monitoring  │    │
│  │    Skill     │  │    Skill     │  │    Skill     │    │
│  └──────────────┘  └──────────────┘  └──────────────┘    │
│         │                  │                  │            │
├─────────────────────────────────────────────────────────────┤
│                   Skill Execution Layer                     │
│  (Context-aware, Learning-enabled, Self-documenting)        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │   Database   │  │    HNSW      │  │    Health    │    │
│  │    Pools     │  │   Indexes    │  │   Checks     │    │
│  └──────────────┘  └──────────────┘  └──────────────┘    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
                   PostgreSQL Cluster
```

## Implementation

### 1. Skill Taxonomy

Create skills in categories:

**Operations Skills** (`/skills/operations/`)
- `cluster-status` - Check cluster health and state
- `cluster-backup` - Backup databases and restore
- `cluster-scale` - Scale up/down connection pools
- `cluster-failover` - Handle node failures

**Vector Database Skills** (`/skills/vector/`)
- `vector-search` - Semantic search across memories
- `vector-insert` - Bulk insert with optimization
- `vector-index` - Manage HNSW indexes
- `vector-benchmark` - Performance testing

**Maintenance Skills** (`/skills/maintenance/`)
- `maintenance-optimize` - Query and index optimization
- `maintenance-vacuum` - Database cleanup
- `maintenance-analyze` - Statistics update
- `maintenance-reindex` - Rebuild indexes

**Monitoring Skills** (`/skills/monitoring/`)
- `monitoring-health` - Real-time health checks
- `monitoring-performance` - Performance metrics
- `monitoring-alerts` - Alert configuration
- `monitoring-logs` - Log analysis

**Security Skills** (`/skills/security/`)
- `security-audit` - Security scanning
- `security-rotate` - Credential rotation
- `security-encrypt` - Enable SSL/TLS
- `security-compliance` - Compliance checking

### 2. Skill Template

```yaml
---
name: cluster-status
description: Check PostgreSQL cluster health and status
category: operations
version: 1.0.0
llm_accessible: true
autonomous_execution: true
requires_confirmation: false
---

# Cluster Status Skill

Check the health and status of the PostgreSQL cluster.

## Usage

```bash
/cluster-status [--format json|human|prometheus]
```

## What This Does

1. **Connection Health**: Verify all database connections
2. **Pool Status**: Check connection pool utilization
3. **HNSW Indexes**: Validate vector indexes
4. **Performance**: Current query performance metrics
5. **Alerts**: Any active warnings or errors

## LLM Instructions

You are checking the health of a distributed PostgreSQL cluster with RuVector vector database support.

**When to use this skill:**
- User asks "how is the database?"
- Before major operations (backup, scale, migrate)
- After errors or failures
- Periodic health checks (every 5 minutes)

**How to interpret results:**

<context>
The skill will return a health status object:
</context>

<output_schema>
{
  "status": "healthy|degraded|critical",
  "timestamp": "ISO-8601",
  "components": {
    "database": {"status": "up|down", "latency_ms": 4.2},
    "pools": {"active": 15, "max": 35, "utilization": "43%"},
    "hnsw": {"loaded": true, "index_count": 11},
    "performance": {"avg_query_ms": 5.3, "qps": 1200}
  },
  "alerts": ["Pool utilization high (43%)", ...],
  "recommendations": ["Consider scaling pools", ...]
}
</output_schema>

<decision_tree>
- If status is "critical": Alert humans immediately
- If status is "degraded": Investigate alerts, run diagnostics
- If pools > 80% utilized: Run /cluster-scale
- If HNSW not loaded: Run /vector-index rebuild
- If performance degraded: Run /maintenance-optimize
</decision_tree>

## Implementation

```python
#!/usr/bin/env python3
"""Cluster status skill implementation."""

import sys
import json
from pathlib import Path

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent.parent / "src"))

from db.pool import DualDatabasePools
from db.hnsw_profiles import HNSWProfileManager
import logging

def check_cluster_status(output_format="human"):
    """Check cluster health and return status."""
    try:
        # Initialize pools (lazy loading)
        pools = DualDatabasePools()

        # Check database connectivity
        with pools.project.get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                db_status = "up"

        # Check pool utilization
        pool_stats = pools.get_pool_stats()

        # Check HNSW status
        hnsw_mgr = HNSWProfileManager(pools.project)
        hnsw_stats = hnsw_mgr.get_current_stats()

        # Aggregate status
        status = {
            "status": "healthy",
            "timestamp": datetime.now().isoformat(),
            "components": {
                "database": {"status": db_status},
                "pools": pool_stats,
                "hnsw": hnsw_stats
            },
            "alerts": [],
            "recommendations": []
        }

        # Check for issues
        if pool_stats["utilization"] > 80:
            status["status"] = "degraded"
            status["alerts"].append("Pool utilization high")
            status["recommendations"].append("Run /cluster-scale")

        # Format output
        if output_format == "json":
            print(json.dumps(status, indent=2))
        else:
            print(f"Cluster Status: {status['status'].upper()}")
            print(f"Database: {status['components']['database']['status']}")
            print(f"Pool Utilization: {status['components']['pools']['utilization']}")

        return 0 if status["status"] == "healthy" else 1

    except Exception as e:
        logging.error(f"Health check failed: {e}")
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Check cluster status")
    parser.add_argument("--format", choices=["human", "json", "prometheus"], default="human")
    args = parser.parse_args()

    sys.exit(check_cluster_status(args.format))
```

## Testing

```python
def test_cluster_status_skill():
    """Test skill execution."""
    from skills.operations.cluster_status import check_cluster_status

    # Should return healthy status
    result = check_cluster_status(output_format="json")
    assert result == 0

def test_skill_llm_accessibility():
    """Verify LLM can execute skill."""
    # Simulate Claude Code execution
    result = subprocess.run(
        ["python", "skills/operations/cluster_status.py", "--format", "json"],
        capture_output=True,
        text=True
    )

    assert result.returncode == 0
    status = json.loads(result.stdout)
    assert "status" in status
    assert status["status"] in ["healthy", "degraded", "critical"]
```
```

### 3. Skill Discovery and Registration

Create a skill registry for LLM discovery:

```python
# skills/__init__.py
"""Skill registry for LLM access."""

from typing import Dict, List, Any
import importlib
import yaml
from pathlib import Path

class SkillRegistry:
    """Registry of all available skills."""

    def __init__(self):
        self.skills: Dict[str, Any] = {}
        self._discover_skills()

    def _discover_skills(self):
        """Auto-discover all skill files."""
        skill_dirs = Path(__file__).parent.glob("*/")

        for skill_dir in skill_dirs:
            if not skill_dir.is_dir():
                continue

            for skill_file in skill_dir.glob("*.py"):
                if skill_file.name.startswith("_"):
                    continue

                # Parse frontmatter
                with open(skill_file) as f:
                    content = f.read()
                    if content.startswith("---"):
                        frontmatter = yaml.safe_load(
                            content.split("---")[1]
                        )

                        self.skills[frontmatter["name"]] = {
                            "path": str(skill_file),
                            "metadata": frontmatter,
                            "category": frontmatter["category"]
                        }

    def get_skill(self, name: str) -> Dict[str, Any]:
        """Get skill by name."""
        return self.skills.get(name)

    def list_skills(self, category: str = None) -> List[str]:
        """List all skills, optionally filtered by category."""
        if category:
            return [
                name for name, skill in self.skills.items()
                if skill["category"] == category
            ]
        return list(self.skills.keys())

    def get_llm_accessible_skills(self) -> List[Dict[str, Any]]:
        """Get all skills accessible to LLMs."""
        return [
            {"name": name, **skill}
            for name, skill in self.skills.items()
            if skill["metadata"].get("llm_accessible", False)
        ]

# Global registry
SKILL_REGISTRY = SkillRegistry()
```

### 4. LLM Integration

Expose skills to Claude Code:

```python
# .claude-code/skills.json
{
  "skills": [
    {
      "name": "cluster-status",
      "command": "python skills/operations/cluster_status.py",
      "description": "Check PostgreSQL cluster health",
      "category": "operations",
      "autonomous": true
    },
    {
      "name": "vector-search",
      "command": "python skills/vector/vector_search.py",
      "description": "Semantic vector search",
      "category": "vector",
      "autonomous": true
    }
  ]
}
```

### 5. Autonomous Maintenance Agent

Create an autonomous agent that uses skills:

```python
# agents/autonomous_dba.py
"""Autonomous Database Administrator Agent."""

from skills import SKILL_REGISTRY
import logging
import time

class AutonomousDBA:
    """Self-maintaining database administrator."""

    def __init__(self):
        self.skills = SKILL_REGISTRY
        self.running = True

    def monitor_loop(self):
        """Continuous monitoring and maintenance loop."""
        while self.running:
            # Check health every 5 minutes
            health = self.execute_skill("cluster-status", format="json")

            if health["status"] == "critical":
                self.handle_critical(health)
            elif health["status"] == "degraded":
                self.handle_degraded(health)

            # Run optimizations if needed
            if self.should_optimize():
                self.execute_skill("maintenance-optimize")

            time.sleep(300)  # 5 minutes

    def handle_critical(self, health):
        """Handle critical issues."""
        logging.critical(f"Cluster critical: {health['alerts']}")

        # Attempt automatic recovery
        for alert in health["alerts"]:
            if "Pool exhausted" in alert:
                self.execute_skill("cluster-scale", direction="up")
            elif "HNSW failed" in alert:
                self.execute_skill("vector-index", action="rebuild")

        # Alert humans if recovery fails
        if not self.verify_recovery():
            self.alert_humans(health)

    def execute_skill(self, skill_name, **kwargs):
        """Execute a skill with parameters."""
        skill = self.skills.get_skill(skill_name)
        # Implementation...
```

## Skill Development Workflow

### For Every New Feature

1. **Implement Core Feature** (e.g., HNSW dual-profile)
2. **Create Skill Interface** (`/skills/vector/hnsw-profile.py`)
3. **Write Skill Documentation** (YAML frontmatter + markdown)
4. **Add LLM Instructions** (when to use, how to interpret)
5. **Implement Tests** (skill execution + LLM simulation)
6. **Register in Skill Registry**
7. **Document in CAPABILITIES.md**

### Example Development

```bash
# Feature: Implement bulk insert optimization
# 1. Core implementation
src/db/bulk_ops.py

# 2. Skill interface (created simultaneously)
skills/vector/bulk-insert.py

# 3. Documentation
skills/vector/bulk-insert.md

# 4. Tests
tests/skills/test_bulk_insert_skill.py

# 5. Registration (automatic via discovery)
# 6. Update capabilities
.claude-flow/CAPABILITIES.md
```

## Benefits

### For LLMs (Claude Code)

1. **Autonomous Operation**: Can manage cluster without human intervention
2. **Self-Healing**: Detect and fix issues automatically
3. **Learning**: Improve decision-making over time
4. **Context-Aware**: Understand system state and history
5. **Efficient**: Use optimized operations instead of trial-and-error

### For Humans

1. **Reduced Toil**: LLM handles routine maintenance
2. **24/7 Monitoring**: LLM never sleeps
3. **Faster Response**: Sub-second issue detection and response
4. **Consistency**: Same approach every time
5. **Documentation**: Skills self-document the system

### For the System

1. **Reliability**: Proactive maintenance prevents issues
2. **Performance**: Continuous optimization
3. **Security**: Automated security scanning and remediation
4. **Scalability**: Autonomous scaling decisions
5. **Evolution**: System improves as skills learn

## Consequences

### Positive

1. **LLM-Managed Database**: First truly autonomous database system
2. **Reduced Operations Cost**: 80-90% reduction in manual work
3. **Faster Issue Resolution**: Minutes vs hours
4. **Better Documentation**: Skills force clear interfaces
5. **Innovation Platform**: Easy to add new capabilities

### Negative

1. **Development Overhead**: 30-40% more code (skills + docs)
2. **Testing Complexity**: Need to test both code and LLM interaction
3. **Safety Concerns**: LLM could make incorrect decisions
4. **Trust Building**: Users need to trust autonomous operations

### Risk Mitigation

1. **Confirmation Required**: Mark dangerous skills with `requires_confirmation: true`
2. **Dry Run Mode**: All skills support `--dry-run` flag
3. **Audit Logging**: All skill executions logged
4. **Rollback Capability**: All operations reversible
5. **Human Override**: Humans can disable autonomous mode

## Success Metrics

1. **Skill Coverage**: 90%+ of operations have skills (target by Week 4)
2. **LLM Success Rate**: >95% successful autonomous operations
3. **Mean Time to Recovery**: <5 minutes (vs 60+ minutes manual)
4. **Operations Reduction**: 80%+ reduction in manual interventions
5. **Developer Satisfaction**: Survey feedback on skill usability

## Migration Plan

### Week 1: Foundation
- Create skill directory structure
- Implement SkillRegistry
- Create first 5 core skills (status, backup, health, search, optimize)
- Write skill development guide

### Week 2: Coverage
- Create skills for all existing features (15-20 skills)
- Implement autonomous DBA agent
- Add skill testing framework
- Update CAPABILITIES.md

### Week 3: Enhancement
- Add learning capabilities to skills
- Implement skill chaining (workflows)
- Create skill analytics dashboard
- Production testing

### Week 4: Production
- Deploy autonomous agent to production
- Monitor and iterate
- Collect feedback
- Expand skill library

## References

- [Claude Code Skills Specification](https://docs.anthropic.com/claude/docs/claude-code-skills)
- [LLM-First Design Principles](https://www.anthropic.com/research/constitutional-ai)
- [Autonomous Agent Patterns](https://github.com/ruvnet/claude-flow)
- [Database Automation Best Practices](https://sre.google/books/)

## Appendix: Skill Naming Conventions

**Format**: `{category}-{action}`

**Examples**:
- `cluster-status`, `cluster-scale`, `cluster-backup`
- `vector-search`, `vector-insert`, `vector-index`
- `maintenance-optimize`, `maintenance-vacuum`
- `monitoring-health`, `monitoring-alerts`
- `security-audit`, `security-rotate`

**File Structure**:
```
skills/
├── operations/
│   ├── cluster_status.py
│   ├── cluster_scale.py
│   └── cluster_backup.py
├── vector/
│   ├── vector_search.py
│   ├── vector_insert.py
│   └── vector_index.py
├── maintenance/
│   ├── maintenance_optimize.py
│   └── maintenance_vacuum.py
├── monitoring/
│   ├── monitoring_health.py
│   └── monitoring_alerts.py
├── security/
│   ├── security_audit.py
│   └── security_rotate.py
└── __init__.py  # Skill registry
```

## Appendix: Example LLM Conversation

```
User: "The database seems slow"

Claude: Let me check the cluster status.
[Executes /cluster-status]

Status: degraded
Issue: Pool utilization at 87%
Recommendation: Scale pools

Claude: I found the issue - connection pools are at 87% capacity.
I'll scale them up for you.
[Executes /cluster-scale --direction up --increment 10]

Done! Pools increased from 25→35. Performance should improve.
Would you like me to run a benchmark to verify?
```
