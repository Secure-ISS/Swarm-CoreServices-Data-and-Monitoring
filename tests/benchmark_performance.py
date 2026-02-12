#!/usr/bin/env python3
"""
Performance Validation Benchmark Suite

Validates all optimization features against ROI targets:
1. Bulk operations (2.6-5x speedup)
2. HNSW dual-profile strategy (2x under load)
3. Connection pool capacity (35+ concurrent agents)
4. Redis query caching (50-80% latency reduction)
5. Prepared statements (10-15% speedup)
6. Index monitoring (identify optimization opportunities)

Generates comprehensive performance report in tests/validation-performance.md
"""

# Standard library imports
import json
import logging
import os
import statistics
import sys
import time
from contextlib import contextmanager
from datetime import datetime
from typing import Any, Dict, List, Tuple

# Third-party imports
from dotenv import load_dotenv

# Add src to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

# Load environment variables
load_dotenv()

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# Local imports
from src.db.bulk_ops import bulk_insert_memory_entries, bulk_insert_patterns
from src.db.hnsw_profiles import PROFILES, HNSWProfileManager, ProfileType

# Import after logger is defined
from src.db.pool import get_pools
from src.db.vector_ops import search_memory, store_memory

# Optional imports
try:
    # Local imports
    from src.db.cache import VectorQueryCache

    REDIS_AVAILABLE = True
except ImportError:
    REDIS_AVAILABLE = False
    logger.warning("Redis module not available, cache benchmark will be skipped")

try:
    # Local imports
    from src.db.monitoring import IndexMonitor, initialize_prepared_statements

    MONITORING_AVAILABLE = True
except ImportError:
    MONITORING_AVAILABLE = False
    logger.warning("Monitoring module not available, some benchmarks will be skipped")


