"""
Health Check Endpoints for Monitoring
Provides standardized health check endpoints for load balancers and monitoring systems
"""

# Standard library imports
import logging
import time
from datetime import datetime
from typing import Any, Dict

# Third-party imports
import psycopg2
import redis

logger = logging.getLogger(__name__)


class HealthChecker:
    """Health check manager for database and cache services"""

    def __init__(self, pg_pool, redis_client):
        """
        Initialize health checker

        Args:
            pg_pool: PostgreSQL connection pool
            redis_client: Redis client instance
        """
        self.pg_pool = pg_pool
        self.redis_client = redis_client
        self.start_time = time.time()

    def check_postgres(self) -> Dict[str, Any]:
        """
        Check PostgreSQL health

        Returns:
            dict: Health status with details
        """
        try:
            start = time.time()
            with self.pg_pool.get_connection() as conn:
                with conn.cursor() as cur:
                    # Simple query to test connectivity
                    cur.execute("SELECT 1")
                    result = cur.fetchone()

                    # Get connection pool stats
                    cur.execute(
                        """
                        SELECT
                            count(*) as total_connections,
                            sum(case when state = 'active' then 1 else 0 end) as active_connections,
                            sum(case when state = 'idle' then 1 else 0 end) as idle_connections
                        FROM pg_stat_activity
                        WHERE datname = current_database()
                    """
                    )
                    stats = cur.fetchone()

            latency = (time.time() - start) * 1000  # Convert to ms

            return {
                "status": "healthy",
                "latency_ms": round(latency, 2),
                "connections": {"total": stats[0], "active": stats[1], "idle": stats[2]},
                "timestamp": datetime.utcnow().isoformat(),
            }

        except Exception as e:
            logger.error(f"PostgreSQL health check failed: {e}")
            return {
                "status": "unhealthy",
                "error": str(e),
                "timestamp": datetime.utcnow().isoformat(),
            }

    def check_redis(self) -> Dict[str, Any]:
        """
        Check Redis health

        Returns:
            dict: Health status with details
        """
        try:
            start = time.time()

            # Ping Redis
            self.redis_client.ping()

            # Get info
            info = self.redis_client.info()

            latency = (time.time() - start) * 1000  # Convert to ms

            return {
                "status": "healthy",
                "latency_ms": round(latency, 2),
                "memory": {
                    "used_bytes": info.get("used_memory", 0),
                    "max_bytes": info.get("maxmemory", 0),
                    "fragmentation_ratio": info.get("mem_fragmentation_ratio", 0),
                },
                "keys": info.get("db0", {}).get("keys", 0),
                "clients": info.get("connected_clients", 0),
                "timestamp": datetime.utcnow().isoformat(),
            }

        except Exception as e:
            logger.error(f"Redis health check failed: {e}")
            return {
                "status": "unhealthy",
                "error": str(e),
                "timestamp": datetime.utcnow().isoformat(),
            }

    def check_ruvector(self) -> Dict[str, Any]:
        """
        Check RuVector extension health

        Returns:
            dict: Health status with details
        """
        try:
            with self.pg_pool.get_connection() as conn:
                with conn.cursor() as cur:
                    # Check RuVector extension
                    cur.execute(
                        """
                        SELECT extname, extversion
                        FROM pg_extension
                        WHERE extname = 'ruvector'
                    """
                    )
                    ext = cur.fetchone()

                    if not ext:
                        return {
                            "status": "unhealthy",
                            "error": "RuVector extension not installed",
                            "timestamp": datetime.utcnow().isoformat(),
                        }

                    # Get vector counts
                    cur.execute(
                        """
                        SELECT
                            schemaname,
                            tablename,
                            n_live_tup as vector_count
                        FROM pg_stat_user_tables
                        WHERE schemaname IN ('public', 'claude_flow')
                          AND tablename IN ('embeddings', 'memory_entries')
                    """
                    )
                    tables = cur.fetchall()

                    # Get HNSW index stats
                    cur.execute(
                        """
                        SELECT
                            schemaname,
                            indexname,
                            idx_scan as scans
                        FROM pg_stat_user_indexes
                        WHERE indexname LIKE '%hnsw%'
                    """
                    )
                    indexes = cur.fetchall()

            return {
                "status": "healthy",
                "extension_version": ext[1],
                "tables": [{"schema": t[0], "table": t[1], "vectors": t[2]} for t in tables],
                "hnsw_indexes": [{"schema": i[0], "index": i[1], "scans": i[2]} for i in indexes],
                "timestamp": datetime.utcnow().isoformat(),
            }

        except Exception as e:
            logger.error(f"RuVector health check failed: {e}")
            return {
                "status": "unhealthy",
                "error": str(e),
                "timestamp": datetime.utcnow().isoformat(),
            }

    def get_full_health(self) -> Dict[str, Any]:
        """
        Get complete health status

        Returns:
            dict: Complete health status
        """
        postgres = self.check_postgres()
        redis = self.check_redis()
        ruvector = self.check_ruvector()

        # Overall status
        all_healthy = all(check["status"] == "healthy" for check in [postgres, redis, ruvector])

        uptime = time.time() - self.start_time

        return {
            "status": "healthy" if all_healthy else "unhealthy",
            "uptime_seconds": round(uptime, 2),
            "timestamp": datetime.utcnow().isoformat(),
            "checks": {"postgres": postgres, "redis": redis, "ruvector": ruvector},
        }

    def get_readiness(self) -> Dict[str, Any]:
        """
        Check if service is ready to handle requests

        Returns:
            dict: Readiness status
        """
        postgres = self.check_postgres()
        redis = self.check_redis()

        ready = postgres["status"] == "healthy" and redis["status"] == "healthy"

        return {
            "ready": ready,
            "timestamp": datetime.utcnow().isoformat(),
            "checks": {"postgres": postgres["status"], "redis": redis["status"]},
        }

    def get_liveness(self) -> Dict[str, Any]:
        """
        Check if service is alive (basic liveness probe)

        Returns:
            dict: Liveness status
        """
        return {
            "alive": True,
            "uptime_seconds": round(time.time() - self.start_time, 2),
            "timestamp": datetime.utcnow().isoformat(),
        }


# Flask/FastAPI endpoint examples

"""
# Flask
from flask import Flask, jsonify

app = Flask(__name__)
health_checker = HealthChecker(pg_pool, redis_client)

@app.route('/health')
def health():
    return jsonify(health_checker.get_full_health())

@app.route('/health/ready')
def ready():
    status = health_checker.get_readiness()
    code = 200 if status["ready"] else 503
    return jsonify(status), code

@app.route('/health/live')
def live():
    return jsonify(health_checker.get_liveness())

# FastAPI
from fastapi import FastAPI, Response

app = FastAPI()
health_checker = HealthChecker(pg_pool, redis_client)

@app.get("/health")
async def health():
    return health_checker.get_full_health()

@app.get("/health/ready")
async def ready(response: Response):
    status = health_checker.get_readiness()
    if not status["ready"]:
        response.status_code = 503
    return status

@app.get("/health/live")
async def live():
    return health_checker.get_liveness()
"""
