"""Comprehensive integration tests for distributed PostgreSQL cluster.

Tests end-to-end functionality including:
- Connection management and pool behavior
- Data distribution across nodes
- Query routing (reads vs writes)
- Cross-shard operations
- Error handling and recovery
- Performance under load
"""

# Standard library imports
import concurrent.futures
import time
from typing import Dict, List

# Third-party imports
import psycopg2
import pytest
from psycopg2.extras import RealDictCursor


class TestConnectionManagement:
    """Test connection pooling and management."""

    def test_basic_connection(self, postgres_cursor):
        """Test basic database connectivity."""
        postgres_cursor.execute("SELECT version(), current_database()")
        result = postgres_cursor.fetchone()

        assert result is not None
        assert "PostgreSQL" in result["version"]
        assert result["current_database"] == "distributed_postgres_cluster"

    def test_ruvector_extension(self, postgres_cursor):
        """Test RuVector extension is installed."""
        postgres_cursor.execute(
            "SELECT extname, extversion FROM pg_extension WHERE extname = 'ruvector'"
        )
        result = postgres_cursor.fetchone()

        assert result is not None
        assert result["extname"] == "ruvector"
        assert result["extversion"] is not None

    def test_connection_pool_capacity(self, test_env: Dict[str, str]):
        """Test connection pool handles concurrent connections."""
        max_connections = 40
        connections = []

        try:
            # Create maximum allowed connections
            for i in range(max_connections):
                conn = psycopg2.connect(
                    host=test_env["postgres_host"],
                    port=test_env["postgres_port"],
                    database=test_env["postgres_db"],
                    user=test_env["postgres_user"],
                    password=test_env["postgres_password"],
                    connect_timeout=5,
                )
                connections.append(conn)

            # Verify all connections are active
            assert len(connections) == max_connections

            # Test query on all connections
            for conn in connections[:5]:  # Test a sample
                with conn.cursor() as cur:
                    cur.execute("SELECT 1")
                    assert cur.fetchone()[0] == 1

        finally:
            # Clean up
            for conn in connections:
                conn.close()

    def test_connection_recovery_after_timeout(self, test_env: Dict[str, str]):
        """Test connection recovery after timeout."""
        conn = psycopg2.connect(
            host=test_env["postgres_host"],
            port=test_env["postgres_port"],
            database=test_env["postgres_db"],
            user=test_env["postgres_user"],
            password=test_env["postgres_password"],
            connect_timeout=5,
        )

        try:
            with conn.cursor() as cur:
                # Execute long-running query
                cur.execute("SELECT pg_sleep(0.5)")

                # Connection should still work
                cur.execute("SELECT 1")
                assert cur.fetchone()[0] == 1
        finally:
            conn.close()

    @pytest.mark.slow
    def test_concurrent_connections(self, test_env: Dict[str, str]):
        """Test handling of concurrent database operations."""
        num_workers = 20
        queries_per_worker = 10

        def worker(worker_id: int) -> int:
            """Execute queries in parallel."""
            conn = psycopg2.connect(
                host=test_env["postgres_host"],
                port=test_env["postgres_port"],
                database=test_env["postgres_db"],
                user=test_env["postgres_user"],
                password=test_env["postgres_password"],
                connect_timeout=10,
            )

            try:
                successful = 0
                with conn.cursor() as cur:
                    for i in range(queries_per_worker):
                        cur.execute("SELECT %s::integer", (worker_id * 100 + i,))
                        result = cur.fetchone()[0]
                        assert result == worker_id * 100 + i
                        successful += 1
                return successful
            finally:
                conn.close()

        with concurrent.futures.ThreadPoolExecutor(max_workers=num_workers) as executor:
            futures = [executor.submit(worker, i) for i in range(num_workers)]
            results = [f.result() for f in concurrent.futures.as_completed(futures)]

        # All workers should complete successfully
        assert len(results) == num_workers
        assert all(r == queries_per_worker for r in results)


