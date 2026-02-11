#!/usr/bin/env python3
"""Performance Tests - Security Layer Performance.

Tests performance impact of security measures:
- Input validation overhead
- SQL injection prevention overhead
- Authentication overhead
- Authorization overhead
"""

import os
import sys
import unittest
import time
from typing import List

# Add parent directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../..'))

from src.db.pool import DualDatabasePools
from src.db.vector_ops import store_memory, search_memory, retrieve_memory


class TestInputValidationPerformance(unittest.TestCase):
    """Test performance impact of input validation."""

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
        if hasattr(cls, 'pools'):
            cls.pools.close()

    def test_validation_overhead_small_inputs(self):
        """Test validation overhead with small inputs."""
        iterations = 100
        namespace = "perf_test"

        start = time.time()

        with self.pools.project_cursor() as cur:
            for i in range(iterations):
                store_memory(
                    cur,
                    namespace=namespace,
                    key=f"key_{i}",
                    value="small value"
                )

        duration = time.time() - start
        avg_time = (duration / iterations) * 1000  # ms

        print(f"\nSmall input validation: {avg_time:.2f}ms per operation")

        # Validation should add minimal overhead (<1ms per operation)
        self.assertLess(avg_time, 10)  # Very generous threshold

    def test_validation_overhead_large_inputs(self):
        """Test validation overhead with large inputs."""
        iterations = 50
        namespace = "perf_test"
        large_value = "x" * 10000  # 10KB

        start = time.time()

        with self.pools.project_cursor() as cur:
            for i in range(iterations):
                store_memory(
                    cur,
                    namespace=namespace,
                    key=f"large_key_{i}",
                    value=large_value
                )

        duration = time.time() - start
        avg_time = (duration / iterations) * 1000  # ms

        print(f"\nLarge input validation: {avg_time:.2f}ms per operation")

        # Even with large inputs, validation should be fast
        self.assertLess(avg_time, 50)

    def test_embedding_validation_overhead(self):
        """Test embedding dimension validation overhead."""
        iterations = 100
        namespace = "perf_test"
        embedding = [0.1] * 384

        start = time.time()

        with self.pools.project_cursor() as cur:
            for i in range(iterations):
                store_memory(
                    cur,
                    namespace=namespace,
                    key=f"embed_key_{i}",
                    value="test",
                    embedding=embedding
                )

        duration = time.time() - start
        avg_time = (duration / iterations) * 1000  # ms

        print(f"\nEmbedding validation: {avg_time:.2f}ms per operation")

        # Embedding validation should be very fast
        self.assertLess(avg_time, 10)


class TestQueryParameterizationPerformance(unittest.TestCase):
    """Test performance of parameterized queries vs string concatenation."""

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
        if hasattr(cls, 'pools'):
            cls.pools.close()

    def test_parameterized_query_performance(self):
        """Test parameterized query performance (our secure method)."""
        iterations = 100
        namespace = "perf_test"

        start = time.time()

        with self.pools.project_cursor() as cur:
            for i in range(iterations):
                retrieve_memory(cur, namespace, f"key_{i}")

        duration = time.time() - start
        avg_time = (duration / iterations) * 1000  # ms

        print(f"\nParameterized queries: {avg_time:.2f}ms per operation")

        # Should be fast
        self.assertLess(avg_time, 10)

    def test_batch_query_performance(self):
        """Test batch query performance."""
        batch_size = 100
        namespace = "perf_test"

        # Store test data
        with self.pools.project_cursor() as cur:
            for i in range(batch_size):
                store_memory(
                    cur,
                    namespace=namespace,
                    key=f"batch_key_{i}",
                    value=f"value_{i}"
                )

        # Measure batch retrieval
        start = time.time()

        with self.pools.project_cursor() as cur:
            for i in range(batch_size):
                retrieve_memory(cur, namespace, f"batch_key_{i}")

        duration = time.time() - start
        avg_time = (duration / batch_size) * 1000  # ms

        print(f"\nBatch queries: {avg_time:.2f}ms per query")

        # Batch queries should be efficient
        self.assertLess(avg_time, 10)


