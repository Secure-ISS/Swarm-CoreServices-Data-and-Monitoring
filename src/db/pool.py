"""PostgreSQL Connection Pools with RuVector Support

This module provides connection pools for both project-specific and shared
knowledge databases with RuVector vector operations support.
"""
import os
from contextlib import contextmanager
from typing import Optional, Dict, Any
import psycopg2
from psycopg2 import pool
from psycopg2.extras import RealDictCursor


class DualDatabasePools:
    """Manages connection pools for project and shared databases."""

    def __init__(self):
        """Initialize both connection pools from environment variables."""
        self.project_pool = self._create_project_pool()
        self.shared_pool = self._create_shared_pool()

    def _create_project_pool(self):
        """Create connection pool for project-specific database."""
        return psycopg2.pool.ThreadedConnectionPool(
            minconn=1,
            maxconn=10,
            host=os.getenv('RUVECTOR_HOST', 'localhost'),
            port=int(os.getenv('RUVECTOR_PORT', 5432)),
            database=os.getenv('RUVECTOR_DB'),
            user=os.getenv('RUVECTOR_USER'),
            password=os.getenv('RUVECTOR_PASSWORD'),
            cursor_factory=RealDictCursor
        )

    def _create_shared_pool(self):
        """Create connection pool for shared knowledge database."""
        return psycopg2.pool.ThreadedConnectionPool(
            minconn=1,
            maxconn=5,
            host=os.getenv('SHARED_KNOWLEDGE_HOST', 'localhost'),
            port=int(os.getenv('SHARED_KNOWLEDGE_PORT', 5432)),
            database=os.getenv('SHARED_KNOWLEDGE_DB'),
            user=os.getenv('SHARED_KNOWLEDGE_USER'),
            password=os.getenv('SHARED_KNOWLEDGE_PASSWORD'),
            cursor_factory=RealDictCursor
        )

    @contextmanager
    def project_cursor(self):
        """Get a cursor from the project database pool."""
        conn = self.project_pool.getconn()
        try:
            with conn.cursor() as cur:
                yield cur
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            self.project_pool.putconn(conn)

    @contextmanager
    def shared_cursor(self):
        """Get a cursor from the shared knowledge database pool."""
        conn = self.shared_pool.getconn()
        try:
            with conn.cursor() as cur:
                yield cur
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            self.shared_pool.putconn(conn)

    def health_check(self) -> Dict[str, Any]:
        """Check health of both database connections."""
        results = {}

        # Check project database
        try:
            with self.project_cursor() as cur:
                cur.execute("SELECT version(), current_database(), current_user")
                result = cur.fetchone()
                cur.execute("SELECT extversion FROM pg_extension WHERE extname = 'ruvector'")
                ruvector = cur.fetchone()
                results['project'] = {
                    'status': 'healthy',
                    'database': result['current_database'],
                    'user': result['current_user'],
                    'ruvector_version': ruvector['extversion'] if ruvector else None
                }
        except Exception as e:
            results['project'] = {'status': 'error', 'error': str(e)}

        # Check shared database
        try:
            with self.shared_cursor() as cur:
                cur.execute("SELECT version(), current_database(), current_user")
                result = cur.fetchone()
                cur.execute("SELECT extversion FROM pg_extension WHERE extname = 'ruvector'")
                ruvector = cur.fetchone()
                results['shared'] = {
                    'status': 'healthy',
                    'database': result['current_database'],
                    'user': result['current_user'],
                    'ruvector_version': ruvector['extversion'] if ruvector else None
                }
        except Exception as e:
            results['shared'] = {'status': 'error', 'error': str(e)}

        return results

    def close(self):
        """Close all connections in both pools."""
        self.project_pool.closeall()
        self.shared_pool.closeall()


# Global pool instance (singleton pattern)
_pools: Optional[DualDatabasePools] = None


def get_pools() -> DualDatabasePools:
    """Get or create the global database pools instance."""
    global _pools
    if _pools is None:
        _pools = DualDatabasePools()
    return _pools


# Backward-compatible alias
DatabasePools = DualDatabasePools


def close_pools():
    """Close all database pools."""
    global _pools
    if _pools is not None:
        _pools.close()
        _pools = None
