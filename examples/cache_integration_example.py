#!/usr/bin/env python3
"""
Redis Cache Integration Example
Demonstrates how to integrate caching with vector operations.
"""

# Standard library imports
import logging
import os
import sys
import time
from typing import Any, Dict, List

# Add project root to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

# Third-party imports
from dotenv import load_dotenv

# Local imports
from src.db.cache import get_cache
from src.db.pool import get_pools

load_dotenv()

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


def search_vectors_uncached(
    namespace: str, vector: List[float], top_k: int = 10, distance_threshold: float = None
) -> List[Dict[str, Any]]:
    """
    Vector search WITHOUT caching (for comparison).

    Args:
        namespace: Vector namespace/collection
        vector: Query vector
        top_k: Number of results to return
        distance_threshold: Maximum distance for results

    Returns:
        List of search results with content and distance
    """
    try:
        pools = get_pools()

        query = """
        SELECT
            content,
            metadata,
            embedding <=> %s::ruvector AS distance
        FROM claude_flow.embeddings
        WHERE namespace = %s
        ORDER BY distance
        LIMIT %s
        """

        params = [str(vector), namespace, top_k]

        with pools.project_pool.connection() as conn:
            with conn.cursor() as cur:
                cur.execute(query, params)
                results = []
                for row in cur.fetchall():
                    results.append(
                        {"content": row[0], "metadata": row[1], "distance": float(row[2])}
                    )

                # Filter by distance threshold if specified
                if distance_threshold is not None:
                    results = [r for r in results if r["distance"] <= distance_threshold]

                return results

    except Exception as e:
        logger.error(f"Vector search failed: {e}")
        return []


def search_vectors_cached(
    namespace: str,
    vector: List[float],
    top_k: int = 10,
    distance_threshold: float = None,
    ttl: int = 300,
) -> List[Dict[str, Any]]:
    """
    Vector search WITH caching.

    Args:
        namespace: Vector namespace/collection
        vector: Query vector
        top_k: Number of results to return
        distance_threshold: Maximum distance for results
        ttl: Cache TTL in seconds

    Returns:
        List of search results with content and distance
    """
    cache = get_cache()

    # Wrap the uncached function with cache decorator
    cached_fn = cache.cache_vector_search(ttl=ttl)(search_vectors_uncached)

    # Call with caching
    return cached_fn(
        namespace=namespace, vector=vector, top_k=top_k, distance_threshold=distance_threshold
    )


def demo_cache_performance():
    """Demonstrate cache performance improvement."""
    print("\n" + "=" * 70)
    print("Cache Performance Demonstration")
    print("=" * 70)

    # Generate a test vector
    test_vector = [0.1] * 1536  # Dummy vector for demo
    namespace = "demo"

    print("\n1️⃣  First Query (Cache Miss)")
    print("-" * 70)
    start = time.time()
    results1 = search_vectors_cached(namespace, test_vector, top_k=10, ttl=60)
    time1 = time.time() - start
    print(f"   Query time: {time1*1000:.2f}ms")
    print(f"   Results: {len(results1)} vectors")

    print("\n2️⃣  Second Query - Same Vector (Cache Hit)")
    print("-" * 70)
    start = time.time()
    results2 = search_vectors_cached(namespace, test_vector, top_k=10, ttl=60)
    time2 = time.time() - start
    print(f"   Query time: {time2*1000:.2f}ms")
    print(f"   Results: {len(results2)} vectors")

    if time1 > 0 and time2 > 0:
        speedup = time1 / time2
        reduction = (time1 - time2) / time1 * 100
        print(f"\n⚡ Performance Impact:")
        print(f"   Speedup: {speedup:.1f}x faster")
        print(f"   Latency reduction: {reduction:.1f}%")

    # Get cache statistics
    cache = get_cache()
    stats = cache.get_stats()

    print(f"\n📊 Cache Statistics:")
    print(f"   Hits: {stats['hits']}")
    print(f"   Misses: {stats['misses']}")
    print(f"   Hit Rate: {stats['hit_rate']}")
    print(f"   Errors: {stats['errors']}")

    print("\n" + "=" * 70)


def demo_cache_strategies():
    """Demonstrate different cache strategies."""
    print("\n" + "=" * 70)
    print("Cache Strategy Examples")
    print("=" * 70)

    test_vector = [0.2] * 1536

    print("\n1️⃣  Short TTL (60s) - Fast-changing data")
    print("-" * 70)
    results = search_vectors_cached("volatile_data", test_vector, top_k=5, ttl=60)
    print(f"   Cached for: 60 seconds")
    print(f"   Use case: Real-time updates, trending content")

    print("\n2️⃣  Medium TTL (300s) - Default strategy")
    print("-" * 70)
    results = search_vectors_cached("standard_data", test_vector, top_k=5, ttl=300)
    print(f"   Cached for: 5 minutes")
    print(f"   Use case: General queries, balanced performance")

    print("\n3️⃣  Long TTL (3600s) - Stable data")
    print("-" * 70)
    results = search_vectors_cached("static_data", test_vector, top_k=5, ttl=3600)
    print(f"   Cached for: 1 hour")
    print(f"   Use case: Documentation, reference data")

    print("\n" + "=" * 70)


def demo_cache_invalidation():
    """Demonstrate cache invalidation techniques."""
    print("\n" + "=" * 70)
    print("Cache Invalidation Examples")
    print("=" * 70)

    cache = get_cache()

    print("\n1️⃣  Clear All Cache")
    print("-" * 70)
    print("   Command: cache.redis.flushdb()")
    print("   Use case: Data rebuild, schema changes")

    print("\n2️⃣  Clear Namespace Pattern")
    print("-" * 70)
    print("   Command: Delete keys matching 'vector_search:namespace:*'")
    print("   Use case: Namespace-specific updates")

    print("\n3️⃣  Automatic Expiration")
    print("-" * 70)
    print("   Strategy: TTL-based (set per query)")
    print("   Use case: No manual intervention needed")

    print("\n" + "=" * 70)


def main():
    """Run cache integration examples."""
    print("\n" + "=" * 70)
    print("Redis Cache Integration - Examples")
    print("Distributed PostgreSQL Cluster")
    print("=" * 70)

    try:
        # Demo 1: Performance comparison
        demo_cache_performance()

        # Demo 2: Cache strategies
        demo_cache_strategies()

        # Demo 3: Cache invalidation
        demo_cache_invalidation()

        print("\n✅ All examples completed successfully!")
        print("\nNext Steps:")
        print("  1. Integrate caching into your vector search functions")
        print("  2. Monitor cache hit rates and adjust TTL as needed")
        print("  3. Set up production monitoring with Redis metrics")
        print("  4. Review docs/REDIS_CACHE.md for detailed documentation")

    except Exception as e:
        logger.error(f"Example failed: {e}")
        logger.exception("Full traceback:")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
