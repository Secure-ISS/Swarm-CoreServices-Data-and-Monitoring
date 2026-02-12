"""Integration tests for Citus distributed database sharding.

Tests Citus-specific functionality:
- Shard distribution and rebalancing
- Distributed queries across workers
- Co-location of related data
- Reference tables
- Distributed transactions
- Query performance with sharding
"""

# Standard library imports
import time
from typing import Dict, List

# Third-party imports
import psycopg2
import pytest


@pytest.mark.citus
class TestCitusClusterSetup:
    """Test Citus cluster configuration and health."""

    def test_citus_extension_enabled(self, citus_cursor):
        """Test that Citus extension is enabled."""
        citus_cursor.execute("SELECT extname, extversion FROM pg_extension WHERE extname = 'citus'")
        result = citus_cursor.fetchone()

        assert result is not None
        assert result["extname"] == "citus"
        assert result["extversion"] is not None

    def test_worker_nodes_active(self, citus_cursor):
        """Test that all worker nodes are active."""
        citus_cursor.execute("SELECT * FROM citus_get_active_worker_nodes()")
        workers = citus_cursor.fetchall()

        assert len(workers) > 0, "No active worker nodes found"

        for worker in workers:
            assert worker["node_name"] is not None
            assert worker["node_port"] == 5432

    def test_distributed_tables_exist(self, citus_cursor):
        """Test that distributed tables are properly configured."""
        citus_cursor.execute(
            """
            SELECT logicalrelid::regclass as table_name,
                   partmethod as distribution_type,
                   partkey as distribution_column
            FROM pg_dist_partition
            ORDER BY logicalrelid
            """
        )
        distributed_tables = citus_cursor.fetchall()

        assert len(distributed_tables) > 0, "No distributed tables found"

        # Verify key tables are distributed
        table_names = [row["table_name"] for row in distributed_tables]
        assert "memory_entries" in table_names
        assert "patterns" in table_names

    def test_reference_tables_exist(self, citus_cursor):
        """Test that reference tables are properly configured."""
        citus_cursor.execute(
            """
            SELECT logicalrelid::regclass as table_name
            FROM pg_dist_partition
            WHERE partmethod = 'n'  -- 'n' indicates reference table
            """
        )
        reference_tables = citus_cursor.fetchall()

        assert len(reference_tables) > 0, "No reference tables found"

        # Verify reference tables
        table_names = [row["table_name"] for row in reference_tables]
        assert "sessions" in table_names or "metadata" in table_names


@pytest.mark.citus
class TestShardDistribution:
    """Test shard distribution and data placement."""

    def test_shard_count_per_table(self, citus_cursor):
        """Test that shards are distributed across tables."""
        citus_cursor.execute(
            """
            SELECT logicalrelid::regclass as table_name,
                   count(*) as shard_count
            FROM pg_dist_shard
            GROUP BY logicalrelid
            ORDER BY shard_count DESC
            """
        )
        shard_distribution = citus_cursor.fetchall()

        assert len(shard_distribution) > 0

        for row in shard_distribution:
            # Each distributed table should have multiple shards
            assert (
                row["shard_count"] >= 4
            ), f"Table {row['table_name']} has only {row['shard_count']} shards"

    def test_data_distribution_by_namespace(
        self, citus_cursor, test_namespace: str, sample_vector: List[float]
    ):
        """Test that data is distributed based on namespace (distribution column)."""
        # Insert data into multiple namespaces
        namespaces = [f"{test_namespace}_{i}" for i in range(5)]

        for ns in namespaces:
            citus_cursor.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                """,
                (ns, "test_key", "test_value", sample_vector),
            )

        # Verify data exists
        for ns in namespaces:
            citus_cursor.execute(
                "SELECT COUNT(*) FROM memory_entries WHERE namespace = %s",
                (ns,),
            )
            count = citus_cursor.fetchone()["count"]
            assert count == 1, f"Data not found for namespace {ns}"

    def test_co_location_query_efficiency(
        self, citus_cursor, test_namespace: str, sample_vector: List[float]
    ):
        """Test that co-located data (same namespace) queries efficiently."""
        # Insert co-located data (same namespace)
        for i in range(10):
            citus_cursor.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                """,
                (test_namespace, f"key_{i}", f"value_{i}", sample_vector),
            )

            # Also insert into patterns table (co-located by namespace)
            citus_cursor.execute(
                """
                INSERT INTO patterns (namespace, pattern_type, pattern_data, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                """,
                (
                    test_namespace,
                    "test_pattern",
                    '{"data": "test"}',
                    sample_vector,
                ),
            )

        # Query co-located data with JOIN
        start_time = time.time()
        citus_cursor.execute(
            """
            SELECT m.key, p.pattern_type
            FROM memory_entries m
            JOIN patterns p ON m.namespace = p.namespace
            WHERE m.namespace = %s
            """,
            (test_namespace,),
        )
        results = citus_cursor.fetchall()
        elapsed = time.time() - start_time

        assert len(results) == 100  # 10 memory_entries × 10 patterns
        assert elapsed < 0.5, f"Co-located JOIN took {elapsed:.3f}s (expected <0.5s)"


