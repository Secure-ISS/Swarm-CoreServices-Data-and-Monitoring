"""Pytest configuration for integration tests.

Provides fixtures for:
- Database connections (single-node and distributed)
- Redis cache connections
- HAProxy routing
- Patroni cluster management
- Test data cleanup
"""

# Standard library imports
import os
import time
from typing import Dict, Generator, List, Optional

# Third-party imports
import psycopg2
import pytest
import redis
from psycopg2.extras import RealDictCursor


@pytest.fixture(scope="session")
def test_env() -> Dict[str, str]:
    """Get test environment configuration."""
    return {
        # Single-node PostgreSQL
        "postgres_host": os.getenv("RUVECTOR_HOST", "localhost"),
        "postgres_port": int(os.getenv("RUVECTOR_PORT", "5432")),
        "postgres_db": os.getenv("RUVECTOR_DB", "distributed_postgres_cluster"),
        "postgres_user": os.getenv("RUVECTOR_USER", "dpg_cluster"),
        "postgres_password": os.getenv("RUVECTOR_PASSWORD", "dpg_cluster_2026"),
        # Redis cache
        "redis_host": os.getenv("REDIS_HOST", "localhost"),
        "redis_port": int(os.getenv("REDIS_PORT", "6379")),
        # HAProxy
        "haproxy_primary_port": int(os.getenv("HAPROXY_PRIMARY_PORT", "5432")),
        "haproxy_replica_port": int(os.getenv("HAPROXY_REPLICA_PORT", "5433")),
        # Patroni
        "patroni_enabled": os.getenv("ENABLE_PATRONI", "false").lower() == "true",
        "patroni_hosts": os.getenv("PATRONI_HOSTS", "localhost").split(","),
        "patroni_port": int(os.getenv("PATRONI_PORT", "8008")),
        # Citus
        "citus_enabled": os.getenv("ENABLE_CITUS", "false").lower() == "true",
        "citus_coordinator": os.getenv("CITUS_COORDINATOR", "localhost:5432"),
        "citus_workers": (
            os.getenv("CITUS_WORKERS", "").split(",") if os.getenv("CITUS_WORKERS") else []
        ),
    }


@pytest.fixture(scope="session")
def postgres_connection(
    test_env: Dict[str, str]
) -> Generator[psycopg2.extensions.connection, None, None]:
    """Provide PostgreSQL connection for tests."""
    conn = psycopg2.connect(
        host=test_env["postgres_host"],
        port=test_env["postgres_port"],
        database=test_env["postgres_db"],
        user=test_env["postgres_user"],
        password=test_env["postgres_password"],
        cursor_factory=RealDictCursor,
        connect_timeout=10,
    )
    yield conn
    conn.close()


@pytest.fixture(scope="function")
def postgres_cursor(postgres_connection) -> Generator:
    """Provide PostgreSQL cursor with automatic rollback."""
    with postgres_connection.cursor() as cursor:
        yield cursor
        postgres_connection.rollback()


@pytest.fixture(scope="session")
def redis_connection(test_env: Dict[str, str]) -> Generator[redis.Redis, None, None]:
    """Provide Redis connection for tests."""
    client = redis.Redis(
        host=test_env["redis_host"],
        port=test_env["redis_port"],
        decode_responses=True,
        socket_connect_timeout=5,
    )

    # Test connection
    try:
        client.ping()
    except redis.ConnectionError:
        pytest.skip("Redis not available")

    yield client

    # Cleanup test keys
    test_keys = client.keys("test:*")
    if test_keys:
        client.delete(*test_keys)

    client.close()


@pytest.fixture(scope="session")
def citus_connection(test_env: Dict[str, str]) -> Optional[Generator]:
    """Provide Citus coordinator connection if enabled."""
    if not test_env["citus_enabled"]:
        pytest.skip("Citus not enabled")

    host, port = test_env["citus_coordinator"].split(":")
    conn = psycopg2.connect(
        host=host,
        port=int(port),
        database=test_env["postgres_db"],
        user=test_env["postgres_user"],
        password=test_env["postgres_password"],
        cursor_factory=RealDictCursor,
        connect_timeout=10,
    )

    yield conn
    conn.close()


@pytest.fixture(scope="function")
def citus_cursor(citus_connection) -> Generator:
    """Provide Citus cursor with automatic rollback."""
    if citus_connection is None:
        pytest.skip("Citus not available")

    with citus_connection.cursor() as cursor:
        yield cursor
        citus_connection.rollback()


@pytest.fixture(scope="session")
def patroni_nodes(test_env: Dict[str, str]) -> List[Dict[str, str]]:
    """Get Patroni cluster node information."""
    if not test_env["patroni_enabled"]:
        pytest.skip("Patroni not enabled")

    # Third-party imports
    import requests

    nodes = []
    for host in test_env["patroni_hosts"]:
        try:
            url = f"http://{host}:{test_env['patroni_port']}/cluster"
            response = requests.get(url, timeout=5)
            response.raise_for_status()
            cluster_info = response.json()

            for member in cluster_info.get("members", []):
                nodes.append(
                    {
                        "name": member["name"],
                        "host": member["host"],
                        "port": member["port"],
                        "role": member["role"],
                        "state": member["state"],
                    }
                )
            break
        except Exception:
            continue

    if not nodes:
        pytest.skip("Patroni cluster not available")

    return nodes


@pytest.fixture(scope="function")
def test_namespace() -> str:
    """Generate unique test namespace."""
    # Standard library imports
    import uuid

    return f"test_{uuid.uuid4().hex[:8]}"


@pytest.fixture(scope="function")
def cleanup_test_data(postgres_cursor, test_namespace: str):
    """Clean up test data after each test."""
    yield

    # Clean up test data
    tables = [
        "memory_entries",
        "patterns",
        "trajectories",
        "graph_nodes",
        "graph_edges",
        "hyperbolic_embeddings",
    ]

    for table in tables:
        try:
            postgres_cursor.execute(f"DELETE FROM {table} WHERE namespace = %s", (test_namespace,))
        except Exception:
            pass


@pytest.fixture(scope="function")
def sample_vector() -> List[float]:
    """Generate sample 384-dimensional vector."""
    # Third-party imports
    import numpy as np

    vec = np.random.randn(384).astype(np.float32)
    vec = vec / np.linalg.norm(vec)  # Normalize
    return vec.tolist()


@pytest.fixture(scope="function")
def wait_for_replication():
    """Wait for replication lag to settle."""

    def _wait(max_lag_ms: int = 100, timeout: int = 30):
        """Wait for replication lag to be below threshold.

        Args:
            max_lag_ms: Maximum acceptable lag in milliseconds
            timeout: Maximum time to wait in seconds
        """
        time.sleep(timeout / 10)  # Simple wait, can be enhanced

    return _wait


# Markers for different test categories
def pytest_configure(config):
    """Register custom markers."""
    config.addinivalue_line("markers", "citus: mark test as requiring Citus")
    config.addinivalue_line("markers", "patroni: mark test as requiring Patroni")
    config.addinivalue_line("markers", "redis: mark test as requiring Redis")
    config.addinivalue_line("markers", "haproxy: mark test as requiring HAProxy")
    config.addinivalue_line("markers", "slow: mark test as slow running")
    config.addinivalue_line("markers", "destructive: mark test as potentially destructive")
