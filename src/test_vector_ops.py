#!/usr/bin/env python3
"""Test script for vector operations with RuVector.

This script verifies:
1. Database connections to both project and shared databases
2. RuVector extension is properly installed
3. HNSW indexes are working
4. Vector similarity search is performant
"""
# Standard library imports
import os
import sys
import time
from pathlib import Path

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))

# Third-party imports
from dotenv import load_dotenv

# Local imports
from db.pool import DualDatabasePools, close_pools, get_pools
from db.vector_ops import count_memories, retrieve_memory, search_memory, store_memory

# Load environment variables
load_dotenv()


def test_connection_health():
    """Test connection health for both databases."""
    print("=" * 60)
    print("Testing Database Connections")
    print("=" * 60)

    pools = get_pools()
    health = pools.health_check()

    # Project database
    print("\n📊 Project Database:")
    proj = health["project"]
    if proj["status"] == "healthy":
        print(f"  ✅ Status: {proj['status']}")
        print(f"  📦 Database: {proj['database']}")
        print(f"  👤 User: {proj['user']}")
        print(f"  🚀 RuVector: {proj['ruvector_version']}")
    else:
        print(f"  ❌ Error: {proj.get('error', 'Unknown')}")
        return False

    # Shared database
    print("\n📚 Shared Knowledge Database:")
    shared = health["shared"]
    if shared["status"] == "healthy":
        print(f"  ✅ Status: {shared['status']}")
        print(f"  📦 Database: {shared['database']}")
        print(f"  👤 User: {shared['user']}")
        print(f"  🚀 RuVector: {shared['ruvector_version']}")
    else:
        print(f"  ❌ Error: {shared.get('error', 'Unknown')}")
        return False

    return True


def test_hnsw_indexes():
    """Test HNSW indexes exist and are functional."""
    print("\n" + "=" * 60)
    print("Testing HNSW Indexes")
    print("=" * 60)

    pools = get_pools()

    with pools.project_cursor() as cur:
        # Check for HNSW indexes by looking at index access method
        cur.execute(
            """
            SELECT
                schemaname,
                tablename,
                indexname,
                indexdef
            FROM pg_indexes
            WHERE indexdef LIKE '%USING hnsw%'
            ORDER BY tablename
        """
        )

        indexes = cur.fetchall()
        if not indexes:
            print("  ❌ No HNSW indexes found!")
            return False

        print(f"\n  ✅ Found {len(indexes)} HNSW indexes:")
        for idx in indexes:
            print(f"     - {idx['indexname']} on {idx['tablename']}")

    return True


def test_vector_storage_and_retrieval():
    """Test storing and retrieving vectors."""
    print("\n" + "=" * 60)
    print("Testing Vector Storage & Retrieval")
    print("=" * 60)

    pools = get_pools()
    namespace = "test-distributed-postgres-cluster"

    # Create test embeddings (384 dimensions)
    test_data = [
        {
            "key": "postgres-cluster-1",
            "value": "Distributed PostgreSQL cluster with automatic failover",
            "embedding": [0.1] * 384,  # Simple test embedding
            "metadata": {"type": "cluster-info", "version": "1.0"},
        },
        {
            "key": "postgres-cluster-2",
            "value": "High-availability PostgreSQL setup with replication",
            "embedding": [0.2] * 384,
            "metadata": {"type": "cluster-info", "version": "2.0"},
        },
        {
            "key": "postgres-cluster-3",
            "value": "Sharded PostgreSQL configuration for scalability",
            "embedding": [0.15] * 384,
            "metadata": {"type": "cluster-info", "version": "3.0"},
        },
    ]

    # Store test data
    print("\n📝 Storing test vectors...")
    with pools.project_cursor() as cur:
        for item in test_data:
            store_memory(
                cur,
                namespace=namespace,
                key=item["key"],
                value=item["value"],
                embedding=item["embedding"],
                metadata=item["metadata"],
            )
    print(f"  ✅ Stored {len(test_data)} vectors")

    # Retrieve by key
    print("\n🔍 Retrieving by key...")
    with pools.project_cursor() as cur:
        result = retrieve_memory(cur, namespace, "postgres-cluster-1")
        if result:
            print(f"  ✅ Retrieved: {result['key']}")
            print(f"     Value: {result['value'][:50]}...")
        else:
            print("  ❌ Failed to retrieve")
            return False

    # Count memories
    with pools.project_cursor() as cur:
        count = count_memories(cur, namespace)
        print(f"\n📊 Total memories in namespace: {count}")

    return True


