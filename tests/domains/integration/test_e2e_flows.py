#!/usr/bin/env python3
"""Integration Domain Tests - End-to-End Integration Flows.

Tests complete integration flows across multiple components:
- Database → Vector Ops → Memory
- MCP Server → Database → Response
- Event Bus → Handlers → Storage
"""

# Standard library imports
import os
import sys
import time
import unittest
from typing import Any, Dict

# Add parent directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../.."))

# Local imports
from src.db.pool import DualDatabasePools
from src.db.vector_ops import delete_memory, retrieve_memory, search_memory, store_memory


class TestMemoryStorageFlow(unittest.TestCase):
    """Test complete memory storage and retrieval flow."""

    @classmethod
    def setUpClass(cls):
        """Set up database pools."""
        try:
            cls.pools = DualDatabasePools()
        except Exception as e:
            raise unittest.SkipTest(f"Database not available: {e}")

    @classmethod
    def tearDownClass(cls):
        """Clean up pools."""
        if hasattr(cls, "pools"):
            cls.pools.close()

    def test_complete_memory_lifecycle(self):
        """Test complete memory lifecycle: store → retrieve → search → delete."""
        namespace = f"test_e2e_{int(time.time())}"
        key = "lifecycle_key"
        value = "Test value for lifecycle"
        embedding = [0.1 * i for i in range(384)]

        # 1. Store memory
        with self.pools.project_cursor() as cur:
            store_memory(
                cur,
                namespace=namespace,
                key=key,
                value=value,
                embedding=embedding,
                metadata={"test": "lifecycle"},
            )

        # 2. Retrieve memory
        with self.pools.project_cursor() as cur:
            result = retrieve_memory(cur, namespace, key)

        self.assertIsNotNone(result)
        self.assertEqual(result["value"], value)
        self.assertEqual(result["metadata"]["test"], "lifecycle")

        # 3. Search for memory
        with self.pools.project_cursor() as cur:
            search_results = search_memory(
                cur, namespace=namespace, query_embedding=embedding, limit=10, min_similarity=0.9
            )

        self.assertGreater(len(search_results), 0)
        self.assertEqual(search_results[0]["key"], key)
        self.assertGreater(search_results[0]["similarity"], 0.99)

        # 4. Delete memory
        with self.pools.project_cursor() as cur:
            deleted = delete_memory(cur, namespace, key)

        self.assertTrue(deleted)

        # 5. Verify deletion
        with self.pools.project_cursor() as cur:
            result = retrieve_memory(cur, namespace, key)

        self.assertIsNone(result)

    def test_cross_database_isolation(self):
        """Test isolation between project and shared databases."""
        namespace = f"test_isolation_{int(time.time())}"
        key = "isolation_key"

        # Store in project database
        with self.pools.project_cursor() as cur:
            store_memory(cur, namespace=namespace, key=key, value="project_value")

        # Store in shared database with same namespace/key
        with self.pools.shared_cursor() as cur:
            store_memory(cur, namespace=namespace, key=key, value="shared_value")

        # Verify isolation
        with self.pools.project_cursor() as cur:
            project_result = retrieve_memory(cur, namespace, key)

        with self.pools.shared_cursor() as cur:
            shared_result = retrieve_memory(cur, namespace, key)

        self.assertEqual(project_result["value"], "project_value")
        self.assertEqual(shared_result["value"], "shared_value")


class TestVectorSearchFlow(unittest.TestCase):
    """Test vector search integration flow."""

    @classmethod
    def setUpClass(cls):
        """Set up database pools and test data."""
        try:
            cls.pools = DualDatabasePools()
        except Exception as e:
            raise unittest.SkipTest(f"Database not available: {e}")

        cls.namespace = f"test_search_{int(time.time())}"

        # Store test data
        cls.test_data = [
            {
                "key": "doc1",
                "value": "Machine learning and AI",
                "embedding": [0.8, 0.6] + [0.0] * 382,
            },
            {
                "key": "doc2",
                "value": "Database management systems",
                "embedding": [0.2, 0.9] + [0.0] * 382,
            },
            {
                "key": "doc3",
                "value": "Deep learning neural networks",
                "embedding": [0.9, 0.5] + [0.0] * 382,
            },
        ]

        with cls.pools.project_cursor() as cur:
            for doc in cls.test_data:
                store_memory(
                    cur,
                    namespace=cls.namespace,
                    key=doc["key"],
                    value=doc["value"],
                    embedding=doc["embedding"],
                )

    @classmethod
    def tearDownClass(cls):
        """Clean up test data and pools."""
        if hasattr(cls, "pools"):
            with cls.pools.project_cursor() as cur:
                for doc in cls.test_data:
                    delete_memory(cur, cls.namespace, doc["key"])

            cls.pools.close()

    def test_similarity_search(self):
        """Test vector similarity search."""
        # Query similar to doc1 (ML/AI)
        query = [0.85, 0.55] + [0.0] * 382

        with self.pools.project_cursor() as cur:
            results = search_memory(
                cur, namespace=self.namespace, query_embedding=query, limit=3, min_similarity=0.5
            )

        self.assertGreater(len(results), 0)

        # First result should be doc1 or doc3 (both ML-related)
        top_result = results[0]
        self.assertIn(top_result["key"], ["doc1", "doc3"])

    def test_search_with_threshold(self):
        """Test search with similarity threshold."""
        # Query very different from all documents
        query = [0.1, 0.1] + [0.0] * 382

        with self.pools.project_cursor() as cur:
            # High threshold - should get fewer/no results
            strict_results = search_memory(
                cur, namespace=self.namespace, query_embedding=query, limit=10, min_similarity=0.99
            )

            # Low threshold - should get all results
            loose_results = search_memory(
                cur, namespace=self.namespace, query_embedding=query, limit=10, min_similarity=0.0
            )

        self.assertEqual(len(strict_results), 0)
        self.assertGreater(len(loose_results), 0)

    def test_search_limit(self):
        """Test search result limiting."""
        query = [0.5, 0.5] + [0.0] * 382

        with self.pools.project_cursor() as cur:
            # Limit to 1 result
            results_1 = search_memory(
                cur, namespace=self.namespace, query_embedding=query, limit=1, min_similarity=0.0
            )

            # Limit to 2 results
            results_2 = search_memory(
                cur, namespace=self.namespace, query_embedding=query, limit=2, min_similarity=0.0
            )

        self.assertEqual(len(results_1), 1)
        self.assertLessEqual(len(results_2), 2)


