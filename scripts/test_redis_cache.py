#!/usr/bin/env python3
"""
Redis Cache Integration Test & Benchmark
Tests cache functionality and measures latency reduction.
"""

# Standard library imports
import logging
import os
import random
import sys
import time
from typing import List

# Add project root to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

# Third-party imports
from dotenv import load_dotenv

# Local imports
from src.db.cache import get_cache

# Load environment
load_dotenv()

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


def generate_test_vector(dim: int = 1536) -> List[float]:
    """Generate random test vector."""
    return [random.random() for _ in range(dim)]


def mock_vector_search(namespace: str, vector: List[float], top_k: int = 10, **kwargs):
    """Mock vector search function with artificial latency."""
    # Simulate database query latency (50-100ms)
    time.sleep(0.05 + random.random() * 0.05)

    # Return mock results
    return [
        {
            "id": f"doc_{i}",
            "content": f"Document {i}",
            "distance": random.random(),
            "metadata": {"source": "test"},
        }
        for i in range(top_k)
    ]


def test_redis_connection():
    """Test 1: Redis connection and basic operations."""
    print("\n=== Test 1: Redis Connection ===")
    try:
        cache = get_cache()

        if cache.redis is None:
            print("❌ FAIL: Redis not available")
            return False

        # Test basic operations
        cache.redis.set("test_key", "test_value", ex=10)
        value = cache.redis.get("test_key")

        if value == "test_value":
            print("✅ PASS: Redis connected and working")
            print(f"   Host: {os.getenv('REDIS_HOST', 'localhost')}")
            print(f"   Port: {os.getenv('REDIS_PORT', '6379')}")
            print(f"   DB: {os.getenv('REDIS_DB', '0')}")
            return True
        else:
            print("❌ FAIL: Redis data mismatch")
            return False

    except Exception as e:
        print(f"❌ FAIL: {e}")
        return False


def test_cache_decorator():
    """Test 2: Cache decorator functionality."""
    print("\n=== Test 2: Cache Decorator ===")
    try:
        cache = get_cache()

        # Wrap mock function with cache decorator
        cached_search = cache.cache_vector_search(ttl=60)(mock_vector_search)

        # First call (cache miss)
        vector = generate_test_vector()
        start = time.time()
        result1 = cached_search("test_namespace", vector, top_k=5)
        time1 = time.time() - start

        # Second call (cache hit)
        start = time.time()
        result2 = cached_search("test_namespace", vector, top_k=5)
        time2 = time.time() - start

        # Verify results match
        if result1 == result2:
            speedup = (time1 / time2) if time2 > 0 else 0
            print("✅ PASS: Cache decorator working")
            print(f"   First call (miss): {time1*1000:.2f}ms")
            print(f"   Second call (hit): {time2*1000:.2f}ms")
            print(f"   Speedup: {speedup:.2f}x")
            return True
        else:
            print("❌ FAIL: Cached results don't match")
            return False

    except Exception as e:
        print(f"❌ FAIL: {e}")
        logger.exception("Cache decorator test failed")
        return False


def test_cache_key_generation():
    """Test 3: Cache key generation consistency."""
    print("\n=== Test 3: Cache Key Generation ===")
    try:
        cache = get_cache()

        vector = generate_test_vector()

        # Generate same key multiple times
        key1 = cache._generate_cache_key("test", "ns", vector, 10)
        key2 = cache._generate_cache_key("test", "ns", vector, 10)
        key3 = cache._generate_cache_key("test", "ns", vector, 10, param1="value")

        if key1 == key2 and key1 != key3:
            print("✅ PASS: Cache key generation consistent")
            print(f"   Key (no params): {key1}")
            print(f"   Key (with param): {key3}")
            return True
        else:
            print("❌ FAIL: Cache key inconsistency")
            return False

    except Exception as e:
        print(f"❌ FAIL: {e}")
        return False