class PerformanceBenchmark:
    """Comprehensive performance benchmark suite."""

    def __init__(self):
        """Initialize benchmark environment."""
        self.pools = get_pools()
        self.results = {
            "timestamp": datetime.utcnow().isoformat(),
            "benchmarks": {},
            "summary": {},
            "target_validation": {},
        }

        # Test data
        self.test_vector = [0.1] * 384
        self.test_entries = []

        logger.info("Performance benchmark initialized")

    def generate_test_data(self, count: int = 1000) -> List[Dict[str, Any]]:
        """Generate test memory entries."""
        entries = []
        for i in range(count):
            entries.append(
                {
                    "namespace": "benchmark",
                    "key": f"test_entry_{i}",
                    "value": f"Test value {i} for performance benchmarking",
                    "embedding": [0.1 + (i * 0.001) for _ in range(384)],
                    "metadata": {"index": i, "batch": i // 100, "type": "benchmark"},
                    "tags": ["performance", "test", f"batch_{i // 100}"],
                }
            )
        return entries

    @contextmanager
    def timer(self, operation: str):
        """Time an operation."""
        start = time.perf_counter()
        yield
        elapsed = time.perf_counter() - start
        logger.info(f"{operation}: {elapsed:.3f}s")
        return elapsed

    def cleanup_test_data(self):
        """Clean up benchmark test data."""
        try:
            with self.pools.project_cursor() as cur:
                cur.execute("DELETE FROM memory_entries WHERE namespace = 'benchmark'")
                cur.execute("DELETE FROM patterns WHERE name LIKE 'bench_%'")
                deleted = cur.rowcount
                logger.info(f"Cleaned up {deleted} test entries")
        except Exception as e:
            logger.error(f"Cleanup failed: {e}")

    def benchmark_bulk_operations(self) -> Dict[str, Any]:
        """
        Benchmark 1: Bulk Operations (PostgreSQL COPY)
        Target: 2.6-5x speedup vs individual inserts
        """
        logger.info("\n=== BENCHMARK 1: Bulk Operations ===")

        count = 1000
        entries = self.generate_test_data(count)

        # Baseline: Individual inserts
        with self.pools.project_cursor() as cur:
            # Clean up
            cur.execute("DELETE FROM memory_entries WHERE namespace = 'benchmark'")

            individual_start = time.perf_counter()
            for entry in entries[:100]:  # Use subset for speed
                store_memory(
                    cur,
                    entry["namespace"],
                    entry["key"],
                    entry["value"],
                    entry["embedding"],
                    entry["metadata"],
                    entry["tags"],
                )
            individual_time = time.perf_counter() - individual_start
            individual_rate = 100 / individual_time

            # Clean for bulk test
            cur.execute("DELETE FROM memory_entries WHERE namespace = 'benchmark'")

        # Bulk insert
        with self.pools.project_cursor() as cur:
            bulk_start = time.perf_counter()
            inserted = bulk_insert_memory_entries(cur, entries)
            bulk_time = time.perf_counter() - bulk_start
            bulk_rate = inserted / bulk_time

        # Calculate speedup (extrapolate individual time for fair comparison)
        projected_individual_time = (individual_time / 100) * count
        speedup = projected_individual_time / bulk_time

        result = {
            "individual_100_time": round(individual_time, 3),
            "individual_rate": round(individual_rate, 1),
            "projected_1000_time": round(projected_individual_time, 3),
            "bulk_1000_time": round(bulk_time, 3),
            "bulk_rate": round(bulk_rate, 1),
            "speedup": round(speedup, 2),
            "target_min": 2.6,
            "target_max": 5.0,
            "achieved": speedup >= 2.6,
            "entries_inserted": inserted,
        }

        logger.info(f"Speedup: {speedup:.2f}x (target: 2.6-5x)")
        logger.info(f"Target achieved: {result['achieved']}")

        self.results["benchmarks"]["bulk_operations"] = result
        return result

    def benchmark_hnsw_profiles(self) -> Dict[str, Any]:
        """
        Benchmark 2: HNSW Dual-Profile Strategy
        Target: 2x speed improvement under load (SPEED vs ACCURACY profile)
        """
        logger.info("\n=== BENCHMARK 2: HNSW Profile Strategy ===")

        # Create profile manager
        manager = HNSWProfileManager(self.pools.project_pool, schema="public", auto_adjust=False)

        # Insert test data for searching
        entries = self.generate_test_data(500)
        with self.pools.project_cursor() as cur:
            cur.execute("DELETE FROM memory_entries WHERE namespace = 'benchmark'")
            bulk_insert_memory_entries(cur, entries)

        # Test query
        query_vector = [0.15] * 384
        num_queries = 50

        # Benchmark ACCURACY profile
        manager.switch_profile(ProfileType.ACCURACY, "Benchmark test")
        accuracy_times = []
        for _ in range(num_queries):
            start = time.perf_counter()
            with self.pools.project_cursor() as cur:
                results = search_memory(cur, "benchmark", query_vector, limit=10)
            accuracy_times.append(time.perf_counter() - start)

        # Benchmark SPEED profile
        manager.switch_profile(ProfileType.SPEED, "Benchmark test")
        speed_times = []
        for _ in range(num_queries):
            start = time.perf_counter()
            with self.pools.project_cursor() as cur:
                results = search_memory(cur, "benchmark", query_vector, limit=10)
            speed_times.append(time.perf_counter() - start)

        # Calculate statistics
        accuracy_avg = statistics.mean(accuracy_times) * 1000  # ms
        speed_avg = statistics.mean(speed_times) * 1000  # ms
        speedup = accuracy_avg / speed_avg

        result = {
            "accuracy_profile": {
                "avg_latency_ms": round(accuracy_avg, 2),
                "min_latency_ms": round(min(accuracy_times) * 1000, 2),
                "max_latency_ms": round(max(accuracy_times) * 1000, 2),
                "ef_search": PROFILES[ProfileType.ACCURACY].ef_search,
            },
            "speed_profile": {
                "avg_latency_ms": round(speed_avg, 2),
                "min_latency_ms": round(min(speed_times) * 1000, 2),
                "max_latency_ms": round(max(speed_times) * 1000, 2),
                "ef_search": PROFILES[ProfileType.SPEED].ef_search,
            },
            "speedup": round(speedup, 2),
            "target": 2.0,
            "achieved": speedup >= 2.0,
            "queries_tested": num_queries,
        }

        logger.info(f"ACCURACY avg: {accuracy_avg:.2f}ms")
        logger.info(f"SPEED avg: {speed_avg:.2f}ms")
        logger.info(f"Speedup: {speedup:.2f}x (target: 2x)")
        logger.info(f"Target achieved: {result['achieved']}")

        # Reset to balanced
        manager.switch_profile(ProfileType.BALANCED, "Reset after benchmark")

        self.results["benchmarks"]["hnsw_profiles"] = result
        return result

    def benchmark_connection_pool(self) -> Dict[str, Any]:
        """
        Benchmark 3: Connection Pool Capacity
        Target: Support 35+ concurrent agents (25 base + 10 burst)
        """
        logger.info("\n=== BENCHMARK 3: Connection Pool Capacity ===")

        # Standard library imports
        import queue
        import threading

        # Test concurrent connections
        max_concurrent = 40  # Test beyond target
        connection_queue = queue.Queue()
        errors = []

        def get_connection(thread_id):
            """Simulate agent acquiring connection."""
            try:
                with self.pools.project_cursor() as cur:
                    cur.execute("SELECT 1")
                    connection_queue.put(
                        {"thread_id": thread_id, "success": True, "timestamp": time.time()}
                    )
                    time.sleep(0.1)  # Hold connection briefly
            except Exception as e:
                errors.append({"thread_id": thread_id, "error": str(e)})
                connection_queue.put({"thread_id": thread_id, "success": False, "error": str(e)})

        # Spawn concurrent threads
        start_time = time.time()
        threads = []
        for i in range(max_concurrent):
            thread = threading.Thread(target=get_connection, args=(i,))
            threads.append(thread)
            thread.start()

        # Wait for all threads
        for thread in threads:
            thread.join(timeout=5)

        elapsed = time.time() - start_time

        # Collect results
        results = []
        while not connection_queue.empty():
            results.append(connection_queue.get())

        successful = sum(1 for r in results if r.get("success", False))
        failed = len(errors)

        result = {
            "max_concurrent_tested": max_concurrent,
            "successful_connections": successful,
            "failed_connections": failed,
            "success_rate": round(successful / max_concurrent * 100, 2),
            "total_time": round(elapsed, 3),
            "target_capacity": 35,
            "achieved": successful >= 35,
            "pool_config": {
                "project_minconn": 1,
                "project_maxconn": 10,
                "shared_minconn": 1,
                "shared_maxconn": 5,
                "total_capacity": 15,
            },
        }

        logger.info(f"Successful: {successful}/{max_concurrent}")
        logger.info(f"Success rate: {result['success_rate']}%")
        logger.info(f"Target achieved (35+): {result['achieved']}")

        if errors:
            logger.warning(f"Errors encountered: {len(errors)}")
            result["errors"] = errors[:5]  # Include sample

        self.results["benchmarks"]["connection_pool"] = result
        return result

    def benchmark_redis_cache(self) -> Dict[str, Any]:
        """
        Benchmark 4: Redis Query Caching
        Target: 50-80% latency reduction for repeated queries
        """
        logger.info("\n=== BENCHMARK 4: Redis Query Caching ===")

        if not REDIS_AVAILABLE:
            logger.warning("Redis module not available, skipping cache benchmark")
            return {"status": "skipped", "reason": "Redis module not installed"}

        try:
            cache = VectorQueryCache(host="localhost", port=6379, default_ttl=300)

            if cache.redis is None:
                logger.warning("Redis not available, skipping cache benchmark")
                return {"status": "skipped", "reason": "Redis not available"}

            # Prepare test data
            query_vector = [0.2] * 384
            num_queries = 100

            # Uncached queries (baseline)
            uncached_times = []
            for i in range(num_queries):
                start = time.perf_counter()
                with self.pools.project_cursor() as cur:
                    results = search_memory(cur, "benchmark", query_vector, limit=10)
                uncached_times.append(time.perf_counter() - start)

            # Cached queries
            # Simulate cache decorator
            def cached_search():
                cache_key = f"bench_search_{hash(tuple(query_vector))}"
                cached_result = cache.redis.get(cache_key)
                if cached_result:
                    return json.loads(cached_result)

                with self.pools.project_cursor() as cur:
                    results = search_memory(cur, "benchmark", query_vector, limit=10)
                cache.redis.setex(cache_key, 300, json.dumps(results, default=str))
                return results

            cached_times = []
            for i in range(num_queries):
                start = time.perf_counter()
                results = cached_search()
                cached_times.append(time.perf_counter() - start)

            # Calculate statistics
            uncached_avg = statistics.mean(uncached_times) * 1000
            cached_avg = statistics.mean(cached_times) * 1000
            reduction = (1 - (cached_avg / uncached_avg)) * 100

            result = {
                "uncached_avg_ms": round(uncached_avg, 3),
                "cached_avg_ms": round(cached_avg, 3),
                "latency_reduction_pct": round(reduction, 2),
                "target_min": 50,
                "target_max": 80,
                "achieved": reduction >= 50,
                "queries_tested": num_queries,
                "cache_stats": cache.get_stats(),
            }

            logger.info(f"Uncached avg: {uncached_avg:.3f}ms")
            logger.info(f"Cached avg: {cached_avg:.3f}ms")
            logger.info(f"Latency reduction: {reduction:.2f}% (target: 50-80%)")
            logger.info(f"Target achieved: {result['achieved']}")

            self.results["benchmarks"]["redis_cache"] = result
            return result

        except Exception as e:
            logger.error(f"Redis cache benchmark failed: {e}")
            return {"status": "error", "error": str(e)}

    def benchmark_prepared_statements(self) -> Dict[str, Any]:
        """
        Benchmark 5: Prepared Statements
        Target: 10-15% speedup for repeated queries
        """
        logger.info("\n=== BENCHMARK 5: Prepared Statements ===")

        num_queries = 1000

        # Baseline: Regular queries
        regular_start = time.perf_counter()
        with self.pools.project_cursor() as cur:
            for i in range(num_queries):
                cur.execute(
                    """
                    SELECT namespace, key, value
                    FROM memory_entries
                    WHERE namespace = %s
                    LIMIT 10
                """,
                    ("benchmark",),
                )
                cur.fetchall()
        regular_time = time.perf_counter() - regular_start

        # Prepared statement
        with self.pools.project_cursor() as cur:
            # Prepare statement
            cur.execute(
                """
                PREPARE bench_query (TEXT) AS
                SELECT namespace, key, value
                FROM memory_entries
                WHERE namespace = $1
                LIMIT 10
            """
            )

            prepared_start = time.perf_counter()
            for i in range(num_queries):
                cur.execute("EXECUTE bench_query(%s)", ("benchmark",))
                cur.fetchall()
            prepared_time = time.perf_counter() - prepared_start

            # Clean up
            cur.execute("DEALLOCATE bench_query")

        # Calculate speedup
        speedup_pct = ((regular_time - prepared_time) / regular_time) * 100

        result = {
            "regular_time": round(regular_time, 3),
            "prepared_time": round(prepared_time, 3),
            "speedup_pct": round(speedup_pct, 2),
            "target_min": 10,
            "target_max": 15,
            "achieved": speedup_pct >= 10,
            "queries_tested": num_queries,
        }

        logger.info(f"Regular: {regular_time:.3f}s")
        logger.info(f"Prepared: {prepared_time:.3f}s")
        logger.info(f"Speedup: {speedup_pct:.2f}% (target: 10-15%)")
        logger.info(f"Target achieved: {result['achieved']}")

        self.results["benchmarks"]["prepared_statements"] = result
        return result

    def benchmark_index_monitoring(self) -> Dict[str, Any]:
        """
        Benchmark 6: Index Monitoring
        Target: Identify unused/missing indexes
        """
        logger.info("\n=== BENCHMARK 6: Index Monitoring ===")

        if not MONITORING_AVAILABLE:
            logger.warning("Monitoring module not available, skipping index monitoring")
            return {"status": "skipped", "reason": "Monitoring module has issues"}

        monitor = IndexMonitor(self.pools)

        # Get index statistics
        stats = monitor.get_index_statistics()
        unused = monitor.get_unused_indexes(min_size_mb=0.1)
        missing = monitor.get_missing_indexes(min_seq_scans=10)

        result = {
            "total_indexes": stats["total_indexes"],
            "total_size_mb": stats["total_size_mb"],
            "unused_count": stats["unused_count"],
            "unused_size_mb": stats["unused_size_mb"],
            "unused_percentage": stats["unused_percentage"],
            "tables_needing_indexes": len(missing),
            "optimization_opportunities": {
                "unused_indexes": len(unused),
                "missing_indexes": len(missing),
                "wasted_space_mb": stats["unused_size_mb"],
            },
            "top_indexes": stats["top_indexes"][:5],
        }

        logger.info(f"Total indexes: {stats['total_indexes']}")
        logger.info(f"Unused indexes: {stats['unused_count']} ({stats['unused_size_mb']:.2f} MB)")
        logger.info(f"Tables needing indexes: {len(missing)}")

        if unused:
            logger.info(f"Unused indexes found: {[idx['indexname'] for idx in unused[:5]]}")

        self.results["benchmarks"]["index_monitoring"] = result
        return result

    def generate_summary(self):
        """Generate benchmark summary."""
        benchmarks = self.results["benchmarks"]

        summary = {
            "total_benchmarks": len(benchmarks),
            "targets_achieved": sum(
                1 for b in benchmarks.values() if isinstance(b, dict) and b.get("achieved", False)
            ),
            "key_metrics": {},
        }

        # Extract key metrics
        if "bulk_operations" in benchmarks:
            summary["key_metrics"]["bulk_speedup"] = benchmarks["bulk_operations"]["speedup"]

        if "hnsw_profiles" in benchmarks:
            summary["key_metrics"]["hnsw_speedup"] = benchmarks["hnsw_profiles"]["speedup"]

        if "connection_pool" in benchmarks:
            summary["key_metrics"]["max_concurrent"] = benchmarks["connection_pool"][
                "successful_connections"
            ]

        if "redis_cache" in benchmarks and "latency_reduction_pct" in benchmarks["redis_cache"]:
            summary["key_metrics"]["cache_reduction"] = benchmarks["redis_cache"][
                "latency_reduction_pct"
            ]

        if "prepared_statements" in benchmarks:
            summary["key_metrics"]["prepared_speedup"] = benchmarks["prepared_statements"][
                "speedup_pct"
            ]

        self.results["summary"] = summary

    def generate_report(self, output_file: str = "tests/validation-performance.md"):
        """Generate markdown performance report."""
        report = []

        report.append("# Performance Validation Report\n")
        report.append(f"**Generated:** {self.results['timestamp']}\n")
        report.append(f"**Total Benchmarks:** {self.results['summary']['total_benchmarks']}\n")
        report.append(
            f"**Targets Achieved:** {self.results['summary']['targets_achieved']}/{self.results['summary']['total_benchmarks']}\n"
        )

        report.append("\n## Executive Summary\n")
        metrics = self.results["summary"]["key_metrics"]
        report.append(
            f"- **Bulk Operations:** {metrics.get('bulk_speedup', 'N/A')}x speedup (target: 2.6-5x)\n"
        )
        report.append(
            f"- **HNSW Profiles:** {metrics.get('hnsw_speedup', 'N/A')}x speedup (target: 2x)\n"
        )
        report.append(
            f"- **Connection Pool:** {metrics.get('max_concurrent', 'N/A')} concurrent (target: 35+)\n"
        )
        report.append(
            f"- **Redis Cache:** {metrics.get('cache_reduction', 'N/A')}% reduction (target: 50-80%)\n"
        )
        report.append(
            f"- **Prepared Statements:** {metrics.get('prepared_speedup', 'N/A')}% speedup (target: 10-15%)\n"
        )

        # Detailed results
        report.append("\n## Detailed Benchmark Results\n")

        for name, data in self.results["benchmarks"].items():
            report.append(f"\n### {name.replace('_', ' ').title()}\n")

            if isinstance(data, dict):
                if data.get("status") == "skipped":
                    report.append(f"**Status:** Skipped - {data.get('reason')}\n")
                    continue

                if data.get("status") == "error":
                    report.append(f"**Status:** Error - {data.get('error')}\n")
                    continue

                # Format data as table
                report.append("```\n")
                for key, value in data.items():
                    if isinstance(value, dict):
                        report.append(f"{key}:\n")
                        for k, v in value.items():
                            report.append(f"  {k}: {v}\n")
                    else:
                        report.append(f"{key}: {value}\n")
                report.append("```\n")

                # Validation status
                if "achieved" in data:
                    status = "✅ PASSED" if data["achieved"] else "❌ FAILED"
                    report.append(f"\n**Validation:** {status}\n")

        # Recommendations
        report.append("\n## Recommendations\n")

        bulk_result = self.results["benchmarks"].get("bulk_operations", {})
        if bulk_result.get("speedup", 0) < 2.6:
            report.append(
                "- ⚠️ Bulk operations below target. Consider optimizing COPY protocol or buffer sizes.\n"
            )

        hnsw_result = self.results["benchmarks"].get("hnsw_profiles", {})
        if hnsw_result.get("speedup", 0) < 2.0:
            report.append("- ⚠️ HNSW profiles below target. Consider tuning ef_search parameters.\n")

        pool_result = self.results["benchmarks"].get("connection_pool", {})
        if pool_result.get("successful_connections", 0) < 35:
            report.append(
                "- ⚠️ Connection pool below target. Consider increasing maxconn settings.\n"
            )

        cache_result = self.results["benchmarks"].get("redis_cache", {})
        if cache_result.get("status") == "skipped":
            report.append("- ℹ️ Redis cache not tested. Consider deploying Redis for production.\n")

        index_result = self.results["benchmarks"].get("index_monitoring", {})
        if index_result.get("unused_count", 0) > 0:
            report.append(
                f"- 🔍 Found {index_result['unused_count']} unused indexes. Consider dropping to free space.\n"
            )

        # Write report
        output_path = os.path.join(os.path.dirname(__file__), "..", output_file)
        os.makedirs(os.path.dirname(output_path), exist_ok=True)

        with open(output_path, "w") as f:
            f.write("".join(report))

        logger.info(f"Report written to: {output_path}")
        return output_path

    def run_all(self):
        """Run all benchmarks."""
        logger.info("Starting comprehensive performance validation...")

        try:
            # Run benchmarks
            self.benchmark_bulk_operations()
            self.benchmark_hnsw_profiles()
            self.benchmark_connection_pool()
            self.benchmark_redis_cache()
            self.benchmark_prepared_statements()
            self.benchmark_index_monitoring()

            # Generate summary and report
            self.generate_summary()
            report_path = self.generate_report()

            logger.info("\n" + "=" * 70)
            logger.info("PERFORMANCE VALIDATION COMPLETE")
            logger.info("=" * 70)
            logger.info(f"Report: {report_path}")
            logger.info(
                f"Targets achieved: {self.results['summary']['targets_achieved']}/{self.results['summary']['total_benchmarks']}"
            )

        finally:
            # Cleanup
            self.cleanup_test_data()


if __name__ == "__main__":
    benchmark = PerformanceBenchmark()
    benchmark.run_all()
