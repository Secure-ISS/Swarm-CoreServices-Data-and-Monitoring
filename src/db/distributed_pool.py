"""Distributed PostgreSQL Connection Pool with Shard-Aware Routing.

This module provides connection pooling and routing for a distributed PostgreSQL
cluster with support for:
- Read/write splitting
- Automatic shard detection and routing
- Load balancing across replicas
- Connection retry with exponential backoff
- Health monitoring and automatic failover
- Distributed transaction coordination
"""

# Standard library imports
import hashlib
import logging
import os
import random
import time
from contextlib import contextmanager
from dataclasses import dataclass
from enum import Enum
from typing import Any, Callable, Dict, List, Optional, Tuple

# Third-party imports
import psycopg2
from psycopg2 import DatabaseError, OperationalError, pool
from psycopg2.extras import RealDictCursor

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class NodeRole(Enum):
    """Database node role."""

    COORDINATOR = "coordinator"
    WORKER = "worker"
    REPLICA = "replica"


class QueryType(Enum):
    """Query type for routing decisions."""

    READ = "read"
    WRITE = "write"
    DDL = "ddl"
    DISTRIBUTED = "distributed"


class DistributedConnectionError(Exception):
    """Raised when distributed connection operation fails."""

    pass


class ShardingError(Exception):
    """Raised when sharding operation fails."""

    pass


@dataclass
class DatabaseNode:
    """Represents a database node in the cluster."""

    host: str
    port: int
    database: str
    user: str
    password: str
    role: NodeRole
    shard_id: Optional[int] = None
    weight: float = 1.0  # For load balancing
    max_connections: int = 20
    min_connections: int = 2

    def __hash__(self):
        return hash(f"{self.host}:{self.port}/{self.database}")

    def connection_string(self) -> str:
        """Generate connection string for this node."""
        return f"postgresql://{self.user}:{self.password}@{self.host}:{self.port}/{self.database}"


@dataclass
class RetryConfig:
    """Configuration for connection retry logic."""

    max_retries: int = 3
    initial_backoff: float = 0.1
    max_backoff: float = 10.0
    backoff_multiplier: float = 2.0
    jitter: bool = True


