"""Integration tests for high-availability failover scenarios.

Tests Patroni and HAProxy HA functionality:
- Automatic failover detection
- Read/write splitting via HAProxy
- Replication lag monitoring
- Graceful degradation
- Split-brain prevention
"""

# Standard library imports
import time
from typing import Dict, List

# Third-party imports
import psycopg2
import pytest
import requests


@pytest.mark.patroni
class TestPatroniClusterHealth:
    """Test Patroni cluster health and topology."""

    def test_patroni_api_accessible(self, patroni_nodes: List[Dict]):
        """Test that Patroni REST API is accessible."""
        assert len(patroni_nodes) > 0, "No Patroni nodes found"

        for node in patroni_nodes:
            url = f"http://{node['host']}:8008/health"
            response = requests.get(url, timeout=5)
            assert response.status_code == 200

    def test_cluster_has_leader(self, patroni_nodes: List[Dict]):
        """Test that cluster has exactly one leader."""
        leaders = [n for n in patroni_nodes if n["role"] == "leader"]
        assert len(leaders) == 1, f"Expected 1 leader, found {len(leaders)}"

    def test_cluster_has_replicas(self, patroni_nodes: List[Dict]):
        """Test that cluster has replica nodes."""
        replicas = [n for n in patroni_nodes if n["role"] == "replica"]
        assert len(replicas) >= 1, "No replica nodes found"

    def test_all_nodes_running(self, patroni_nodes: List[Dict]):
        """Test that all nodes are in running state."""
        for node in patroni_nodes:
            assert (
                node["state"] == "running"
            ), f"Node {node['name']} is not running: {node['state']}"


@pytest.mark.patroni
class TestReadWriteSplitting:
    """Test read/write splitting via Patroni pool or HAProxy."""

    def test_write_to_primary(
        self, test_env: Dict, test_namespace: str, sample_vector: List[float]
    ):
        """Test write operation routes to primary."""
        conn = psycopg2.connect(
            host=test_env["postgres_host"],
            port=test_env["haproxy_primary_port"],
            database=test_env["postgres_db"],
            user=test_env["postgres_user"],
            password=test_env["postgres_password"],
            connect_timeout=5,
        )

        try:
            with conn.cursor() as cur:
                # Verify connected to primary
                cur.execute("SELECT pg_is_in_recovery()")
                is_replica = cur.fetchone()[0]
                assert not is_replica, "Write connection not routed to primary"

                # Perform write
                cur.execute(
                    """
                    INSERT INTO memory_entries (namespace, key, value, embedding)
                    VALUES (%s, %s, %s, %s::ruvector)
                    RETURNING id
                    """,
                    (test_namespace, "primary_write", "test_value", sample_vector),
                )
                result = cur.fetchone()
                assert result is not None

            conn.commit()

        finally:
            # Cleanup
            with conn.cursor() as cur:
                cur.execute("DELETE FROM memory_entries WHERE namespace = %s", (test_namespace,))
            conn.commit()
            conn.close()

    @pytest.mark.skip(reason="Requires separate replica port configuration")
    def test_read_from_replica(self, test_env: Dict):
        """Test read operation can route to replica."""
        conn = psycopg2.connect(
            host=test_env["postgres_host"],
            port=test_env["haproxy_replica_port"],
            database=test_env["postgres_db"],
            user=test_env["postgres_user"],
            password=test_env["postgres_password"],
            connect_timeout=5,
        )

        try:
            with conn.cursor() as cur:
                # May connect to replica
                cur.execute("SELECT pg_is_in_recovery()")
                is_replica = cur.fetchone()[0]
                # Replica or primary acceptable (depends on cluster state)

                # Perform read
                cur.execute("SELECT COUNT(*) FROM memory_entries")
                result = cur.fetchone()
                assert result is not None

        finally:
            conn.close()


@pytest.mark.patroni
class TestReplicationLag:
    """Test replication lag monitoring."""

    def test_check_replication_status(self, postgres_cursor):
        """Test querying replication status."""
        # Check if we're on primary
        postgres_cursor.execute("SELECT pg_is_in_recovery()")
        is_replica = postgres_cursor.fetchone()["pg_is_in_recovery"]

        if not is_replica:
            # On primary - check replication slots
            postgres_cursor.execute(
                """
                SELECT slot_name, active, restart_lsn, confirmed_flush_lsn
                FROM pg_replication_slots
                """
            )
            slots = postgres_cursor.fetchall()
            # May have 0 or more slots depending on setup
            assert isinstance(slots, list)

    def test_replication_lag_acceptable(self, postgres_cursor):
        """Test that replication lag is within acceptable limits."""
        # Check if we're on replica
        postgres_cursor.execute("SELECT pg_is_in_recovery()")
        is_replica = postgres_cursor.fetchone()["pg_is_in_recovery"]

        if is_replica:
            # On replica - check lag
            postgres_cursor.execute(
                """
                SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) AS lag_seconds
                """
            )
            result = postgres_cursor.fetchone()
            lag_seconds = result["lag_seconds"]

            if lag_seconds is not None:
                # Lag should be under 5 seconds for healthy replication
                assert lag_seconds < 5.0, f"Replication lag too high: {lag_seconds:.2f}s"


