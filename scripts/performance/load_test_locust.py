#!/usr/bin/env python3
"""Locust Load Testing for Vector Search

Run with:
    locust -f load_test_locust.py --host http://localhost:5432 \\
        --users 100 --spawn-rate 10 --run-time 5m

Or run headless:
    locust -f load_test_locust.py --host http://localhost:5432 \\
        --users 100 --spawn-rate 10 --run-time 5m \\
        --headless --html reports/load_test_results.html
"""
# Standard library imports
import asyncio
import os
import sys
import time
from pathlib import Path

# Third-party imports
import asyncpg
import numpy as np
from locust import User, between, events, task

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent.parent))
# Third-party imports
from dotenv import load_dotenv

# Load environment
load_dotenv(Path(__file__).parent.parent.parent / ".env")

# Global connection pool (shared across all users)
_global_pool = None


async def get_connection_pool():
    """Get or create global connection pool."""
    global _global_pool

    if _global_pool is None:
        conn_string = (
            f"postgresql://{os.getenv('RUVECTOR_USER')}:"
            f"{os.getenv('RUVECTOR_PASSWORD')}@"
            f"{os.getenv('RUVECTOR_HOST', 'localhost')}:"
            f"{os.getenv('RUVECTOR_PORT', '5432')}/"
            f"{os.getenv('RUVECTOR_DB')}"
        )

        _global_pool = await asyncpg.create_pool(
            conn_string, min_size=10, max_size=100, command_timeout=30
        )

    return _global_pool


