#!/usr/bin/env python3
"""Demonstration of bulk insert operations with performance comparison.

This script shows how to use bulk operations for faster data insertion
compared to individual INSERT statements.
"""
import sys
import time
from pathlib import Path
from dotenv import load_dotenv

# Add src directory to Python path
sys.path.insert(0, str(Path(__file__).parent.parent / 'src'))

# Load environment variables
load_dotenv()

from db import (
    get_pools,
    store_memory,
    bulk_insert_memory_entries,
    bulk_insert_patterns,
    bulk_insert_trajectories
)


def demo_basic_bulk_insert():
    """Demonstrate basic bulk insert with memory entries."""
    print("\n" + "=" * 70)
    print("DEMO 1: Basic Bulk Insert")
    print("=" * 70)

    pools = get_pools()

    # Generate 500 test entries
    entries = [
        {
            'namespace': 'demo',
            'key': f'bulk_entry_{i}',
            'value': f'This is test entry {i} for bulk operations demo',
            'embedding': [0.1 + i * 0.0001] * 384,
            'metadata': {
                'demo': True,
                'batch': 'demo_1',
                'index': i
            },
            'tags': ['demo', 'bulk', f'group_{i // 100}']
        }
        for i in range(500)
    ]

    # Bulk insert
    print(f"\nInserting {len(entries)} entries using bulk COPY...")
    start = time.time()

    with pools.project_cursor() as cur:
        count = bulk_insert_memory_entries(cur, entries)

    elapsed = time.time() - start
    print(f"✓ Inserted {count} entries in {elapsed:.3f}s ({count/elapsed:.0f} entries/sec)")

    # Cleanup
    with pools.project_cursor() as cur:
        cur.execute("DELETE FROM memory_entries WHERE namespace = 'demo'")
    print("✓ Cleaned up demo data")


def demo_performance_comparison():
    """Compare individual vs bulk insert performance."""
    print("\n" + "=" * 70)
    print("DEMO 2: Performance Comparison")
    print("=" * 70)

    pools = get_pools()
    test_size = 200

    # Generate test data
    entries = [
        {
            'namespace': 'perf_test',
            'key': f'entry_{i}',
            'value': f'Performance test entry {i}',
            'embedding': [0.2 + i * 0.0001] * 384,
            'metadata': {'index': i},
            'tags': ['performance', 'comparison']
        }
        for i in range(test_size)
    ]

    # Method 1: Individual INSERTs
    print(f"\nMethod 1: Individual INSERTs ({test_size} entries)...")
    start = time.time()

    with pools.project_cursor() as cur:
        for entry in entries:
            store_memory(
                cur,
                entry['namespace'],
                entry['key'],
                entry['value'],
                entry['embedding'],
                entry['metadata'],
                entry['tags']
            )

    individual_time = time.time() - start
    print(f"  Time: {individual_time:.3f}s ({test_size/individual_time:.0f} entries/sec)")

    # Cleanup
    with pools.project_cursor() as cur:
        cur.execute("DELETE FROM memory_entries WHERE namespace = 'perf_test'")

    # Method 2: Bulk COPY
    print(f"\nMethod 2: Bulk COPY ({test_size} entries)...")
    start = time.time()

    with pools.project_cursor() as cur:
        bulk_insert_memory_entries(cur, entries)

    bulk_time = time.time() - start
    print(f"  Time: {bulk_time:.3f}s ({test_size/bulk_time:.0f} entries/sec)")

    # Results
    speedup = individual_time / bulk_time
    print(f"\n✓ Bulk COPY is {speedup:.1f}x faster!")

    # Cleanup
    with pools.project_cursor() as cur:
        cur.execute("DELETE FROM memory_entries WHERE namespace = 'perf_test'")
    print("✓ Cleaned up test data")