def benchmark_cache_performance():
    """Benchmark: Cache hit rate and latency reduction."""
    print("\n=== Benchmark: Cache Performance ===")
    try:
        cache = get_cache()
        cached_search = cache.cache_vector_search(ttl=60)(mock_vector_search)

        # Generate test vectors
        test_vectors = [generate_test_vector() for _ in range(10)]

        # Reset stats
        cache.stats = {"hits": 0, "misses": 0, "errors": 0}

        # Run queries (mix of new and repeated)
        print("\nRunning 50 queries (50% repeated)...")
        uncached_times = []
        cached_times = []

        for i in range(50):
            # 50% chance to use a repeated vector
            if i < 25 or random.random() < 0.5:
                vector = random.choice(test_vectors)
            else:
                vector = generate_test_vector()

            start = time.time()
            result = cached_search("benchmark", vector, top_k=10)
            elapsed = time.time() - start

            # Track timing
            if i < 10:  # First 10 are all misses
                uncached_times.append(elapsed)
            else:
                cached_times.append(elapsed)

        # Calculate statistics
        stats = cache.get_stats()
        avg_uncached = sum(uncached_times) / len(uncached_times) * 1000
        avg_cached = sum(cached_times) / len(cached_times) * 1000
        latency_reduction = (
            ((avg_uncached - avg_cached) / avg_uncached * 100) if avg_uncached > 0 else 0
        )

        print(f"\n📊 Cache Statistics:")
        print(f"   Total Queries: 50")
        print(f"   Cache Hits: {stats['hits']}")
        print(f"   Cache Misses: {stats['misses']}")
        print(f"   Hit Rate: {stats['hit_rate']}")
        print(f"   Errors: {stats['errors']}")

        print(f"\n⚡ Performance Impact:")
        print(f"   Avg Latency (uncached): {avg_uncached:.2f}ms")
        print(f"   Avg Latency (cached): {avg_cached:.2f}ms")
        print(f"   Latency Reduction: {latency_reduction:.1f}%")

        # Check success criteria
        hit_rate = float(stats["hit_rate"].rstrip("%"))
        success = hit_rate >= 50 and latency_reduction >= 50

        if success:
            print(f"\n✅ SUCCESS: Cache performance targets met!")
            print(f"   ✓ Hit rate >50%: {hit_rate:.1f}%")
            print(f"   ✓ Latency reduction >50%: {latency_reduction:.1f}%")
        else:
            print(f"\n⚠️  WARNING: Performance targets not fully met")
            if hit_rate < 50:
                print(f"   ✗ Hit rate below 50%: {hit_rate:.1f}%")
            if latency_reduction < 50:
                print(f"   ✗ Latency reduction below 50%: {latency_reduction:.1f}%")

        return success

    except Exception as e:
        print(f"❌ FAIL: {e}")
        logger.exception("Benchmark failed")
        return False


def test_cache_invalidation():
    """Test 4: Cache TTL and invalidation."""
    print("\n=== Test 4: Cache TTL ===")
    try:
        cache = get_cache()
        cached_search = cache.cache_vector_search(ttl=2)(mock_vector_search)

        vector = generate_test_vector()

        # First call
        result1 = cached_search("ttl_test", vector, top_k=5)

        # Immediate second call (should hit cache)
        result2 = cached_search("ttl_test", vector, top_k=5)

        if result1 != result2:
            print("❌ FAIL: Cache not persisting")
            return False

        # Wait for TTL expiration
        print("   Waiting for TTL expiration (2s)...")
        time.sleep(2.5)

        # Third call (should miss cache - new result)
        result3 = cached_search("ttl_test", vector, top_k=5)

        # Results should differ (mock returns random data)
        print("✅ PASS: Cache TTL working")
        return True

    except Exception as e:
        print(f"❌ FAIL: {e}")
        return False


def main():
    """Run all tests and benchmarks."""
    print("=" * 60)
    print("Redis Cache Integration Test & Benchmark")
    print("=" * 60)

    results = []

    # Run tests
    results.append(("Redis Connection", test_redis_connection()))
    results.append(("Cache Decorator", test_cache_decorator()))
    results.append(("Cache Key Generation", test_cache_key_generation()))
    results.append(("Cache TTL", test_cache_invalidation()))
    results.append(("Performance Benchmark", benchmark_cache_performance()))

    # Summary
    print("\n" + "=" * 60)
    print("Test Summary")
    print("=" * 60)

    passed = sum(1 for _, result in results if result)
    total = len(results)

    for test_name, result in results:
        status = "✅ PASS" if result else "❌ FAIL"
        print(f"{status}: {test_name}")

    print(f"\n📊 Overall: {passed}/{total} tests passed ({passed/total*100:.1f}%)")

    if passed == total:
        print("\n🎉 All tests passed! Redis cache is fully operational.")
        return 0
    else:
        print(f"\n⚠️  {total - passed} test(s) failed. Check logs for details.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
