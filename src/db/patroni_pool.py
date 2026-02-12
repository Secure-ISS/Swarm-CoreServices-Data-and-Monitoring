"""Patroni HA-Aware Connection Pool with Automatic Failover.

This module provides connection pooling for PostgreSQL clusters managed by Patroni
with support for:
- Dynamic primary detection via Patroni REST API
- Automatic failover handling
- Read/write splitting (primary for writes, replicas for reads)
- Connection pool refresh on topology changes
- Load balancing across replicas for reads
"""

# Standard library imports
import logging
import os
import time
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Set

# Third-party imports
import psycopg2
import requests
from psycopg2 import DatabaseError, OperationalError, pool
from psycopg2.extras import RealDictCursor

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class PatroniConnectionError(Exception):
    """Raised when Patroni cluster connection fails."""

    pass


class PatroniTopologyError(Exception):
    """Raised when Patroni topology detection fails."""

    pass


@dataclass
class PatroniNode:
    """Represents a node in the Patroni cluster."""

    host: str
    port: int
    role: str  # 'leader' or 'replica'
    state: str  # 'running', 'stopped', etc.
    lag: Optional[int] = None  # Replication lag in bytes
    timeline: Optional[int] = None
    tags: Optional[Dict[str, Any]] = None

    def __hash__(self):
        return hash(f"{self.host}:{self.port}")

    def __eq__(self, other):
        return self.host == other.host and self.port == other.port


@dataclass
class PatroniClusterConfig:
    """Configuration for Patroni cluster."""

    # Patroni REST API endpoints
    patroni_hosts: List[str]
    patroni_port: int = 8008

    # Database credentials
    database: str = "postgres"
    user: str = "postgres"
    password: str = ""

    # Connection pool settings
    min_connections: int = 2
    max_connections: int = 20

    # Health check settings
    health_check_interval: int = 30  # seconds
    api_timeout: int = 5  # seconds

    # Failover settings
    failover_timeout: int = 30  # seconds
    max_retry_attempts: int = 3