def demo_conflict_handling():
    """Demonstrate conflict resolution strategies."""
    print("\n" + "=" * 70)
    print("DEMO 3: Conflict Handling")
    print("=" * 70)

    pools = get_pools()

    # Initial batch
    initial_entries = [
        {
            'namespace': 'conflict_demo',
            'key': f'entry_{i}',
            'value': f'Original value {i}',
            'embedding': [0.3] * 384,
            'metadata': {'version': 1},
            'tags': ['original']
        }
        for i in range(50)
    ]

    print(f"\nInserting {len(initial_entries)} initial entries...")
    with pools.project_cursor() as cur:
        count = bulk_insert_memory_entries(cur, initial_entries)
    print(f"✓ Inserted {count} entries")

    # Overlapping batch with skip
    overlapping_entries = [
        {
            'namespace': 'conflict_demo',
            'key': f'entry_{i}',
            'value': f'Updated value {i}',
            'embedding': [0.4] * 384,
            'metadata': {'version': 2},
            'tags': ['updated']
        }
        for i in range(75)  # 0-74, overlaps with 0-49
    ]

    print(f"\nInserting {len(overlapping_entries)} entries with 'skip' conflict strategy...")
    with pools.project_cursor() as cur:
        count = bulk_insert_memory_entries(cur, overlapping_entries, on_conflict='skip')
    print(f"✓ Inserted {count} new entries (25 new, 50 skipped)")

    # Verify count
    with pools.project_cursor() as cur:
        cur.execute("SELECT COUNT(*) as cnt FROM memory_entries WHERE namespace = 'conflict_demo'")
        result = cur.fetchone()
    print(f"✓ Total entries: {result['cnt']}")

    # Update with update strategy
    update_entries = [
        {
            'namespace': 'conflict_demo',
            'key': f'entry_{i}',
            'value': f'FINAL value {i}',
            'embedding': [0.5] * 384,
            'metadata': {'version': 3, 'final': True},
            'tags': ['final']
        }
        for i in range(75)
    ]

    print(f"\nInserting {len(update_entries)} entries with 'update' conflict strategy...")
    with pools.project_cursor() as cur:
        count = bulk_insert_memory_entries(cur, update_entries, on_conflict='update')
    print(f"✓ Updated {count} entries")

    # Verify updates
    with pools.project_cursor() as cur:
        cur.execute("""
            SELECT COUNT(*) as cnt
            FROM memory_entries
            WHERE namespace = 'conflict_demo'
              AND value LIKE 'FINAL%'
        """)
        result = cur.fetchone()
    print(f"✓ Entries with 'FINAL' value: {result['cnt']}")

    # Cleanup
    with pools.project_cursor() as cur:
        cur.execute("DELETE FROM memory_entries WHERE namespace = 'conflict_demo'")
    print("✓ Cleaned up demo data")


def demo_multi_table_bulk():
    """Demonstrate bulk inserts across multiple table types."""
    print("\n" + "=" * 70)
    print("DEMO 4: Multi-Table Bulk Operations")
    print("=" * 70)

    pools = get_pools()

    # 1. Bulk insert patterns
    patterns = [
        {
            'name': f'demo_pattern_{i}',
            'pattern_type': f'demo_type_{i % 3}',
            'description': f'Demo pattern {i} for bulk operations',
            'embedding': [0.6 + i * 0.001] * 384,
            'confidence': 0.7 + (i % 10) * 0.02,
            'usage_count': i * 5,
            'success_count': i * 4,
            'metadata': {'demo': True, 'category': 'test'}
        }
        for i in range(30)
    ]

    print(f"\nInserting {len(patterns)} patterns...")
    start = time.time()
    with pools.project_cursor() as cur:
        count = bulk_insert_patterns(cur, patterns)
    elapsed = time.time() - start
    print(f"✓ Inserted {count} patterns in {elapsed:.3f}s")

    # 2. Bulk insert trajectories
    trajectories = [
        {
            'trajectory_id': f'demo_traj_{i // 5}',
            'step_number': i % 5,
            'action': f'action_{i % 3}',
            'state': {'position': i, 'velocity': i * 0.5},
            'reward': float(i % 4),
            'embedding': [0.7 + i * 0.001] * 384,
            'metadata': {'demo': True, 'experiment': 'bulk_demo'}
        }
        for i in range(50)
    ]

    print(f"\nInserting {len(trajectories)} trajectories...")
    start = time.time()
    with pools.project_cursor() as cur:
        count = bulk_insert_trajectories(cur, trajectories)
    elapsed = time.time() - start
    print(f"✓ Inserted {count} trajectories in {elapsed:.3f}s")

    # Cleanup
    with pools.project_cursor() as cur:
        cur.execute("DELETE FROM patterns WHERE pattern_type LIKE 'demo_type_%'")
        cur.execute("DELETE FROM trajectories WHERE trajectory_id LIKE 'demo_traj_%'")
    print("✓ Cleaned up demo data")


def main():
    """Run all demos."""
    print("\n" + "=" * 70)
    print("BULK OPERATIONS DEMONSTRATION")
    print("=" * 70)

    try:
        demo_basic_bulk_insert()
        demo_performance_comparison()
        demo_conflict_handling()
        demo_multi_table_bulk()

        print("\n" + "=" * 70)
        print("ALL DEMOS COMPLETED SUCCESSFULLY ✓")
        print("=" * 70)
        print("\nKey Takeaways:")
        print("  • Bulk COPY is 2-3x faster than individual INSERTs")
        print("  • Use 'skip' to ignore duplicates, 'update' to overwrite")
        print("  • Works with memory_entries, patterns, and trajectories tables")
        print("  • Automatic validation and transaction safety")
        print("  • Best for batches of 10+ entries")
        print("\n")

    except Exception as e:
        print("\n" + "=" * 70)
        print("DEMO FAILED")
        print("=" * 70)
        print(f"Error: {e}")
        raise


if __name__ == '__main__':
    main()
