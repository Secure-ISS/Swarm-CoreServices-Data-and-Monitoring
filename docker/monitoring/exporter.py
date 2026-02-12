#!/usr/bin/env python3
"""
Custom Application Metrics Exporter for Distributed PostgreSQL Cluster
Exposes RuVector-specific and application-level metrics to Prometheus
"""

# Standard library imports
import logging
import os
import time
from typing import Optional

# Third-party imports
import psycopg2
import redis
from prometheus_client import Counter, Gauge, Histogram, Info, start_http_server

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# Configuration from environment
POSTGRES_HOST = os.getenv("POSTGRES_HOST", "localhost")
POSTGRES_PORT = int(os.getenv("POSTGRES_PORT", 5432))
POSTGRES_USER = os.getenv("POSTGRES_USER", "dpg_cluster")
POSTGRES_PASSWORD = os.getenv("POSTGRES_PASSWORD", "dpg_cluster_2026")
POSTGRES_DB = os.getenv("POSTGRES_DB", "distributed_postgres_cluster")

REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", 6379))

EXPORTER_PORT = int(os.getenv("EXPORTER_PORT", 9999))
SCRAPE_INTERVAL = int(os.getenv("SCRAPE_INTERVAL", 15))

# Prometheus metrics

# RuVector-specific metrics
ruvector_index_size = Gauge(
    "ruvector_index_size_bytes",
    "Size of RuVector HNSW indexes in bytes",
    ["schema", "table", "index_name"],
)

ruvector_vector_count = Gauge(
    "ruvector_vector_count", "Number of vectors in RuVector tables", ["schema", "table"]
)

ruvector_search_latency = Histogram(
    "ruvector_search_latency_seconds",
    "Latency of RuVector similarity searches",
    ["schema", "table"],
    buckets=[0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0],
)

ruvector_index_operations = Counter(
    "ruvector_index_operations_total",
    "Total number of RuVector index operations",
    ["schema", "table", "operation"],
)

# Database connection metrics
db_connections_active = Gauge("dpg_db_connections_active", "Number of active database connections")

db_connections_idle = Gauge("dpg_db_connections_idle", "Number of idle database connections")

db_connections_waiting = Gauge(
    "dpg_db_connections_waiting", "Number of connections waiting for a backend"
)

# Query performance metrics
db_query_duration = Histogram(
    "dpg_query_duration_seconds",
    "Duration of database queries",
    ["query_type"],
    buckets=[0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0],
)

db_cache_hit_ratio = Gauge("dpg_cache_hit_ratio", "Database cache hit ratio (0-1)")

db_temp_files = Counter("dpg_temp_files_total", "Total number of temporary files created")

db_temp_bytes = Counter("dpg_temp_bytes_total", "Total bytes written to temporary files")

# Replication metrics
db_replication_lag = Gauge("dpg_replication_lag_seconds", "Replication lag in seconds", ["replica"])

db_replication_status = Gauge(
    "dpg_replication_status", "Replication status (1=streaming, 0=not streaming)", ["replica"]
)

# Table metrics
db_table_size = Gauge(
    "dpg_table_size_bytes", "Size of database tables in bytes", ["schema", "table"]
)

db_table_rows = Gauge("dpg_table_rows", "Estimated number of rows in tables", ["schema", "table"])

db_index_size = Gauge(
    "dpg_index_size_bytes", "Size of database indexes in bytes", ["schema", "table", "index"]
)

# Redis metrics
redis_memory_used = Gauge("dpg_redis_memory_used_bytes", "Redis memory usage in bytes")

redis_keys_total = Gauge("dpg_redis_keys_total", "Total number of keys in Redis")

redis_hit_rate = Gauge("dpg_redis_hit_rate", "Redis cache hit rate (0-1)")

redis_evicted_keys = Counter("dpg_redis_evicted_keys_total", "Total number of evicted keys")

# Application info
app_info = Info("dpg_application", "Application information")


