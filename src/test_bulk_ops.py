#!/usr/bin/env python3
"""Test suite for bulk operations with performance benchmarks.

This test suite validates the bulk insert operations and provides
performance comparisons with individual INSERT statements.
"""
# Standard library imports
import logging
import os
import sys
import time
from pathlib import Path
from typing import Any, Dict, List

# Third-party imports
# Load environment variables
from dotenv import load_dotenv

load_dotenv()

# Local imports
from db.bulk_ops import (
    InvalidEmbeddingError,
    VectorOperationError,
    bulk_insert_memory_entries,
    bulk_insert_patterns,
    bulk_insert_trajectories,
)
from db.pool import get_pools
from db.vector_ops import count_memories, store_memory

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


def generate_test_entries(count: int, namespace: str = "bulk_test") -> List[Dict[str, Any]]:
    """Generate test memory entries with embeddings."""
    return [
        {
            "namespace": namespace,
            "key": f"entry_{i}",
            "value": f"Test value {i} for bulk operations",
            "embedding": [0.1 + (i % 100) * 0.001] * 384,
            "metadata": {"index": i, "test": True, "batch": "bulk_ops_test"},
            "tags": ["test", "bulk", f"batch_{i // 100}"],
        }
        for i in range(count)
    ]


def test_bulk_insert_basic():
    """Test basic bulk insert functionality."""
    logger.info("=" * 70)
    logger.info("TEST 1: Basic bulk insert")
    logger.info("=" * 70)

    pools = get_pools()

    try:
        with pools.project_cursor() as cur:
            # Clean up test data
            cur.execute("DELETE FROM memory_entries WHERE namespace = 'bulk_test_basic'")

            # Generate and insert test entries
            entries = generate_test_entries(100, "bulk_test_basic")
            count = bulk_insert_memory_entries(cur, entries)

            assert count == 100, f"Expected 100 inserts, got {count}"

            # Verify data
            cur.execute(
                "SELECT COUNT(*) as cnt FROM memory_entries WHERE namespace = 'bulk_test_basic'"
            )
            result = cur.fetchone()
            assert result["cnt"] == 100, f"Expected 100 rows, got {result['cnt']}"

            logger.info("✓ Basic bulk insert test PASSED")
            return True

    except Exception as e:
        logger.error(f"✗ Basic bulk insert test FAILED: {e}")
        raise
    finally:
        # Cleanup
        with pools.project_cursor() as cur:
            cur.execute("DELETE FROM memory_entries WHERE namespace = 'bulk_test_basic'")


def test_bulk_insert_conflict_skip():
    """Test bulk insert with conflict resolution (skip)."""
    logger.info("=" * 70)
    logger.info("TEST 2: Bulk insert with conflict (skip)")
    logger.info("=" * 70)

    pools = get_pools()

    try:
        with pools.project_cursor() as cur:
            # Clean up
            cur.execute("DELETE FROM memory_entries WHERE namespace = 'bulk_test_conflict'")

            # First batch
            entries = generate_test_entries(50, "bulk_test_conflict")
            count1 = bulk_insert_memory_entries(cur, entries)
            assert count1 == 50, f"Expected 50 inserts, got {count1}"

            # Second batch with overlap (should skip duplicates)
            entries2 = generate_test_entries(100, "bulk_test_conflict")
            count2 = bulk_insert_memory_entries(cur, entries2, on_conflict="skip")

            # Should insert only 50 new entries (51-99)
            cur.execute(
                "SELECT COUNT(*) as cnt FROM memory_entries WHERE namespace = 'bulk_test_conflict'"
            )
            result = cur.fetchone()
            assert result["cnt"] == 100, f"Expected 100 total rows, got {result['cnt']}"

            logger.info("✓ Conflict skip test PASSED")
            return True

    except Exception as e:
        logger.error(f"✗ Conflict skip test FAILED: {e}")
        raise
    finally:
        # Cleanup
        with pools.project_cursor() as cur:
            cur.execute("DELETE FROM memory_entries WHERE namespace = 'bulk_test_conflict'")


