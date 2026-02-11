"""
Citus-specific MCP tools for distributed cluster management.

These tools extend postgres-mcp with Citus distributed database capabilities.
"""

from typing import Any, Dict, List
import asyncpg
import logging

logger = logging.getLogger(__name__)


class CitusTools:
    """MCP tools for Citus distributed database management."""

    def __init__(self, connection_url: str):
        self.connection_url = connection_url
        self.pool = None

    async def initialize(self):
        """Initialize connection pool."""
        self.pool = await asyncpg.create_pool(
            self.connection_url,
            min_size=2,
            max_size=10
        )

    async def close(self):
        """Close connection pool."""
        if self.pool:
            await self.pool.close()

    async def get_shard_distribution(self) -> List[Dict[str, Any]]:
        """
        Get shard distribution across worker nodes.

        Returns:
            List of dicts with nodename, shard_count, total_size
        """
        query = """
        SELECT
            nodename,
            COUNT(*) as shard_count,
            pg_size_pretty(SUM(shard_size)) as total_size,
            ROUND(AVG(shard_size::numeric) / 1024 / 1024, 2) as avg_shard_size_mb
        FROM citus_shards
        GROUP BY nodename
        ORDER BY shard_count DESC
        """

        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query)
            return [dict(row) for row in rows]

    async def get_distributed_query_stats(self, limit: int = 10) -> List[Dict[str, Any]]:
        """
        Get distributed query performance statistics.

        Args:
            limit: Number of top queries to return

        Returns:
            List of dicts with query statistics
        """
        query = """
        SELECT
            queryid,
            LEFT(query, 100) as query_preview,
            calls,
            ROUND(mean_exec_time::numeric, 2) as mean_exec_time_ms,
            ROUND(max_exec_time::numeric, 2) as max_exec_time_ms,
            ROUND(total_exec_time::numeric, 2) as total_exec_time_ms
        FROM citus_stat_statements
        ORDER BY total_exec_time DESC
        LIMIT $1
        """

        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query, limit)
            return [dict(row) for row in rows]

    async def rebalance_shards(
        self,
        strategy: str = "by_shard_count",
        drain_only: bool = False
    ) -> Dict[str, Any]:
        """
        Rebalance shards across worker nodes.

        Args:
            strategy: Rebalancing strategy ("by_shard_count" or "by_disk_size")
            drain_only: Only drain nodes marked for removal

        Returns:
            Dict with rebalancing job info
        """
        query = """
        SELECT citus_rebalance_start(
            rebalance_strategy => $1::citus_rebalance_strategy,
            drain_only => $2
        ) as job_id
        """

        async with self.pool.acquire() as conn:
            row = await conn.fetchrow(query, strategy, drain_only)

            # Get job status
            status_query = "SELECT * FROM citus_rebalance_status()"
            status_rows = await conn.fetch(status_query)

            return {
                "job_id": row["job_id"],
                "status": [dict(s) for s in status_rows]
            }

    async def get_rebalance_status(self) -> List[Dict[str, Any]]:
        """Get current rebalancing job status."""
        query = "SELECT * FROM citus_rebalance_status()"

        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query)
            return [dict(row) for row in rows]

    async def get_worker_health(self) -> List[Dict[str, Any]]:
        """Get health status of all worker nodes."""
        query = """
        SELECT
            nodename,
            nodeport,
            isactive,
            shouldhaveshards,
            hasmetadata,
            metadatasynced,
            CASE
                WHEN isactive AND shouldhaveshards AND metadatasynced THEN 'healthy'
                WHEN isactive AND NOT metadatasynced THEN 'syncing'
                WHEN NOT isactive THEN 'down'
                ELSE 'unknown'
            END as health_status
        FROM citus_get_active_worker_nodes()
        FULL OUTER JOIN pg_dist_node USING (nodename, nodeport)
        """

        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query)
            return [dict(row) for row in rows]

    async def get_table_types(self) -> List[Dict[str, Any]]:
        """Get distribution type of all tables (distributed, reference, local)."""
        query = """
        SELECT
            schemaname,
            tablename,
            CASE
                WHEN partmethod = 'h' THEN 'Distributed (hash)'
                WHEN partmethod = 'r' THEN 'Reference (replicated)'
                WHEN partmethod = 'n' THEN 'Distributed (none/append)'
                ELSE 'Local (coordinator-only)'
            END as table_type,
            partkey as distribution_column,
            colocationid,
            repmodel as replication_model
        FROM citus_tables
        UNION ALL
        SELECT
            schemaname,
            tablename,
            'Local (coordinator-only)' as table_type,
            NULL as distribution_column,
            NULL as colocationid,
            NULL as replication_model
        FROM pg_tables
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'citus', 'citus_internal')
          AND (schemaname, tablename) NOT IN (
              SELECT schemaname, tablename FROM citus_tables
          )
        ORDER BY table_type, schemaname, tablename
        """

        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query)
            return [dict(row) for row in rows]

    async def get_distributed_table_info(self, table_name: str) -> Dict[str, Any]:
        """Get detailed information about a distributed table."""
        query = """
        SELECT
            logicalrelid::text as table_name,
            partmethod,
            partkey,
            colocationid,
            repmodel,
            COUNT(*) FILTER (WHERE shardstate = 1) as active_shards,
            COUNT(*) FILTER (WHERE shardstate != 1) as inactive_shards,
            pg_size_pretty(SUM(shard_size)) as total_size
        FROM citus_tables
        JOIN citus_shards USING (table_name)
        WHERE logicalrelid::text = $1
        GROUP BY logicalrelid, partmethod, partkey, colocationid, repmodel
        """

        async with self.pool.acquire() as conn:
            row = await conn.fetchrow(query, table_name)
            return dict(row) if row else None


# MCP Tool Definitions
CITUS_TOOLS = [
    {
        "name": "citus_shard_distribution",
        "description": "Show how shards are distributed across worker nodes with counts and sizes",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "required": []
        }
    },
    {
        "name": "citus_distributed_query_stats",
        "description": "Get performance statistics for distributed queries",
        "inputSchema": {
            "type": "object",
            "properties": {
                "limit": {
                    "type": "integer",
                    "description": "Number of top queries to return",
                    "default": 10
                }
            },
            "required": []
        }
    },
    {
        "name": "citus_rebalance_shards",
        "description": "Rebalance shards across worker nodes (use with caution in production)",
        "inputSchema": {
            "type": "object",
            "properties": {
                "strategy": {
                    "type": "string",
                    "enum": ["by_shard_count", "by_disk_size"],
                    "description": "Rebalancing strategy",
                    "default": "by_shard_count"
                },
                "drain_only": {
                    "type": "boolean",
                    "description": "Only drain nodes marked for removal",
                    "default": False
                }
            },
            "required": []
        }
    },
    {
        "name": "citus_worker_health",
        "description": "Check health status of all worker nodes",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "required": []
        }
    },
    {
        "name": "citus_table_types",
        "description": "List all tables showing whether they are distributed, reference, or local",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "required": []
        }
    }
]
