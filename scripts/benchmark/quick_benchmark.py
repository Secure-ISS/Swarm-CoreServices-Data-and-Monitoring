#!/usr/bin/env python3
"""Quick Database Performance Benchmark

Runs lightweight performance tests to validate production readiness.
"""

# Standard library imports
import os
import sys
import time
from pathlib import Path

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

# Third-party imports
from dotenv import load_dotenv

# Local imports
from src.db.pool import DualDatabasePools

# Load environment
env_path = Path(__file__).parent.parent.parent / ".env"
if env_path.exists():
    load_dotenv(env_path)


def benchmark_simple_query(pools: DualDatabasePools, iterations: int = 100):
    """Benchmark simple SELECT queries."""
    print(f"\n[1/4] Simple query benchmark ({iterations} iterations)")

    times = []
    with pools.project_cursor() as cur:
        for i in range(iterations):
            start = time.perf_counter()
            cur.execute("SELECT 1;")
            cur.fetchone()
            elapsed = (time.perf_counter() - start) * 1000
            times.append(elapsed)

            if i % 20 == 0:
                print(f"  Progress: {i}/{iterations}")

    avg_time = sum(times) / len(times)
    p95_time = sorted(times)[int(len(times) * 0.95)]
    p99_time = sorted(times)[int(len(times) * 0.99)]

    print(f"  Average: {avg_time:.2f}ms")
    print(f"  P95: {p95_time:.2f}ms")
    print(f"  P99: {p99_time:.2f}ms")

    return avg_time


def benchmark_vector_search(pools: DualDatabasePools, iterations: int = 50):
    """Benchmark RuVector search operations."""
    print(f"\n[2/4] Vector search benchmark ({iterations} iterations)")

    # Create test vector if not exists
    with pools.project_cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS benchmark_vectors (
                id SERIAL PRIMARY KEY,
                embedding ruvector(128)
            );
        """
        )

        # Insert test data if empty
        cur.execute("SELECT COUNT(*) FROM benchmark_vectors;")
        count = cur.fetchone()["count"]

        if count == 0:
            print("  Inserting test vectors...")
            for i in range(100):
                # Create random vector
                vector = f"[{','.join(['0.1'] * 128)}]"
                cur.execute("INSERT INTO benchmark_vectors (embedding) VALUES (%s);", (vector,))

        # Create HNSW index if not exists
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS benchmark_vectors_hnsw_idx
            ON benchmark_vectors
            USING hnsw (embedding ruvector_cosine_ops)
            WITH (m = 16, ef_construction = 100);
        """
        )

    times = []
    query_vector = f"[{','.join(['0.1'] * 128)}]"

    with pools.project_cursor() as cur:
        for i in range(iterations):
            start = time.perf_counter()
            cur.execute(
                """
                SELECT id, embedding <-> %s::ruvector AS distance
                FROM benchmark_vectors
                ORDER BY embedding <-> %s::ruvector
                LIMIT 10;
            """,
                (query_vector, query_vector),
            )
            cur.fetchall()
            elapsed = (time.perf_counter() - start) * 1000
            times.append(elapsed)

            if i % 10 == 0:
                print(f"  Progress: {i}/{iterations}")

    avg_time = sum(times) / len(times)
    p95_time = sorted(times)[int(len(times) * 0.95)]
    p99_time = sorted(times)[int(len(times) * 0.99)]

    print(f"  Average: {avg_time:.2f}ms")
    print(f"  P95: {p95_time:.2f}ms")
    print(f"  P99: {p99_time:.2f}ms")

    # Cleanup
    with pools.project_cursor() as cur:
        cur.execute("DROP TABLE IF EXISTS benchmark_vectors;")

    return avg_time