def test_bulk_insert_conflict_update():
    """Test bulk insert with conflict resolution (update)."""
    logger.info("=" * 70)
    logger.info("TEST 3: Bulk insert with conflict (update)")
    logger.info("=" * 70)

    pools = get_pools()

    try:
        with pools.project_cursor() as cur:
            # Clean up
            cur.execute("DELETE FROM memory_entries WHERE namespace = 'bulk_test_update'")

            # First batch
            entries = generate_test_entries(50, "bulk_test_update")
            count1 = bulk_insert_memory_entries(cur, entries)
            assert count1 == 50, f"Expected 50 inserts, got {count1}"

            # Second batch with modified values
            entries2 = [
                {
                    **entry,
                    "value": f'UPDATED: {entry["value"]}',
                    "metadata": {"updated": True, "index": entry["metadata"]["index"]},
                }
                for entry in generate_test_entries(75, "bulk_test_update")
            ]

            count2 = bulk_insert_memory_entries(cur, entries2, on_conflict="update")

            # Verify total count (should have 75 entries total)
            cur.execute(
                "SELECT COUNT(*) as cnt FROM memory_entries WHERE namespace = 'bulk_test_update'"
            )
            result = cur.fetchone()
            assert result["cnt"] == 75, f"Expected 75 total rows, got {result['cnt']}"

            # Verify all entries have UPDATED prefix (all 75 were inserted/updated)
            cur.execute(
                """
                SELECT COUNT(*) as cnt
                FROM memory_entries
                WHERE namespace = 'bulk_test_update'
                  AND value LIKE 'UPDATED:%'
            """
            )
            result = cur.fetchone()
            assert result["cnt"] == 75, f"Expected 75 updated rows, got {result['cnt']}"

            logger.info("✓ Conflict update test PASSED")
            return True

    except Exception as e:
        logger.error(f"✗ Conflict update test FAILED: {e}")
        raise
    finally:
        # Cleanup
        with pools.project_cursor() as cur:
            cur.execute("DELETE FROM memory_entries WHERE namespace = 'bulk_test_update'")


def test_bulk_insert_validation():
    """Test input validation and error handling."""
    logger.info("=" * 70)
    logger.info("TEST 4: Input validation")
    logger.info("=" * 70)

    pools = get_pools()

    try:
        with pools.project_cursor() as cur:
            # Test empty entries
            try:
                bulk_insert_memory_entries(cur, [])
                assert False, "Should have raised ValueError for empty entries"
            except ValueError as e:
                logger.info(f"✓ Empty entries validation: {e}")

            # Test missing required fields
            try:
                invalid_entries = [{"namespace": "test"}]  # Missing key and value
                bulk_insert_memory_entries(cur, invalid_entries)
                assert False, "Should have raised ValueError for missing fields"
            except ValueError as e:
                logger.info(f"✓ Missing fields validation: {e}")

            # Test invalid embedding dimensions
            try:
                invalid_entries = [
                    {
                        "namespace": "test",
                        "key": "test",
                        "value": "test",
                        "embedding": [0.1] * 128,  # Wrong dimensions
                    }
                ]
                bulk_insert_memory_entries(cur, invalid_entries)
                assert False, "Should have raised InvalidEmbeddingError"
            except InvalidEmbeddingError as e:
                logger.info(f"✓ Invalid embedding validation: {e}")

            logger.info("✓ Validation test PASSED")
            return True

    except Exception as e:
        logger.error(f"✗ Validation test FAILED: {e}")
        raise


def benchmark_performance():
    """Benchmark bulk vs individual inserts."""
    logger.info("=" * 70)
    logger.info("BENCHMARK: Bulk vs Individual Inserts")
    logger.info("=" * 70)

    pools = get_pools()
    test_counts = [10, 100, 1000]

    for count in test_counts:
        logger.info(f"\nTesting with {count} entries:")
        logger.info("-" * 50)

        entries = generate_test_entries(count, f"bench_{count}")

        # Benchmark individual inserts
        try:
            with pools.project_cursor() as cur:
                cur.execute(f"DELETE FROM memory_entries WHERE namespace = 'bench_{count}'")

                start = time.time()
                for entry in entries:
                    store_memory(
                        cur,
                        entry["namespace"],
                        entry["key"],
                        entry["value"],
                        entry["embedding"],
                        entry["metadata"],
                        entry["tags"],
                    )
                individual_time = time.time() - start

                logger.info(
                    f"Individual INSERTs: {individual_time:.3f}s ({count/individual_time:.0f} entries/sec)"
                )
        except Exception as e:
            logger.error(f"Individual insert benchmark failed: {e}")
            individual_time = None

        # Benchmark bulk insert
        try:
            with pools.project_cursor() as cur:
                cur.execute(f"DELETE FROM memory_entries WHERE namespace = 'bench_{count}'")

                start = time.time()
                bulk_insert_memory_entries(cur, entries)
                bulk_time = time.time() - start

                logger.info(
                    f"Bulk COPY:          {bulk_time:.3f}s ({count/bulk_time:.0f} entries/sec)"
                )

                if individual_time:
                    speedup = individual_time / bulk_time
                    logger.info(f"Speedup:            {speedup:.1f}x faster")
        except Exception as e:
            logger.error(f"Bulk insert benchmark failed: {e}")

        # Cleanup
        with pools.project_cursor() as cur:
            cur.execute(f"DELETE FROM memory_entries WHERE namespace = 'bench_{count}'")