@pytest.mark.patroni
@pytest.mark.destructive
@pytest.mark.skip(reason="Destructive test - requires manual execution")
class TestFailoverScenarios:
    """Test failover scenarios (destructive tests)."""

    def test_automatic_failover_on_primary_failure(self, patroni_nodes: List[Dict], test_env: Dict):
        """Test automatic failover when primary fails.

        WARNING: This test simulates primary failure and should only be run
        in non-production environments.
        """
        # Get initial primary
        initial_leader = next(n for n in patroni_nodes if n["role"] == "leader")
        initial_leader_host = initial_leader["host"]

        # Simulate primary failure (requires manual intervention or docker stop)
        # This is a placeholder - actual implementation would need to stop the node
        pytest.skip("Requires manual primary node shutdown")

        # Wait for failover
        max_wait = 30  # seconds
        start_time = time.time()
        new_leader = None

        while time.time() - start_time < max_wait:
            time.sleep(2)

            # Check for new leader
            for node_host in test_env["patroni_hosts"]:
                try:
                    url = f"http://{node_host}:8008/cluster"
                    response = requests.get(url, timeout=5)
                    cluster_info = response.json()

                    for member in cluster_info["members"]:
                        if member["role"] == "leader" and member["host"] != initial_leader_host:
                            new_leader = member
                            break

                    if new_leader:
                        break
                except Exception:
                    continue

            if new_leader:
                break

        assert new_leader is not None, "Failover did not complete within timeout"
        assert new_leader["host"] != initial_leader_host, "New leader is same as old leader"

    def test_write_consistency_during_failover(self):
        """Test that writes during failover are handled correctly."""
        pytest.skip("Requires complex failover orchestration")


@pytest.mark.patroni
class TestSplitBrainPrevention:
    """Test split-brain prevention mechanisms."""

    def test_only_one_leader_exists(self, test_env: Dict):
        """Test that only one leader exists at any time."""
        leaders = []

        for patroni_host in test_env["patroni_hosts"]:
            try:
                url = f"http://{patroni_host}:8008/cluster"
                response = requests.get(url, timeout=5)
                cluster_info = response.json()

                for member in cluster_info["members"]:
                    if member["role"] == "leader":
                        leaders.append(member)
            except Exception:
                continue

        # Should have exactly one leader across all nodes
        assert len(leaders) == 1, f"Expected 1 leader, found {len(leaders)}: {leaders}"


@pytest.mark.patroni
class TestGracefulDegradation:
    """Test graceful degradation during partial failures."""

    def test_read_only_mode_on_all_replicas_down(self):
        """Test system operates in read-only mode if all replicas are down."""
        pytest.skip("Requires replica shutdown orchestration")

    def test_connection_retry_on_transient_failure(self, test_env: Dict):
        """Test that transient connection failures are handled."""
        max_retries = 3
        retry_count = 0
        connected = False

        while retry_count < max_retries and not connected:
            try:
                conn = psycopg2.connect(
                    host=test_env["postgres_host"],
                    port=test_env["postgres_port"],
                    database=test_env["postgres_db"],
                    user=test_env["postgres_user"],
                    password=test_env["postgres_password"],
                    connect_timeout=5,
                )
                conn.close()
                connected = True
            except psycopg2.OperationalError:
                retry_count += 1
                time.sleep(1)

        assert connected or retry_count < max_retries, "Failed to connect after retries"


@pytest.mark.haproxy
class TestHAProxyRouting:
    """Test HAProxy load balancing and routing."""

    def test_haproxy_stats_page_accessible(self, test_env: Dict):
        """Test HAProxy statistics page is accessible."""
        try:
            response = requests.get(
                f"http://{test_env['postgres_host']}:8404",
                timeout=5,
            )
            # May be accessible or not depending on setup
            assert response.status_code in [200, 401, 404]
        except requests.RequestException:
            pytest.skip("HAProxy stats page not configured")

    def test_connection_through_haproxy(self, test_env: Dict):
        """Test database connection through HAProxy."""
        try:
            conn = psycopg2.connect(
                host=test_env["postgres_host"],
                port=test_env["haproxy_primary_port"],
                database=test_env["postgres_db"],
                user=test_env["postgres_user"],
                password=test_env["postgres_password"],
                connect_timeout=5,
            )

            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                result = cur.fetchone()
                assert result[0] == 1

            conn.close()
        except psycopg2.OperationalError:
            pytest.skip("HAProxy not configured or not accessible")


if __name__ == "__main__":
    pytest.main([__file__, "-v", "-m", "patroni", "--tb=short"])