class TestConcurrentAccessFlow(unittest.TestCase):
    """Test concurrent access patterns."""

    @classmethod
    def setUpClass(cls):
        """Set up database pools."""
        try:
            cls.pools = DualDatabasePools()
        except Exception as e:
            raise unittest.SkipTest(f"Database not available: {e}")

    @classmethod
    def tearDownClass(cls):
        """Clean up pools."""
        if hasattr(cls, "pools"):
            cls.pools.close()

    def test_concurrent_writes(self):
        """Test concurrent write operations."""
        # Standard library imports
        import threading

        namespace = f"test_concurrent_{int(time.time())}"
        num_threads = 5
        writes_per_thread = 10
        errors = []
        successful_writes = []

        def write_worker(thread_id):
            """Worker that writes multiple entries."""
            try:
                for i in range(writes_per_thread):
                    with self.pools.project_cursor() as cur:
                        key = f"thread_{thread_id}_item_{i}"
                        store_memory(
                            cur, namespace=namespace, key=key, value=f"value_{thread_id}_{i}"
                        )
                        successful_writes.append(key)
            except Exception as e:
                errors.append(e)

        # Start threads
        threads = []
        for i in range(num_threads):
            thread = threading.Thread(target=write_worker, args=(i,))
            threads.append(thread)
            thread.start()

        # Wait for completion
        for thread in threads:
            thread.join()

        # Verify
        self.assertEqual(len(errors), 0, f"Errors occurred: {errors}")
        self.assertEqual(len(successful_writes), num_threads * writes_per_thread)

    def test_concurrent_reads(self):
        """Test concurrent read operations."""
        # Standard library imports
        import threading

        namespace = f"test_read_{int(time.time())}"

        # Store test data
        with self.pools.project_cursor() as cur:
            for i in range(10):
                store_memory(cur, namespace=namespace, key=f"key_{i}", value=f"value_{i}")

        # Concurrent reads
        results = []
        errors = []

        def read_worker(key_index):
            """Worker that reads an entry."""
            try:
                with self.pools.project_cursor() as cur:
                    result = retrieve_memory(cur, namespace, f"key_{key_index}")
                    if result:
                        results.append(result)
            except Exception as e:
                errors.append(e)

        # Start threads
        threads = []
        for i in range(10):
            thread = threading.Thread(target=read_worker, args=(i,))
            threads.append(thread)
            thread.start()

        # Wait for completion
        for thread in threads:
            thread.join()

        # Verify
        self.assertEqual(len(errors), 0, f"Errors occurred: {errors}")
        self.assertEqual(len(results), 10)


class TestErrorRecoveryFlow(unittest.TestCase):
    """Test error recovery in integration flows."""

    @classmethod
    def setUpClass(cls):
        """Set up database pools."""
        try:
            cls.pools = DualDatabasePools()
        except Exception as e:
            raise unittest.SkipTest(f"Database not available: {e}")

    @classmethod
    def tearDownClass(cls):
        """Clean up pools."""
        if hasattr(cls, "pools"):
            cls.pools.close()

    def test_transaction_rollback_recovery(self):
        """Test recovery from transaction rollback."""
        namespace = f"test_rollback_{int(time.time())}"

        # Successful transaction
        with self.pools.project_cursor() as cur:
            store_memory(cur, namespace, "key1", "value1")

        # Failed transaction (invalid embedding)
        try:
            with self.pools.project_cursor() as cur:
                store_memory(
                    cur, namespace, "key2", "value2", embedding=[0.1] * 512  # Wrong dimensions
                )
        except Exception:
            pass  # Expected

        # Verify first transaction committed, second rolled back
        with self.pools.project_cursor() as cur:
            result1 = retrieve_memory(cur, namespace, "key1")
            result2 = retrieve_memory(cur, namespace, "key2")

        self.assertIsNotNone(result1)
        self.assertIsNone(result2)

    def test_connection_pool_recovery(self):
        """Test connection pool recovery after errors."""
        # Get initial health
        health_before = self.pools.health_check()

        # Cause some errors
        for _ in range(5):
            try:
                with self.pools.project_cursor() as cur:
                    cur.execute("SELECT * FROM nonexistent_table")
            except Exception:
                pass  # Expected

        # Pool should still be healthy
        health_after = self.pools.health_check()

        self.assertEqual(health_before["project"]["status"], health_after["project"]["status"])


def run_e2e_integration_tests():
    """Run all end-to-end integration tests."""
    suite = unittest.TestSuite()

    test_classes = [
        TestMemoryStorageFlow,
        TestVectorSearchFlow,
        TestConcurrentAccessFlow,
        TestErrorRecoveryFlow,
    ]

    for test_class in test_classes:
        tests = unittest.TestLoader().loadTestsFromTestCase(test_class)
        suite.addTests(tests)

    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(run_e2e_integration_tests())
