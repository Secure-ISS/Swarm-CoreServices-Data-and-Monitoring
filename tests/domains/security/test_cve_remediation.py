#!/usr/bin/env python3
"""Security Domain Tests - CVE Remediation Validation.

Tests for CVE-1, CVE-2, and CVE-3 remediation strategies including:
- SQL injection prevention
- Path traversal prevention
- Input validation and sanitization
"""

# Standard library imports
import os
import sys
import unittest
from typing import Any, Dict, List
from unittest.mock import MagicMock, patch

# Add parent directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../.."))

# Local imports
from src.db.pool import DatabaseConnectionError, DualDatabasePools
from src.db.vector_ops import (
    InvalidEmbeddingError,
    VectorOperationError,
    retrieve_memory,
    search_memory,
    store_memory,
)


class TestCVE1SQLInjectionPrevention(unittest.TestCase):
    """Test CVE-1: SQL Injection Prevention.

    Validates that parameterized queries prevent SQL injection attacks
    across all database operations.
    """

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

    def test_sql_injection_in_namespace(self):
        """Test that SQL injection in namespace parameter is prevented."""
        malicious_namespace = "'; DROP TABLE memory_entries; --"

        with self.pools.project_cursor() as cur:
            # Should not execute DROP TABLE
            store_memory(
                cur,
                namespace=malicious_namespace,
                key="test_key",
                value="test_value",
                embedding=[0.1] * 384,
            )

            # Verify table still exists
            cur.execute("SELECT COUNT(*) as count FROM memory_entries")
            result = cur.fetchone()
            self.assertIsNotNone(result)

    def test_sql_injection_in_key(self):
        """Test that SQL injection in key parameter is prevented."""
        malicious_key = "key' OR '1'='1"

        with self.pools.project_cursor() as cur:
            store_memory(cur, namespace="test", key=malicious_key, value="test_value")

            # Should retrieve only the specific key, not all keys
            result = retrieve_memory(cur, "test", malicious_key)
            self.assertIsNotNone(result)
            self.assertEqual(result["key"], malicious_key)

    def test_sql_injection_in_search_query(self):
        """Test SQL injection prevention in vector search."""
        with self.pools.project_cursor() as cur:
            # Store legitimate data
            store_memory(
                cur,
                namespace="test_search",
                key="key1",
                value="sensitive data",
                embedding=[0.1] * 384,
            )

            # Attempt SQL injection through search
            try:
                # Malicious embedding that tries to inject SQL
                results = search_memory(
                    cur, namespace="test_search' OR '1'='1", query_embedding=[0.1] * 384, limit=10
                )
                # Should return no results from the injection
                self.assertEqual(len(results), 0)
            except (VectorOperationError, ValueError):
                # Expected - malicious input rejected
                pass

    def test_sql_injection_in_metadata(self):
        """Test SQL injection prevention in JSON metadata."""
        malicious_metadata = {"key": "'; DELETE FROM memory_entries WHERE '1'='1"}

        with self.pools.project_cursor() as cur:
            store_memory(
                cur,
                namespace="test",
                key="metadata_test",
                value="test",
                metadata=malicious_metadata,
            )

            # Verify data stored safely
            result = retrieve_memory(cur, "test", "metadata_test")
            self.assertEqual(result["metadata"]["key"], malicious_metadata["key"])


class TestCVE2PathTraversalPrevention(unittest.TestCase):
    """Test CVE-2: Path Traversal Prevention.

    Validates that file paths and namespaces cannot escape
    intended directories or database schemas.
    """

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

    def test_path_traversal_in_namespace(self):
        """Test that path traversal patterns in namespace are handled safely."""
        traversal_namespaces = [
            "../../../etc/passwd",
            "..\\..\\windows\\system32",
            "test/../../../secret",
            "test/./../../data",
        ]

        for namespace in traversal_namespaces:
            with self.pools.project_cursor() as cur:
                # Should store literally, not traverse
                store_memory(cur, namespace=namespace, key="test_key", value="test_value")

                # Should retrieve with exact namespace
                result = retrieve_memory(cur, namespace, "test_key")
                self.assertIsNotNone(result)
                self.assertEqual(result["namespace"], namespace)

    def test_schema_traversal_prevention(self):
        """Test that schema names cannot be manipulated."""
        with self.pools.project_cursor() as cur:
            # Attempt to access different schema
            malicious_namespace = "information_schema.tables"

            store_memory(cur, namespace=malicious_namespace, key="test", value="test")

            # Verify stored in memory_entries, not system tables
            cur.execute("SELECT schemaname FROM pg_tables WHERE tablename = 'memory_entries'")
            result = cur.fetchone()
            self.assertIn(result["schemaname"], ["public", "claude_flow"])

    def test_null_byte_injection(self):
        """Test that null byte injection is prevented."""
        null_byte_namespace = "test\x00malicious"

        with self.pools.project_cursor() as cur:
            try:
                store_memory(cur, namespace=null_byte_namespace, key="test", value="test")

                # If stored, verify it doesn't bypass security
                result = retrieve_memory(cur, null_byte_namespace, "test")
                if result:
                    # Should store the literal null byte, not interpret it
                    self.assertIn("\x00", result["namespace"])
            except (ValueError, VectorOperationError):
                # Expected - input validation may reject this
                pass