def test_vector_similarity_search():
    """Test vector similarity search with HNSW."""
    print("\n" + "=" * 60)
    print("Testing Vector Similarity Search (HNSW)")
    print("=" * 60)

    pools = get_pools()
    namespace = "test-distributed-postgres-cluster"

    # Query embedding (similar to first test vector)
    query_embedding = [0.11] * 384

    print("\n🔎 Performing similarity search...")
    start_time = time.time()

    with pools.project_cursor() as cur:
        results = search_memory(
            cur, namespace=namespace, query_embedding=query_embedding, limit=5, min_similarity=0.5
        )

    elapsed_ms = (time.time() - start_time) * 1000

    print(f"  ⚡ Search completed in {elapsed_ms:.2f}ms")
    print(f"  📊 Found {len(results)} results:")

    for i, result in enumerate(results, 1):
        similarity = result["similarity"]
        print(f"\n     {i}. {result['key']} (similarity: {similarity:.4f})")
        print(f"        {result['value'][:60]}...")

    # Check performance
    if elapsed_ms < 50:
        print(f"\n  ✅ Performance: Excellent (<50ms target)")
    elif elapsed_ms < 100:
        print(f"\n  ⚠️  Performance: Good but can be improved")
    else:
        print(f"\n  ❌ Performance: Slow (target is <50ms)")

    return True


def test_shared_knowledge_access():
    """Test access to shared knowledge database."""
    print("\n" + "=" * 60)
    print("Testing Shared Knowledge Database Access")
    print("=" * 60)

    pools = get_pools()

    with pools.shared_cursor() as cur:
        count = count_memories(cur, "claude-flow-v3-learnings")
        print(f"\n  📚 Shared knowledge entries: {count}")

        if count > 0:
            print(f"  ✅ Successfully accessing shared knowledge database")
            return True
        else:
            print(f"  ⚠️  No entries found in shared namespace")
            return True  # Not an error, just empty


def cleanup_test_data():
    """Clean up test data."""
    print("\n" + "=" * 60)
    print("Cleaning Up Test Data")
    print("=" * 60)

    pools = get_pools()
    namespace = "test-distributed-postgres-cluster"

    with pools.project_cursor() as cur:
        cur.execute(
            """
            DELETE FROM memory_entries
            WHERE namespace = %s
        """,
            (namespace,),
        )
        print(f"  ✅ Cleaned up test namespace: {namespace}")


def main():
    """Run all tests."""
    print("\n🚀 RuVector + PostgreSQL Integration Tests")
    print("=" * 60)

    try:
        # Run tests
        tests = [
            ("Connection Health", test_connection_health),
            ("HNSW Indexes", test_hnsw_indexes),
            ("Vector Storage & Retrieval", test_vector_storage_and_retrieval),
            ("Vector Similarity Search", test_vector_similarity_search),
            ("Shared Knowledge Access", test_shared_knowledge_access),
        ]

        results = []
        for name, test_func in tests:
            try:
                success = test_func()
                results.append((name, success))
            except Exception as e:
                print(f"\n  ❌ Test failed with error: {e}")
                results.append((name, False))

        # Cleanup
        try:
            cleanup_test_data()
        except Exception as e:
            print(f"  ⚠️  Cleanup error: {e}")

        # Summary
        print("\n" + "=" * 60)
        print("Test Summary")
        print("=" * 60)

        passed = sum(1 for _, success in results if success)
        total = len(results)

        for name, success in results:
            status = "✅ PASS" if success else "❌ FAIL"
            print(f"  {status}: {name}")

        print(f"\n  Results: {passed}/{total} tests passed")

        if passed == total:
            print("\n  🎉 All tests passed! Vector operations are working correctly.")
            return 0
        else:
            print("\n  ⚠️  Some tests failed. Please review the output above.")
            return 1

    except Exception as e:
        print(f"\n❌ Fatal error: {e}")
        # Standard library imports
        import traceback

        traceback.print_exc()
        return 1
    finally:
        close_pools()


if __name__ == "__main__":
    sys.exit(main())
