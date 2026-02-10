#!/usr/bin/env python3
"""Integration tests for DistributedDatabasePool.

Tests connection pooling, query routing, shard awareness, and distributed transactions.
"""

import os
import sys
import unittest
import time
from typing import List

# Add parent directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from src.db.distributed_pool import (
    DistributedDatabasePool,
    DatabaseNode,
    NodeRole,
    QueryType,
    RetryConfig,
    DistributedConnectionError,
    create_pool_from_env
)


class TestDistributedPoolBasic(unittest.TestCase):
    """Test basic distributed pool functionality."""

    @classmethod
    def setUpClass(cls):
        """Set up test database connection."""
        cls.coordinator = DatabaseNode(
            host=os.getenv('COORDINATOR_HOST', 'localhost'),
            port=int(os.getenv('COORDINATOR_PORT', '5432')),
            database=os.getenv('COORDINATOR_DB', 'distributed_postgres_cluster'),
            user=os.getenv('COORDINATOR_USER', 'dpg_cluster'),
            password=os.getenv('COORDINATOR_PASSWORD', 'dpg_cluster_2026'),
            role=NodeRole.COORDINATOR
        )

    def setUp(self):
        """Create fresh pool for each test."""
        self.pool = DistributedDatabasePool(coordinator_node=self.coordinator)

    def tearDown(self):
        """Close pool after each test."""
        if self.pool:
            self.pool.close()

    def test_pool_initialization(self):
        """Test that pool initializes correctly."""
        self.assertIsNotNone(self.pool._coordinator_pool)
        self.assertEqual(len(self.pool._worker_pools), 0)
        self.assertEqual(len(self.pool._replica_pools), 0)

    def test_simple_read_query(self):
        """Test simple read query."""
        with self.pool.cursor(QueryType.READ) as cur:
            cur.execute("SELECT 1 as test")
            result = cur.fetchone()
            self.assertEqual(result['test'], 1)

    def test_simple_write_query(self):
        """Test simple write query."""
        # Create test table
        with self.pool.cursor(QueryType.WRITE) as cur:
            cur.execute("""
                CREATE TABLE IF NOT EXISTS test_distributed_writes (
                    id SERIAL PRIMARY KEY,
                    value TEXT,
                    created_at TIMESTAMP DEFAULT NOW()
                )
            """)

        # Insert data
        test_value = f"test_{int(time.time())}"
        with self.pool.cursor(QueryType.WRITE) as cur:
            cur.execute(
                "INSERT INTO test_distributed_writes (value) VALUES (%s) RETURNING id",
                (test_value,)
            )
            result = cur.fetchone()
            self.assertIsNotNone(result['id'])

        # Verify data
        with self.pool.cursor(QueryType.READ) as cur:
            cur.execute(
                "SELECT * FROM test_distributed_writes WHERE value = %s",
                (test_value,)
            )
            result = cur.fetchone()
            self.assertEqual(result['value'], test_value)

    def test_transaction_commit(self):
        """Test transaction commit."""
        with self.pool.cursor(QueryType.WRITE) as cur:
            cur.execute("""
                CREATE TABLE IF NOT EXISTS test_transactions (
                    id SERIAL PRIMARY KEY,
                    value TEXT
                )
            """)

        test_value = f"commit_test_{int(time.time())}"

        with self.pool.cursor(QueryType.WRITE) as cur:
            cur.execute(
                "INSERT INTO test_transactions (value) VALUES (%s)",
                (test_value,)
            )

        # Verify committed
        with self.pool.cursor(QueryType.READ) as cur:
            cur.execute(
                "SELECT COUNT(*) as count FROM test_transactions WHERE value = %s",
                (test_value,)
            )
            result = cur.fetchone()
            self.assertEqual(result['count'], 1)

    def test_transaction_rollback(self):
        """Test transaction rollback on error."""
        with self.pool.cursor(QueryType.WRITE) as cur:
            cur.execute("""
                CREATE TABLE IF NOT EXISTS test_rollback (
                    id SERIAL PRIMARY KEY,
                    value TEXT UNIQUE
                )
            """)

        test_value = f"rollback_test_{int(time.time())}"

        # First insert
        with self.pool.cursor(QueryType.WRITE) as cur:
            cur.execute(
                "INSERT INTO test_rollback (value) VALUES (%s)",
                (test_value,)
            )

        # Second insert (should fail due to unique constraint)
        with self.assertRaises(Exception):
            with self.pool.cursor(QueryType.WRITE) as cur:
                cur.execute(
                    "INSERT INTO test_rollback (value) VALUES (%s)",
                    (test_value,)
                )

        # Should still have only one row
        with self.pool.cursor(QueryType.READ) as cur:
            cur.execute(
                "SELECT COUNT(*) as count FROM test_rollback WHERE value = %s",
                (test_value,)
            )
            result = cur.fetchone()
            self.assertEqual(result['count'], 1)

    def test_statistics_tracking(self):
        """Test query statistics tracking."""
        initial_stats = self.pool.get_statistics()

        # Perform some queries
        with self.pool.cursor(QueryType.READ) as cur:
            cur.execute("SELECT 1")

        with self.pool.cursor(QueryType.WRITE) as cur:
            cur.execute("SELECT 2")

        final_stats = self.pool.get_statistics()

        self.assertGreater(final_stats['total'], initial_stats['total'])
        self.assertGreater(final_stats['reads'], initial_stats['reads'])

    def test_health_check(self):
        """Test health check functionality."""
        health = self.pool.health_check()

        self.assertIn('coordinator', health)
        self.assertIn('workers', health)
        self.assertIn('replicas', health)
        self.assertIn('statistics', health)

        self.assertTrue(health['coordinator']['healthy'])
        self.assertEqual(health['coordinator']['host'], self.coordinator.host)


