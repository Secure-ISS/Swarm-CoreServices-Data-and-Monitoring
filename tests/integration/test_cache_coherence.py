"""Integration tests for Redis caching layer.

Tests cache functionality:
- Cache hit/miss behavior
- Cache invalidation
- Cache coherence with database
- TTL and expiration
- Cache warming strategies
- Cache performance
"""

# Standard library imports
import json
import time
from typing import Dict, List

# Third-party imports
import psycopg2
import pytest
import redis


@pytest.mark.redis
class TestRedisCacheSetup:
    """Test Redis cache configuration and connectivity."""

    def test_redis_connection(self, redis_connection: redis.Redis):
        """Test Redis connection is established."""
        assert redis_connection.ping()

    def test_redis_info(self, redis_connection: redis.Redis):
        """Test Redis server information."""
        info = redis_connection.info()
        assert "redis_version" in info
        assert info["redis_mode"] == "standalone" or info["redis_mode"] == "cluster"

    def test_redis_memory_policy(self, redis_connection: redis.Redis):
        """Test Redis eviction policy is configured."""
        config = redis_connection.config_get("maxmemory-policy")
        # Should be LRU or similar for cache
        assert (
            "lru" in config.get("maxmemory-policy", "").lower()
            or "lfu" in config.get("maxmemory-policy", "").lower()
        )


@pytest.mark.redis
class TestCacheOperations:
    """Test basic cache operations."""

    def test_cache_set_and_get(self, redis_connection: redis.Redis):
        """Test setting and getting cache values."""
        key = "test:simple"
        value = "test_value"

        # Set value
        redis_connection.set(key, value)

        # Get value
        retrieved = redis_connection.get(key)
        assert retrieved == value

    def test_cache_with_ttl(self, redis_connection: redis.Redis):
        """Test cache expiration with TTL."""
        key = "test:ttl"
        value = "expires_soon"
        ttl_seconds = 2

        # Set with TTL
        redis_connection.setex(key, ttl_seconds, value)

        # Value should exist
        assert redis_connection.get(key) == value

        # Wait for expiration
        time.sleep(ttl_seconds + 0.5)

        # Value should be expired
        assert redis_connection.get(key) is None

    def test_cache_delete(self, redis_connection: redis.Redis):
        """Test cache key deletion."""
        key = "test:delete"
        value = "to_be_deleted"

        redis_connection.set(key, value)
        assert redis_connection.get(key) == value

        # Delete key
        redis_connection.delete(key)
        assert redis_connection.get(key) is None

    def test_cache_multiple_keys(self, redis_connection: redis.Redis):
        """Test caching multiple keys."""
        data = {
            "test:multi:1": "value1",
            "test:multi:2": "value2",
            "test:multi:3": "value3",
        }

        # Set multiple keys
        for key, value in data.items():
            redis_connection.set(key, value)

        # Get multiple keys
        retrieved = redis_connection.mget(list(data.keys()))
        assert retrieved == list(data.values())