@pytest.mark.citus
class TestDistributedQueries:
    """Test distributed query execution across workers."""

    def test_distributed_insert(
        self, citus_cursor, test_namespace: str, sample_vector: List[float]
    ):
        """Test distributed insert across shards."""
        # Insert data that will be distributed
        num_records = 100
        for i in range(num_records):
            ns = f"{test_namespace}_{i % 10}"  # 10 different namespaces
            citus_cursor.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                """,
                (ns, f"key_{i}", f"value_{i}", sample_vector),
            )

        # Verify total count
        citus_cursor.execute(
            "SELECT COUNT(*) FROM memory_entries WHERE namespace LIKE %s",
            (f"{test_namespace}_%",),
        )
        total = citus_cursor.fetchone()["count"]
        assert total == num_records

    def test_distributed_aggregation(
        self, citus_cursor, test_namespace: str, sample_vector: List[float]
    ):
        """Test distributed aggregation across shards."""
        # Insert test data
        for i in range(50):
            ns = f"{test_namespace}_{i % 5}"
            citus_cursor.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                """,
                (ns, f"key_{i}", f"value_{i}", sample_vector),
            )

        # Test distributed GROUP BY
        citus_cursor.execute(
            """
            SELECT namespace, COUNT(*) as count
            FROM memory_entries
            WHERE namespace LIKE %s
            GROUP BY namespace
            ORDER BY namespace
            """,
            (f"{test_namespace}_%",),
        )
        results = citus_cursor.fetchall()

        assert len(results) == 5
        for row in results:
            assert row["count"] == 10

    def test_distributed_vector_search(
        self, citus_cursor, test_namespace: str, sample_vector: List[float]
    ):
        """Test vector search across distributed shards."""
        # Insert vectors into multiple namespaces
        for i in range(20):
            ns = f"{test_namespace}_{i % 4}"
            citus_cursor.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                """,
                (ns, f"vec_{i}", f"value_{i}", sample_vector),
            )

        # Perform distributed vector search
        start_time = time.time()
        citus_cursor.execute(
            """
            SELECT namespace, key, embedding <=> %s::ruvector AS distance
            FROM memory_entries
            WHERE namespace LIKE %s
            ORDER BY distance
            LIMIT 10
            """,
            (sample_vector, f"{test_namespace}_%"),
        )
        results = citus_cursor.fetchall()
        elapsed = time.time() - start_time

        assert len(results) == 10
        assert elapsed < 0.1, f"Distributed vector search took {elapsed:.3f}s"


@pytest.mark.citus
class TestReferenceTablesForce:
    """Test reference table functionality."""

    def test_reference_table_replication(self, citus_cursor, test_namespace: str):
        """Test that reference tables are replicated to all workers."""
        # Insert into metadata reference table
        citus_cursor.execute(
            "INSERT INTO metadata (key, value) VALUES (%s, %s) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
            (f"{test_namespace}_ref", "test_value"),
        )

        # Verify data exists
        citus_cursor.execute(
            "SELECT value FROM metadata WHERE key = %s",
            (f"{test_namespace}_ref",),
        )
        result = citus_cursor.fetchone()
        assert result["value"] == "test_value"

        # Cleanup
        citus_cursor.execute(
            "DELETE FROM metadata WHERE key = %s",
            (f"{test_namespace}_ref",),
        )

    def test_join_distributed_with_reference(
        self, citus_cursor, test_namespace: str, sample_vector: List[float]
    ):
        """Test JOIN between distributed and reference tables."""
        # Insert metadata
        citus_cursor.execute(
            "INSERT INTO metadata (key, value) VALUES (%s, %s) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
            (test_namespace, "metadata_value"),
        )

        # Insert distributed data
        citus_cursor.execute(
            """
            INSERT INTO memory_entries (namespace, key, value, embedding)
            VALUES (%s, %s, %s, %s::ruvector)
            """,
            (test_namespace, "test_key", "entry_value", sample_vector),
        )

        # JOIN distributed with reference
        citus_cursor.execute(
            """
            SELECT m.value as entry_value, md.value as metadata_value
            FROM memory_entries m
            CROSS JOIN metadata md
            WHERE m.namespace = %s AND md.key = %s
            """,
            (test_namespace, test_namespace),
        )
        result = citus_cursor.fetchone()

        assert result is not None
        assert result["entry_value"] == "entry_value"
        assert result["metadata_value"] == "metadata_value"

        # Cleanup
        citus_cursor.execute("DELETE FROM metadata WHERE key = %s", (test_namespace,))


@pytest.mark.citus
@pytest.mark.slow
class TestShardRebalancing:
    """Test shard rebalancing functionality."""

    def test_shard_placement_info(self, citus_cursor):
        """Test querying shard placement information."""
        citus_cursor.execute(
            """
            SELECT shardid,
                   nodename,
                   nodeport,
                   shardstate
            FROM pg_dist_placement
            ORDER BY shardid
            LIMIT 10
            """
        )
        placements = citus_cursor.fetchall()

        assert len(placements) > 0

        for placement in placements:
            assert placement["shardid"] is not None
            assert placement["nodename"] is not None
            assert placement["shardstate"] == 1  # 1 = finalized

    def test_shard_sizes(self, citus_cursor):
        """Test querying shard sizes."""
        citus_cursor.execute(
            """
            SELECT logicalrelid::regclass as table_name,
                   shardid,
                   pg_size_pretty(citus_table_size(logicalrelid)) as table_size
            FROM pg_dist_shard
            WHERE logicalrelid = 'memory_entries'::regclass
            LIMIT 5
            """
        )
        shard_sizes = citus_cursor.fetchall()

        assert len(shard_sizes) > 0

        for shard in shard_sizes:
            assert shard["table_name"] == "memory_entries"
            assert shard["table_size"] is not None


@pytest.mark.citus
class TestDistributedTransactions:
    """Test distributed transaction handling."""

    def test_two_phase_commit(
        self, citus_connection, test_namespace: str, sample_vector: List[float]
    ):
        """Test two-phase commit across shards."""
        with citus_connection.cursor() as cur:
            # Insert into multiple shards (different namespaces)
            cur.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                """,
                (f"{test_namespace}_1", "key1", "value1", sample_vector),
            )

            cur.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                """,
                (f"{test_namespace}_2", "key2", "value2", sample_vector),
            )

            # Commit transaction
            citus_connection.commit()

            # Verify both inserts succeeded
            cur.execute(
                "SELECT COUNT(*) FROM memory_entries WHERE namespace LIKE %s",
                (f"{test_namespace}_%",),
            )
            count = cur.fetchone()["count"]
            assert count == 2

            # Cleanup
            cur.execute(
                "DELETE FROM memory_entries WHERE namespace LIKE %s",
                (f"{test_namespace}_%",),
            )
            citus_connection.commit()

    def test_distributed_transaction_rollback(
        self, citus_connection, test_namespace: str, sample_vector: List[float]
    ):
        """Test rollback of distributed transaction."""
        with citus_connection.cursor() as cur:
            # Insert data
            cur.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                """,
                (test_namespace, "rollback_key", "rollback_value", sample_vector),
            )

            # Rollback
            citus_connection.rollback()

            # Verify rollback
            cur.execute(
                "SELECT COUNT(*) FROM memory_entries WHERE namespace = %s",
                (test_namespace,),
            )
            count = cur.fetchone()["count"]
            assert count == 0


@pytest.mark.citus
@pytest.mark.slow
class TestCitusPerformance:
    """Test Citus performance characteristics."""

    def test_parallel_query_execution(
        self, citus_cursor, test_namespace: str, sample_vector: List[float]
    ):
        """Test parallel query execution across workers."""
        # Insert large dataset across shards
        num_records = 1000
        for i in range(num_records):
            ns = f"{test_namespace}_{i % 10}"
            citus_cursor.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                """,
                (ns, f"key_{i}", f"value_{i}", sample_vector),
            )

        # Measure parallel query performance
        start_time = time.time()
        citus_cursor.execute(
            """
            SELECT namespace, COUNT(*) as count, AVG(LENGTH(value)) as avg_length
            FROM memory_entries
            WHERE namespace LIKE %s
            GROUP BY namespace
            """,
            (f"{test_namespace}_%",),
        )
        results = citus_cursor.fetchall()
        elapsed = time.time() - start_time

        assert len(results) == 10
        assert elapsed < 1.0, f"Parallel query took {elapsed:.3f}s (expected <1s)"


if __name__ == "__main__":
    pytest.main([__file__, "-v", "-m", "citus", "--tb=short"])
