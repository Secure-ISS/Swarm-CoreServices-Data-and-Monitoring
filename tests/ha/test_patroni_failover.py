"""
Patroni Failover Testing Suite

Tests automatic failover scenarios including:
- Primary node failure simulation
- Automatic standby promotion
- Data consistency validation
- Failover timing measurement
- Split-brain scenario handling
"""

# Standard library imports
import asyncio
import subprocess
import time
from datetime import datetime, timedelta
from typing import Dict, List, Optional

# Third-party imports
import psycopg2
import pytest
from psycopg2.extras import RealDictCursor


class PatroniFailoverTester:
    """Test harness for Patroni failover scenarios"""

    def __init__(self, nodes: List[Dict[str, str]]):
        """
        Initialize failover tester

        Args:
            nodes: List of node configs with host, port, name
        """
        self.nodes = nodes
        self.connections = {}
        self.failover_start_time = None
        self.failover_end_time = None

    def connect_to_node(self, node: Dict[str, str]) -> psycopg2.extensions.connection:
        """Establish connection to a PostgreSQL node"""
        try:
            conn = psycopg2.connect(
                host=node["host"],
                port=node["port"],
                database="postgres",
                user="postgres",
                password="postgres",
                connect_timeout=5,
            )
            return conn
        except psycopg2.Error as e:
            print(f"Connection to {node['name']} failed: {e}")
            return None

    def get_primary_node(self) -> Optional[Dict[str, str]]:
        """Identify current primary node"""
        for node in self.nodes:
            conn = self.connect_to_node(node)
            if conn:
                try:
                    with conn.cursor() as cur:
                        cur.execute("SELECT pg_is_in_recovery()")
                        is_replica = cur.fetchone()[0]
                        if not is_replica:
                            return node
                finally:
                    conn.close()
        return None

    def get_standby_nodes(self) -> List[Dict[str, str]]:
        """Get all standby nodes"""
        standbys = []
        for node in self.nodes:
            conn = self.connect_to_node(node)
            if conn:
                try:
                    with conn.cursor() as cur:
                        cur.execute("SELECT pg_is_in_recovery()")
                        is_replica = cur.fetchone()[0]
                        if is_replica:
                            standbys.append(node)
                finally:
                    conn.close()
        return standbys

    def get_replication_lag(self, node: Dict[str, str]) -> float:
        """Get replication lag in seconds for a standby node"""
        conn = self.connect_to_node(node)
        if not conn:
            return float("inf")

        try:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))
                    AS lag_seconds
                """
                )
                result = cur.fetchone()
                return result[0] if result[0] is not None else 0.0
        finally:
            conn.close()

    def simulate_node_failure(self, node: Dict[str, str]) -> bool:
        """Simulate node failure by stopping Patroni service"""
        try:
            # Using docker stop for containerized setup
            cmd = ["docker", "stop", node["container_name"]]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            return result.returncode == 0
        except Exception as e:
            print(f"Failed to stop node {node['name']}: {e}")
            return False

    def restore_node(self, node: Dict[str, str]) -> bool:
        """Restore previously failed node"""
        try:
            cmd = ["docker", "start", node["container_name"]]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            return result.returncode == 0
        except Exception as e:
            print(f"Failed to start node {node['name']}: {e}")
            return False

    def insert_test_data(self, node: Dict[str, str], test_id: str) -> bool:
        """Insert test data to verify consistency"""
        conn = self.connect_to_node(node)
        if not conn:
            return False

        try:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    CREATE TABLE IF NOT EXISTS failover_test (
                        id SERIAL PRIMARY KEY,
                        test_id VARCHAR(100),
                        data TEXT,
                        created_at TIMESTAMP DEFAULT NOW()
                    )
                """
                )
                cur.execute(
                    "INSERT INTO failover_test (test_id, data) VALUES (%s, %s)",
                    (test_id, f"Test data at {datetime.now()}"),
                )
                conn.commit()
                return True
        except Exception as e:
            print(f"Failed to insert test data: {e}")
            conn.rollback()
            return False
        finally:
            conn.close()

    def verify_test_data(self, node: Dict[str, str], test_id: str) -> bool:
        """Verify test data exists on node"""
        conn = self.connect_to_node(node)
        if not conn:
            return False

        try:
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) FROM failover_test WHERE test_id = %s", (test_id,))
                count = cur.fetchone()[0]
                return count > 0
        except Exception as e:
            print(f"Failed to verify test data: {e}")
            return False
        finally:
            conn.close()

    def wait_for_promotion(self, timeout: int = 30) -> Optional[Dict[str, str]]:
        """Wait for a standby to be promoted to primary"""
        start_time = time.time()

        while time.time() - start_time < timeout:
            new_primary = self.get_primary_node()
            if new_primary:
                return new_primary
            time.sleep(1)

        return None

    def measure_failover_time(self) -> float:
        """Calculate failover duration in seconds"""
        if self.failover_start_time and self.failover_end_time:
            return (self.failover_end_time - self.failover_start_time).total_seconds()
        return 0.0


@pytest.fixture
def patroni_cluster():
    """Fixture providing Patroni cluster configuration"""
    nodes = [
        {
            "name": "pg-node-1",
            "host": "localhost",
            "port": "5432",
            "container_name": "patroni-node-1",
        },
        {
            "name": "pg-node-2",
            "host": "localhost",
            "port": "5433",
            "container_name": "patroni-node-2",
        },
        {
            "name": "pg-node-3",
            "host": "localhost",
            "port": "5434",
            "container_name": "patroni-node-3",
        },
    ]
    return PatroniFailoverTester(nodes)