class MetricsCollector:
    """Collects and exposes custom metrics"""

    def __init__(self):
        self.pg_conn: Optional[psycopg2.extensions.connection] = None
        self.redis_client: Optional[redis.Redis] = None
        self.connect_database()
        self.connect_redis()

    def connect_database(self):
        """Establish PostgreSQL connection"""
        try:
            self.pg_conn = psycopg2.connect(
                host=POSTGRES_HOST,
                port=POSTGRES_PORT,
                user=POSTGRES_USER,
                password=POSTGRES_PASSWORD,
                dbname=POSTGRES_DB,
                connect_timeout=5,
            )
            logger.info(f"Connected to PostgreSQL at {POSTGRES_HOST}:{POSTGRES_PORT}")
        except Exception as e:
            logger.error(f"Failed to connect to PostgreSQL: {e}")
            self.pg_conn = None

    def connect_redis(self):
        """Establish Redis connection"""
        try:
            self.redis_client = redis.Redis(
                host=REDIS_HOST, port=REDIS_PORT, decode_responses=True, socket_connect_timeout=5
            )
            self.redis_client.ping()
            logger.info(f"Connected to Redis at {REDIS_HOST}:{REDIS_PORT}")
        except Exception as e:
            logger.error(f"Failed to connect to Redis: {e}")
            self.redis_client = None

    def collect_ruvector_metrics(self):
        """Collect RuVector-specific metrics"""
        if not self.pg_conn:
            return

        try:
            with self.pg_conn.cursor() as cur:
                # Get vector counts per table
                cur.execute(
                    """
                    SELECT
                        schemaname,
                        tablename,
                        n_live_tup as row_count
                    FROM pg_stat_user_tables
                    WHERE schemaname IN ('public', 'claude_flow')
                      AND tablename IN ('embeddings', 'memory_entries', 'patterns')
                """
                )

                for row in cur.fetchall():
                    schema, table, count = row
                    ruvector_vector_count.labels(schema=schema, table=table).set(count or 0)

                # Get index sizes
                cur.execute(
                    """
                    SELECT
                        schemaname,
                        tablename,
                        indexname,
                        pg_relation_size(indexrelid) as size
                    FROM pg_stat_user_indexes
                    WHERE schemaname IN ('public', 'claude_flow')
                      AND indexname LIKE '%hnsw%'
                """
                )

                for row in cur.fetchall():
                    schema, table, index, size = row
                    ruvector_index_size.labels(schema=schema, table=table, index_name=index).set(
                        size or 0
                    )

                logger.debug("Collected RuVector metrics")

        except Exception as e:
            logger.error(f"Error collecting RuVector metrics: {e}")
            self.connect_database()

    def collect_database_metrics(self):
        """Collect database performance metrics"""
        if not self.pg_conn:
            return

        try:
            with self.pg_conn.cursor() as cur:
                # Connection counts
                cur.execute(
                    """
                    SELECT state, count(*)
                    FROM pg_stat_activity
                    WHERE datname = %s
                    GROUP BY state
                """,
                    (POSTGRES_DB,),
                )

                connection_counts = dict(cur.fetchall())
                db_connections_active.set(connection_counts.get("active", 0))
                db_connections_idle.set(connection_counts.get("idle", 0))
                db_connections_waiting.set(connection_counts.get("idle in transaction", 0))

                # Cache hit ratio
                cur.execute(
                    """
                    SELECT
                        CASE
                            WHEN (blks_hit + blks_read) = 0 THEN 1.0
                            ELSE blks_hit::float / (blks_hit + blks_read)
                        END as hit_ratio
                    FROM pg_stat_database
                    WHERE datname = %s
                """,
                    (POSTGRES_DB,),
                )

                hit_ratio = cur.fetchone()[0]
                db_cache_hit_ratio.set(hit_ratio or 0)

                # Temporary files
                cur.execute(
                    """
                    SELECT temp_files, temp_bytes
                    FROM pg_stat_database
                    WHERE datname = %s
                """,
                    (POSTGRES_DB,),
                )

                temp_files, temp_bytes = cur.fetchone()
                db_temp_files.inc(temp_files or 0)
                db_temp_bytes.inc(temp_bytes or 0)

                # Table sizes
                cur.execute(
                    """
                    SELECT
                        schemaname,
                        tablename,
                        pg_total_relation_size(schemaname||'.'||tablename) as total_size,
                        n_live_tup as row_count
                    FROM pg_stat_user_tables
                    WHERE schemaname IN ('public', 'claude_flow')
                """
                )

                for row in cur.fetchall():
                    schema, table, size, rows = row
                    db_table_size.labels(schema=schema, table=table).set(size or 0)
                    db_table_rows.labels(schema=schema, table=table).set(rows or 0)

                # Index sizes
                cur.execute(
                    """
                    SELECT
                        schemaname,
                        tablename,
                        indexname,
                        pg_relation_size(indexrelid) as size
                    FROM pg_stat_user_indexes
                    WHERE schemaname IN ('public', 'claude_flow')
                """
                )

                for row in cur.fetchall():
                    schema, table, index, size = row
                    db_index_size.labels(schema=schema, table=table, index=index).set(size or 0)

                logger.debug("Collected database metrics")

        except Exception as e:
            logger.error(f"Error collecting database metrics: {e}")
            self.connect_database()

    def collect_redis_metrics(self):
        """Collect Redis metrics"""
        if not self.redis_client:
            return

        try:
            info = self.redis_client.info()

            # Memory usage
            redis_memory_used.set(info.get("used_memory", 0))

            # Key count
            redis_keys_total.set(info.get("db0", {}).get("keys", 0))

            # Hit rate
            hits = info.get("keyspace_hits", 0)
            misses = info.get("keyspace_misses", 0)
            total = hits + misses
            hit_rate = hits / total if total > 0 else 0
            redis_hit_rate.set(hit_rate)

            # Evictions
            redis_evicted_keys.inc(info.get("evicted_keys", 0))

            logger.debug("Collected Redis metrics")

        except Exception as e:
            logger.error(f"Error collecting Redis metrics: {e}")
            self.connect_redis()

    def collect_all_metrics(self):
        """Collect all metrics"""
        logger.info("Collecting metrics...")

        try:
            self.collect_ruvector_metrics()
            self.collect_database_metrics()
            self.collect_redis_metrics()
        except Exception as e:
            logger.error(f"Error collecting metrics: {e}")

    def run(self):
        """Main collection loop"""
        logger.info(f"Starting metrics collector (scrape interval: {SCRAPE_INTERVAL}s)")

        # Set application info
        app_info.info(
            {
                "version": "1.0.0",
                "name": "dpg-cluster",
                "postgres_host": POSTGRES_HOST,
                "redis_host": REDIS_HOST,
            }
        )

        while True:
            try:
                self.collect_all_metrics()
                time.sleep(SCRAPE_INTERVAL)
            except KeyboardInterrupt:
                logger.info("Shutting down metrics collector")
                break
            except Exception as e:
                logger.error(f"Unexpected error: {e}")
                time.sleep(SCRAPE_INTERVAL)


def main():
    """Main entry point"""
    logger.info(f"Starting custom metrics exporter on port {EXPORTER_PORT}")

    # Start HTTP server for Prometheus
    start_http_server(EXPORTER_PORT)

    # Start metrics collector
    collector = MetricsCollector()
    collector.run()


if __name__ == "__main__":
    main()