@pytest.mark.redis
class TestCacheWithDatabase:
    """Test cache coherence with database."""

    def test_cache_database_sync(
        self,
        redis_connection: redis.Redis,
        postgres_cursor,
        test_namespace: str,
        sample_vector: List[float],
    ):
        """Test cache stays in sync with database."""
        cache_key = f"test:db_sync:{test_namespace}"

        # Insert into database
        postgres_cursor.execute(
            """
            INSERT INTO memory_entries (namespace, key, value, embedding)
            VALUES (%s, %s, %s, %s::ruvector)
            RETURNING id, value
            """,
            (test_namespace, "sync_key", "sync_value", sample_vector),
        )
        db_result = postgres_cursor.fetchone()

        # Cache the result
        redis_connection.setex(
            cache_key,
            300,  # 5 minutes TTL
            json.dumps({"id": db_result["id"], "value": db_result["value"]}),
        )

        # Verify cache contains correct data
        cached = json.loads(redis_connection.get(cache_key))
        assert cached["value"] == "sync_value"

        # Verify database contains correct data
        postgres_cursor.execute(
            "SELECT value FROM memory_entries WHERE namespace = %s AND key = %s",
            (test_namespace, "sync_key"),
        )
        db_value = postgres_cursor.fetchone()["value"]
        assert db_value == "sync_value"

    def test_cache_invalidation_on_update(
        self,
        redis_connection: redis.Redis,
        postgres_connection,
        test_namespace: str,
        sample_vector: List[float],
    ):
        """Test cache is invalidated when database is updated."""
        cache_key = f"test:invalidate:{test_namespace}"

        with postgres_connection.cursor() as cur:
            # Insert initial data
            cur.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                RETURNING id, value
                """,
                (test_namespace, "inv_key", "original_value", sample_vector),
            )
            result = cur.fetchone()
            postgres_connection.commit()

            # Cache the result
            redis_connection.setex(
                cache_key,
                300,
                json.dumps({"id": result["id"], "value": result["value"]}),
            )

            # Update database
            cur.execute(
                """
                UPDATE memory_entries
                SET value = %s
                WHERE namespace = %s AND key = %s
                """,
                ("updated_value", test_namespace, "inv_key"),
            )
            postgres_connection.commit()

            # Invalidate cache
            redis_connection.delete(cache_key)

            # Cache should be empty
            assert redis_connection.get(cache_key) is None

            # Database should have new value
            cur.execute(
                "SELECT value FROM memory_entries WHERE namespace = %s AND key = %s",
                (test_namespace, "inv_key"),
            )
            db_value = cur.fetchone()["value"]
            assert db_value == "updated_value"

            # Cleanup
            cur.execute("DELETE FROM memory_entries WHERE namespace = %s", (test_namespace,))
            postgres_connection.commit()

    def test_cache_miss_loads_from_database(
        self,
        redis_connection: redis.Redis,
        postgres_cursor,
        test_namespace: str,
        sample_vector: List[float],
    ):
        """Test cache miss triggers database load."""
        cache_key = f"test:cache_miss:{test_namespace}"

        # Ensure cache is empty
        redis_connection.delete(cache_key)

        # Insert data into database
        postgres_cursor.execute(
            """
            INSERT INTO memory_entries (namespace, key, value, embedding)
            VALUES (%s, %s, %s, %s::ruvector)
            RETURNING id, value
            """,
            (test_namespace, "miss_key", "loaded_from_db", sample_vector),
        )
        db_result = postgres_cursor.fetchone()

        # Simulate cache miss - load from database
        cached = redis_connection.get(cache_key)
        if cached is None:
            # Cache miss - load from database
            cached_data = {"id": db_result["id"], "value": db_result["value"]}
            redis_connection.setex(cache_key, 300, json.dumps(cached_data))

        # Verify cache now has data
        cached = json.loads(redis_connection.get(cache_key))
        assert cached["value"] == "loaded_from_db"


@pytest.mark.redis
class TestCachePerformance:
    """Test cache performance characteristics."""

    def test_cache_vs_database_performance(
        self,
        redis_connection: redis.Redis,
        postgres_cursor,
        test_namespace: str,
        sample_vector: List[float],
    ):
        """Test that cache is faster than database."""
        # Insert test data
        postgres_cursor.execute(
            """
            INSERT INTO memory_entries (namespace, key, value, embedding)
            VALUES (%s, %s, %s, %s::ruvector)
            RETURNING id, value
            """,
            (test_namespace, "perf_key", "perf_value", sample_vector),
        )
        db_result = postgres_cursor.fetchone()

        # Cache the data
        cache_key = f"test:perf:{test_namespace}"
        cache_data = json.dumps({"id": db_result["id"], "value": db_result["value"]})
        redis_connection.setex(cache_key, 300, cache_data)

        # Measure database query time (repeated for averaging)
        db_times = []
        for _ in range(10):
            start = time.time()
            postgres_cursor.execute(
                "SELECT value FROM memory_entries WHERE namespace = %s AND key = %s",
                (test_namespace, "perf_key"),
            )
            postgres_cursor.fetchone()
            db_times.append(time.time() - start)

        avg_db_time = sum(db_times) / len(db_times)

        # Measure cache query time (repeated for averaging)
        cache_times = []
        for _ in range(10):
            start = time.time()
            redis_connection.get(cache_key)
            cache_times.append(time.time() - start)

        avg_cache_time = sum(cache_times) / len(cache_times)

        # Cache should be significantly faster
        assert (
            avg_cache_time < avg_db_time
        ), f"Cache ({avg_cache_time*1000:.2f}ms) not faster than DB ({avg_db_time*1000:.2f}ms)"

    @pytest.mark.slow
    def test_cache_throughput(self, redis_connection: redis.Redis):
        """Test cache read/write throughput."""
        num_operations = 1000

        # Write throughput
        start = time.time()
        for i in range(num_operations):
            redis_connection.set(f"test:throughput:{i}", f"value_{i}")
        write_time = time.time() - start
        write_ops_per_sec = num_operations / write_time

        # Read throughput
        start = time.time()
        for i in range(num_operations):
            redis_connection.get(f"test:throughput:{i}")
        read_time = time.time() - start
        read_ops_per_sec = num_operations / read_time

        # Cleanup
        redis_connection.delete(*[f"test:throughput:{i}" for i in range(num_operations)])

        # Should handle at least 1000 ops/sec
        assert (
            write_ops_per_sec > 1000
        ), f"Write throughput too low: {write_ops_per_sec:.0f} ops/sec"
        assert read_ops_per_sec > 1000, f"Read throughput too low: {read_ops_per_sec:.0f} ops/sec"


@pytest.mark.redis
class TestCacheStrategies:
    """Test different caching strategies."""

    def test_write_through_cache(
        self,
        redis_connection: redis.Redis,
        postgres_connection,
        test_namespace: str,
        sample_vector: List[float],
    ):
        """Test write-through caching strategy."""
        cache_key = f"test:write_through:{test_namespace}"

        with postgres_connection.cursor() as cur:
            # Write to database
            cur.execute(
                """
                INSERT INTO memory_entries (namespace, key, value, embedding)
                VALUES (%s, %s, %s, %s::ruvector)
                RETURNING id, value
                """,
                (test_namespace, "wt_key", "wt_value", sample_vector),
            )
            result = cur.fetchone()
            postgres_connection.commit()

            # Write to cache (write-through)
            cache_data = json.dumps({"id": result["id"], "value": result["value"]})
            redis_connection.setex(cache_key, 300, cache_data)

            # Both should have data
            cached = json.loads(redis_connection.get(cache_key))
            assert cached["value"] == "wt_value"

            cur.execute(
                "SELECT value FROM memory_entries WHERE namespace = %s AND key = %s",
                (test_namespace, "wt_key"),
            )
            db_value = cur.fetchone()["value"]
            assert db_value == "wt_value"

            # Cleanup
            cur.execute("DELETE FROM memory_entries WHERE namespace = %s", (test_namespace,))
            postgres_connection.commit()

    def test_cache_aside_pattern(
        self,
        redis_connection: redis.Redis,
        postgres_cursor,
        test_namespace: str,
        sample_vector: List[float],
    ):
        """Test cache-aside (lazy loading) pattern."""
        cache_key = f"test:cache_aside:{test_namespace}"

        # Insert into database
        postgres_cursor.execute(
            """
            INSERT INTO memory_entries (namespace, key, value, embedding)
            VALUES (%s, %s, %s, %s::ruvector)
            RETURNING id, value
            """,
            (test_namespace, "ca_key", "ca_value", sample_vector),
        )

        # First read - cache miss
        cached = redis_connection.get(cache_key)
        assert cached is None

        # Load from database
        postgres_cursor.execute(
            "SELECT id, value FROM memory_entries WHERE namespace = %s AND key = %s",
            (test_namespace, "ca_key"),
        )
        db_result = postgres_cursor.fetchone()

        # Populate cache
        cache_data = json.dumps({"id": db_result["id"], "value": db_result["value"]})
        redis_connection.setex(cache_key, 300, cache_data)

        # Second read - cache hit
        cached = redis_connection.get(cache_key)
        assert cached is not None
        cached_result = json.loads(cached)
        assert cached_result["value"] == "ca_value"


if __name__ == "__main__":
    pytest.main([__file__, "-v", "-m", "redis", "--tb=short"])