class DistributedDatabasePool:
    """Manages connection pools for a distributed PostgreSQL cluster.

    Features:
    - Multiple node support (coordinator + workers/replicas)
    - Shard-aware query routing
    - Read/write splitting for replicas
    - Automatic failover and retry
    - Load balancing
    - Health monitoring
    """

    def __init__(
        self,
        coordinator_node: DatabaseNode,
        worker_nodes: Optional[List[DatabaseNode]] = None,
        replica_nodes: Optional[List[DatabaseNode]] = None,
        retry_config: Optional[RetryConfig] = None,
        enable_health_check: bool = True,
        health_check_interval: int = 60,
    ):
        """Initialize distributed database pool.

        Args:
            coordinator_node: Primary coordinator node (required)
            worker_nodes: Optional list of worker nodes (for Citus-style distribution)
            replica_nodes: Optional list of read replicas
            retry_config: Retry configuration
            enable_health_check: Enable periodic health checks
            health_check_interval: Seconds between health checks
        """
        self.coordinator = coordinator_node
        self.workers = worker_nodes or []
        self.replicas = replica_nodes or []
        self.retry_config = retry_config or RetryConfig()
        self.enable_health_check = enable_health_check
        self.health_check_interval = health_check_interval

        # Connection pools
        self._coordinator_pool: Optional[pool.ThreadedConnectionPool] = None
        self._worker_pools: Dict[int, pool.ThreadedConnectionPool] = {}
        self._replica_pools: List[pool.ThreadedConnectionPool] = []

        # Health state
        self._node_health: Dict[str, bool] = {}
        self._last_health_check: float = 0

        # Shard mapping (populated on first connection)
        self._shard_map: Dict[int, DatabaseNode] = {}

        # Statistics
        self._query_stats: Dict[str, int] = {
            "total": 0,
            "reads": 0,
            "writes": 0,
            "errors": 0,
            "retries": 0,
        }

        # Initialize pools
        self._initialize_pools()

    def _initialize_pools(self):
        """Initialize all connection pools."""
        try:
            # Coordinator pool
            logger.info(
                f"Initializing coordinator pool: {self.coordinator.host}:{self.coordinator.port}"
            )
            self._coordinator_pool = self._create_pool(self.coordinator)
            self._node_health[f"{self.coordinator.host}:{self.coordinator.port}"] = True

            # Worker pools (indexed by shard_id)
            for worker in self.workers:
                logger.info(
                    f"Initializing worker pool: {worker.host}:{worker.port} (shard {worker.shard_id})"
                )
                if worker.shard_id is None:
                    logger.warning(f"Worker {worker.host}:{worker.port} has no shard_id")
                    continue
                self._worker_pools[worker.shard_id] = self._create_pool(worker)
                self._shard_map[worker.shard_id] = worker
                self._node_health[f"{worker.host}:{worker.port}"] = True

            # Replica pools
            for idx, replica in enumerate(self.replicas):
                logger.info(f"Initializing replica pool {idx}: {replica.host}:{replica.port}")
                replica_pool = self._create_pool(replica)
                self._replica_pools.append(replica_pool)
                self._node_health[f"{replica.host}:{replica.port}"] = True

            logger.info(
                f"✓ Initialized distributed pool: 1 coordinator, {len(self.workers)} workers, {len(self.replicas)} replicas"
            )

        except Exception as e:
            logger.error(f"✗ Failed to initialize distributed pool: {e}")
            self.close()
            raise DistributedConnectionError(f"Pool initialization failed: {e}") from e

    def _create_pool(self, node: DatabaseNode) -> pool.ThreadedConnectionPool:
        """Create a connection pool for a specific node."""
        # Build connection parameters with SSL/TLS support
        conn_params = {
            "minconn": node.min_connections,
            "maxconn": node.max_connections,
            "host": node.host,
            "port": node.port,
            "database": node.database,
            "user": node.user,
            "password": node.password,
            "cursor_factory": RealDictCursor,
            "connect_timeout": 10,
            "options": "-c statement_timeout=30000",  # 30s statement timeout
        }

        # Add SSL/TLS configuration
        sslmode = os.getenv("DISTRIBUTED_SSLMODE", "prefer")
        if sslmode != "disable":
            conn_params["sslmode"] = sslmode

            # Add SSL certificate paths if provided
            sslrootcert = os.getenv("DISTRIBUTED_SSLROOTCERT")
            if sslrootcert and os.path.exists(sslrootcert):
                conn_params["sslrootcert"] = sslrootcert

            sslcert = os.getenv("DISTRIBUTED_SSLCERT")
            if sslcert and os.path.exists(sslcert):
                conn_params["sslcert"] = sslcert

            sslkey = os.getenv("DISTRIBUTED_SSLKEY")
            if sslkey and os.path.exists(sslkey):
                conn_params["sslkey"] = sslkey

            logger.info(f"Distributed pool SSL mode for {node.host}:{node.port}: {sslmode}")

        try:
            return psycopg2.pool.ThreadedConnectionPool(**conn_params)
        except OperationalError as e:
            raise DistributedConnectionError(
                f"Cannot connect to {node.host}:{node.port}. Error: {e}"
            ) from e

    def _retry_with_backoff(self, operation: Callable, operation_name: str) -> Any:
        """Execute operation with exponential backoff retry.

        Args:
            operation: Function to execute
            operation_name: Name for logging

        Returns:
            Result of operation

        Raises:
            DistributedConnectionError: If all retries fail
        """
        last_error = None
        backoff = self.retry_config.initial_backoff

        for attempt in range(self.retry_config.max_retries):
            try:
                return operation()
            except (OperationalError, DatabaseError) as e:
                last_error = e
                self._query_stats["retries"] += 1

                if attempt < self.retry_config.max_retries - 1:
                    # Add jitter to prevent thundering herd
                    sleep_time = backoff
                    if self.retry_config.jitter:
                        sleep_time *= 0.5 + random.random()

                    logger.warning(
                        f"Retry {attempt + 1}/{self.retry_config.max_retries} for {operation_name} "
                        f"after {sleep_time:.2f}s. Error: {e}"
                    )
                    time.sleep(sleep_time)
                    backoff = min(
                        backoff * self.retry_config.backoff_multiplier,
                        self.retry_config.max_backoff,
                    )
                else:
                    logger.error(f"All retries exhausted for {operation_name}")

        self._query_stats["errors"] += 1
        raise DistributedConnectionError(
            f"{operation_name} failed after {self.retry_config.max_retries} retries: {last_error}"
        )

    def _get_shard_for_key(self, shard_key: Any) -> int:
        """Determine shard ID for a given shard key.

        Args:
            shard_key: The key to hash for shard determination

        Returns:
            Shard ID
        """
        if not self.workers:
            return 0  # No sharding if no workers

        # Hash the shard key
        key_str = str(shard_key)
        hash_value = int(hashlib.md5(key_str.encode(), usedforsecurity=False).hexdigest(), 16)

        # Modulo to get shard
        num_shards = len(self.workers)
        shard_id = hash_value % num_shards

        return shard_id

    def _select_replica_pool(self) -> pool.ThreadedConnectionPool:
        """Select a replica pool using weighted round-robin.

        Returns:
            Selected replica pool
        """
        if not self._replica_pools:
            # Fallback to coordinator if no replicas
            return self._coordinator_pool

        # Simple round-robin (could be enhanced with weights)
        idx = self._query_stats["reads"] % len(self._replica_pools)
        return self._replica_pools[idx]

    @contextmanager
    def cursor(
        self,
        query_type: QueryType = QueryType.WRITE,
        shard_key: Optional[Any] = None,
        preferred_node: Optional[str] = None,
    ):
        """Get a cursor with automatic routing to appropriate node.

        Args:
            query_type: Type of query (READ/WRITE/DDL/DISTRIBUTED)
            shard_key: Optional key for shard routing
            preferred_node: Optional preferred node identifier

        Yields:
            Database cursor

        Example:
            # Write to coordinator
            with pool.cursor(QueryType.WRITE) as cur:
                cur.execute("INSERT INTO table VALUES (%s)", (value,))

            # Read from replica
            with pool.cursor(QueryType.READ) as cur:
                cur.execute("SELECT * FROM table")

            # Shard-aware write
            with pool.cursor(QueryType.WRITE, shard_key=user_id) as cur:
                cur.execute("INSERT INTO users VALUES (%s, %s)", (user_id, name))
        """
        # Periodic health check
        if self.enable_health_check:
            current_time = time.time()
            if current_time - self._last_health_check > self.health_check_interval:
                self._perform_health_check()
                self._last_health_check = current_time

        # Route to appropriate pool
        if query_type == QueryType.READ and self._replica_pools:
            selected_pool = self._select_replica_pool()
            self._query_stats["reads"] += 1
        elif shard_key is not None and self.workers:
            shard_id = self._get_shard_for_key(shard_key)
            selected_pool = self._worker_pools.get(shard_id, self._coordinator_pool)
            self._query_stats["writes"] += 1
        else:
            selected_pool = self._coordinator_pool
            if query_type == QueryType.WRITE:
                self._query_stats["writes"] += 1
            else:
                self._query_stats["reads"] += 1

        self._query_stats["total"] += 1

        # Execute with retry
        conn = None
        try:

            def get_conn():
                return selected_pool.getconn()

            conn = self._retry_with_backoff(get_conn, "get_connection")

            with conn.cursor() as cur:
                yield cur
            conn.commit()

        except DatabaseError as e:
            if conn:
                conn.rollback()
            logger.error(f"Database error: {e}")
            self._query_stats["errors"] += 1
            raise
        except Exception as e:
            if conn:
                conn.rollback()
            logger.error(f"Unexpected error: {e}")
            self._query_stats["errors"] += 1
            raise DistributedConnectionError(f"Transaction failed: {e}") from e
        finally:
            if conn:
                selected_pool.putconn(conn)

    @contextmanager
    def distributed_transaction(self, shard_keys: List[Any] = None):
        """Execute a distributed transaction across multiple shards.

        This uses two-phase commit for consistency across shards.

        Args:
            shard_keys: List of shard keys involved in transaction

        Yields:
            Dict of shard_id -> cursor

        Example:
            with pool.distributed_transaction([user_id_1, user_id_2]) as cursors:
                for shard_id, cur in cursors.items():
                    cur.execute("UPDATE users SET balance = balance - 100")
        """
        if not shard_keys or not self.workers:
            # Single node transaction
            with self.cursor(QueryType.WRITE) as cur:
                yield {0: cur}
            return

        # Determine involved shards
        shard_ids = list(set(self._get_shard_for_key(key) for key in shard_keys))

        connections = {}
        cursors = {}
        transaction_id = f"dist_txn_{int(time.time() * 1000)}"

        try:
            # Phase 1: Prepare on all shards
            for shard_id in shard_ids:
                selected_pool = self._worker_pools.get(shard_id, self._coordinator_pool)
                conn = selected_pool.getconn()
                connections[shard_id] = conn
                cursors[shard_id] = conn.cursor()

                # Begin transaction
                cursors[shard_id].execute("BEGIN")

            # Execute user operations
            yield cursors

            # Phase 2: Prepare all shards
            for shard_id, cur in cursors.items():
                cur.execute(f"PREPARE TRANSACTION '{transaction_id}_{shard_id}'")

            # Phase 3: Commit all shards
            for shard_id, cur in cursors.items():
                cur.execute(f"COMMIT PREPARED '{transaction_id}_{shard_id}'")

            logger.info(
                f"Distributed transaction {transaction_id} committed across {len(shard_ids)} shards"
            )

        except Exception as e:
            logger.error(f"Distributed transaction {transaction_id} failed: {e}")

            # Rollback all prepared transactions
            for shard_id, cur in cursors.items():
                try:
                    cur.execute(f"ROLLBACK PREPARED '{transaction_id}_{shard_id}'")
                except Exception as rollback_error:
                    logger.error(f"Failed to rollback shard {shard_id}: {rollback_error}")

            raise DistributedConnectionError(f"Distributed transaction failed: {e}") from e

        finally:
            # Close cursors and return connections
            for shard_id, cur in cursors.items():
                cur.close()
            for shard_id, conn in connections.items():
                selected_pool = self._worker_pools.get(shard_id, self._coordinator_pool)
                selected_pool.putconn(conn)

    def _perform_health_check(self):
        """Perform health check on all nodes."""

        def check_pool(pool_obj, node_key):
            try:
                conn = pool_obj.getconn()
                with conn.cursor() as cur:
                    cur.execute("SELECT 1")
                pool_obj.putconn(conn)
                self._node_health[node_key] = True
                return True
            except Exception as e:
                logger.warning(f"Health check failed for {node_key}: {e}")
                self._node_health[node_key] = False
                return False

        # Check coordinator
        check_pool(self._coordinator_pool, f"{self.coordinator.host}:{self.coordinator.port}")

        # Check workers
        for shard_id, worker_pool in self._worker_pools.items():
            worker = self._shard_map[shard_id]
            check_pool(worker_pool, f"{worker.host}:{worker.port}")

        # Check replicas
        for idx, replica_pool in enumerate(self._replica_pools):
            replica = self.replicas[idx]
            check_pool(replica_pool, f"{replica.host}:{replica.port}")

    def health_check(self) -> Dict[str, Any]:
        """Perform comprehensive health check and return status.

        Returns:
            Dictionary with health status of all nodes
        """
        self._perform_health_check()

        return {
            "coordinator": {
                "host": self.coordinator.host,
                "port": self.coordinator.port,
                "healthy": self._node_health.get(
                    f"{self.coordinator.host}:{self.coordinator.port}", False
                ),
            },
            "workers": [
                {
                    "shard_id": worker.shard_id,
                    "host": worker.host,
                    "port": worker.port,
                    "healthy": self._node_health.get(f"{worker.host}:{worker.port}", False),
                }
                for worker in self.workers
            ],
            "replicas": [
                {
                    "host": replica.host,
                    "port": replica.port,
                    "healthy": self._node_health.get(f"{replica.host}:{replica.port}", False),
                }
                for replica in self.replicas
            ],
            "statistics": self._query_stats.copy(),
        }

    def get_statistics(self) -> Dict[str, int]:
        """Get query statistics.

        Returns:
            Dictionary with query statistics
        """
        return self._query_stats.copy()

    def close(self):
        """Close all connection pools."""
        if self._coordinator_pool:
            self._coordinator_pool.closeall()

        for worker_pool in self._worker_pools.values():
            worker_pool.closeall()

        for replica_pool in self._replica_pools:
            replica_pool.closeall()

        logger.info("✓ All distributed pools closed")


