"""Connection pooling examples.

Demonstrates:
- Using context managers
- Pool health checks
- Concurrent operations
- Connection cleanup
"""

# Standard library imports
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Local imports
from src.db import close_pools, get_pools
from src.db.vector_ops import retrieve_memory, store_memory


def worker_task(worker_id, namespace):
    """Worker task that uses database connection."""
    pools = get_pools()

    # Store data
    with pools.project_cursor() as cur:
        store_memory(
            cur,
            namespace,
            f"worker_{worker_id}",
            f"Data from worker {worker_id}",
        )

    # Retrieve data
    with pools.project_cursor() as cur:
        result = retrieve_memory(cur, namespace, f"worker_{worker_id}")
        if result:
            print(f"  Worker {worker_id}: ✓ Retrieved data")


def main():
    """Run connection pooling examples."""
    print("=== Connection Pooling ===\n")

    # 1. Check pool health
    print("1. Checking pool health...")
    pools = get_pools()
    health = pools.health_check()

    print(f"  Mode: {health.get('mode', 'unknown')}")
    if "project" in health:
        print(f"  Project DB: {health['project']['status']}")
        print(f"    Database: {health['project'].get('database')}")
        print(f"    RuVector: {health['project'].get('ruvector_version')}")
    if "shared" in health:
        print(f"  Shared DB: {health['shared']['status']}")

    # 2. Using context managers (proper pattern)
    print("\n2. Using context managers (recommended)...")
    namespace = "example_pool"

    # Good - automatic connection management
    with pools.project_cursor() as cur:
        store_memory(cur, namespace, "test_key", "test value")
        print("  ✓ Stored data (connection auto-released)")

    with pools.project_cursor() as cur:
        result = retrieve_memory(cur, namespace, "test_key")
        if result:
            print("  ✓ Retrieved data (connection auto-released)")

    # 3. Concurrent operations
    print("\n3. Running concurrent operations...")
    num_workers = 10
    threads = []

    start = time.time()
    for i in range(num_workers):
        thread = threading.Thread(target=worker_task, args=(i, namespace))
        threads.append(thread)
        thread.start()

    # Wait for all threads
    for thread in threads:
        thread.join()

    duration = time.time() - start
    print(f"  ✓ {num_workers} workers completed in {duration:.2f}s")

    # 4. Monitor pool usage
    print("\n4. Checking pool status...")
    print(f"  Project pool - used: {pools.project_pool._used}")
    print(f"  Project pool - max: 40")
    print(f"  Shared pool - used: {pools.shared_pool._used}")
    print(f"  Shared pool - max: 15")

    # 5. Proper cleanup
    print("\n5. Cleanup...")
    with pools.project_cursor() as cur:
        cur.execute("DELETE FROM memory_entries WHERE namespace = %s", (namespace,))
        print(f"  ✓ Cleaned up namespace '{namespace}'")

    # Close pools (optional, for demonstration)
    close_pools()
    print("  ✓ Closed all pool connections")

    print("\n=== Done! ===")
    print("\nBest Practices:")
    print("  - Always use context managers (with statement)")
    print("  - Connections are automatically released")
    print("  - Pool handles concurrent access")
    print("  - Don't manually manage connections")


if __name__ == "__main__":
    main()