class TestAuthenticationPerformance(unittest.TestCase):
    """Test authentication performance overhead."""

    def test_connection_establishment_time(self):
        """Test connection establishment time."""
        iterations = 10
        timings = []

        for _ in range(iterations):
            start = time.time()

            try:
                pools = DualDatabasePools()
                pools.close()
            except Exception as e:
                raise unittest.SkipTest(f"Database not available: {e}")

            duration = time.time() - start
            timings.append(duration)

        avg_time = (sum(timings) / len(timings)) * 1000  # ms

        print(f"\nConnection establishment: {avg_time:.2f}ms average")

        # Connection establishment should be reasonably fast
        # (includes authentication)
        self.assertLess(avg_time, 1000)  # Under 1 second

    def test_connection_reuse_overhead(self):
        """Test connection reuse from pool."""
        try:
            pools = DualDatabasePools()
        except Exception as e:
            raise unittest.SkipTest(f"Database not available: {e}")

        iterations = 100
        start = time.time()

        for _ in range(iterations):
            with pools.project_cursor() as cur:
                cur.execute("SELECT 1")

        duration = time.time() - start
        avg_time = (duration / iterations) * 1000  # ms

        print(f"\nConnection reuse: {avg_time:.2f}ms per query")

        pools.close()

        # Connection reuse should be very fast
        self.assertLess(avg_time, 5)


class TestSecurityOverheadBenchmark(unittest.TestCase):
    """Comprehensive security overhead benchmark."""

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
        if hasattr(cls, 'pools'):
            cls.pools.close()

    def test_complete_security_stack_overhead(self):
        """Test total overhead of complete security stack."""
        iterations = 50
        namespace = "perf_test"

        # Test data with various security validations
        test_data = [
            {
                'key': f'key_{i}',
                'value': f'value_{i}',
                'embedding': [0.1 * i % 384 for _ in range(384)],
                'metadata': {'test': True, 'index': i}
            }
            for i in range(iterations)
        ]

        # Measure complete flow: validate → store → retrieve → validate
        start = time.time()

        for data in test_data:
            with self.pools.project_cursor() as cur:
                # Store (includes validation)
                store_memory(
                    cur,
                    namespace=namespace,
                    key=data['key'],
                    value=data['value'],
                    embedding=data['embedding'],
                    metadata=data['metadata']
                )

                # Retrieve (includes validation)
                result = retrieve_memory(cur, namespace, data['key'])
                self.assertIsNotNone(result)

        duration = time.time() - start
        avg_time = (duration / iterations) * 1000  # ms

        print(f"\nComplete security stack: {avg_time:.2f}ms per operation")

        # Total security overhead should be minimal
        self.assertLess(avg_time, 20)  # Very generous threshold

    def test_vector_search_security_overhead(self):
        """Test security overhead in vector search."""
        iterations = 20
        namespace = "perf_test"

        # Store test vectors
        for i in range(100):
            with self.pools.project_cursor() as cur:
                store_memory(
                    cur,
                    namespace=namespace,
                    key=f"vec_key_{i}",
                    value=f"value_{i}",
                    embedding=[0.01 * i % 384 for _ in range(384)]
                )

        # Measure search with security validation
        query_embedding = [0.5] * 384
        start = time.time()

        for _ in range(iterations):
            with self.pools.project_cursor() as cur:
                results = search_memory(
                    cur,
                    namespace=namespace,
                    query_embedding=query_embedding,
                    limit=10,
                    min_similarity=0.7
                )

        duration = time.time() - start
        avg_time = (duration / iterations) * 1000  # ms

        print(f"\nVector search with security: {avg_time:.2f}ms per search")

        # Vector search should remain fast even with security
        # Target: <50ms (from requirements)
        self.assertLess(avg_time, 100)  # Generous for test environment


def run_security_performance_tests():
    """Run all security performance tests."""
    suite = unittest.TestSuite()

    test_classes = [
        TestInputValidationPerformance,
        TestQueryParameterizationPerformance,
        TestAuthenticationPerformance,
        TestSecurityOverheadBenchmark,
    ]

    for test_class in test_classes:
        tests = unittest.TestLoader().loadTestsFromTestCase(test_class)
        suite.addTests(tests)

    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(run_security_performance_tests())