class TestDistributedPoolReplicas(unittest.TestCase):
    """Test distributed pool with read replicas."""

    @classmethod
    def setUpClass(cls):
        """Set up test database connections."""
        cls.coordinator = DatabaseNode(
            host=os.getenv('COORDINATOR_HOST', 'localhost'),
            port=int(os.getenv('COORDINATOR_PORT', '5432')),
            database=os.getenv('COORDINATOR_DB', 'distributed_postgres_cluster'),
            user=os.getenv('COORDINATOR_USER', 'dpg_cluster'),
            password=os.getenv('COORDINATOR_PASSWORD', 'dpg_cluster_2026'),
            role=NodeRole.COORDINATOR
        )

        # For testing, use same database as replica
        # In production, this would be a separate server
        cls.replica = DatabaseNode(
            host=os.getenv('COORDINATOR_HOST', 'localhost'),
            port=int(os.getenv('COORDINATOR_PORT', '5432')),
            database=os.getenv('COORDINATOR_DB', 'distributed_postgres_cluster'),
            user=os.getenv('COORDINATOR_USER', 'dpg_cluster'),
            password=os.getenv('COORDINATOR_PASSWORD', 'dpg_cluster_2026'),
            role=NodeRole.REPLICA
        )

    def setUp(self):
        """Create pool with replica."""
        self.pool = DistributedDatabasePool(
            coordinator_node=self.coordinator,
            replica_nodes=[self.replica]
        )

    def tearDown(self):
        """Close pool."""
        if self.pool:
            self.pool.close()

    def test_replica_initialization(self):
        """Test that replicas are initialized."""
        self.assertEqual(len(self.pool._replica_pools), 1)

    def test_read_routing_to_replica(self):
        """Test that reads are routed to replicas."""
        initial_reads = self.pool.get_statistics()['reads']

        # Perform read query
        with self.pool.cursor(QueryType.READ) as cur:
            cur.execute("SELECT 1")

        final_reads = self.pool.get_statistics()['reads']
        self.assertEqual(final_reads, initial_reads + 1)

    def test_write_routing_to_coordinator(self):
        """Test that writes go to coordinator, not replicas."""
        initial_writes = self.pool.get_statistics()['writes']

        # Create test table
        with self.pool.cursor(QueryType.WRITE) as cur:
            cur.execute("""
                CREATE TABLE IF NOT EXISTS test_replica_writes (
                    id SERIAL PRIMARY KEY,
                    value TEXT
                )
            """)

        final_writes = self.pool.get_statistics()['writes']
        self.assertGreater(final_writes, initial_writes)