class VectorSearchUser(User):
    """Simulates a user performing vector search operations."""

    # Wait 0.1-0.5 seconds between tasks
    wait_time = between(0.1, 0.5)

    def on_start(self):
        """Initialize for each user."""
        # Create event loop for this user
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)

        # Get shared connection pool
        self.pool = self.loop.run_until_complete(get_connection_pool())

        # User-specific namespace (simulates tenant isolation)
        self.namespace = f"user-namespace-{self.environment.runner.user_count % 20}"

    def on_stop(self):
        """Cleanup for each user."""
        # Don't close pool (it's shared)
        self.loop.close()

    @task(weight=10)
    def vector_search_single_shard(self):
        """
        Most common operation: Vector search in single namespace.

        Weight: 10 (executed 10x more often than other tasks)
        """
        start_time = time.time()
        query_type = "vector_search_single_shard"

        try:
            # Generate random query embedding
            query_embedding = np.random.randn(384).tolist()

            # Execute search
            result_count = self.loop.run_until_complete(
                self._execute_vector_search(query_embedding, self.namespace, limit=10)
            )

            # Report success to Locust
            total_time = int((time.time() - start_time) * 1000)  # ms
            events.request.fire(
                request_type="postgresql",
                name=query_type,
                response_time=total_time,
                response_length=result_count,
                exception=None,
                context={},
            )

        except Exception as e:
            total_time = int((time.time() - start_time) * 1000)
            events.request.fire(
                request_type="postgresql",
                name=query_type,
                response_time=total_time,
                response_length=0,
                exception=e,
                context={},
            )

    @task(weight=3)
    def vector_search_cross_shard(self):
        """
        Less common: Vector search across multiple namespaces.

        Weight: 3 (executed 3x as often as inserts)
        """
        start_time = time.time()
        query_type = "vector_search_cross_shard"

        try:
            query_embedding = np.random.randn(384).tolist()

            # Search across 5 namespaces (different shards)
            namespaces = [f"user-namespace-{i}" for i in range(5)]

            result_count = self.loop.run_until_complete(
                self._execute_cross_shard_search(query_embedding, namespaces, limit=20)
            )

            total_time = int((time.time() - start_time) * 1000)
            events.request.fire(
                request_type="postgresql",
                name=query_type,
                response_time=total_time,
                response_length=result_count,
                exception=None,
                context={},
            )

        except Exception as e:
            total_time = int((time.time() - start_time) * 1000)
            events.request.fire(
                request_type="postgresql",
                name=query_type,
                response_time=total_time,
                response_length=0,
                exception=e,
                context={},
            )

    @task(weight=1)
    def insert_memory(self):
        """
        Occasional write operation: Insert a new memory entry.

        Weight: 1 (executed least often)
        """
        start_time = time.time()
        query_type = "insert_memory"

        try:
            # Generate random data
            embedding = np.random.randn(384).tolist()
            key = f"load-test-{int(time.time() * 1000000)}"
            value = f"Load test entry created at {time.time()}"

            # Execute insert
            self.loop.run_until_complete(
                self._execute_insert(self.namespace, key, value, embedding)
            )

            total_time = int((time.time() - start_time) * 1000)
            events.request.fire(
                request_type="postgresql",
                name=query_type,
                response_time=total_time,
                response_length=1,
                exception=None,
                context={},
            )

        except Exception as e:
            total_time = int((time.time() - start_time) * 1000)
            events.request.fire(
                request_type="postgresql",
                name=query_type,
                response_time=total_time,
                response_length=0,
                exception=e,
                context={},
            )

    @task(weight=2)
    def retrieve_memory(self):
        """
        Common operation: Retrieve memory by key.

        Weight: 2
        """
        start_time = time.time()
        query_type = "retrieve_memory"

        try:
            # Retrieve a random key (most will not exist, simulating cache misses)
            key = f"load-test-{np.random.randint(0, 1000000)}"

            found = self.loop.run_until_complete(self._execute_retrieve(self.namespace, key))

            total_time = int((time.time() - start_time) * 1000)
            events.request.fire(
                request_type="postgresql",
                name=query_type,
                response_time=total_time,
                response_length=1 if found else 0,
                exception=None,
                context={},
            )

        except Exception as e:
            total_time = int((time.time() - start_time) * 1000)
            events.request.fire(
                request_type="postgresql",
                name=query_type,
                response_time=total_time,
                response_length=0,
                exception=e,
                context={},
            )

    # Helper methods for database operations

    async def _execute_vector_search(self, embedding, namespace, limit=10):
        """Execute vector search query."""
        async with self.pool.acquire() as conn:
            embedding_str = f"[{','.join(str(v) for v in embedding)}]"

            rows = await conn.fetch(
                """
                SELECT namespace, key, value, metadata,
                       1 - (embedding <=> $1::ruvector) as similarity
                FROM memory_entries
                WHERE namespace = $2
                  AND embedding IS NOT NULL
                  AND (1 - (embedding <=> $1::ruvector)) >= 0.7
                ORDER BY embedding <=> $1::ruvector
                LIMIT $3
            """,
                embedding_str,
                namespace,
                limit,
            )

            return len(rows)

    async def _execute_cross_shard_search(self, embedding, namespaces, limit=20):
        """Execute cross-shard vector search."""
        async with self.pool.acquire() as conn:
            embedding_str = f"[{','.join(str(v) for v in embedding)}]"

            rows = await conn.fetch(
                """
                SELECT namespace, key, value, metadata,
                       1 - (embedding <=> $1::ruvector) as similarity
                FROM memory_entries
                WHERE namespace = ANY($2)
                  AND embedding IS NOT NULL
                ORDER BY embedding <=> $1::ruvector
                LIMIT $3
            """,
                embedding_str,
                namespaces,
                limit,
            )

            return len(rows)

    async def _execute_insert(self, namespace, key, value, embedding):
        """Execute insert operation."""
        async with self.pool.acquire() as conn:
            embedding_str = f"[{','.join(str(v) for v in embedding)}]"

            await conn.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES ($1, $2, $3, $4::ruvector)
                ON CONFLICT (namespace, key) DO UPDATE
                SET value = EXCLUDED.value,
                    embedding = EXCLUDED.embedding,
                    updated_at = NOW()
            """,
                namespace,
                key,
                value,
                embedding_str,
            )

    async def _execute_retrieve(self, namespace, key):
        """Execute retrieve operation."""
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow(
                """
                SELECT namespace, key, value, metadata
                FROM memory_entries
                WHERE namespace = $1 AND key = $2
            """,
                namespace,
                key,
            )

            return row is not None


class BulkInsertUser(User):
    """Simulates bulk insert operations (less common)."""

    wait_time = between(5, 10)  # Longer wait between bulk operations

    def on_start(self):
        """Initialize."""
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self.pool = self.loop.run_until_complete(get_connection_pool())
        self.namespace = f"bulk-namespace-{self.environment.runner.user_count % 5}"

    def on_stop(self):
        """Cleanup."""
        self.loop.close()

    @task
    def bulk_insert(self):
        """Insert a batch of entries."""
        start_time = time.time()
        query_type = "bulk_insert"
        batch_size = 50

        try:
            # Generate batch
            batch = []
            for i in range(batch_size):
                embedding = np.random.randn(384).tolist()
                batch.append(
                    {
                        "key": f"bulk-{int(time.time() * 1000000)}-{i}",
                        "value": f"Bulk entry {i}",
                        "embedding": embedding,
                    }
                )

            # Execute batch insert
            self.loop.run_until_complete(self._execute_batch_insert(self.namespace, batch))

            total_time = int((time.time() - start_time) * 1000)
            events.request.fire(
                request_type="postgresql",
                name=query_type,
                response_time=total_time,
                response_length=batch_size,
                exception=None,
                context={},
            )

        except Exception as e:
            total_time = int((time.time() - start_time) * 1000)
            events.request.fire(
                request_type="postgresql",
                name=query_type,
                response_time=total_time,
                response_length=0,
                exception=e,
                context={},
            )

    async def _execute_batch_insert(self, namespace, batch):
        """Execute batch insert in transaction."""
        async with self.pool.acquire() as conn:
            async with conn.transaction():
                for item in batch:
                    embedding_str = f"[{','.join(str(v) for v in item['embedding'])}]"
                    await conn.execute(
                        """
                        INSERT INTO memory_entries (namespace, key, value, embedding)
                        VALUES ($1, $2, $3, $4::ruvector)
                        ON CONFLICT (namespace, key) DO UPDATE
                        SET value = EXCLUDED.value,
                            embedding = EXCLUDED.embedding
                    """,
                        namespace,
                        item["key"],
                        item["value"],
                        embedding_str,
                    )


@events.test_start.add_listener
def on_test_start(environment, **kwargs):
    """Called when test starts."""
    print("\n" + "=" * 60)
    print("🚀 Load Test Starting")
    print("=" * 60)
    print(f"Target host: {environment.host}")
    print(f"Users: {environment.runner.target_user_count}")
    print(f"Spawn rate: {environment.runner.spawn_rate}")
    print("=" * 60 + "\n")


@events.test_stop.add_listener
def on_test_stop(environment, **kwargs):
    """Called when test stops."""
    print("\n" + "=" * 60)
    print("🏁 Load Test Completed")
    print("=" * 60)

    # Print summary statistics
    stats = environment.runner.stats

    print(f"\nTotal requests: {stats.total.num_requests}")
    print(f"Total failures: {stats.total.num_failures}")
    print(f"Success rate: {(1 - stats.total.fail_ratio) * 100:.2f}%")
    print(f"RPS: {stats.total.total_rps:.2f}")

    print(f"\nResponse times (ms):")
    print(f"  Median: {stats.total.median_response_time}")
    print(f"  95th percentile: {stats.total.get_response_time_percentile(0.95)}")
    print(f"  99th percentile: {stats.total.get_response_time_percentile(0.99)}")

    print("\n" + "=" * 60 + "\n")

    # Close global pool
    global _global_pool
    if _global_pool:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(_global_pool.close())
        loop.close()
