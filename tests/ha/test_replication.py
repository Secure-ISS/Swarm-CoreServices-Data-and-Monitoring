"""
PostgreSQL Replication Testing Suite

Tests streaming replication functionality including:
- Replication health and status
- Replication lag monitoring
- Synchronous vs asynchronous modes
- Data integrity across nodes
"""

# Standard library imports
import hashlib
import time
from datetime import datetime
from typing import Dict, List, Optional

# Third-party imports
import psycopg2
import pytest
from psycopg2.extras import RealDictCursor


class ReplicationTester:
    """Test harness for PostgreSQL replication"""

    def __init__(self, nodes: List[Dict[str, str]]):
        self.nodes = nodes

    def connect_to_node(self, node: Dict[str, str]) -> Optional[psycopg2.extensions.connection]:
        """Connect to a PostgreSQL node"""
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

    def get_replication_status(self, node: Dict[str, str]) -> Optional[List[Dict]]:
        """Get replication status from a node"""
        conn = self.connect_to_node(node)
        if not conn:
            return None

        try:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute(
                    """
                    SELECT
                        application_name,
                        client_addr,
                        state,
                        sync_state,
                        sent_lsn,
                        write_lsn,
                        flush_lsn,
                        replay_lsn,
                        sync_priority,
                        pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replication_lag_bytes
                    FROM pg_stat_replication
                """
                )
                return cur.fetchall()
        finally:
            conn.close()

    def get_replication_lag_seconds(self, node: Dict[str, str]) -> Optional[float]:
        """Get replication lag in seconds for a standby"""
        conn = self.connect_to_node(node)
        if not conn:
            return None

        try:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT
                        CASE
                            WHEN pg_is_in_recovery() THEN
                                EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))
                            ELSE
                                0
                        END AS lag_seconds
                """
                )
                result = cur.fetchone()
                return result[0] if result else None
        finally:
            conn.close()

    def get_wal_status(self, node: Dict[str, str]) -> Optional[Dict]:
        """Get WAL status from a node"""
        conn = self.connect_to_node(node)
        if not conn:
            return None

        try:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute(
                    """
                    SELECT
                        pg_current_wal_lsn() AS current_wal_lsn,
                        pg_walfile_name(pg_current_wal_lsn()) AS current_wal_file,
                        pg_is_in_recovery() AS is_standby
                """
                )
                return cur.fetchone()
        finally:
            conn.close()

    def check_synchronous_replication(self, node: Dict[str, str]) -> Dict:
        """Check if synchronous replication is configured"""
        conn = self.connect_to_node(node)
        if not conn:
            return {"enabled": False, "standbys": []}

        try:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute(
                    """
                    SELECT
                        setting AS synchronous_standby_names
                    FROM pg_settings
                    WHERE name = 'synchronous_standby_names'
                """
                )
                result = cur.fetchone()
                sync_config = result["synchronous_standby_names"] if result else ""

                # Get actual synchronous standbys
                cur.execute(
                    """
                    SELECT
                        application_name,
                        sync_state
                    FROM pg_stat_replication
                    WHERE sync_state IN ('sync', 'quorum')
                """
                )
                sync_standbys = cur.fetchall()

                return {
                    "enabled": bool(sync_config and sync_config != ""),
                    "config": sync_config,
                    "standbys": sync_standbys,
                }
        finally:
            conn.close()

    def insert_test_data_with_checksum(
        self, node: Dict[str, str], test_id: str, data_size: int = 1000
    ) -> Optional[str]:
        """Insert test data and return checksum"""
        conn = self.connect_to_node(node)
        if not conn:
            return None

        try:
            # Generate test data
            test_data = "x" * data_size
            checksum = hashlib.sha256(test_data.encode()).hexdigest()

            with conn.cursor() as cur:
                cur.execute(
                    """
                    CREATE TABLE IF NOT EXISTS replication_test (
                        id SERIAL PRIMARY KEY,
                        test_id VARCHAR(100),
                        data TEXT,
                        checksum VARCHAR(64),
                        created_at TIMESTAMP DEFAULT NOW()
                    )
                """
                )
                cur.execute(
                    """
                    INSERT INTO replication_test (test_id, data, checksum)
                    VALUES (%s, %s, %s)
                """,
                    (test_id, test_data, checksum),
                )
                conn.commit()
                return checksum
        except Exception as e:
            print(f"Failed to insert test data: {e}")
            conn.rollback()
            return None
        finally:
            conn.close()

    def verify_data_checksum(
        self, node: Dict[str, str], test_id: str, expected_checksum: str
    ) -> bool:
        """Verify data integrity using checksum"""
        conn = self.connect_to_node(node)
        if not conn:
            return False

        try:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT checksum FROM replication_test
                    WHERE test_id = %s
                """,
                    (test_id,),
                )
                result = cur.fetchone()
                return result and result[0] == expected_checksum
        except Exception as e:
            print(f"Failed to verify checksum: {e}")
            return False
        finally:
            conn.close()

    def wait_for_replication(
        self, standby: Dict[str, str], max_lag_seconds: float = 1.0, timeout: int = 10
    ) -> bool:
        """Wait for replication to catch up"""
        start_time = time.time()

        while time.time() - start_time < timeout:
            lag = self.get_replication_lag_seconds(standby)
            if lag is not None and lag < max_lag_seconds:
                return True
            time.sleep(0.5)

        return False