class TestDistributedPoolSharding(unittest.TestCase):
    """Test distributed pool with sharding."""

    @classmethod
    def setUpClass(cls):
        """Set up test database connections."""
        cls.coordinator = DatabaseNode(
            host=os.getenv('COORDINATOR_HOST', 'localhost'),
            port=int(os.getenv('COORDINATOR_PORT', '5432')),
            database=os.getenv('COORDINATOR_DB', 'distributed_postgres_cluster'),
            user=os.getenv('COORDINATOR_USER', 'dpg_cluster'),
            password=os.getenv('COORDINATOR_PASSWORD', 'dpg_cluster_2026'),
            role=NodeRole.COORDINATOR
        )

        # For testing, use same database as workers
        # In production, these would be separate servers
        cls.worker_0 = DatabaseNode(
            host=os.getenv('COORDINATOR_HOST', 'localhost'),
            port=int(os.getenv('COORDINATOR_PORT', '5432')),
            database=os.getenv('COORDINATOR_DB', 'distributed_postgres_cluster'),
            user=os.getenv('COORDINATOR_USER', 'dpg_cluster'),
            password=os.getenv('COORDINATOR_PASSWORD', 'dpg_cluster_2026'),
            role=NodeRole.WORKER,
            shard_id=0
        )

        cls.worker_1 = DatabaseNode(
            host=os.getenv('COORDINATOR_HOST', 'localhost'),
            port=int(os.getenv('COORDINATOR_PORT', '5432')),
            database=os.getenv('COORDINATOR_DB', 'distributed_postgres_cluster'),
            user=os.getenv('COORDINATOR_USER', 'dpg_cluster'),
            password=os.getenv('COORDINATOR_PASSWORD', 'dpg_cluster_2026'),
            role=NodeRole.WORKER,
            shard_id=1
        )

    def setUp(self):
        """Create pool with workers."""
        self.pool = DistributedDatabasePool(
            coordinator_node=self.coordinator,
            worker_nodes=[self.worker_0, self.worker_1]
        )

    def tearDown(self):
        """Close pool."""
        if self.pool:
            self.pool.close()

    def test_worker_initialization(self):
        """Test that workers are initialized."""
        self.assertEqual(len(self.pool._worker_pools), 2)
        self.assertIn(0, self.pool._worker_pools)
        self.assertIn(1, self.pool._worker_pools)

    def test_shard_key_routing(self):
        """Test that queries are routed based on shard key."""
        # Create test table
        with self.pool.cursor(QueryType.DDL) as cur:
            cur.execute("""
                CREATE TABLE IF NOT EXISTS test_sharded_data (
                    user_id BIGINT PRIMARY KEY,
                    data TEXT
                )
            """)

        # Insert with different shard keys
        test_users = [1001, 1002, 1003]

        for user_id in test_users:
            shard_id = self.pool._get_shard_for_key(user_id)
            self.assertIn(shard_id, [0, 1])  # Should map to one of our shards

            with self.pool.cursor(QueryType.WRITE, shard_key=user_id) as cur:
                cur.execute(
                    "INSERT INTO test_sharded_data (user_id, data) VALUES (%s, %s) "
                    "ON CONFLICT (user_id) DO UPDATE SET data = EXCLUDED.data",
                    (user_id, f"data_{user_id}")
                )

        # Verify data
        for user_id in test_users:
            with self.pool.cursor(QueryType.READ, shard_key=user_id) as cur:
                cur.execute(
                    "SELECT * FROM test_sharded_data WHERE user_id = %s",
                    (user_id,)
                )
                result = cur.fetchone()
                self.assertEqual(result['user_id'], user_id)

    def test_consistent_hashing(self):
        """Test that same key always maps to same shard."""
        test_key = "consistent_key_123"

        shard_ids = set()
        for _ in range(10):
            shard_id = self.pool._get_shard_for_key(test_key)
            shard_ids.add(shard_id)

        # Should always map to same shard
        self.assertEqual(len(shard_ids), 1)