def benchmark_connection_pool(pools: DualDatabasePools, iterations: int = 20):
    """Benchmark connection pool performance."""
    print(f"\n[3/4] Connection pool benchmark ({iterations} iterations)")

    times = []
    failures = 0

    for i in range(iterations):
        try:
            start = time.perf_counter()
            with pools.project_cursor() as cur:
                cur.execute("SELECT pg_sleep(0.01);")  # 10ms query
            elapsed = (time.perf_counter() - start) * 1000
            times.append(elapsed)

            if i % 5 == 0:
                print(f"  Progress: {i}/{iterations}")

        except Exception as e:
            failures += 1
            print(f"  ✗ Connection failed: {e}")

    if times:
        avg_time = sum(times) / len(times)
        success_rate = ((iterations - failures) / iterations) * 100
        print(f"  Average: {avg_time:.2f}ms")
        print(f"  Success rate: {success_rate:.1f}%")
        return avg_time, success_rate
    else:
        print(f"  ✗ All connections failed")
        return 0, 0


def benchmark_database_size(pools: DualDatabasePools):
    """Get database size information."""
    print(f"\n[4/4] Database size metrics")

    with pools.project_cursor() as cur:
        # Database size
        cur.execute("SELECT pg_size_pretty(pg_database_size(current_database())) AS size;")
        db_size = cur.fetchone()["size"]
        print(f"  Database size: {db_size}")

        # Table sizes
        cur.execute(
            """
            SELECT
                schemaname,
                tablename,
                pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
            FROM pg_tables
            WHERE schemaname IN ('public', 'claude_flow')
            ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
            LIMIT 5;
        """
        )

        print("  Largest tables:")
        for row in cur.fetchall():
            print(f"    {row['schemaname']}.{row['tablename']}: {row['size']}")

        # Index count
        cur.execute(
            """
            SELECT COUNT(*) as count
            FROM pg_indexes
            WHERE schemaname IN ('public', 'claude_flow');
        """
        )
        index_count = cur.fetchone()["count"]
        print(f"  Total indexes: {index_count}")

        # HNSW index count
        cur.execute(
            """
            SELECT COUNT(*) as count
            FROM pg_indexes
            WHERE schemaname IN ('public', 'claude_flow')
              AND indexdef LIKE '%hnsw%';
        """
        )
        hnsw_count = cur.fetchone()["count"]
        print(f"  HNSW indexes: {hnsw_count}")


def main():
    """Run all benchmarks."""
    print("=" * 60)
    print("Database Performance Benchmark")
    print("=" * 60)

    try:
        pools = DualDatabasePools()
        print("✓ Connected to database")

        # Run benchmarks
        simple_avg = benchmark_simple_query(pools)
        vector_avg = benchmark_vector_search(pools)
        pool_avg, pool_success = benchmark_connection_pool(pools)
        benchmark_database_size(pools)

        # Summary
        print("\n" + "=" * 60)
        print("Benchmark Summary")
        print("=" * 60)
        print(f"Simple query average: {simple_avg:.2f}ms")
        print(f"Vector search average: {vector_avg:.2f}ms")
        print(f"Connection pool average: {pool_avg:.2f}ms")
        print(f"Connection pool success: {pool_success:.1f}%")

        # Evaluate results
        print("\n" + "=" * 60)
        print("Production Readiness Assessment")
        print("=" * 60)

        all_pass = True

        if simple_avg < 10:
            print("✓ Simple queries: PASS (<10ms)")
        else:
            print(f"✗ Simple queries: FAIL ({simple_avg:.2f}ms ≥10ms)")
            all_pass = False

        if vector_avg < 50:
            print("✓ Vector search: PASS (<50ms)")
        else:
            print(f"⚠ Vector search: WARN ({vector_avg:.2f}ms ≥50ms)")

        if pool_success >= 95:
            print(f"✓ Connection pool: PASS ({pool_success:.1f}% success)")
        else:
            print(f"✗ Connection pool: FAIL ({pool_success:.1f}% <95%)")
            all_pass = False

        if all_pass:
            print("\n🎉 All benchmarks passed - production ready!")
            return 0
        else:
            print("\n⚠ Some benchmarks failed - review before production")
            return 1

    except Exception as e:
        print(f"\n✗ Benchmark failed: {e}")
        return 1
    finally:
        if "pools" in locals():
            pools.close()


if __name__ == "__main__":
    sys.exit(main())
