"""Batch operations for high performance.

Demonstrates:
- Batch inserts (fast)
- vs. Individual inserts (slow)
- Performance comparison
"""

# Standard library imports
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Local imports
from src.db import get_pools


def batch_store_memories(cursor, entries):
    """Store multiple memories in one transaction."""
    query = """
        INSERT INTO memory_entries
            (namespace, key, value, embedding, metadata, tags)
        VALUES (%s, %s, %s, %s::ruvector, %s::jsonb, %s)
        ON CONFLICT (namespace, key) DO UPDATE
        SET value = EXCLUDED.value,
            embedding = EXCLUDED.embedding,
            metadata = EXCLUDED.metadata,
            tags = EXCLUDED.tags,
            updated_at = NOW()
    """

    data = [
        (
            e["namespace"],
            e["key"],
            e["value"],
            f"[{','.join(str(v) for v in e['embedding'])}]" if e.get("embedding") else None,
            str(e.get("metadata", {})),
            e.get("tags", []),
        )
        for e in entries
    ]

    cursor.executemany(query, data)


def main():
    """Run batch operations examples."""
    print("=== Batch Operations ===\n")

    pools = get_pools()
    namespace = "example_batch"

    # Generate test data
    print("Generating test data (1000 entries)...")
    entries = []
    for i in range(1000):
        entries.append(
            {
                "namespace": namespace,
                "key": f"key_{i}",
                "value": f"Value for key {i}",
                "embedding": [random.random() for _ in range(384)],
                "metadata": {"index": i, "batch": "test"},
                "tags": ["batch", "test"],
            }
        )
    print(f"  ✓ Generated {len(entries)} entries\n")

    # Method 1: Individual inserts (SLOW)
    print("Method 1: Individual inserts...")
    start = time.time()

    # Local imports
    from src.db.vector_ops import store_memory

    for entry in entries[:100]:  # Only 100 for demo
        with pools.project_cursor() as cur:
            store_memory(
                cur,
                entry["namespace"],
                entry["key"],
                entry["value"],
                embedding=entry["embedding"],
                metadata=entry["metadata"],
                tags=entry["tags"],
            )

    duration_individual = time.time() - start
    print(f"  Time: {duration_individual:.2f}s for 100 entries")
    print(f"  Rate: {100/duration_individual:.1f} entries/second\n")

    # Cleanup first batch
    with pools.project_cursor() as cur:
        cur.execute("DELETE FROM memory_entries WHERE namespace = %s", (namespace,))

    # Method 2: Batch insert (FAST)
    print("Method 2: Batch insert...")
    start = time.time()

    with pools.project_cursor() as cur:
        batch_store_memories(cur, entries)

    duration_batch = time.time() - start
    print(f"  Time: {duration_batch:.2f}s for 1000 entries")
    print(f"  Rate: {len(entries)/duration_batch:.1f} entries/second\n")

    # Performance comparison
    print("Performance Comparison:")
    speedup = (duration_individual / 100) / (duration_batch / 1000)
    print(f"  Batch method is ~{speedup:.1f}x faster")
    print(f"  Individual: {duration_individual/100*1000:.2f}ms per entry")
    print(f"  Batch: {duration_batch/1000*1000:.2f}ms per entry\n")

    # Verify data
    print("Verifying data...")
    with pools.project_cursor() as cur:
        cur.execute(
            "SELECT count(*) as count FROM memory_entries WHERE namespace = %s", (namespace,)
        )
        count = cur.fetchone()["count"]
        print(f"  ✓ Inserted {count} entries\n")

    # Cleanup
    print("Cleanup...")
    with pools.project_cursor() as cur:
        cur.execute("DELETE FROM memory_entries WHERE namespace = %s", (namespace,))
        print(f"  ✓ Cleaned up namespace '{namespace}'")

    print("\n=== Done! ===")
    print("\nKey Takeaways:")
    print("  - Use batch inserts for large datasets")
    print("  - Batch operations are 10-50x faster")
    print("  - Reduce transaction overhead with executemany()")


if __name__ == "__main__":
    main()