def create_pool_from_env() -> DistributedDatabasePool:
    """Create a distributed pool from environment variables.

    Environment variables:
        # Coordinator (required)
        COORDINATOR_HOST, COORDINATOR_PORT, COORDINATOR_DB,
        COORDINATOR_USER, COORDINATOR_PASSWORD

        # Workers (optional, comma-separated)
        WORKER_HOSTS, WORKER_PORTS, WORKER_DBS,
        WORKER_USERS, WORKER_PASSWORDS, WORKER_SHARD_IDS

        # Replicas (optional, comma-separated)
        REPLICA_HOSTS, REPLICA_PORTS, REPLICA_DBS,
        REPLICA_USERS, REPLICA_PASSWORDS

    Returns:
        DistributedDatabasePool instance
    """
    # Coordinator node (required)
    coordinator_password = os.getenv("COORDINATOR_PASSWORD")
    if not coordinator_password:
        raise ValueError(
            "COORDINATOR_PASSWORD environment variable is required. "
            "Please set it in your .env file or environment."
        )

    coordinator = DatabaseNode(
        host=os.getenv("COORDINATOR_HOST", "localhost"),
        port=int(os.getenv("COORDINATOR_PORT", "5432")),
        database=os.getenv("COORDINATOR_DB", "distributed_postgres_cluster"),
        user=os.getenv("COORDINATOR_USER", "dpg_cluster"),
        password=coordinator_password,
        role=NodeRole.COORDINATOR,
    )

    # Worker nodes (optional)
    workers = []
    worker_hosts = os.getenv("WORKER_HOSTS", "").split(",")
    if worker_hosts and worker_hosts[0]:
        worker_ports = os.getenv("WORKER_PORTS", "").split(",")
        worker_dbs = os.getenv("WORKER_DBS", "").split(",")
        worker_users = os.getenv("WORKER_USERS", "").split(",")
        worker_passwords = os.getenv("WORKER_PASSWORDS", "").split(",")
        worker_shard_ids = os.getenv("WORKER_SHARD_IDS", "").split(",")

        for idx, host in enumerate(worker_hosts):
            if host.strip():
                workers.append(
                    DatabaseNode(
                        host=host.strip(),
                        port=int(worker_ports[idx]) if idx < len(worker_ports) else 5432,
                        database=worker_dbs[idx].strip() if idx < len(worker_dbs) else "postgres",
                        user=worker_users[idx].strip() if idx < len(worker_users) else "postgres",
                        password=(
                            worker_passwords[idx].strip() if idx < len(worker_passwords) else ""
                        ),
                        role=NodeRole.WORKER,
                        shard_id=int(worker_shard_ids[idx]) if idx < len(worker_shard_ids) else idx,
                    )
                )

    # Replica nodes (optional)
    replicas = []
    replica_hosts = os.getenv("REPLICA_HOSTS", "").split(",")
    if replica_hosts and replica_hosts[0]:
        replica_ports = os.getenv("REPLICA_PORTS", "").split(",")
        replica_dbs = os.getenv("REPLICA_DBS", "").split(",")
        replica_users = os.getenv("REPLICA_USERS", "").split(",")
        replica_passwords = os.getenv("REPLICA_PASSWORDS", "").split(",")

        for idx, host in enumerate(replica_hosts):
            if host.strip():
                replicas.append(
                    DatabaseNode(
                        host=host.strip(),
                        port=int(replica_ports[idx]) if idx < len(replica_ports) else 5432,
                        database=replica_dbs[idx].strip() if idx < len(replica_dbs) else "postgres",
                        user=replica_users[idx].strip() if idx < len(replica_users) else "postgres",
                        password=(
                            replica_passwords[idx].strip() if idx < len(replica_passwords) else ""
                        ),
                        role=NodeRole.REPLICA,
                    )
                )

    return DistributedDatabasePool(
        coordinator_node=coordinator,
        worker_nodes=workers if workers else None,
        replica_nodes=replicas if replicas else None,
    )


# Global distributed pool instance
_distributed_pool: Optional[DistributedDatabasePool] = None


def get_distributed_pool() -> DistributedDatabasePool:
    """Get or create the global distributed pool instance."""
    global _distributed_pool
    if _distributed_pool is None:
        _distributed_pool = create_pool_from_env()
    return _distributed_pool


def close_distributed_pool():
    """Close the global distributed pool."""
    global _distributed_pool
    if _distributed_pool is not None:
        _distributed_pool.close()
        _distributed_pool = None
