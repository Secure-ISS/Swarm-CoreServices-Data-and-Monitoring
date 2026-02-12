#!/usr/bin/env python3
"""
Continuous health monitoring service for PostgreSQL mesh cluster
Runs as a Docker service and monitors cluster health in real-time
"""

# Standard library imports
import json
import logging
import os
import sys
import time
from datetime import datetime
from typing import Dict, List, Optional

# Third-party imports
import psycopg2
from psycopg2.extras import RealDictCursor

# Configuration from environment
COORDINATOR_HOST = os.getenv("COORDINATOR_HOST", "pg-coordinator")
COORDINATOR_PORT = int(os.getenv("COORDINATOR_PORT", 5432))
WORKER_HOSTS = os.getenv("WORKER_HOSTS", "").split(",")
POOLER_HOST = os.getenv("POOLER_HOST", "pgbouncer")
POOLER_PORT = int(os.getenv("POOLER_PORT", 6432))
CHECK_INTERVAL = int(os.getenv("CHECK_INTERVAL", 60))
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
LOG_FILE = os.getenv("LOG_FILE", "/logs/health-monitor.log")

# Setup logging
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger("health-monitor")


class PostgreSQLHealthMonitor:
    """Health monitoring for PostgreSQL mesh cluster"""

    def __init__(self):
        self.coordinator_host = COORDINATOR_HOST
        self.coordinator_port = COORDINATOR_PORT
        self.worker_hosts = [host.strip() for host in WORKER_HOSTS if host.strip()]
        self.pooler_host = POOLER_HOST
        self.pooler_port = POOLER_PORT
        self.db_name = "distributed_postgres_cluster"
        self.db_user = "dpg_cluster"
        self.db_password = self._load_password()

    def _load_password(self) -> str:
        """Load database password from secret or environment"""
        secret_file = "/run/secrets/postgres_password"
        if os.path.exists(secret_file):
            with open(secret_file, "r") as f:
                return f.read().strip()

        password = os.getenv("POSTGRES_PASSWORD")
        if not password:
            raise ValueError(
                "POSTGRES_PASSWORD environment variable is required. "
                "Set it in environment or mount Docker secret at /run/secrets/postgres_password"
            )
        return password

    def get_connection(
        self, host: str, port: int = 5432, database: str = None
    ) -> Optional[psycopg2.extensions.connection]:
        """Establish database connection"""
        try:
            return psycopg2.connect(
                host=host,
                port=port,
                database=database or self.db_name,
                user=self.db_user,
                password=self.db_password,
                connect_timeout=5,
            )
        except Exception as e:
            logger.error(f"Failed to connect to {host}:{port} - {e}")
            return None

    def check_coordinator_health(self) -> Dict:
        """Check coordinator node health"""
        health_status = {
            "node": "coordinator",
            "host": self.coordinator_host,
            "timestamp": datetime.utcnow().isoformat(),
            "healthy": False,
            "metrics": {},
        }

        conn = self.get_connection(self.coordinator_host, self.coordinator_port)
        if not conn:
            health_status["error"] = "Connection failed"
            return health_status

        try:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                # Basic health check
                cur.execute("SELECT 1")
                health_status["healthy"] = True

                # Get connection stats
                cur.execute(
                    """
                    SELECT
                        count(*) as total_connections,
                        count(*) FILTER (WHERE state = 'active') as active_connections,
                        count(*) FILTER (WHERE state = 'idle') as idle_connections,
                        max(extract(epoch from (now() - query_start))) as max_query_duration
                    FROM pg_stat_activity
                    WHERE datname = %s
                """,
                    (self.db_name,),
                )
                conn_stats = cur.fetchone()
                health_status["metrics"]["connections"] = dict(conn_stats)

                # Get database size
                cur.execute(
                    """
                    SELECT pg_size_pretty(pg_database_size(%s)) as size
                """,
                    (self.db_name,),
                )
                db_size = cur.fetchone()
                health_status["metrics"]["database_size"] = db_size["size"]

                # Get replication status
                cur.execute(
                    """
                    SELECT
                        count(*) as replication_slots,
                        count(*) FILTER (WHERE active = true) as active_slots
                    FROM pg_replication_slots
                """
                )
                repl_stats = cur.fetchone()
                health_status["metrics"]["replication"] = dict(repl_stats)

                # Get cache hit ratio
                cur.execute(
                    """
                    SELECT
                        ROUND(100.0 * sum(blks_hit) / NULLIF(sum(blks_hit) + sum(blks_read), 0), 2) as cache_hit_ratio
                    FROM pg_stat_database
                    WHERE datname = %s
                """,
                    (self.db_name,),
                )
                cache_ratio = cur.fetchone()
                health_status["metrics"]["cache_hit_ratio"] = cache_ratio["cache_hit_ratio"]

                # Check for long-running queries
                cur.execute(
                    """
                    SELECT count(*) as long_queries
                    FROM pg_stat_activity
                    WHERE state = 'active'
                    AND now() - query_start > interval '5 minutes'
                    AND datname = %s
                """,
                    (self.db_name,),
                )
                long_queries = cur.fetchone()
                health_status["metrics"]["long_running_queries"] = long_queries["long_queries"]

                # Check for locks
                cur.execute(
                    """
                    SELECT count(*) as waiting_locks
                    FROM pg_locks
                    WHERE NOT granted
                """
                )
                locks = cur.fetchone()
                health_status["metrics"]["waiting_locks"] = locks["waiting_locks"]

        except Exception as e:
            logger.error(f"Error checking coordinator health: {e}")
            health_status["healthy"] = False
            health_status["error"] = str(e)
        finally:
            conn.close()

        return health_status

    def check_worker_health(self, worker_host: str) -> Dict:
        """Check worker node health"""
        health_status = {
            "node": "worker",
            "host": worker_host,
            "timestamp": datetime.utcnow().isoformat(),
            "healthy": False,
            "metrics": {},
        }

        conn = self.get_connection(worker_host, self.coordinator_port)
        if not conn:
            health_status["error"] = "Connection failed"
            return health_status

        try:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                # Basic health check
                cur.execute("SELECT 1")
                health_status["healthy"] = True

                # Get connection stats
                cur.execute(
                    """
                    SELECT
                        count(*) as total_connections,
                        count(*) FILTER (WHERE state = 'active') as active_connections
                    FROM pg_stat_activity
                    WHERE datname = %s
                """,
                    (self.db_name,),
                )
                conn_stats = cur.fetchone()
                health_status["metrics"]["connections"] = dict(conn_stats)

                # Get database size
                cur.execute(
                    """
                    SELECT pg_size_pretty(pg_database_size(%s)) as size
                """,
                    (self.db_name,),
                )
                db_size = cur.fetchone()
                health_status["metrics"]["database_size"] = db_size["size"]

                # Get table count
                cur.execute(
                    """
                    SELECT count(*) as table_count
                    FROM information_schema.tables
                    WHERE table_schema = 'public'
                """
                )
                table_count = cur.fetchone()
                health_status["metrics"]["table_count"] = table_count["table_count"]

        except Exception as e:
            logger.error(f"Error checking worker {worker_host} health: {e}")
            health_status["healthy"] = False
            health_status["error"] = str(e)
        finally:
            conn.close()

        return health_status

    def check_pooler_health(self) -> Dict:
        """Check connection pooler health"""
        health_status = {
            "node": "pooler",
            "host": self.pooler_host,
            "timestamp": datetime.utcnow().isoformat(),
            "healthy": False,
            "metrics": {},
        }

        conn = self.get_connection(self.pooler_host, self.pooler_port)
        if not conn:
            health_status["error"] = "Connection failed"
            return health_status

        try:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                # Basic health check
                cur.execute("SELECT 1")
                health_status["healthy"] = True

                # Note: PgBouncer-specific queries would go here
                # For now, just verify connection works

        except Exception as e:
            logger.error(f"Error checking pooler health: {e}")
            health_status["healthy"] = False
            health_status["error"] = str(e)
        finally:
            conn.close()

        return health_status

    def run_health_check(self) -> Dict:
        """Run comprehensive health check"""
        logger.info("Running health check...")

        results = {
            "timestamp": datetime.utcnow().isoformat(),
            "coordinator": None,
            "workers": [],
            "pooler": None,
            "overall_status": "healthy",
        }

        # Check coordinator
        coordinator_health = self.check_coordinator_health()
        results["coordinator"] = coordinator_health
        if not coordinator_health["healthy"]:
            results["overall_status"] = "unhealthy"
            logger.warning("Coordinator is unhealthy!")

        # Check workers
        for worker_host in self.worker_hosts:
            worker_health = self.check_worker_health(worker_host)
            results["workers"].append(worker_health)
            if not worker_health["healthy"]:
                results["overall_status"] = "degraded"
                logger.warning(f"Worker {worker_host} is unhealthy!")

        # Check pooler
        pooler_health = self.check_pooler_health()
        results["pooler"] = pooler_health
        if not pooler_health["healthy"]:
            results["overall_status"] = "degraded"
            logger.warning("Connection pooler is unhealthy!")

        # Log summary
        healthy_workers = sum(1 for w in results["workers"] if w["healthy"])
        total_workers = len(results["workers"])
        logger.info(f"Health check complete - Status: {results['overall_status']}")
        logger.info(f"Coordinator: {'✓' if results['coordinator']['healthy'] else '✗'}")
        logger.info(f"Workers: {healthy_workers}/{total_workers} healthy")
        logger.info(f"Pooler: {'✓' if results['pooler']['healthy'] else '✗'}")

        return results

    def save_health_report(self, results: Dict):
        """Save health check results to file"""
        report_file = f"/logs/health-report-{datetime.utcnow().strftime('%Y%m%d')}.json"
        try:
            with open(report_file, "a") as f:
                f.write(json.dumps(results) + "\n")
        except Exception as e:
            logger.error(f"Failed to save health report: {e}")

    def run_monitor_loop(self):
        """Main monitoring loop"""
        logger.info("Starting PostgreSQL mesh health monitor...")
        logger.info(f"Coordinator: {self.coordinator_host}:{self.coordinator_port}")
        logger.info(f"Workers: {', '.join(self.worker_hosts)}")
        logger.info(f"Pooler: {self.pooler_host}:{self.pooler_port}")
        logger.info(f"Check interval: {CHECK_INTERVAL}s")

        while True:
            try:
                results = self.run_health_check()
                self.save_health_report(results)

                # Alert on critical issues
                if results["overall_status"] == "unhealthy":
                    logger.error("CRITICAL: Cluster is unhealthy!")
                    # Here you could add alerting logic (email, Slack, etc.)

                time.sleep(CHECK_INTERVAL)

            except KeyboardInterrupt:
                logger.info("Shutting down health monitor...")
                break
            except Exception as e:
                logger.error(f"Error in monitor loop: {e}")
                time.sleep(CHECK_INTERVAL)


def main():
    """Main entry point"""
    monitor = PostgreSQLHealthMonitor()
    monitor.run_monitor_loop()


if __name__ == "__main__":
    main()