@pytest.fixture
def replication_cluster():
    """Fixture providing replication cluster configuration"""
    nodes = [
        {"name": "pg-primary", "host": "localhost", "port": "5432", "role": "primary"},
        {"name": "pg-standby-1", "host": "localhost", "port": "5433", "role": "standby"},
        {"name": "pg-standby-2", "host": "localhost", "port": "5434", "role": "standby"},
    ]
    return ReplicationTester(nodes)


class TestReplication:
    """PostgreSQL replication test suite"""

    def test_replication_slots_exist(self, replication_cluster):
        """Test that replication slots are configured"""
        primary = [n for n in replication_cluster.nodes if n["role"] == "primary"][0]
        conn = replication_cluster.connect_to_node(primary)
        assert conn is not None

        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute("SELECT * FROM pg_replication_slots")
            slots = cur.fetchall()
            assert len(slots) > 0, "No replication slots found"
            print(f"Found {len(slots)} replication slots")
            for slot in slots:
                print(f"  - {slot['slot_name']}: {slot['slot_type']}, active={slot['active']}")

        conn.close()

    def test_streaming_replication_active(self, replication_cluster):
        """Test that streaming replication is active"""
        primary = [n for n in replication_cluster.nodes if n["role"] == "primary"][0]
        status = replication_cluster.get_replication_status(primary)

        assert status is not None, "Could not get replication status"
        assert len(status) > 0, "No active replication connections"

        for replica in status:
            assert (
                replica["state"] == "streaming"
            ), f"Replica {replica['application_name']} not streaming"
            print(
                f"Replica {replica['application_name']}: {replica['state']}, "
                f"lag={replica['replication_lag_bytes']} bytes"
            )

    def test_replication_lag_acceptable(self, replication_cluster):
        """Test that replication lag is within acceptable limits"""
        standbys = [n for n in replication_cluster.nodes if n["role"] == "standby"]
        max_acceptable_lag = 5.0  # seconds

        for standby in standbys:
            lag = replication_cluster.get_replication_lag_seconds(standby)
            assert lag is not None, f"Could not get lag for {standby['name']}"
            assert (
                lag < max_acceptable_lag
            ), f"Replication lag too high for {standby['name']}: {lag}s"
            print(f"{standby['name']} lag: {lag:.3f}s")

    def test_data_consistency_across_nodes(self, replication_cluster):
        """Test data consistency between primary and standbys"""
        primary = [n for n in replication_cluster.nodes if n["role"] == "primary"][0]
        standbys = [n for n in replication_cluster.nodes if n["role"] == "standby"]

        # Insert test data on primary
        test_id = f"consistency_test_{int(time.time())}"
        checksum = replication_cluster.insert_test_data_with_checksum(primary, test_id, 5000)
        assert checksum is not None, "Failed to insert test data"

        # Wait for replication
        for standby in standbys:
            assert replication_cluster.wait_for_replication(
                standby, max_lag_seconds=2.0
            ), f"Replication timeout for {standby['name']}"

        # Verify data on all standbys
        for standby in standbys:
            assert replication_cluster.verify_data_checksum(
                standby, test_id, checksum
            ), f"Data mismatch on {standby['name']}"
            print(f"Data verified on {standby['name']}")

    def test_synchronous_replication_config(self, replication_cluster):
        """Test synchronous replication configuration"""
        primary = [n for n in replication_cluster.nodes if n["role"] == "primary"][0]
        sync_info = replication_cluster.check_synchronous_replication(primary)

        print(f"Synchronous replication enabled: {sync_info['enabled']}")
        print(f"Configuration: {sync_info['config']}")
        print(f"Synchronous standbys: {len(sync_info['standbys'])}")

        # If sync replication is enabled, verify at least one sync standby
        if sync_info["enabled"]:
            assert (
                len(sync_info["standbys"]) > 0
            ), "Synchronous replication enabled but no sync standbys"

    def test_wal_archiving_status(self, replication_cluster):
        """Test WAL archiving configuration"""
        primary = [n for n in replication_cluster.nodes if n["role"] == "primary"][0]
        conn = replication_cluster.connect_to_node(primary)
        assert conn is not None

        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                """
                SELECT
                    name, setting
                FROM pg_settings
                WHERE name IN ('archive_mode', 'archive_command', 'wal_level')
            """
            )
            settings = {row["name"]: row["setting"] for row in cur.fetchall()}

            print(f"WAL level: {settings.get('wal_level')}")
            print(f"Archive mode: {settings.get('archive_mode')}")
            print(f"Archive command: {settings.get('archive_command')}")

            # Verify minimum wal_level for replication
            assert settings.get("wal_level") in [
                "replica",
                "logical",
            ], "WAL level insufficient for replication"

        conn.close()

    def test_bulk_data_replication(self, replication_cluster):
        """Test replication with bulk data inserts"""
        primary = [n for n in replication_cluster.nodes if n["role"] == "primary"][0]
        standbys = [n for n in replication_cluster.nodes if n["role"] == "standby"]

        conn = replication_cluster.connect_to_node(primary)
        assert conn is not None

        try:
            # Insert bulk data
            test_id = f"bulk_test_{int(time.time())}"
            checksums = []

            with conn.cursor() as cur:
                for i in range(100):
                    data = f"bulk_data_{i}" * 100
                    checksum = hashlib.sha256(data.encode()).hexdigest()
                    checksums.append(checksum)

                    cur.execute(
                        """
                        INSERT INTO replication_test (test_id, data, checksum)
                        VALUES (%s, %s, %s)
                    """,
                        (f"{test_id}_{i}", data, checksum),
                    )

                conn.commit()

            # Wait for replication
            time.sleep(3)

            # Verify on standbys
            for standby in standbys:
                conn_standby = replication_cluster.connect_to_node(standby)
                assert conn_standby is not None

                with conn_standby.cursor() as cur:
                    cur.execute(
                        """
                        SELECT COUNT(*) FROM replication_test
                        WHERE test_id LIKE %s
                    """,
                        (f"{test_id}_%",),
                    )
                    count = cur.fetchone()[0]
                    assert count == 100, f"Bulk data incomplete on {standby['name']}: {count}/100"

                conn_standby.close()
                print(f"Bulk data verified on {standby['name']}")

        finally:
            conn.close()

    def test_replication_after_network_delay(self, replication_cluster):
        """Test replication recovery after simulated network delay"""
        primary = [n for n in replication_cluster.nodes if n["role"] == "primary"][0]
        standbys = [n for n in replication_cluster.nodes if n["role"] == "standby"]

        # Insert data
        test_id = f"delay_test_{int(time.time())}"
        checksum = replication_cluster.insert_test_data_with_checksum(primary, test_id)
        assert checksum is not None

        # Simulate delay (in production, would use network tools)
        time.sleep(2)

        # Verify eventual consistency
        for standby in standbys:
            assert replication_cluster.wait_for_replication(
                standby, max_lag_seconds=2.0, timeout=15
            ), f"Replication did not recover for {standby['name']}"

            assert replication_cluster.verify_data_checksum(
                standby, test_id, checksum
            ), f"Data inconsistency on {standby['name']} after delay"


if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])