class TestPatroniFailover:
    """Patroni failover test suite"""

    def test_identify_primary_node(self, patroni_cluster):
        """Test identification of current primary node"""
        primary = patroni_cluster.get_primary_node()
        assert primary is not None, "Should identify primary node"
        assert "name" in primary
        print(f"Primary node identified: {primary['name']}")

    def test_identify_standby_nodes(self, patroni_cluster):
        """Test identification of standby nodes"""
        standbys = patroni_cluster.get_standby_nodes()
        assert len(standbys) >= 1, "Should have at least one standby"
        print(f"Standby nodes: {[s['name'] for s in standbys]}")

    def test_replication_lag(self, patroni_cluster):
        """Test replication lag measurement"""
        standbys = patroni_cluster.get_standby_nodes()
        assert len(standbys) > 0, "Need standby nodes to test lag"

        for standby in standbys:
            lag = patroni_cluster.get_replication_lag(standby)
            assert lag < 5.0, f"Replication lag too high: {lag}s"
            print(f"Replication lag for {standby['name']}: {lag}s")

    def test_primary_failover(self, patroni_cluster):
        """Test automatic failover when primary fails"""
        # Get initial primary
        original_primary = patroni_cluster.get_primary_node()
        assert original_primary is not None, "Need primary node"

        # Insert test data
        test_id = f"failover_test_{int(time.time())}"
        assert patroni_cluster.insert_test_data(original_primary, test_id)

        # Wait for replication
        time.sleep(2)

        # Simulate primary failure
        patroni_cluster.failover_start_time = datetime.now()
        print(f"Simulating failure of {original_primary['name']}")
        assert patroni_cluster.simulate_node_failure(original_primary)

        # Wait for promotion
        new_primary = patroni_cluster.wait_for_promotion(timeout=30)
        patroni_cluster.failover_end_time = datetime.now()

        assert new_primary is not None, "Failover did not complete"
        assert new_primary["name"] != original_primary["name"], "Primary should change"

        # Measure failover time
        failover_time = patroni_cluster.measure_failover_time()
        print(f"Failover completed in {failover_time:.2f}s")
        assert failover_time < 30, f"Failover too slow: {failover_time}s"

        # Verify data consistency
        assert patroni_cluster.verify_test_data(
            new_primary, test_id
        ), "Data not consistent after failover"

        # Restore original primary
        patroni_cluster.restore_node(original_primary)
        time.sleep(5)  # Wait for node to rejoin

    def test_data_consistency_during_failover(self, patroni_cluster):
        """Test that no data is lost during failover"""
        primary = patroni_cluster.get_primary_node()
        assert primary is not None

        # Insert multiple test records
        test_ids = []
        for i in range(10):
            test_id = f"consistency_test_{int(time.time())}_{i}"
            assert patroni_cluster.insert_test_data(primary, test_id)
            test_ids.append(test_id)
            time.sleep(0.1)

        # Wait for replication
        time.sleep(3)

        # Trigger failover
        assert patroni_cluster.simulate_node_failure(primary)
        new_primary = patroni_cluster.wait_for_promotion(timeout=30)
        assert new_primary is not None

        # Verify all test data exists
        for test_id in test_ids:
            assert patroni_cluster.verify_test_data(
                new_primary, test_id
            ), f"Data loss detected: {test_id}"

        # Cleanup
        patroni_cluster.restore_node(primary)

    def test_split_brain_prevention(self, patroni_cluster):
        """Test that split-brain scenarios are prevented"""
        # This test would require network partition simulation
        # For now, verify that only one primary exists at any time
        primary_count = 0

        for node in patroni_cluster.nodes:
            conn = patroni_cluster.connect_to_node(node)
            if conn:
                try:
                    with conn.cursor() as cur:
                        cur.execute("SELECT pg_is_in_recovery()")
                        is_replica = cur.fetchone()[0]
                        if not is_replica:
                            primary_count += 1
                finally:
                    conn.close()

        assert primary_count == 1, f"Split-brain detected: {primary_count} primaries"
        print("Split-brain prevention: PASS (single primary verified)")

    def test_failed_node_rejoin(self, patroni_cluster):
        """Test that failed node can rejoin cluster as standby"""
        primary = patroni_cluster.get_primary_node()
        assert primary is not None

        # Simulate and restore failure
        assert patroni_cluster.simulate_node_failure(primary)
        time.sleep(5)

        new_primary = patroni_cluster.wait_for_promotion(timeout=30)
        assert new_primary is not None

        # Restore failed node
        assert patroni_cluster.restore_node(primary)

        # Wait for node to rejoin
        time.sleep(10)

        # Verify it rejoined as standby
        conn = patroni_cluster.connect_to_node(primary)
        assert conn is not None, "Failed node did not rejoin"

        with conn.cursor() as cur:
            cur.execute("SELECT pg_is_in_recovery()")
            is_replica = cur.fetchone()[0]
            assert is_replica, "Rejoined node should be standby"

        conn.close()
        print(f"{primary['name']} successfully rejoined as standby")


if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])