def test_bulk_patterns():
    """Test bulk insert for patterns table."""
    logger.info("=" * 70)
    logger.info("TEST 5: Bulk pattern inserts")
    logger.info("=" * 70)

    pools = get_pools()

    try:
        with pools.project_cursor() as cur:
            # Clean up
            cur.execute("DELETE FROM patterns WHERE pattern_type LIKE 'bulk_test_%'")

            # Generate test patterns matching actual schema
            patterns = [
                {
                    "name": f"bulk_test_pattern_{i}",
                    "pattern_type": f"bulk_test_type_{i % 5}",
                    "description": f"Test pattern {i} for bulk operations",
                    "embedding": [0.2 + i * 0.001] * 384,
                    "confidence": 0.5 + (i % 10) * 0.05,
                    "usage_count": i * 10,
                    "success_count": i * 8,
                    "metadata": {"complexity": i % 5, "category": "test", "batch": "bulk_test"},
                }
                for i in range(50)
            ]

            count = bulk_insert_patterns(cur, patterns)
            assert count == 50, f"Expected 50 inserts, got {count}"

            # Verify
            cur.execute(
                "SELECT COUNT(*) as cnt FROM patterns WHERE pattern_type LIKE 'bulk_test_%'"
            )
            result = cur.fetchone()
            assert result["cnt"] == 50, f"Expected 50 rows, got {result['cnt']}"

            logger.info("✓ Bulk pattern insert test PASSED")
            return True

    except Exception as e:
        logger.error(f"✗ Bulk pattern insert test FAILED: {e}")
        raise
    finally:
        # Cleanup
        with pools.project_cursor() as cur:
            cur.execute("DELETE FROM patterns WHERE pattern_type LIKE 'bulk_test_%'")


def test_bulk_trajectories():
    """Test bulk insert for trajectories table."""
    logger.info("=" * 70)
    logger.info("TEST 6: Bulk trajectory inserts")
    logger.info("=" * 70)

    pools = get_pools()

    try:
        with pools.project_cursor() as cur:
            # Clean up
            cur.execute("DELETE FROM trajectories WHERE trajectory_id LIKE 'bulk_test_%'")

            # Generate test trajectories matching actual schema (action is TEXT)
            trajectories = [
                {
                    "trajectory_id": f"bulk_test_traj_{i // 10}",
                    "step_number": i % 10,
                    "action": f"move_forward_speed_{i % 3}",
                    "state": {"position": i, "velocity": i * 0.5},
                    "reward": float(i % 5),
                    "embedding": [0.3 + i * 0.001] * 384,
                    "metadata": {"batch": "bulk_test", "index": i},
                }
                for i in range(100)
            ]

            count = bulk_insert_trajectories(cur, trajectories)
            assert count == 100, f"Expected 100 inserts, got {count}"

            # Verify
            cur.execute(
                "SELECT COUNT(*) as cnt FROM trajectories WHERE trajectory_id LIKE 'bulk_test_%'"
            )
            result = cur.fetchone()
            assert result["cnt"] == 100, f"Expected 100 rows, got {result['cnt']}"

            logger.info("✓ Bulk trajectory insert test PASSED")
            return True

    except Exception as e:
        logger.error(f"✗ Bulk trajectory insert test FAILED: {e}")
        raise
    finally:
        # Cleanup
        with pools.project_cursor() as cur:
            cur.execute("DELETE FROM trajectories WHERE trajectory_id LIKE 'bulk_test_%'")


def main():
    """Run all tests and benchmarks."""
    logger.info("\n" + "=" * 70)
    logger.info("BULK OPERATIONS TEST SUITE")
    logger.info("=" * 70 + "\n")

    try:
        # Run functional tests
        test_bulk_insert_basic()
        test_bulk_insert_conflict_skip()
        test_bulk_insert_conflict_update()
        test_bulk_insert_validation()
        test_bulk_patterns()
        test_bulk_trajectories()

        # Run performance benchmarks
        benchmark_performance()

        logger.info("\n" + "=" * 70)
        logger.info("ALL TESTS PASSED ✓")
        logger.info("=" * 70)

    except Exception as e:
        logger.error("\n" + "=" * 70)
        logger.error("TESTS FAILED ✗")
        logger.error(f"Error: {e}")
        logger.error("=" * 70)
        raise


if __name__ == "__main__":
    main()
