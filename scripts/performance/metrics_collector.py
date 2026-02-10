#!/usr/bin/env python3
"""Prometheus Metrics Collector for Distributed PostgreSQL

Collects and exports performance metrics:
- Vector search latency
- Query throughput
- Shard statistics
- Replication lag
- Connection pool stats
"""
import asyncio
import asyncpg
import time
import sys
import os
from pathlib import Path
from typing import Dict, Optional
from prometheus_client import (
    Counter, Histogram, Gauge, Info,
    start_http_server, CollectorRegistry
)

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent.parent))
from dotenv import load_dotenv

# Load environment
load_dotenv(Path(__file__).parent.parent.parent / '.env')


class MetricsCollector:
    """Collects PostgreSQL and vector operation metrics."""

    def __init__(self, connection_string: str, port: int = 9090):
        self.conn_string = connection_string
        self.port = port
        self.pool: Optional[asyncpg.Pool] = None
        self.registry = CollectorRegistry()

        # Define metrics
        self._setup_metrics()

    def _setup_metrics(self):
        """Setup Prometheus metrics."""
        # Vector search metrics
        self.vector_search_duration = Histogram(
            'vector_search_duration_seconds',
            'Duration of vector search operations',
            ['namespace', 'operation_type'],
            registry=self.registry,
            buckets=(0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0)
        )

        self.vector_search_results = Counter(
            'vector_search_results_total',
            'Total number of vector search results returned',
            ['namespace'],
            registry=self.registry
        )

        self.vector_search_errors = Counter(
            'vector_search_errors_total',
            'Total number of vector search errors',
            ['namespace', 'error_type'],
            registry=self.registry
        )

        # Database connection metrics
        self.db_connections_active = Gauge(
            'db_connections_active',
            'Number of active database connections',
            registry=self.registry
        )

        self.db_connections_idle = Gauge(
            'db_connections_idle',
            'Number of idle database connections',
            registry=self.registry
        )

        self.db_connections_total = Gauge(
            'db_connections_total',
            'Total number of database connections',
            registry=self.registry
        )

        # Query metrics
        self.db_queries_total = Counter(
            'db_queries_total',
            'Total number of database queries',
            ['query_type'],
            registry=self.registry
        )

        self.db_query_duration = Histogram(
            'db_query_duration_seconds',
            'Database query duration',
            ['query_type'],
            registry=self.registry
        )

        # Table size metrics
        self.table_size_bytes = Gauge(
            'table_size_bytes',
            'Size of database tables in bytes',
            ['table_name', 'schema'],
            registry=self.registry
        )

        self.table_row_count = Gauge(
            'table_row_count',
            'Number of rows in table',
            ['table_name', 'schema'],
            registry=self.registry
        )

        # Index metrics
        self.index_size_bytes = Gauge(
            'index_size_bytes',
            'Size of database indexes in bytes',
            ['index_name', 'table_name'],
            registry=self.registry
        )

        self.index_scans_total = Counter(
            'index_scans_total',
            'Total number of index scans',
            ['index_name', 'table_name'],
            registry=self.registry
        )

        # Replication metrics
        self.replication_lag_bytes = Gauge(
            'replication_lag_bytes',
            'Replication lag in bytes',
            ['replica_name'],
            registry=self.registry
        )

        self.replication_lag_seconds = Gauge(
            'replication_lag_seconds',
            'Replication lag in seconds',
            ['replica_name'],
            registry=self.registry
        )

        # Cache hit ratio
        self.cache_hit_ratio = Gauge(
            'cache_hit_ratio',
            'PostgreSQL cache hit ratio (0-1)',
            registry=self.registry
        )

        # System info
        self.db_info = Info(
            'db_info',
            'Database system information',
            registry=self.registry
        )

    async def setup(self):
        """Setup database connection pool."""
        print("🔧 Setting up metrics collector...")
        self.pool = await asyncpg.create_pool(
            self.conn_string,
            min_size=2,
            max_size=5,
            command_timeout=30
        )
        print(f"   ✓ Connection pool ready")
        print(f"   ✓ Metrics will be exposed on http://localhost:{self.port}/metrics")

    async def teardown(self):
        """Cleanup."""
        if self.pool:
            await self.pool.close()
            print("\n🔧 Metrics collector stopped")

    async def collect_db_info(self):
        """Collect database version and configuration info."""
        try:
            async with self.pool.acquire() as conn:
                # Get version info
                row = await conn.fetchrow("""
                    SELECT
                        version() as pg_version,
                        current_database() as database,
                        current_user as user
                """)

                # Get RuVector version
                ruvector_row = await conn.fetchrow("""
                    SELECT extversion as version
                    FROM pg_extension
                    WHERE extname = 'ruvector'
                """)

                self.db_info.info({
                    'pg_version': row['pg_version'],
                    'database': row['database'],
                    'user': row['user'],
                    'ruvector_version': ruvector_row['version'] if ruvector_row else 'N/A'
                })

        except Exception as e:
            print(f"   ⚠ Failed to collect DB info: {e}")

    async def collect_connection_metrics(self):
        """Collect connection pool metrics."""
        try:
            async with self.pool.acquire() as conn:
                rows = await conn.fetch("""
                    SELECT
                        state,
                        COUNT(*) as count
                    FROM pg_stat_activity
                    WHERE datname = current_database()
                    GROUP BY state
                """)

                active = 0
                idle = 0
                total = 0

                for row in rows:
                    count = row['count']
                    total += count

                    if row['state'] == 'active':
                        active = count
                    elif row['state'] == 'idle':
                        idle = count

                self.db_connections_active.set(active)
                self.db_connections_idle.set(idle)
                self.db_connections_total.set(total)

        except Exception as e:
            print(f"   ⚠ Failed to collect connection metrics: {e}")

    async def collect_table_metrics(self):
        """Collect table size and row count metrics."""
        try:
            async with self.pool.acquire() as conn:
                # Table sizes
                rows = await conn.fetch("""
                    SELECT
                        schemaname,
                        tablename,
                        pg_total_relation_size(schemaname||'.'||tablename) as size_bytes
                    FROM pg_tables
                    WHERE schemaname IN ('public', 'claude_flow')
                    ORDER BY size_bytes DESC
                    LIMIT 20
                """)

                for row in rows:
                    self.table_size_bytes.labels(
                        table_name=row['tablename'],
                        schema=row['schemaname']
                    ).set(row['size_bytes'])

                # Row counts (approximate from stats)
                rows = await conn.fetch("""
                    SELECT
                        schemaname,
                        tablename,
                        n_live_tup as row_count
                    FROM pg_stat_user_tables
                    WHERE schemaname IN ('public', 'claude_flow')
                """)

                for row in rows:
                    self.table_row_count.labels(
                        table_name=row['tablename'],
                        schema=row['schemaname']
                    ).set(row['row_count'])

        except Exception as e:
            print(f"   ⚠ Failed to collect table metrics: {e}")

    async def collect_index_metrics(self):
        """Collect index size and scan statistics."""
        try:
            async with self.pool.acquire() as conn:
                # Index sizes
                rows = await conn.fetch("""
                    SELECT
                        schemaname,
                        tablename,
                        indexname,
                        pg_relation_size(indexrelid) as size_bytes,
                        idx_scan
                    FROM pg_stat_user_indexes
                    WHERE schemaname IN ('public', 'claude_flow')
                      AND indexname LIKE '%hnsw%'
                    ORDER BY size_bytes DESC
                    LIMIT 20
                """)

                for row in rows:
                    self.index_size_bytes.labels(
                        index_name=row['indexname'],
                        table_name=row['tablename']
                    ).set(row['size_bytes'])

                    # Note: Counter doesn't support .set(), so we skip idx_scan
                    # In production, you'd track incremental changes

        except Exception as e:
            print(f"   ⚠ Failed to collect index metrics: {e}")

    async def collect_replication_metrics(self):
        """Collect replication lag metrics."""
        try:
            async with self.pool.acquire() as conn:
                rows = await conn.fetch("""
                    SELECT
                        application_name,
                        client_addr,
                        write_lag,
                        flush_lag,
                        replay_lag,
                        sync_state
                    FROM pg_stat_replication
                """)

                for row in rows:
                    replica_name = row['application_name'] or str(row['client_addr'])

                    # Convert lag intervals to seconds
                    if row['replay_lag']:
                        lag_seconds = row['replay_lag'].total_seconds()
                        self.replication_lag_seconds.labels(
                            replica_name=replica_name
                        ).set(lag_seconds)

        except Exception as e:
            # Replication might not be configured
            pass

    async def collect_cache_metrics(self):
        """Collect cache hit ratio metrics."""
        try:
            async with self.pool.acquire() as conn:
                row = await conn.fetchrow("""
                    SELECT
                        sum(heap_blks_read) as heap_read,
                        sum(heap_blks_hit) as heap_hit
                    FROM pg_statio_user_tables
                """)

                if row and row['heap_read'] is not None:
                    total = row['heap_read'] + row['heap_hit']
                    if total > 0:
                        hit_ratio = row['heap_hit'] / total
                        self.cache_hit_ratio.set(hit_ratio)

        except Exception as e:
            print(f"   ⚠ Failed to collect cache metrics: {e}")

    async def collect_all_metrics(self):
        """Collect all metrics."""
        tasks = [
            self.collect_connection_metrics(),
            self.collect_table_metrics(),
            self.collect_index_metrics(),
            self.collect_replication_metrics(),
            self.collect_cache_metrics()
        ]

        await asyncio.gather(*tasks, return_exceptions=True)

    async def run(self, interval: int = 15):
        """Run metrics collection loop."""
        # Start HTTP server for Prometheus
        start_http_server(self.port, registry=self.registry)
        print(f"📊 Metrics server started on port {self.port}")

        # Collect DB info once
        await self.collect_db_info()

        print(f"🔄 Collecting metrics every {interval} seconds...")
        print("   Press Ctrl+C to stop\n")

        try:
            while True:
                start = time.time()

                # Collect all metrics
                await self.collect_all_metrics()

                duration = time.time() - start
                print(f"   ✓ Metrics collected in {duration:.2f}s")

                # Sleep until next interval
                await asyncio.sleep(max(0, interval - duration))

        except KeyboardInterrupt:
            print("\n\n🛑 Shutting down metrics collector...")


async def main():
    """Main entry point."""
    print("="*60)
    print("📊 PostgreSQL Metrics Collector")
    print("="*60)

    # Build connection string
    conn_string = (
        f"postgresql://{os.getenv('RUVECTOR_USER')}:"
        f"{os.getenv('RUVECTOR_PASSWORD')}@"
        f"{os.getenv('RUVECTOR_HOST', 'localhost')}:"
        f"{os.getenv('RUVECTOR_PORT', '5432')}/"
        f"{os.getenv('RUVECTOR_DB')}"
    )

    # Get port from env or use default
    port = int(os.getenv('METRICS_PORT', '9090'))

    collector = MetricsCollector(conn_string, port=port)

    try:
        await collector.setup()
        await collector.run(interval=15)

    except Exception as e:
        print(f"\n❌ Collector failed: {e}")
        import traceback
        traceback.print_exc()
        return 1

    finally:
        await collector.teardown()

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