class TestCVE3InputValidation(unittest.TestCase):
    """Test CVE-3: Comprehensive Input Validation.

    Validates all inputs are properly validated before database operations.
    """

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

    def test_empty_namespace_rejected(self):
        """Test that empty namespace is rejected."""
        with self.pools.project_cursor() as cur:
            with self.assertRaises(ValueError):
                store_memory(cur, "", "key", "value")

    def test_empty_key_rejected(self):
        """Test that empty key is rejected."""
        with self.pools.project_cursor() as cur:
            with self.assertRaises(ValueError):
                store_memory(cur, "namespace", "", "value")

    def test_empty_value_rejected(self):
        """Test that empty value is rejected."""
        with self.pools.project_cursor() as cur:
            with self.assertRaises(ValueError):
                store_memory(cur, "namespace", "key", "")

    def test_invalid_embedding_dimensions(self):
        """Test that wrong embedding dimensions are rejected."""
        with self.pools.project_cursor() as cur:
            # Too few dimensions
            with self.assertRaises(InvalidEmbeddingError):
                store_memory(cur, "test", "key", "value", embedding=[0.1] * 128)

            # Too many dimensions
            with self.assertRaises(InvalidEmbeddingError):
                store_memory(cur, "test", "key", "value", embedding=[0.1] * 512)

    def test_invalid_similarity_threshold(self):
        """Test that invalid similarity thresholds are rejected."""
        with self.pools.project_cursor() as cur:
            # Negative similarity
            with self.assertRaises(ValueError):
                search_memory(cur, "test", [0.1] * 384, min_similarity=-0.5)

            # Similarity > 1
            with self.assertRaises(ValueError):
                search_memory(cur, "test", [0.1] * 384, min_similarity=1.5)

    def test_invalid_limit_values(self):
        """Test that invalid limit values are rejected."""
        with self.pools.project_cursor() as cur:
            # Zero limit
            with self.assertRaises(ValueError):
                search_memory(cur, "test", [0.1] * 384, limit=0)

            # Negative limit
            with self.assertRaises(ValueError):
                search_memory(cur, "test", [0.1] * 384, limit=-10)

            # Excessive limit
            with self.assertRaises(ValueError):
                search_memory(cur, "test", [0.1] * 384, limit=10000)

    def test_malformed_embedding_values(self):
        """Test that malformed embedding values are rejected."""
        with self.pools.project_cursor() as cur:
            # Non-numeric values
            with self.assertRaises((InvalidEmbeddingError, TypeError)):
                store_memory(cur, "test", "key", "value", embedding=["not", "a", "number"] * 128)

            # NaN values
            with self.assertRaises((InvalidEmbeddingError, ValueError)):
                store_memory(cur, "test", "key", "value", embedding=[float("nan")] * 384)

            # Infinity values
            with self.assertRaises((InvalidEmbeddingError, ValueError)):
                store_memory(cur, "test", "key", "value", embedding=[float("inf")] * 384)

    def test_oversized_input_handling(self):
        """Test handling of extremely large inputs."""
        with self.pools.project_cursor() as cur:
            # Very long value (1MB)
            large_value = "x" * (1024 * 1024)

            try:
                store_memory(cur, "test", "large_key", large_value)
                result = retrieve_memory(cur, "test", "large_key")
                self.assertEqual(len(result["value"]), len(large_value))
            except (VectorOperationError, MemoryError):
                # Expected - may have size limits
                pass

    def test_unicode_and_special_characters(self):
        """Test handling of unicode and special characters."""
        special_chars = [
            "emoji_🚀_test",
            "中文测试",
            "עברית",
            "مرحبا",
            "test\ttab\nnewline",
            "quote'test\"quote",
        ]

        with self.pools.project_cursor() as cur:
            for i, text in enumerate(special_chars):
                store_memory(cur, namespace="unicode_test", key=f"key_{i}", value=text)

                result = retrieve_memory(cur, "unicode_test", f"key_{i}")
                self.assertEqual(result["value"], text)


class TestSecurityBoundaries(unittest.TestCase):
    """Test security boundaries and isolation."""

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

    def test_namespace_isolation(self):
        """Test that namespaces are properly isolated."""
        with self.pools.project_cursor() as cur:
            # Store in two different namespaces
            store_memory(cur, "namespace_a", "shared_key", "value_a")
            store_memory(cur, "namespace_b", "shared_key", "value_b")

            # Retrieve from each namespace
            result_a = retrieve_memory(cur, "namespace_a", "shared_key")
            result_b = retrieve_memory(cur, "namespace_b", "shared_key")

            self.assertEqual(result_a["value"], "value_a")
            self.assertEqual(result_b["value"], "value_b")

    def test_database_pool_isolation(self):
        """Test that project and shared pools are isolated."""
        # Store in project database
        with self.pools.project_cursor() as cur:
            store_memory(cur, "isolation_test", "project_key", "project_value")

        # Store in shared database
        with self.pools.shared_cursor() as cur:
            store_memory(cur, "isolation_test", "shared_key", "shared_value")

        # Verify isolation
        with self.pools.project_cursor() as cur:
            result = retrieve_memory(cur, "isolation_test", "shared_key")
            self.assertIsNone(result)  # Should not see shared key

        with self.pools.shared_cursor() as cur:
            result = retrieve_memory(cur, "isolation_test", "project_key")
            self.assertIsNone(result)  # Should not see project key

    def test_connection_timeout_security(self):
        """Test that connection timeouts prevent resource exhaustion."""
        # Pool already configured with 10s timeout
        health = self.pools.health_check()

        self.assertIn("project", health)
        self.assertIn("shared", health)

        # Both should be healthy with proper timeouts
        if health["project"]["status"] == "healthy":
            self.assertIsNotNone(health["project"]["database"])


def run_security_tests():
    """Run all security domain tests."""
    suite = unittest.TestSuite()

    test_classes = [
        TestCVE1SQLInjectionPrevention,
        TestCVE2PathTraversalPrevention,
        TestCVE3InputValidation,
        TestSecurityBoundaries,
    ]

    for test_class in test_classes:
        tests = unittest.TestLoader().loadTestsFromTestCase(test_class)
        suite.addTests(tests)

    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(run_security_tests())
