"""PostgreSQL Connection Pools with RuVector Support

This module provides connection pools for both project-specific and shared
knowledge databases with RuVector vector operations support.
"""

# Standard library imports
import logging
import os
from contextlib import contextmanager
from typing import Any, Dict, Optional

# Third-party imports
import psycopg2
from psycopg2 import DatabaseError, OperationalError, pool
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
    """Manages connection pools for project and shared databases.

    Supports both single-node and Patroni HA modes based on environment variables.
    """

    def __init__(self, enable_patroni: bool = None):
        """Initialize both connection pools from environment variables.

        Args:
            enable_patroni: Force Patroni mode on/off. If None, auto-detect from environment.

        Raises:
            DatabaseConnectionError: If connection to database fails
            DatabaseConfigurationError: If required configuration is missing
        """
        # Auto-detect or use explicit Patroni mode
        if enable_patroni is None:
            enable_patroni = os.getenv("ENABLE_PATRONI", "false").lower() == "true"

        self.patroni_mode = enable_patroni
        self.patroni_pool = None

        if self.patroni_mode:
            logger.info("Operating in Patroni HA mode")
            try:
                # Import here to avoid circular dependency
                from .patroni_pool import create_patroni_pool_from_env

                self.patroni_pool = create_patroni_pool_from_env()
                logger.info("✓ Patroni HA pool initialized")
                # In Patroni mode, project_pool and shared_pool point to the same HA pool
                self.project_pool = None
                self.shared_pool = None
                return
            except Exception as e:
                logger.error(f"✗ Failed to initialize Patroni pool: {e}")
                raise DatabaseConnectionError(f"Patroni pool initialization failed: {e}") from e

        # Single-node mode
        logger.info("Operating in single-node mode")
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
        required = ["RUVECTOR_DB", "RUVECTOR_USER", "RUVECTOR_PASSWORD"]
        missing = [key for key in required if not os.getenv(key)]

        if missing:
            raise DatabaseConfigurationError(
                f"Missing required environment variables: {', '.join(missing)}"
            )

        return {
            "host": os.getenv("RUVECTOR_HOST", "localhost"),
            "port": int(os.getenv("RUVECTOR_PORT", "5432")),
            "database": os.getenv("RUVECTOR_DB"),
            "user": os.getenv("RUVECTOR_USER"),
            "password": os.getenv("RUVECTOR_PASSWORD"),
        }

    def _validate_shared_config(self) -> Dict[str, str]:
        """Validate and return shared database configuration.

        Returns:
            Dict with validated configuration

        Raises:
            DatabaseConfigurationError: If required config is missing
        """
        required = ["SHARED_KNOWLEDGE_DB", "SHARED_KNOWLEDGE_USER", "SHARED_KNOWLEDGE_PASSWORD"]
        missing = [key for key in required if not os.getenv(key)]

        if missing:
            raise DatabaseConfigurationError(
                f"Missing required environment variables: {', '.join(missing)}"
            )

        return {
            "host": os.getenv("SHARED_KNOWLEDGE_HOST", "localhost"),
            "port": int(os.getenv("SHARED_KNOWLEDGE_PORT", "5432")),
            "database": os.getenv("SHARED_KNOWLEDGE_DB"),
            "user": os.getenv("SHARED_KNOWLEDGE_USER"),
            "password": os.getenv("SHARED_KNOWLEDGE_PASSWORD"),
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

        # Build connection parameters with SSL/TLS support
        conn_params = {
            "minconn": 2,
            "maxconn": 40,  # Increased from 25 to support 35+ concurrent agents with headroom
            "host": config["host"],
            "port": config["port"],
            "database": config["database"],
            "user": config["user"],
            "password": config["password"],
            "cursor_factory": RealDictCursor,
            "connect_timeout": 10,
        }

        # Add SSL/TLS configuration
        sslmode = os.getenv("RUVECTOR_SSLMODE", "prefer")
        if sslmode != "disable":
            conn_params["sslmode"] = sslmode

            # Add SSL certificate paths if provided
            sslrootcert = os.getenv("RUVECTOR_SSLROOTCERT")
            if sslrootcert and os.path.exists(sslrootcert):
                conn_params["sslrootcert"] = sslrootcert

            sslcert = os.getenv("RUVECTOR_SSLCERT")
            if sslcert and os.path.exists(sslcert):
                conn_params["sslcert"] = sslcert

            sslkey = os.getenv("RUVECTOR_SSLKEY")
            if sslkey and os.path.exists(sslkey):
                conn_params["sslkey"] = sslkey

            logger.info(f"Project pool SSL mode: {sslmode}")

        try:
            return psycopg2.pool.ThreadedConnectionPool(**conn_params)
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

        # Build connection parameters with SSL/TLS support
        conn_params = {
            "minconn": 1,
            "maxconn": 15,  # Increased from 10 to support 35+ concurrent agents with headroom
            "host": config["host"],
            "port": config["port"],
            "database": config["database"],
            "user": config["user"],
            "password": config["password"],
            "cursor_factory": RealDictCursor,
            "connect_timeout": 10,
        }

        # Add SSL/TLS configuration
        sslmode = os.getenv("SHARED_KNOWLEDGE_SSLMODE", "prefer")
        if sslmode != "disable":
            conn_params["sslmode"] = sslmode

            # Add SSL certificate paths if provided
            sslrootcert = os.getenv("SHARED_KNOWLEDGE_SSLROOTCERT")
            if sslrootcert and os.path.exists(sslrootcert):
                conn_params["sslrootcert"] = sslrootcert

            sslcert = os.getenv("SHARED_KNOWLEDGE_SSLCERT")
            if sslcert and os.path.exists(sslcert):
                conn_params["sslcert"] = sslcert

            sslkey = os.getenv("SHARED_KNOWLEDGE_SSLKEY")
            if sslkey and os.path.exists(sslkey):
                conn_params["sslkey"] = sslkey

            logger.info(f"Shared pool SSL mode: {sslmode}")

        try:
            return psycopg2.pool.ThreadedConnectionPool(**conn_params)
        except OperationalError as e:
            raise DatabaseConnectionError(
                f"Cannot connect to shared database at {config['host']}:{config['port']}. "
                f"Ensure PostgreSQL is running. Error: {e}"
            ) from e
        except Exception as e:
            raise DatabaseConnectionError(f"Unexpected error creating shared pool: {e}") from e

    @contextmanager
    def project_cursor(self, read_only: bool = False):
        """Get a cursor from the project database pool.

        Args:
            read_only: If True and Patroni mode is enabled, route to replica.
                      Ignored in single-node mode.

        Yields:
            psycopg2 cursor with RealDictCursor factory

        Raises:
            DatabaseError: If database operation fails
        """
        # Patroni mode - use HA pool with read/write routing
        if self.patroni_mode:
            with self.patroni_pool.cursor(read_only=read_only) as cur:
                yield cur
            return

        # Single-node mode
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
    def shared_cursor(self, read_only: bool = False):
        """Get a cursor from the shared knowledge database pool.

        Args:
            read_only: If True and Patroni mode is enabled, route to replica.
                      Ignored in single-node mode.

        Yields:
            psycopg2 cursor with RealDictCursor factory

        Raises:
            DatabaseError: If database operation fails
        """
        # Patroni mode - use HA pool with read/write routing
        if self.patroni_mode:
            with self.patroni_pool.cursor(read_only=read_only) as cur:
                yield cur
            return

        # Single-node mode
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

        # Patroni mode - use HA pool health check
        if self.patroni_mode:
            return {
                "mode": "patroni",
                "ha_cluster": self.patroni_pool.health_check(),
            }

        # Single-node mode
        results["mode"] = "single-node"

        # Check project database
        try:
            with self.project_cursor() as cur:
                cur.execute("SELECT version(), current_database(), current_user")
                result = cur.fetchone()
                cur.execute("SELECT extversion FROM pg_extension WHERE extname = 'ruvector'")
                ruvector = cur.fetchone()

                # Check SSL/TLS status
                cur.execute("SELECT ssl, cipher FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
                ssl_info = cur.fetchone()

                results["project"] = {
                    "status": "healthy",
                    "database": result["current_database"],
                    "user": result["current_user"],
                    "ruvector_version": ruvector["extversion"] if ruvector else None,
                    "ssl_enabled": ssl_info["ssl"] if ssl_info else False,
                    "ssl_cipher": ssl_info["cipher"] if ssl_info and ssl_info["ssl"] else None,
                }
        except Exception as e:
            results["project"] = {"status": "error", "error": str(e)}

        # Check shared database
        try:
            with self.shared_cursor() as cur:
                cur.execute("SELECT version(), current_database(), current_user")
                result = cur.fetchone()
                cur.execute("SELECT extversion FROM pg_extension WHERE extname = 'ruvector'")
                ruvector = cur.fetchone()

                # Check SSL/TLS status
                cur.execute("SELECT ssl, cipher FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
                ssl_info = cur.fetchone()

                results["shared"] = {
                    "status": "healthy",
                    "database": result["current_database"],
                    "user": result["current_user"],
                    "ruvector_version": ruvector["extversion"] if ruvector else None,
                    "ssl_enabled": ssl_info["ssl"] if ssl_info else False,
                    "ssl_cipher": ssl_info["cipher"] if ssl_info and ssl_info["ssl"] else None,
                }
        except Exception as e:
            results["shared"] = {"status": "error", "error": str(e)}

        return results

    def close(self):
        """Close all connections in both pools."""
        if self.patroni_mode:
            if self.patroni_pool:
                self.patroni_pool.close()
        else:
            if self.project_pool:
                self.project_pool.closeall()
            if self.shared_pool:
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
