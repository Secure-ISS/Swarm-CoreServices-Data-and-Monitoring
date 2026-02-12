#!/usr/bin/env python3
"""Unit tests for Redis Query Caching Layer.

Tests VectorQueryCache functionality including:
- Cache hits and misses
- TTL expiration
- Hit/miss statistics
- Error handling
- Key generation
"""

# Standard library imports
import json
import os
import sys
import time
import unittest
from unittest.mock import MagicMock, Mock, patch

# Add project root to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../.."))

# Mock redis module before importing cache
mock_redis_module = MagicMock()


# Create proper exception classes
class RedisError(Exception):
    """Mock Redis base exception."""

    pass


class ConnectionError(RedisError):
    """Mock Redis connection error."""

    pass


mock_redis_module.RedisError = RedisError
mock_redis_module.ConnectionError = ConnectionError
sys.modules["redis"] = mock_redis_module

# Local imports
from src.db.cache import VectorQueryCache, get_cache


class TestVectorQueryCache(unittest.TestCase):
    """Test VectorQueryCache functionality."""

    def setUp(self):
        """Set up test fixtures."""
        # Mock redis client
        self.mock_redis = MagicMock()
        self.mock_redis.ping.return_value = True
        self.mock_redis.get.return_value = None
        self.mock_redis.setex.return_value = True

    @patch("src.db.cache.redis.Redis")
    def test_cache_initialization_success(self, mock_redis_class):
        """Test successful cache initialization."""
        mock_redis_class.return_value = self.mock_redis

        cache = VectorQueryCache(
            host="test-host", port=6380, password="test-pass", db=1, default_ttl=600
        )

        self.assertIsNotNone(cache.redis)
        self.assertEqual(cache.default_ttl, 600)
        self.assertEqual(cache.stats["hits"], 0)
        self.assertEqual(cache.stats["misses"], 0)
        self.assertEqual(cache.stats["errors"], 0)

        # Verify redis.Redis was called with correct params
        mock_redis_class.assert_called_once_with(
            host="test-host",
            port=6380,
            password="test-pass",
            db=1,
            decode_responses=True,
            socket_connect_timeout=5,
        )

        # Verify ping was called
        self.mock_redis.ping.assert_called_once()

    @patch("src.db.cache.redis.Redis")
    def test_cache_initialization_failure(self, mock_redis_class):
        """Test cache initialization with Redis unavailable."""
        mock_redis_instance = MagicMock()
        mock_redis_instance.ping.side_effect = ConnectionError("Connection failed")
        mock_redis_class.return_value = mock_redis_instance

        cache = VectorQueryCache()

        # Cache should disable when Redis unavailable
        self.assertIsNone(cache.redis)
        self.assertEqual(cache.default_ttl, 300)

    def test_generate_cache_key_basic(self):
        """Test cache key generation with basic parameters."""
        cache = VectorQueryCache()
        cache.redis = self.mock_redis

        vector = [0.1, 0.2, 0.3]
        key = cache._generate_cache_key("test_prefix", "test_namespace", vector, 10)

        # Key should contain all components
        self.assertIn("test_prefix", key)
        self.assertIn("test_namespace", key)
        self.assertIn("10", key)
        self.assertTrue(len(key.split(":")) >= 4)

    def test_generate_cache_key_with_params(self):
        """Test cache key generation with additional parameters."""
        cache = VectorQueryCache()
        cache.redis = self.mock_redis

        vector = [0.1, 0.2, 0.3]
        key = cache._generate_cache_key(
            "prefix", "namespace", vector, 5, filter_type="active", min_score=0.8
        )

        # Key should include parameter hash
        self.assertIn("prefix", key)
        self.assertIn("namespace", key)
        parts = key.split(":")
        self.assertGreater(len(parts), 4)

    def test_generate_cache_key_deterministic(self):
        """Test that same inputs produce same cache key."""
        cache = VectorQueryCache()
        cache.redis = self.mock_redis

        vector = [0.123456, 0.234567, 0.345678]

        key1 = cache._generate_cache_key("prefix", "ns", vector, 10, param1="value1")
        key2 = cache._generate_cache_key("prefix", "ns", vector, 10, param1="value1")

        self.assertEqual(key1, key2)

    def test_generate_cache_key_different_vectors(self):
        """Test that different vectors produce different keys."""
        cache = VectorQueryCache()
        cache.redis = self.mock_redis

        vector1 = [0.1, 0.2, 0.3]
        vector2 = [0.1, 0.2, 0.4]

        key1 = cache._generate_cache_key("prefix", "ns", vector1, 10)
        key2 = cache._generate_cache_key("prefix", "ns", vector2, 10)

        self.assertNotEqual(key1, key2)

    @patch("src.db.cache.redis.Redis")
    def test_cache_hit(self, mock_redis_class):
        """Test cache hit scenario."""
        mock_redis_class.return_value = self.mock_redis

        # Setup cached result
        cached_data = [{"id": "123", "distance": 0.5}]
        self.mock_redis.get.return_value = json.dumps(cached_data)

        cache = VectorQueryCache()

        # Create mock function
        mock_func = Mock(return_value=None)

        # Decorate function
        @cache.cache_vector_search()
        def search_func(namespace, vector, top_k=10):
            return mock_func(namespace, vector, top_k)

        # Execute search
        result = search_func("test_ns", [0.1, 0.2], top_k=5)

        # Should return cached result
        self.assertEqual(result, cached_data)

        # Function should not be called (cache hit)
        mock_func.assert_not_called()

        # Stats should show hit
        stats = cache.get_stats()
        self.assertEqual(stats["hits"], 1)
        self.assertEqual(stats["misses"], 0)

    @patch("src.db.cache.redis.Redis")
    def test_cache_miss(self, mock_redis_class):
        """Test cache miss scenario."""
        mock_redis_class.return_value = self.mock_redis

        # No cached result
        self.mock_redis.get.return_value = None

        cache = VectorQueryCache()

        # Create mock function
        result_data = [{"id": "456", "distance": 0.3}]
        mock_func = Mock(return_value=result_data)

        # Decorate function
        @cache.cache_vector_search()
        def search_func(namespace, vector, top_k=10):
            return mock_func(namespace, vector, top_k)

        # Execute search
        result = search_func("test_ns", [0.1, 0.2], top_k=5)

        # Should return function result
        self.assertEqual(result, result_data)

        # Function should be called (cache miss)
        mock_func.assert_called_once_with("test_ns", [0.1, 0.2], 5)

        # Result should be cached
        self.mock_redis.setex.assert_called_once()

        # Stats should show miss
        stats = cache.get_stats()
        self.assertEqual(stats["hits"], 0)
        self.assertEqual(stats["misses"], 1)

    @patch("src.db.cache.redis.Redis")
    def test_cache_ttl(self, mock_redis_class):
        """Test cache TTL (time to live)."""
        mock_redis_class.return_value = self.mock_redis
        self.mock_redis.get.return_value = None

        cache = VectorQueryCache(default_ttl=120)

        result_data = [{"id": "789"}]
        mock_func = Mock(return_value=result_data)

        @cache.cache_vector_search()
        def search_func(namespace, vector, top_k=10):
            return mock_func(namespace, vector, top_k)

        search_func("ns", [0.1], 5)

        # Verify TTL was set correctly
        call_args = self.mock_redis.setex.call_args
        self.assertEqual(call_args[0][1], 120)  # TTL should be 120 seconds

    @patch("src.db.cache.redis.Redis")
    def test_cache_custom_ttl(self, mock_redis_class):
        """Test cache with custom TTL."""
        mock_redis_class.return_value = self.mock_redis
        self.mock_redis.get.return_value = None

        cache = VectorQueryCache(default_ttl=300)

        result_data = [{"id": "999"}]
        mock_func = Mock(return_value=result_data)

        # Use custom TTL
        @cache.cache_vector_search(ttl=60)
        def search_func(namespace, vector, top_k=10):
            return mock_func(namespace, vector, top_k)

        search_func("ns", [0.1], 5)

        # Verify custom TTL was used
        call_args = self.mock_redis.setex.call_args
        self.assertEqual(call_args[0][1], 60)  # TTL should be 60 seconds

    @patch("src.db.cache.redis.Redis")
    def test_cache_disabled_when_redis_unavailable(self, mock_redis_class):
        """Test that cache is bypassed when Redis is unavailable."""
        mock_redis_instance = MagicMock()
        mock_redis_instance.ping.side_effect = ConnectionError("Connection failed")
        mock_redis_class.return_value = mock_redis_instance

        cache = VectorQueryCache()

        result_data = [{"id": "111"}]
        mock_func = Mock(return_value=result_data)

        @cache.cache_vector_search()
        def search_func(namespace, vector, top_k=10):
            return mock_func(namespace, vector, top_k)

        result = search_func("ns", [0.1], 5)

        # Should call function directly (no caching)
        self.assertEqual(result, result_data)
        mock_func.assert_called_once()

    @patch("src.db.cache.redis.Redis")
    def test_cache_error_handling(self, mock_redis_class):
        """Test cache error handling."""
        mock_redis_class.return_value = self.mock_redis

        # Simulate Redis error during get
        self.mock_redis.get.side_effect = RedisError("Redis error")

        cache = VectorQueryCache()

        result_data = [{"id": "222"}]
        mock_func = Mock(return_value=result_data)

        @cache.cache_vector_search()
        def search_func(namespace, vector, top_k=10):
            return mock_func(namespace, vector, top_k)

        result = search_func("ns", [0.1], 5)

        # Should fall back to function call
        self.assertEqual(result, result_data)
        mock_func.assert_called_once()

        # Stats should show error
        stats = cache.get_stats()
        self.assertEqual(stats["errors"], 1)

    @patch("src.db.cache.redis.Redis")
    def test_get_stats(self, mock_redis_class):
        """Test cache statistics retrieval."""
        mock_redis_class.return_value = self.mock_redis

        cache = VectorQueryCache()

        # Simulate hits and misses
        self.mock_redis.get.return_value = json.dumps([{"id": "1"}])
        mock_func = Mock()

        @cache.cache_vector_search()
        def search_func(namespace, vector, top_k=10):
            return mock_func(namespace, vector, top_k)

        # 2 hits
        search_func("ns", [0.1], 5)
        search_func("ns", [0.1], 5)

        # 1 miss
        self.mock_redis.get.return_value = None
        mock_func.return_value = [{"id": "2"}]
        search_func("ns", [0.2], 5)

        stats = cache.get_stats()

        self.assertEqual(stats["hits"], 2)
        self.assertEqual(stats["misses"], 1)
        self.assertEqual(stats["hit_rate"], "66.67%")
        self.assertEqual(stats["errors"], 0)

    @patch("src.db.cache.redis.Redis")
    def test_get_stats_no_requests(self, mock_redis_class):
        """Test statistics with no requests."""
        mock_redis_class.return_value = self.mock_redis

        cache = VectorQueryCache()
        stats = cache.get_stats()

        self.assertEqual(stats["hits"], 0)
        self.assertEqual(stats["misses"], 0)
        self.assertEqual(stats["hit_rate"], "0.00%")
        self.assertEqual(stats["errors"], 0)

    @patch("src.db.cache.redis.Redis")
    def test_cache_with_kwargs(self, mock_redis_class):
        """Test cache with keyword arguments."""
        mock_redis_class.return_value = self.mock_redis
        self.mock_redis.get.return_value = None

        cache = VectorQueryCache()

        result_data = [{"id": "333"}]
        mock_func = Mock(return_value=result_data)

        @cache.cache_vector_search()
        def search_func(namespace, vector, top_k=10, **kwargs):
            return mock_func(namespace, vector, top_k, **kwargs)

        result = search_func("ns", [0.1], 5, filter="active", threshold=0.8)

        # Should call function with all params
        self.assertEqual(result, result_data)
        mock_func.assert_called_once_with("ns", [0.1], 5, filter="active", threshold=0.8)

    @patch("src.db.cache.VectorQueryCache")
    def test_get_cache_factory(self, mock_cache_class):
        """Test get_cache factory function."""
        mock_instance = MagicMock()
        mock_cache_class.return_value = mock_instance

        cache = get_cache(host="custom-host", port=7000, password="pass123")

        # get_cache doesn't pass db or default_ttl, VectorQueryCache adds defaults
        self.assertEqual(cache, mock_instance)
        # Verify it was called with the parameters we passed
        call_args = mock_cache_class.call_args
        self.assertEqual(call_args[1]["host"], "custom-host")
        self.assertEqual(call_args[1]["port"], 7000)
        self.assertEqual(call_args[1]["password"], "pass123")


class TestCachePerformance(unittest.TestCase):
    """Test cache performance characteristics."""

    @patch("src.db.cache.redis.Redis")
    def test_cache_hit_rate_calculation(self, mock_redis_class):
        """Test hit rate calculation accuracy."""
        mock_redis = MagicMock()
        mock_redis.ping.return_value = True
        mock_redis_class.return_value = mock_redis

        cache = VectorQueryCache()

        # Simulate varying hit/miss patterns
        test_cases = [
            {"hits": 8, "misses": 2, "expected_rate": "80.00%"},
            {"hits": 5, "misses": 5, "expected_rate": "50.00%"},
            {"hits": 9, "misses": 1, "expected_rate": "90.00%"},
            {"hits": 1, "misses": 9, "expected_rate": "10.00%"},
        ]

        for test_case in test_cases:
            cache.stats["hits"] = test_case["hits"]
            cache.stats["misses"] = test_case["misses"]
            cache.stats["errors"] = 0

            stats = cache.get_stats()
            self.assertEqual(stats["hit_rate"], test_case["expected_rate"])


if __name__ == "__main__":
    unittest.main()
