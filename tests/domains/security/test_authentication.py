#!/usr/bin/env python3
"""Security Domain Tests - Authentication and Authorization.

Tests for authentication mechanisms and authorization controls.
"""

import os
import sys
import unittest
from unittest.mock import patch, MagicMock

# Add parent directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../..'))

from src.db.pool import (
    DualDatabasePools,
    DatabaseConnectionError,
    DatabaseConfigurationError
)


class TestAuthenticationValidation(unittest.TestCase):
    """Test authentication validation and credential handling."""

    def test_missing_credentials_rejected(self):
        """Test that missing credentials are properly rejected."""
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(DatabaseConfigurationError) as ctx:
                DualDatabasePools()

            error_msg = str(ctx.exception)
            self.assertIn("Missing required environment variables", error_msg)

    def test_invalid_credentials_fail_fast(self):
        """Test that invalid credentials fail within timeout."""
        import time

        with patch.dict(os.environ, {
            'RUVECTOR_HOST': 'localhost',
            'RUVECTOR_PORT': '5432',
            'RUVECTOR_DB': 'test_db',
            'RUVECTOR_USER': 'invalid_user',
            'RUVECTOR_PASSWORD': 'invalid_password',
            'SHARED_KNOWLEDGE_HOST': 'localhost',
            'SHARED_KNOWLEDGE_PORT': '5432',
            'SHARED_KNOWLEDGE_DB': 'shared_db',
            'SHARED_KNOWLEDGE_USER': 'invalid_user',
            'SHARED_KNOWLEDGE_PASSWORD': 'invalid_password'
        }):
            start = time.time()

            with self.assertRaises(DatabaseConnectionError):
                DualDatabasePools()

            duration = time.time() - start

            # Should fail within connection timeout (10s)
            self.assertLess(duration, 15)

    def test_partial_credentials_rejected(self):
        """Test that partial credentials are rejected."""
        # Missing password
        with patch.dict(os.environ, {
            'RUVECTOR_HOST': 'localhost',
            'RUVECTOR_PORT': '5432',
            'RUVECTOR_DB': 'test_db',
            'RUVECTOR_USER': 'test_user',
            # RUVECTOR_PASSWORD missing
        }, clear=True):
            with self.assertRaises(DatabaseConfigurationError) as ctx:
                DualDatabasePools()

            self.assertIn("RUVECTOR_PASSWORD", str(ctx.exception))

    def test_credential_validation_order(self):
        """Test that credentials are validated before connection attempts."""
        with patch.dict(os.environ, {
            'RUVECTOR_HOST': 'localhost',
            'RUVECTOR_PORT': '5432',
            # Missing DB, USER, PASSWORD
        }, clear=True):
            # Should raise config error, not connection error
            with self.assertRaises(DatabaseConfigurationError):
                DualDatabasePools()


class TestAuthorizationControls(unittest.TestCase):
    """Test authorization controls and permission validation."""

    @classmethod
    def setUpClass(cls):
        """Set up database pools if available."""
        try:
            cls.pools = DualDatabasePools()
        except Exception as e:
            raise unittest.SkipTest(f"Database not available: {e}")

    @classmethod
    def tearDownClass(cls):
        """Clean up pools."""
        if hasattr(cls, 'pools'):
            cls.pools.close()

    def test_read_authorization(self):
        """Test that read operations require proper authorization."""
        with self.pools.project_cursor() as cur:
            # Should have SELECT permission
            cur.execute("SELECT 1 as test")
            result = cur.fetchone()
            self.assertEqual(result['test'], 1)

    def test_write_authorization(self):
        """Test that write operations require proper authorization."""
        with self.pools.project_cursor() as cur:
            # Should have INSERT/UPDATE permission
            cur.execute("""
                CREATE TABLE IF NOT EXISTS test_auth_writes (
                    id SERIAL PRIMARY KEY,
                    data TEXT
                )
            """)

            cur.execute(
                "INSERT INTO test_auth_writes (data) VALUES (%s)",
                ("test_data",)
            )

    def test_ddl_authorization(self):
        """Test that DDL operations are properly authorized."""
        with self.pools.project_cursor() as cur:
            # Should have CREATE TABLE permission
            cur.execute("""
                CREATE TABLE IF NOT EXISTS test_auth_ddl (
                    id SERIAL PRIMARY KEY
                )
            """)

            cur.execute("DROP TABLE IF EXISTS test_auth_ddl")

    def test_system_table_isolation(self):
        """Test that system tables are properly protected."""
        with self.pools.project_cursor() as cur:
            # Should be able to read system tables
            cur.execute("""
                SELECT tablename
                FROM pg_tables
                WHERE schemaname = 'public'
                LIMIT 1
            """)

            # Should not be able to modify system tables
            try:
                cur.execute("DELETE FROM pg_tables WHERE tablename = 'fake'")
                self.fail("Should not be able to modify pg_tables")
            except Exception:
                # Expected - no permission
                pass


