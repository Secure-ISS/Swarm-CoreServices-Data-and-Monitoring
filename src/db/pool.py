"""PostgreSQL Connection Pools with RuVector Support

This module provides connection pools for both project-specific and shared
knowledge databases with RuVector vector operations support.
"""
import os
import logging
from contextlib import contextmanager
from typing import Optional, Dict, Any
import psycopg2
from psycopg2 import pool, OperationalError, DatabaseError
from psycopg2.extras import RealDictCursor

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class DatabaseConnectionError(Exception):
    """Raised when database connection fails."""
    pass


class DatabaseConfigurationError(Exception):
    """Raised when database configuration is invalid."""
    pass


class DualDatabasePools:
    """Manages connection pools for project and shared databases."""

    def __init__(self):
        """Initialize both connection pools from environment variables.

        Raises:
            DatabaseConnectionError: If connection to database fails
            DatabaseConfigurationError: If required configuration is missing
        """
        try:
            self.project_pool = self._create_project_pool()
            logger.info("✓ Project database pool initialized")
        except Exception as e:
            logger.error(f"✗ Failed to initialize project database pool: {e}")
            raise DatabaseConnectionError(f"Project database connection failed: {e}") from e

        try:
            self.shared_pool = self._create_shared_pool()
            logger.info("✓ Shared database pool initialized")
        except Exception as e:
            logger.error(f"✗ Failed to initialize shared database pool: {e}")
            # Close project pool if shared pool fails
            if self.project_pool:
                self.project_pool.closeall()
            raise DatabaseConnectionError(f"Shared database connection failed: {e}") from e

    def _validate_project_config(self) -> Dict[str, str]:
        """Validate and return project database configuration.

        Returns:
            Dict with validated configuration

        Raises:
            DatabaseConfigurationError: If required config is missing
        """
        required = ['RUVECTOR_DB', 'RUVECTOR_USER', 'RUVECTOR_PASSWORD']
        missing = [key for key in required if not os.getenv(key)]

        if missing:
            raise DatabaseConfigurationError(
                f"Missing required environment variables: {', '.join(missing)}"
            )

        return {
            'host': os.getenv('RUVECTOR_HOST', 'localhost'),
            'port': int(os.getenv('RUVECTOR_PORT', '5432')),
            'database': os.getenv('RUVECTOR_DB'),
            'user': os.getenv('RUVECTOR_USER'),
            'password': os.getenv('RUVECTOR_PASSWORD')
        }

    def _validate_shared_config(self) -> Dict[str, str]:
        """Validate and return shared database configuration.

        Returns:
            Dict with validated configuration

        Raises:
            DatabaseConfigurationError: If required config is missing
        """
        required = ['SHARED_KNOWLEDGE_DB', 'SHARED_KNOWLEDGE_USER', 'SHARED_KNOWLEDGE_PASSWORD']
        missing = [key for key in required if not os.getenv(key)]

        if missing:
            raise DatabaseConfigurationError(
                f"Missing required environment variables: {', '.join(missing)}"
            )

        return {
            'host': os.getenv('SHARED_KNOWLEDGE_HOST', 'localhost'),
            'port': int(os.getenv('SHARED_KNOWLEDGE_PORT', '5432')),
            'database': os.getenv('SHARED_KNOWLEDGE_DB'),
            'user': os.getenv('SHARED_KNOWLEDGE_USER'),
            'password': os.getenv('SHARED_KNOWLEDGE_PASSWORD')
        }

    def _create_project_pool(self):
        """Create connection pool for project-specific database.

        Returns:
            ThreadedConnectionPool instance

        Raises:
            DatabaseConfigurationError: If configuration is invalid
            DatabaseConnectionError: If connection fails
        """
        config = self._validate_project_config()

        try:
            return psycopg2.pool.ThreadedConnectionPool(
                minconn=1,
                maxconn=10,
                host=config['host'],
                port=config['port'],
                database=config['database'],
                user=config['user'],
                password=config['password'],
                cursor_factory=RealDictCursor,
                connect_timeout=10
            )
        except OperationalError as e:
            raise DatabaseConnectionError(
                f"Cannot connect to project database at {config['host']}:{config['port']}. "
                f"Ensure PostgreSQL is running. Error: {e}"
            ) from e
        except Exception as e:
            raise DatabaseConnectionError(f"Unexpected error creating project pool: {e}") from e

    def _create_shared_pool(self):
        """Create connection pool for shared knowledge database.

        Returns:
            ThreadedConnectionPool instance

        Raises:
            DatabaseConfigurationError: If configuration is invalid
            DatabaseConnectionError: If connection fails
        """
        config = self._validate_shared_config()

        try:
            return psycopg2.pool.ThreadedConnectionPool(
                minconn=1,
                maxconn=5,
                host=config['host'],
                port=config['port'],
                database=config['database'],
                user=config['user'],
                password=config['password'],
                cursor_factory=RealDictCursor,
                connect_timeout=10
            )
        except OperationalError as e:
            raise DatabaseConnectionError(
                f"Cannot connect to shared database at {config['host']}:{config['port']}. "
                f"Ensure PostgreSQL is running. Error: {e}"
            ) from e
        except Exception as e:
            raise DatabaseConnectionError(f"Unexpected error creating shared pool: {e}") from e

    @contextmanager
    def project_cursor(self):
        """Get a cursor from the project database pool.

        Yields:
            psycopg2 cursor with RealDictCursor factory

        Raises:
            DatabaseError: If database operation fails
        """
        conn = None
        try:
            conn = self.project_pool.getconn()
            with conn.cursor() as cur:
                yield cur
            conn.commit()
        except DatabaseError as e:
            if conn:
                conn.rollback()
            logger.error(f"Database error in project cursor: {e}")
            raise
        except Exception as e:
            if conn:
                conn.rollback()
            logger.error(f"Unexpected error in project cursor: {e}")
            raise DatabaseError(f"Transaction failed: {e}") from e
        finally:
            if conn:
                self.project_pool.putconn(conn)

    @contextmanager
    def shared_cursor(self):
        """Get a cursor from the shared knowledge database pool.

        Yields:
            psycopg2 cursor with RealDictCursor factory

        Raises:
            DatabaseError: If database operation fails
        """
        conn = None
        try:
            conn = self.shared_pool.getconn()
            with conn.cursor() as cur:
                yield cur
            conn.commit()
        except DatabaseError as e:
            if conn:
                conn.rollback()
            logger.error(f"Database error in shared cursor: {e}")
            raise
        except Exception as e:
            if conn:
                conn.rollback()
            logger.error(f"Unexpected error in shared cursor: {e}")
            raise DatabaseError(f"Transaction failed: {e}") from e
        finally:
            if conn:
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