class TestDistributedPoolRetry(unittest.TestCase):
    """Test retry and failover logic."""

    def test_retry_config(self):
        """Test retry configuration."""
        retry_config = RetryConfig(
            max_retries=5,
            initial_backoff=0.05,
            max_backoff=1.0,
            backoff_multiplier=2.0,
            jitter=True
        )

        self.assertEqual(retry_config.max_retries, 5)
        self.assertEqual(retry_config.initial_backoff, 0.05)

    def test_connection_failure_retry(self):
        """Test that connection failures trigger retry."""
        # Create pool with invalid credentials
        bad_node = DatabaseNode(
            host='localhost',
            port=9999,  # Invalid port
            database='nonexistent',
            user='invalid',
            password='invalid',
            role=NodeRole.COORDINATOR
        )

        retry_config = RetryConfig(max_retries=2, initial_backoff=0.01)

        # Should fail after retries
        with self.assertRaises(DistributedConnectionError):
            pool = DistributedDatabasePool(
                coordinator_node=bad_node,
                retry_config=retry_config
            )


class TestDistributedPoolEnvironment(unittest.TestCase):
    """Test environment-based configuration."""

    def test_create_from_env(self):
        """Test creating pool from environment variables."""
        # This will use environment variables from .env
        try:
            pool = create_pool_from_env()
            self.assertIsNotNone(pool)

            # Test connection
            with pool.cursor(QueryType.READ) as cur:
                cur.execute("SELECT 1")

            pool.close()

        except Exception as e:
            self.skipTest(f"Environment not configured: {e}")


class TestDistributedPoolConcurrency(unittest.TestCase):
    """Test concurrent access to pool."""

    @classmethod
    def setUpClass(cls):
        """Set up test database connection."""
        cls.coordinator = DatabaseNode(
            host=os.getenv('COORDINATOR_HOST', 'localhost'),
            port=int(os.getenv('COORDINATOR_PORT', '5432')),
            database=os.getenv('COORDINATOR_DB', 'distributed_postgres_cluster'),
            user=os.getenv('COORDINATOR_USER', 'dpg_cluster'),
            password=os.getenv('COORDINATOR_PASSWORD', 'dpg_cluster_2026'),
            role=NodeRole.COORDINATOR
        )

    def setUp(self):
        """Create pool."""
        self.pool = DistributedDatabasePool(coordinator_node=self.coordinator)

    def tearDown(self):
        """Close pool."""
        if self.pool:
            self.pool.close()

    def test_concurrent_queries(self):
        """Test multiple concurrent queries."""
        import threading

        results = []
        errors = []

        def run_query(query_id):
            try:
                with self.pool.cursor(QueryType.READ) as cur:
                    cur.execute("SELECT %s as id, pg_sleep(0.01)", (query_id,))
                    result = cur.fetchone()
                    results.append(result['id'])
            except Exception as e:
                errors.append(e)

        # Run 10 concurrent queries
        threads = []
        for i in range(10):
            thread = threading.Thread(target=run_query, args=(i,))
            threads.append(thread)
            thread.start()

        # Wait for all threads
        for thread in threads:
            thread.join()

        # Check results
        self.assertEqual(len(errors), 0, f"Errors occurred: {errors}")
        self.assertEqual(len(results), 10)
        self.assertEqual(sorted(results), list(range(10)))


def run_tests():
    """Run all tests."""
    # Create test suite
    suite = unittest.TestSuite()

    # Add test classes
    test_classes = [
        TestDistributedPoolBasic,
        TestDistributedPoolReplicas,
        TestDistributedPoolSharding,
        TestDistributedPoolRetry,
        TestDistributedPoolEnvironment,
        TestDistributedPoolConcurrency,
    ]

    for test_class in test_classes:
        tests = unittest.TestLoader().loadTestsFromTestCase(test_class)
        suite.addTests(tests)

    # Run tests
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    # Return exit code
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(run_tests())