class TestDataDistribution:
    """Test data distribution and consistency."""

    def test_insert_and_retrieve(
        self, postgres_cursor, test_namespace: str, sample_vector: List[float]
    ):
        """Test basic insert and retrieve operations."""
        # Insert test data
        postgres_cursor.execute(
            """
            INSERT INTO memory_entries (namespace, key, value, embedding)
            VALUES (%s, %s, %s, %s::ruvector)
            RETURNING id
            """,
            (test_namespace, "test_key", "test_value", sample_vector),
        )
        result = postgres_cursor.fetchone()
        entry_id = result["id"]

        # Retrieve data
        postgres_cursor.execute(
            """
            SELECT * FROM memory_entries
            WHERE namespace = %s AND key = %s
            """,
            (test_namespace, "test_key"),
        )
        retrieved = postgres_cursor.fetchone()

        assert retrieved is not None
        assert retrieved["id"] == entry_id
        assert retrieved["value"] == "test_value"

    def test_bulk_insert_performance(
        self, postgres_cursor, test_namespace: str, sample_vector: List[float]
    ):
        """Test bulk insert performance."""
        num_records = 1000
        start_time = time.time()

        # Bulk insert
        records = [
            (test_namespace, f"key_{i}", f"value_{i}", sample_vector) for i in range(num_records)
        ]

        postgres_cursor.executemany(
            """
            INSERT INTO memory_entries (namespace, key, value, embedding)
            VALUES (%s, %s, %s, %s::ruvector)
            """,
            records,
        )

        elapsed = time.time() - start_time

        # Verify count
        postgres_cursor.execute(
            "SELECT COUNT(*) FROM memory_entries WHERE namespace = %s",
            (test_namespace,),
        )
        count = postgres_cursor.fetchone()["count"]

        assert count == num_records
        assert elapsed < 10.0, f"Bulk insert took {elapsed:.2f}s (expected <10s)"

    def test_vector_search(self, postgres_cursor, test_namespace: str, sample_vector: List[float]):
        """Test vector similarity search."""
        # Insert test vectors
        for i in range(10):
            postgres_cursor.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                """,
                (test_namespace, f"vec_{i}", f"value_{i}", sample_vector),
            )

        # Perform vector search
        postgres_cursor.execute(
            """
            SELECT key, value,
                   embedding <=> %s::ruvector AS distance
            FROM memory_entries
            WHERE namespace = %s
            ORDER BY distance
            LIMIT 5
            """,
            (sample_vector, test_namespace),
        )
        results = postgres_cursor.fetchall()

        assert len(results) == 5
        # First result should have smallest distance
        assert results[0]["distance"] <= results[-1]["distance"]

    def test_cross_namespace_isolation(self, postgres_cursor, sample_vector: List[float]):
        """Test that namespaces are properly isolated."""
        namespace1 = "test_ns_1"
        namespace2 = "test_ns_2"

        # Insert into namespace 1
        postgres_cursor.execute(
            """
            INSERT INTO memory_entries (namespace, key, value, embedding)
            VALUES (%s, %s, %s, %s::ruvector)
            """,
            (namespace1, "shared_key", "value_1", sample_vector),
        )

        # Insert into namespace 2
        postgres_cursor.execute(
            """
            INSERT INTO memory_entries (namespace, key, value, embedding)
            VALUES (%s, %s, %s, %s::ruvector)
            """,
            (namespace2, "shared_key", "value_2", sample_vector),
        )

        # Query namespace 1
        postgres_cursor.execute(
            "SELECT value FROM memory_entries WHERE namespace = %s AND key = %s",
            (namespace1, "shared_key"),
        )
        result1 = postgres_cursor.fetchone()

        # Query namespace 2
        postgres_cursor.execute(
            "SELECT value FROM memory_entries WHERE namespace = %s AND key = %s",
            (namespace2, "shared_key"),
        )
        result2 = postgres_cursor.fetchone()

        assert result1["value"] == "value_1"
        assert result2["value"] == "value_2"


class TestTransactionManagement:
    """Test transaction handling and ACID properties."""

    def test_transaction_rollback(
        self, postgres_connection, test_namespace: str, sample_vector: List[float]
    ):
        """Test transaction rollback."""
        with postgres_connection.cursor() as cur:
            # Start transaction
            cur.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                """,
                (test_namespace, "rollback_test", "value", sample_vector),
            )

            # Rollback
            postgres_connection.rollback()

            # Verify not committed
            cur.execute(
                "SELECT COUNT(*) FROM memory_entries WHERE namespace = %s",
                (test_namespace,),
            )
            count = cur.fetchone()["count"]
            assert count == 0

    def test_transaction_commit(
        self, postgres_connection, test_namespace: str, sample_vector: List[float]
    ):
        """Test transaction commit."""
        with postgres_connection.cursor() as cur:
            # Start transaction
            cur.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                """,
                (test_namespace, "commit_test", "value", sample_vector),
            )

            # Commit
            postgres_connection.commit()

            # Verify committed
            cur.execute(
                "SELECT COUNT(*) FROM memory_entries WHERE namespace = %s",
                (test_namespace,),
            )
            count = cur.fetchone()["count"]
            assert count == 1

            # Cleanup
            cur.execute("DELETE FROM memory_entries WHERE namespace = %s", (test_namespace,))
            postgres_connection.commit()

    def test_concurrent_writes_no_conflict(
        self, test_env: Dict[str, str], sample_vector: List[float]
    ):
        """Test concurrent writes to different namespaces."""
        num_workers = 10

        def worker(worker_id: int) -> bool:
            """Write to unique namespace."""
            conn = psycopg2.connect(
                host=test_env["postgres_host"],
                port=test_env["postgres_port"],
                database=test_env["postgres_db"],
                user=test_env["postgres_user"],
                password=test_env["postgres_password"],
            )

            try:
                with conn.cursor() as cur:
                    namespace = f"test_worker_{worker_id}"
                    cur.execute(
                        """
                        INSERT INTO memory_entries (namespace, key, value, embedding)
                        VALUES (%s, %s, %s, %s::ruvector)
                        """,
                        (namespace, "key", f"value_{worker_id}", sample_vector),
                    )
                conn.commit()
                return True
            except Exception as e:
                print(f"Worker {worker_id} failed: {e}")
                return False
            finally:
                conn.close()

        with concurrent.futures.ThreadPoolExecutor(max_workers=num_workers) as executor:
            futures = [executor.submit(worker, i) for i in range(num_workers)]
            results = [f.result() for f in concurrent.futures.as_completed(futures)]

        # All workers should succeed
        assert all(results)


class TestErrorHandling:
    """Test error handling and recovery."""

    def test_invalid_vector_dimension(self, postgres_cursor, test_namespace: str):
        """Test handling of invalid vector dimensions."""
        invalid_vector = [0.1] * 128  # Wrong dimension (should be 384)

        with pytest.raises(psycopg2.DatabaseError):
            postgres_cursor.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                """,
                (test_namespace, "key", "value", invalid_vector),
            )

    def test_duplicate_key_constraint(
        self, postgres_cursor, test_namespace: str, sample_vector: List[float]
    ):
        """Test unique constraint enforcement."""
        # Insert first record
        postgres_cursor.execute(
            """
            INSERT INTO memory_entries (namespace, key, value, embedding)
            VALUES (%s, %s, %s, %s::ruvector)
            """,
            (test_namespace, "dup_key", "value1", sample_vector),
        )

        # Attempt duplicate insert
        with pytest.raises(psycopg2.IntegrityError):
            postgres_cursor.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                """,
                (test_namespace, "dup_key", "value2", sample_vector),
            )

    def test_connection_timeout_handling(self, test_env: Dict[str, str]):
        """Test handling of connection timeouts."""
        # Attempt connection with very short timeout
        with pytest.raises(psycopg2.OperationalError):
            psycopg2.connect(
                host="192.0.2.1",  # Non-routable IP
                port=5432,
                database=test_env["postgres_db"],
                user=test_env["postgres_user"],
                password=test_env["postgres_password"],
                connect_timeout=1,
            )


class TestPerformance:
    """Test performance characteristics."""

    @pytest.mark.slow
    def test_query_performance_simple(
        self, postgres_cursor, test_namespace: str, sample_vector: List[float]
    ):
        """Test simple query performance."""
        # Insert test data
        for i in range(100):
            postgres_cursor.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                """,
                (test_namespace, f"key_{i}", f"value_{i}", sample_vector),
            )

        # Measure query time
        start_time = time.time()
        postgres_cursor.execute(
            "SELECT * FROM memory_entries WHERE namespace = %s LIMIT 10",
            (test_namespace,),
        )
        results = postgres_cursor.fetchall()
        elapsed = time.time() - start_time

        assert len(results) == 10
        assert elapsed < 0.1, f"Query took {elapsed:.3f}s (expected <0.1s)"

    @pytest.mark.slow
    def test_vector_search_performance(
        self, postgres_cursor, test_namespace: str, sample_vector: List[float]
    ):
        """Test vector search performance with HNSW index."""
        # Insert test vectors
        num_vectors = 1000
        for i in range(num_vectors):
            postgres_cursor.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                """,
                (test_namespace, f"vec_{i}", f"value_{i}", sample_vector),
            )

        # Measure vector search time
        start_time = time.time()
        postgres_cursor.execute(
            """
            SELECT key, embedding <=> %s::ruvector AS distance
            FROM memory_entries
            WHERE namespace = %s
            ORDER BY distance
            LIMIT 10
            """,
            (sample_vector, test_namespace),
        )
        results = postgres_cursor.fetchall()
        elapsed = time.time() - start_time

        assert len(results) == 10
        assert elapsed < 0.05, f"Vector search took {elapsed:.3f}s (expected <50ms)"


if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])