class PatroniHAPool:
    """HA-aware connection pool for Patroni-managed PostgreSQL cluster.

    Features:
    - Automatic primary detection via Patroni REST API
    - Read/write splitting (primary for writes, replicas for reads)
    - Automatic failover on primary failure
    - Connection pool refresh on topology changes
    - Load balancing across healthy replicas
    """

    def __init__(self, config: PatroniClusterConfig):
        """Initialize Patroni HA pool.

        Args:
            config: Patroni cluster configuration
        """
        self.config = config
        self._primary_pool: Optional[pool.ThreadedConnectionPool] = None
        self._replica_pools: Dict[str, pool.ThreadedConnectionPool] = {}

        # Cluster topology
        self._primary_node: Optional[PatroniNode] = None
        self._replica_nodes: List[PatroniNode] = []
        self._last_topology_refresh: float = 0

        # Statistics
        self._stats = {
            "failovers": 0,
            "topology_refreshes": 0,
            "reads": 0,
            "writes": 0,
            "errors": 0,
        }

        # Initialize cluster topology
        self._refresh_topology()
        self._initialize_pools()

        logger.info(
            f"✓ Patroni HA pool initialized with primary at "
            f"{self._primary_node.host}:{self._primary_node.port}"
        )

    def _call_patroni_api(self, host: str, endpoint: str = "/cluster") -> Dict[str, Any]:
        """Call Patroni REST API on a specific host.

        Args:
            host: Patroni host
            endpoint: API endpoint

        Returns:
            API response as dictionary

        Raises:
            PatroniTopologyError: If API call fails
        """
        url = f"http://{host}:{self.config.patroni_port}{endpoint}"

        try:
            response = requests.get(url, timeout=self.config.api_timeout)
            response.raise_for_status()
            return response.json()
        except requests.RequestException as e:
            logger.warning(f"Failed to call Patroni API at {url}: {e}")
            raise PatroniTopologyError(f"Patroni API call failed: {e}") from e

    def _discover_cluster_topology(self) -> Dict[str, Any]:
        """Discover cluster topology by querying Patroni API.

        Returns:
            Cluster information dictionary

        Raises:
            PatroniTopologyError: If topology discovery fails on all hosts
        """
        last_error = None

        # Try each Patroni host until one succeeds
        for patroni_host in self.config.patroni_hosts:
            try:
                logger.info(f"Querying Patroni API at {patroni_host}...")
                cluster_info = self._call_patroni_api(patroni_host)
                return cluster_info
            except PatroniTopologyError as e:
                last_error = e
                continue

        # All hosts failed
        raise PatroniTopologyError(
            f"Failed to discover topology from all Patroni hosts: {last_error}"
        )

    def _refresh_topology(self) -> bool:
        """Refresh cluster topology from Patroni API.

        Returns:
            True if topology changed, False otherwise

        Raises:
            PatroniTopologyError: If topology refresh fails
        """
        try:
            cluster_info = self._discover_cluster_topology()
            members = cluster_info.get("members", [])

            if not members:
                raise PatroniTopologyError("No members found in cluster")

            # Parse members
            new_primary = None
            new_replicas = []

            for member in members:
                node = PatroniNode(
                    host=member["host"],
                    port=member["port"],
                    role=member["role"],
                    state=member["state"],
                    lag=member.get("lag"),
                    timeline=member.get("timeline"),
                    tags=member.get("tags"),
                )

                if node.role == "leader":
                    new_primary = node
                elif node.role == "replica" and node.state == "running":
                    new_replicas.append(node)

            if not new_primary:
                raise PatroniTopologyError("No primary node found in cluster")

            # Check if topology changed
            topology_changed = (
                self._primary_node is None
                or new_primary != self._primary_node
                or set(new_replicas) != set(self._replica_nodes)
            )

            if topology_changed:
                logger.info(
                    f"Topology change detected: Primary={new_primary.host}:{new_primary.port}, "
                    f"Replicas={len(new_replicas)}"
                )
                self._primary_node = new_primary
                self._replica_nodes = new_replicas
                self._stats["topology_refreshes"] += 1

            self._last_topology_refresh = time.time()
            return topology_changed

        except Exception as e:
            logger.error(f"Failed to refresh topology: {e}")
            raise PatroniTopologyError(f"Topology refresh failed: {e}") from e

    def _create_node_pool(self, node: PatroniNode, pool_name: str) -> pool.ThreadedConnectionPool:
        """Create connection pool for a specific node.

        Args:
            node: Database node
            pool_name: Pool identifier for logging

        Returns:
            ThreadedConnectionPool instance
        """
        # Build connection parameters with SSL/TLS support
        conn_params = {
            "minconn": self.config.min_connections,
            "maxconn": self.config.max_connections,
            "host": node.host,
            "port": node.port,
            "database": self.config.database,
            "user": self.config.user,
            "password": self.config.password,
            "cursor_factory": RealDictCursor,
            "connect_timeout": 10,
            "options": "-c statement_timeout=30000",
        }

        # Add SSL/TLS configuration
        sslmode = os.getenv("PATRONI_SSLMODE", "prefer")
        if sslmode != "disable":
            conn_params["sslmode"] = sslmode

            # Add SSL certificate paths if provided
            sslrootcert = os.getenv("PATRONI_SSLROOTCERT")
            if sslrootcert and os.path.exists(sslrootcert):
                conn_params["sslrootcert"] = sslrootcert

            sslcert = os.getenv("PATRONI_SSLCERT")
            if sslcert and os.path.exists(sslcert):
                conn_params["sslcert"] = sslcert

            sslkey = os.getenv("PATRONI_SSLKEY")
            if sslkey and os.path.exists(sslkey):
                conn_params["sslkey"] = sslkey

        try:
            logger.info(f"Creating {pool_name} pool for {node.host}:{node.port}")
            return psycopg2.pool.ThreadedConnectionPool(**conn_params)
        except OperationalError as e:
            raise PatroniConnectionError(f"Cannot connect to {node.host}:{node.port}: {e}") from e

    def _initialize_pools(self):
        """Initialize connection pools for all nodes."""
        # Close existing pools
        self._close_all_pools()

        # Create primary pool
        if self._primary_node:
            self._primary_pool = self._create_node_pool(self._primary_node, "primary")

        # Create replica pools
        self._replica_pools = {}
        for replica in self._replica_nodes:
            node_key = f"{replica.host}:{replica.port}"
            self._replica_pools[node_key] = self._create_node_pool(replica, f"replica-{node_key}")

        logger.info(f"✓ Initialized pools: 1 primary, {len(self._replica_pools)} replicas")

    def _close_all_pools(self):
        """Close all connection pools."""
        if self._primary_pool:
            self._primary_pool.closeall()
            self._primary_pool = None

        for replica_pool in self._replica_pools.values():
            replica_pool.closeall()
        self._replica_pools.clear()

    def _maybe_refresh_topology(self):
        """Refresh topology if enough time has elapsed."""
        current_time = time.time()
        if current_time - self._last_topology_refresh > self.config.health_check_interval:
            try:
                if self._refresh_topology():
                    # Topology changed, reinitialize pools
                    self._initialize_pools()
            except PatroniTopologyError as e:
                logger.error(f"Topology refresh failed: {e}")

    def _handle_failover(self) -> bool:
        """Handle primary failover by detecting new primary.

        Returns:
            True if failover succeeded, False otherwise
        """
        logger.warning("Handling failover - detecting new primary...")
        self._stats["failovers"] += 1

        start_time = time.time()
        attempt = 0

        while time.time() - start_time < self.config.failover_timeout:
            attempt += 1
            try:
                # Force topology refresh
                if self._refresh_topology():
                    # Reinitialize pools with new primary
                    self._initialize_pools()
                    logger.info(
                        f"✓ Failover complete - new primary: "
                        f"{self._primary_node.host}:{self._primary_node.port}"
                    )
                    return True
            except PatroniTopologyError as e:
                logger.warning(f"Failover attempt {attempt} failed: {e}")

            # Wait before retry
            time.sleep(2)

        logger.error(f"✗ Failover timeout after {self.config.failover_timeout}s")
        return False

    def _select_replica_pool(self) -> pool.ThreadedConnectionPool:
        """Select a replica pool for load balancing.

        Returns:
            Selected replica pool, or primary pool if no replicas available
        """
        if not self._replica_pools:
            # No replicas, use primary
            return self._primary_pool

        # Simple round-robin based on read count
        replica_keys = list(self._replica_pools.keys())
        idx = self._stats["reads"] % len(replica_keys)
        return self._replica_pools[replica_keys[idx]]

    @contextmanager
    def cursor(self, read_only: bool = False):
        """Get a cursor with automatic routing and failover.

        Args:
            read_only: If True, route to replica; if False, route to primary

        Yields:
            Database cursor

        Example:
            # Write to primary
            with pool.cursor(read_only=False) as cur:
                cur.execute("INSERT INTO table VALUES (%s)", (value,))

            # Read from replica
            with pool.cursor(read_only=True) as cur:
                cur.execute("SELECT * FROM table")
        """
        # Periodic topology refresh
        self._maybe_refresh_topology()

        # Select pool based on operation type
        if read_only:
            selected_pool = self._select_replica_pool()
            self._stats["reads"] += 1
        else:
            selected_pool = self._primary_pool
            self._stats["writes"] += 1

        conn = None
        retry_count = 0

        while retry_count < self.config.max_retry_attempts:
            try:
                conn = selected_pool.getconn()

                with conn.cursor() as cur:
                    yield cur
                conn.commit()
                return  # Success

            except (OperationalError, DatabaseError) as e:
                logger.error(f"Database error: {e}")
                self._stats["errors"] += 1

                if conn:
                    conn.rollback()

                # If write failed on primary, attempt failover
                if not read_only and "primary" in str(selected_pool):
                    logger.warning("Primary connection failed - attempting failover")
                    if self._handle_failover():
                        # Retry with new primary
                        selected_pool = self._primary_pool
                        retry_count += 1
                        continue

                # Re-raise for reads or if failover failed
                raise PatroniConnectionError(f"Database operation failed: {e}") from e

            except Exception as e:
                if conn:
                    conn.rollback()
                logger.error(f"Unexpected error: {e}")
                self._stats["errors"] += 1
                raise PatroniConnectionError(f"Transaction failed: {e}") from e

            finally:
                if conn:
                    selected_pool.putconn(conn)

        raise PatroniConnectionError(
            f"Operation failed after {self.config.max_retry_attempts} retries"
        )

    def health_check(self) -> Dict[str, Any]:
        """Perform comprehensive health check.

        Returns:
            Dictionary with health status
        """
        # Refresh topology
        try:
            self._refresh_topology()
            topology_status = "healthy"
        except Exception as e:
            topology_status = f"error: {e}"

        # Check primary
        primary_status = {"status": "unknown"}
        if self._primary_node and self._primary_pool:
            try:
                conn = self._primary_pool.getconn()
                with conn.cursor() as cur:
                    cur.execute("SELECT pg_is_in_recovery(), version()")
                    result = cur.fetchone()
                self._primary_pool.putconn(conn)
                primary_status = {
                    "status": "healthy",
                    "host": self._primary_node.host,
                    "port": self._primary_node.port,
                    "in_recovery": result["pg_is_in_recovery"],
                }
            except Exception as e:
                primary_status = {
                    "status": "error",
                    "error": str(e),
                }

        # Check replicas
        replica_statuses = []
        for node_key, replica_pool in self._replica_pools.items():
            try:
                conn = replica_pool.getconn()
                with conn.cursor() as cur:
                    cur.execute("SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn()")
                    result = cur.fetchone()
                replica_pool.putconn(conn)
                replica_statuses.append(
                    {
                        "node": node_key,
                        "status": "healthy",
                        "in_recovery": result["pg_is_in_recovery"],
                    }
                )
            except Exception as e:
                replica_statuses.append(
                    {
                        "node": node_key,
                        "status": "error",
                        "error": str(e),
                    }
                )

        return {
            "cluster_topology": topology_status,
            "primary": primary_status,
            "replicas": replica_statuses,
            "statistics": self._stats.copy(),
        }

    def get_statistics(self) -> Dict[str, int]:
        """Get cluster statistics.

        Returns:
            Dictionary with statistics
        """
        return self._stats.copy()

    def close(self):
        """Close all connection pools."""
        self._close_all_pools()
        logger.info("✓ Patroni HA pool closed")