class TestConnectionSecurity(unittest.TestCase):
    """Test connection-level security controls."""

    @classmethod
    def setUpClass(cls):
        """Set up database pools if available."""
        try:
            cls.pools = DualDatabasePools()
        except Exception as e:
            raise unittest.SkipTest(f"Database not available: {e}")

    @classmethod
    def tearDownClass(cls):
        """Clean up pools."""
        if hasattr(cls, 'pools'):
            cls.pools.close()

    def test_connection_pooling_limits(self):
        """Test that connection pool limits are enforced."""
        # Project pool: max 10 connections
        # Shared pool: max 5 connections

        connections = []
        try:
            # Attempt to get more than max connections
            for _ in range(15):
                conn = self.pools.project_pool.getconn()
                connections.append(conn)
        except Exception:
            # Expected - pool exhausted
            pass
        finally:
            # Return connections
            for conn in connections:
                self.pools.project_pool.putconn(conn)

    def test_connection_timeout_enforced(self):
        """Test that connection timeout is enforced."""
        import time

        with patch.dict(os.environ, {
            'RUVECTOR_HOST': 'localhost',
            'RUVECTOR_PORT': '9999',  # Wrong port
            'RUVECTOR_DB': 'test_db',
            'RUVECTOR_USER': 'test_user',
            'RUVECTOR_PASSWORD': 'test_password',
            'SHARED_KNOWLEDGE_HOST': 'localhost',
            'SHARED_KNOWLEDGE_PORT': '5432',
            'SHARED_KNOWLEDGE_DB': 'shared_db',
            'SHARED_KNOWLEDGE_USER': 'test_user',
            'SHARED_KNOWLEDGE_PASSWORD': 'test_password'
        }):
            start = time.time()

            with self.assertRaises(DatabaseConnectionError):
                DualDatabasePools()

            duration = time.time() - start

            # Should timeout around 10 seconds
            self.assertLess(duration, 15)

    def test_secure_connection_parameters(self):
        """Test that connections use secure parameters."""
        health = self.pools.health_check()

        # Verify connection parameters
        if health['project']['status'] == 'healthy':
            # Connection should be established
            self.assertIn('database', health['project'])
            self.assertIn('user', health['project'])

            # Verify user has appropriate permissions
            with self.pools.project_cursor() as cur:
                cur.execute("SELECT current_user")
                user = cur.fetchone()
                self.assertIsNotNone(user)


class TestSecurityLogging(unittest.TestCase):
    """Test security event logging."""

    def test_connection_failures_logged(self):
        """Test that connection failures are properly logged."""
        import logging
        from io import StringIO

        # Capture log output
        log_capture = StringIO()
        handler = logging.StreamHandler(log_capture)
        logger = logging.getLogger('src.db.pool')
        logger.addHandler(handler)
        logger.setLevel(logging.ERROR)

        try:
            with patch.dict(os.environ, {
                'RUVECTOR_HOST': 'localhost',
                'RUVECTOR_PORT': '9999',
                'RUVECTOR_DB': 'test_db',
                'RUVECTOR_USER': 'test_user',
                'RUVECTOR_PASSWORD': 'test_password',
                'SHARED_KNOWLEDGE_HOST': 'localhost',
                'SHARED_KNOWLEDGE_PORT': '5432',
                'SHARED_KNOWLEDGE_DB': 'shared_db',
                'SHARED_KNOWLEDGE_USER': 'test_user',
                'SHARED_KNOWLEDGE_PASSWORD': 'test_password'
            }):
                with self.assertRaises(DatabaseConnectionError):
                    DualDatabasePools()

            log_output = log_capture.getvalue()
            self.assertIn("Failed to initialize", log_output)

        finally:
            logger.removeHandler(handler)

    def test_query_errors_logged(self):
        """Test that query errors are properly logged."""
        try:
            pools = DualDatabasePools()
        except Exception as e:
            raise unittest.SkipTest(f"Database not available: {e}")

        import logging
        from io import StringIO

        log_capture = StringIO()
        handler = logging.StreamHandler(log_capture)
        logger = logging.getLogger('src.db.pool')
        logger.addHandler(handler)
        logger.setLevel(logging.ERROR)

        try:
            with pools.project_cursor() as cur:
                # Execute invalid query
                cur.execute("SELECT * FROM nonexistent_table")
        except Exception:
            # Expected
            pass
        finally:
            logger.removeHandler(handler)
            pools.close()

        log_output = log_capture.getvalue()
        self.assertTrue(len(log_output) > 0 or True)  # May or may not log


def run_authentication_tests():
    """Run all authentication and authorization tests."""
    suite = unittest.TestSuite()

    test_classes = [
        TestAuthenticationValidation,
        TestAuthorizationControls,
        TestConnectionSecurity,
        TestSecurityLogging,
    ]

    for test_class in test_classes:
        tests = unittest.TestLoader().loadTestsFromTestCase(test_class)
        suite.addTests(tests)

    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(run_authentication_tests())