def create_patroni_pool_from_env() -> PatroniHAPool:
    """Create Patroni HA pool from environment variables.

    Environment variables:
        PATRONI_HOSTS: Comma-separated list of Patroni REST API hosts
        PATRONI_PORT: Patroni REST API port (default: 8008)
        PATRONI_DB: Database name
        PATRONI_USER: Database user
        PATRONI_PASSWORD: Database password
        PATRONI_MIN_CONNECTIONS: Minimum connections per pool
        PATRONI_MAX_CONNECTIONS: Maximum connections per pool
        PATRONI_HEALTH_CHECK_INTERVAL: Seconds between health checks

    Returns:
        PatroniHAPool instance

    Raises:
        ValueError: If required environment variables are missing
    """
    patroni_hosts_str = os.getenv("PATRONI_HOSTS")
    if not patroni_hosts_str:
        raise ValueError("PATRONI_HOSTS environment variable is required")

    patroni_password = os.getenv("PATRONI_PASSWORD")
    if not patroni_password:
        raise ValueError("PATRONI_PASSWORD environment variable is required")

    config = PatroniClusterConfig(
        patroni_hosts=patroni_hosts_str.split(","),
        patroni_port=int(os.getenv("PATRONI_PORT", "8008")),
        database=os.getenv("PATRONI_DB", "postgres"),
        user=os.getenv("PATRONI_USER", "postgres"),
        password=patroni_password,
        min_connections=int(os.getenv("PATRONI_MIN_CONNECTIONS", "2")),
        max_connections=int(os.getenv("PATRONI_MAX_CONNECTIONS", "20")),
        health_check_interval=int(os.getenv("PATRONI_HEALTH_CHECK_INTERVAL", "30")),
    )

    return PatroniHAPool(config)


# Global Patroni pool instance
_patroni_pool: Optional[PatroniHAPool] = None


def get_patroni_pool() -> PatroniHAPool:
    """Get or create the global Patroni pool instance."""
    global _patroni_pool
    if _patroni_pool is None:
        _patroni_pool = create_patroni_pool_from_env()
    return _patroni_pool


def close_patroni_pool():
    """Close the global Patroni pool."""
    global _patroni_pool
    if _patroni_pool is not None:
        _patroni_pool.close()
        _patroni_pool = None
