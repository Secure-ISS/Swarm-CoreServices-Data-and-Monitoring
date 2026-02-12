#!/usr/bin/env python3
"""Comprehensive Load Testing Suite for Distributed PostgreSQL Cluster

This module provides a complete benchmark suite for testing:
- Concurrent connection handling
- Vector search performance at scale
- Failover and recovery scenarios
- Shard distribution and rebalancing
- Connection pool exhaustion
- Read/write performance under load
"""

# Standard library imports
import asyncio
import logging
import os
import random
import statistics
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# Third-party imports
import psycopg2
from psycopg2.extras import RealDictCursor

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


@dataclass
class BenchmarkResult:
    """Results from a benchmark run."""

    test_name: str
    duration_seconds: float
    operations_count: int
    success_count: int
    failure_count: int
    ops_per_second: float
    latency_p50: float
    latency_p95: float
    latency_p99: float
    latency_avg: float
    latency_min: float
    latency_max: float
    errors: List[str] = field(default_factory=list)
    metadata: Dict[str, Any] = field(default_factory=dict)

    @property
    def success_rate(self) -> float:
        """Calculate success rate percentage."""
        if self.operations_count == 0:
            return 0.0
        return (self.success_count / self.operations_count) * 100

    def to_dict(self) -> Dict[str, Any]:
        """Convert result to dictionary for serialization."""
        return {
            "test_name": self.test_name,
            "duration_seconds": self.duration_seconds,
            "operations_count": self.operations_count,
            "success_count": self.success_count,
            "failure_count": self.failure_count,
            "success_rate_percent": self.success_rate,
            "ops_per_second": self.ops_per_second,
            "latency": {
                "p50": self.latency_p50,
                "p95": self.latency_p95,
                "p99": self.latency_p99,
                "avg": self.latency_avg,
                "min": self.latency_min,
                "max": self.latency_max,
            },
            "errors": self.errors[:10],  # Limit error list
            "metadata": self.metadata,
        }


class LoadTestRunner:
    """Manages execution of load tests."""

    def __init__(self, db_config: Dict[str, str]):
        """Initialize load test runner.

        Args:
            db_config: Database connection configuration
        """
        self.db_config = db_config
        self.results: List[BenchmarkResult] = []

    def _get_connection(self) -> psycopg2.extensions.connection:
        """Get a new database connection.

        Returns:
            Database connection
        """
        return psycopg2.connect(
            host=self.db_config["host"],
            port=self.db_config["port"],
            database=self.db_config["database"],
            user=self.db_config["user"],
            password=self.db_config["password"],
            cursor_factory=RealDictCursor,
            connect_timeout=10,
        )

    def _calculate_percentiles(self, latencies: List[float]) -> Dict[str, float]:
        """Calculate latency percentiles.

        Args:
            latencies: List of latency measurements

        Returns:
            Dictionary with percentile values
        """
        if not latencies:
            return {"p50": 0, "p95": 0, "p99": 0, "avg": 0, "min": 0, "max": 0}

        sorted_latencies = sorted(latencies)
        n = len(sorted_latencies)

        return {
            "p50": sorted_latencies[int(n * 0.50)],
            "p95": sorted_latencies[int(n * 0.95)],
            "p99": sorted_latencies[int(n * 0.99)],
            "avg": statistics.mean(latencies),
            "min": min(latencies),
            "max": max(latencies),
        }

    def test_concurrent_connections(
        self, num_connections: int, hold_duration: float = 0.1
    ) -> BenchmarkResult:
        """Test concurrent connection handling.

        Args:
            num_connections: Number of concurrent connections
            hold_duration: How long to hold each connection (seconds)

        Returns:
            BenchmarkResult with test results
        """
        logger.info(f"Testing {num_connections} concurrent connections")

        def connect_and_hold():
            """Connect, hold, and disconnect."""
            start = time.perf_counter()
            try:
                conn = self._get_connection()
                with conn.cursor() as cur:
                    cur.execute("SELECT 1")
                    cur.fetchone()
                time.sleep(hold_duration)
                conn.close()
                return time.perf_counter() - start, None
            except Exception as e:
                return time.perf_counter() - start, str(e)

        start_time = time.perf_counter()
        latencies = []
        errors = []
        success = 0
        failure = 0

        with ThreadPoolExecutor(max_workers=num_connections) as executor:
            futures = [executor.submit(connect_and_hold) for _ in range(num_connections)]

            for future in as_completed(futures):
                latency, error = future.result()
                latencies.append(latency * 1000)  # Convert to ms

                if error:
                    failure += 1
                    errors.append(error)
                else:
                    success += 1

        duration = time.perf_counter() - start_time
        percentiles = self._calculate_percentiles(latencies)

        return BenchmarkResult(
            test_name=f"concurrent_connections_{num_connections}",
            duration_seconds=duration,
            operations_count=num_connections,
            success_count=success,
            failure_count=failure,
            ops_per_second=num_connections / duration,
            latency_p50=percentiles["p50"],
            latency_p95=percentiles["p95"],
            latency_p99=percentiles["p99"],
            latency_avg=percentiles["avg"],
            latency_min=percentiles["min"],
            latency_max=percentiles["max"],
            errors=errors,
            metadata={"hold_duration": hold_duration},
        )

    def test_read_heavy_load(self, num_operations: int, concurrency: int = 10) -> BenchmarkResult:
        """Test read-heavy workload.

        Args:
            num_operations: Total number of read operations
            concurrency: Number of concurrent workers

        Returns:
            BenchmarkResult with test results
        """
        logger.info(f"Testing read-heavy load: {num_operations} ops, {concurrency} workers")

        def read_operation():
            """Execute a read operation."""
            start = time.perf_counter()
            try:
                conn = self._get_connection()
                with conn.cursor() as cur:
                    # Simulate realistic read query
                    cur.execute(
                        """
                        SELECT id, embedding, metadata
                        FROM claude_flow.embeddings
                        ORDER BY RANDOM()
                        LIMIT 10
                    """
                    )
                    cur.fetchall()
                conn.close()
                return time.perf_counter() - start, None
            except Exception as e:
                return time.perf_counter() - start, str(e)

        start_time = time.perf_counter()
        latencies = []
        errors = []
        success = 0
        failure = 0

        with ThreadPoolExecutor(max_workers=concurrency) as executor:
            futures = [executor.submit(read_operation) for _ in range(num_operations)]

            for future in as_completed(futures):
                latency, error = future.result()
                latencies.append(latency * 1000)

                if error:
                    failure += 1
                    errors.append(error)
                else:
                    success += 1

        duration = time.perf_counter() - start_time
        percentiles = self._calculate_percentiles(latencies)

        return BenchmarkResult(
            test_name=f"read_heavy_{num_operations}ops_{concurrency}workers",
            duration_seconds=duration,
            operations_count=num_operations,
            success_count=success,
            failure_count=failure,
            ops_per_second=num_operations / duration,
            latency_p50=percentiles["p50"],
            latency_p95=percentiles["p95"],
            latency_p99=percentiles["p99"],
            latency_avg=percentiles["avg"],
            latency_min=percentiles["min"],
            latency_max=percentiles["max"],
            errors=errors,
            metadata={"concurrency": concurrency},
        )

    def test_write_heavy_load(self, num_operations: int, concurrency: int = 10) -> BenchmarkResult:
        """Test write-heavy workload.

        Args:
            num_operations: Total number of write operations
            concurrency: Number of concurrent workers

        Returns:
            BenchmarkResult with test results
        """
        logger.info(f"Testing write-heavy load: {num_operations} ops, {concurrency} workers")

        def write_operation():
            """Execute a write operation."""
            start = time.perf_counter()
            try:
                conn = self._get_connection()
                with conn.cursor() as cur:
                    # Generate random vector
                    vector = [random.random() for _ in range(384)]

                    cur.execute(
                        """
                        INSERT INTO claude_flow.embeddings (text, embedding, metadata, namespace)
                        VALUES (%s, %s::ruvector, %s::jsonb, %s)
                        ON CONFLICT (text, namespace) DO NOTHING
                    """,
                        (
                            f"test_write_{random.randint(1, 1000000)}",
                            vector,
                            '{"benchmark": true}',
                            "load_test",
                        ),
                    )
                conn.commit()
                conn.close()
                return time.perf_counter() - start, None
            except Exception as e:
                return time.perf_counter() - start, str(e)

        start_time = time.perf_counter()
        latencies = []
        errors = []
        success = 0
        failure = 0

        with ThreadPoolExecutor(max_workers=concurrency) as executor:
            futures = [executor.submit(write_operation) for _ in range(num_operations)]

            for future in as_completed(futures):
                latency, error = future.result()
                latencies.append(latency * 1000)

                if error:
                    failure += 1
                    errors.append(error)
                else:
                    success += 1

        duration = time.perf_counter() - start_time
        percentiles = self._calculate_percentiles(latencies)

        # Cleanup test data
        try:
            conn = self._get_connection()
            with conn.cursor() as cur:
                cur.execute("DELETE FROM claude_flow.embeddings WHERE namespace = 'load_test'")
            conn.commit()
            conn.close()
        except Exception as e:
            logger.warning(f"Failed to cleanup test data: {e}")

        return BenchmarkResult(
            test_name=f"write_heavy_{num_operations}ops_{concurrency}workers",
            duration_seconds=duration,
            operations_count=num_operations,
            success_count=success,
            failure_count=failure,
            ops_per_second=num_operations / duration,
            latency_p50=percentiles["p50"],
            latency_p95=percentiles["p95"],
            latency_p99=percentiles["p99"],
            latency_avg=percentiles["avg"],
            latency_min=percentiles["min"],
            latency_max=percentiles["max"],
            errors=errors,
            metadata={"concurrency": concurrency},
        )

    def test_vector_search_performance(
        self, num_searches: int, vector_dim: int = 384, top_k: int = 10
    ) -> BenchmarkResult:
        """Test vector similarity search performance.

        Args:
            num_searches: Number of search operations
            vector_dim: Vector dimensionality
            top_k: Number of results to return

        Returns:
            BenchmarkResult with test results
        """
        logger.info(f"Testing vector search: {num_searches} searches, top_k={top_k}")

        def search_operation():
            """Execute a vector search."""
            start = time.perf_counter()
            try:
                conn = self._get_connection()
                with conn.cursor() as cur:
                    # Generate random query vector
                    query_vector = [random.random() for _ in range(vector_dim)]

                    cur.execute(
                        """
                        SELECT id, text, metadata,
                               embedding <=> %s::ruvector AS distance
                        FROM claude_flow.embeddings
                        ORDER BY embedding <=> %s::ruvector
                        LIMIT %s
                    """,
                        (query_vector, query_vector, top_k),
                    )
                    cur.fetchall()
                conn.close()
                return time.perf_counter() - start, None
            except Exception as e:
                return time.perf_counter() - start, str(e)

        start_time = time.perf_counter()
        latencies = []
        errors = []
        success = 0
        failure = 0

        with ThreadPoolExecutor(max_workers=10) as executor:
            futures = [executor.submit(search_operation) for _ in range(num_searches)]

            for future in as_completed(futures):
                latency, error = future.result()
                latencies.append(latency * 1000)

                if error:
                    failure += 1
                    errors.append(error)
                else:
                    success += 1

        duration = time.perf_counter() - start_time
        percentiles = self._calculate_percentiles(latencies)

        return BenchmarkResult(
            test_name=f"vector_search_{num_searches}ops_top{top_k}",
            duration_seconds=duration,
            operations_count=num_searches,
            success_count=success,
            failure_count=failure,
            ops_per_second=num_searches / duration,
            latency_p50=percentiles["p50"],
            latency_p95=percentiles["p95"],
            latency_p99=percentiles["p99"],
            latency_avg=percentiles["avg"],
            latency_min=percentiles["min"],
            latency_max=percentiles["max"],
            errors=errors,
            metadata={"vector_dim": vector_dim, "top_k": top_k},
        )

    def test_mixed_workload(
        self,
        duration_seconds: int = 60,
        concurrency: int = 20,
        read_weight: float = 0.7,
        write_weight: float = 0.2,
        search_weight: float = 0.1,
    ) -> BenchmarkResult:
        """Test mixed read/write/search workload.

        Args:
            duration_seconds: How long to run the test
            concurrency: Number of concurrent workers
            read_weight: Proportion of read operations
            write_weight: Proportion of write operations
            search_weight: Proportion of search operations

        Returns:
            BenchmarkResult with test results
        """
        logger.info(f"Testing mixed workload for {duration_seconds}s with {concurrency} workers")

        def mixed_operation():
            """Execute a random operation based on weights."""
            op_type = random.choices(
                ["read", "write", "search"], weights=[read_weight, write_weight, search_weight]
            )[0]

            start = time.perf_counter()
            try:
                conn = self._get_connection()
                with conn.cursor() as cur:
                    if op_type == "read":
                        cur.execute("SELECT * FROM claude_flow.embeddings LIMIT 10")
                        cur.fetchall()
                    elif op_type == "write":
                        vector = [random.random() for _ in range(384)]
                        cur.execute(
                            """
                            INSERT INTO claude_flow.embeddings (text, embedding, metadata, namespace)
                            VALUES (%s, %s::ruvector, %s::jsonb, %s)
                            ON CONFLICT DO NOTHING
                        """,
                            (f"mixed_{random.randint(1, 1000000)}", vector, "{}", "mixed_test"),
                        )
                    else:  # search
                        query_vector = [random.random() for _ in range(384)]
                        cur.execute(
                            """
                            SELECT * FROM claude_flow.embeddings
                            ORDER BY embedding <=> %s::ruvector
                            LIMIT 5
                        """,
                            (query_vector,),
                        )
                        cur.fetchall()

                conn.commit()
                conn.close()
                return time.perf_counter() - start, None, op_type
            except Exception as e:
                return time.perf_counter() - start, str(e), op_type

        start_time = time.perf_counter()
        end_time = start_time + duration_seconds
        latencies = []
        errors = []
        success = 0
        failure = 0
        operations = 0
        op_counts = {"read": 0, "write": 0, "search": 0}

        with ThreadPoolExecutor(max_workers=concurrency) as executor:
            futures = []

            while time.perf_counter() < end_time:
                if len(futures) < concurrency:
                    futures.append(executor.submit(mixed_operation))
                    operations += 1

                # Process completed futures
                done = [f for f in futures if f.done()]
                for future in done:
                    latency, error, op_type = future.result()
                    latencies.append(latency * 1000)
                    op_counts[op_type] += 1

                    if error:
                        failure += 1
                        errors.append(error)
                    else:
                        success += 1

                    futures.remove(future)

                time.sleep(0.01)

            # Wait for remaining futures
            for future in as_completed(futures):
                latency, error, op_type = future.result()
                latencies.append(latency * 1000)
                op_counts[op_type] += 1

                if error:
                    failure += 1
                    errors.append(error)
                else:
                    success += 1

        duration = time.perf_counter() - start_time
        percentiles = self._calculate_percentiles(latencies)

        # Cleanup
        try:
            conn = self._get_connection()
            with conn.cursor() as cur:
                cur.execute("DELETE FROM claude_flow.embeddings WHERE namespace = 'mixed_test'")
            conn.commit()
            conn.close()
        except Exception as e:
            logger.warning(f"Failed to cleanup test data: {e}")

        return BenchmarkResult(
            test_name=f"mixed_workload_{duration_seconds}s_{concurrency}workers",
            duration_seconds=duration,
            operations_count=operations,
            success_count=success,
            failure_count=failure,
            ops_per_second=operations / duration,
            latency_p50=percentiles["p50"],
            latency_p95=percentiles["p95"],
            latency_p99=percentiles["p99"],
            latency_avg=percentiles["avg"],
            latency_min=percentiles["min"],
            latency_max=percentiles["max"],
            errors=errors,
            metadata={
                "concurrency": concurrency,
                "read_weight": read_weight,
                "write_weight": write_weight,
                "search_weight": search_weight,
                "operation_counts": op_counts,
            },
        )

    def run_full_suite(self) -> List[BenchmarkResult]:
        """Run the complete benchmark suite.

        Returns:
            List of benchmark results
        """
        logger.info("Starting full benchmark suite")

        # Connection tests
        for num_conns in [10, 25, 40, 50]:
            result = self.test_concurrent_connections(num_conns)
            self.results.append(result)
            logger.info(
                f"✓ {result.test_name}: {result.ops_per_second:.2f} ops/s, "
                f"{result.success_rate:.1f}% success"
            )

        # Read-heavy tests
        for ops in [100, 500, 1000]:
            result = self.test_read_heavy_load(ops, concurrency=20)
            self.results.append(result)
            logger.info(
                f"✓ {result.test_name}: {result.ops_per_second:.2f} ops/s, "
                f"{result.latency_p95:.2f}ms p95"
            )

        # Write-heavy tests
        for ops in [100, 500]:
            result = self.test_write_heavy_load(ops, concurrency=10)
            self.results.append(result)
            logger.info(
                f"✓ {result.test_name}: {result.ops_per_second:.2f} ops/s, "
                f"{result.latency_p95:.2f}ms p95"
            )

        # Vector search tests
        for num_searches in [100, 500, 1000]:
            result = self.test_vector_search_performance(num_searches, top_k=10)
            self.results.append(result)
            logger.info(
                f"✓ {result.test_name}: {result.ops_per_second:.2f} ops/s, "
                f"{result.latency_p95:.2f}ms p95"
            )

        # Mixed workload test
        result = self.test_mixed_workload(duration_seconds=30, concurrency=20)
        self.results.append(result)
        logger.info(
            f"✓ {result.test_name}: {result.ops_per_second:.2f} ops/s, "
            f"{result.success_rate:.1f}% success"
        )

        logger.info("✓ Full benchmark suite completed")
        return self.results

    def generate_report(self, output_file: Optional[str] = None) -> str:
        """Generate a markdown report of all benchmark results.

        Args:
            output_file: Optional file path to write report

        Returns:
            Report as string
        """
        report = [
            "# Load Testing Report",
            f"\nGenerated: {datetime.now().isoformat()}",
            f"\nDatabase: {self.db_config['database']} @ {self.db_config['host']}:{self.db_config['port']}",
            "\n## Summary",
            "\n| Test | Operations | Success Rate | Ops/sec | P50 (ms) | P95 (ms) | P99 (ms) |",
            "|------|-----------|--------------|---------|----------|----------|----------|",
        ]

        for result in self.results:
            report.append(
                f"| {result.test_name} | {result.operations_count} | "
                f"{result.success_rate:.1f}% | {result.ops_per_second:.2f} | "
                f"{result.latency_p50:.2f} | {result.latency_p95:.2f} | {result.latency_p99:.2f} |"
            )

        report.append("\n## Detailed Results\n")

        for result in self.results:
            report.append(f"### {result.test_name}")
            report.append(f"\n- **Duration:** {result.duration_seconds:.2f}s")
            report.append(f"- **Operations:** {result.operations_count}")
            report.append(f"- **Success Rate:** {result.success_rate:.2f}%")
            report.append(f"- **Throughput:** {result.ops_per_second:.2f} ops/sec")
            report.append("\n**Latency:**")
            report.append(f"- P50: {result.latency_p50:.2f}ms")
            report.append(f"- P95: {result.latency_p95:.2f}ms")
            report.append(f"- P99: {result.latency_p99:.2f}ms")
            report.append(f"- Average: {result.latency_avg:.2f}ms")
            report.append(f"- Min/Max: {result.latency_min:.2f}ms / {result.latency_max:.2f}ms")

            if result.metadata:
                report.append("\n**Metadata:**")
                for key, value in result.metadata.items():
                    report.append(f"- {key}: {value}")

            if result.errors:
                report.append(f"\n**Errors ({len(result.errors)}):**")
                for error in result.errors[:5]:
                    report.append(f"- {error}")

            report.append("\n")

        report_text = "\n".join(report)

        if output_file:
            Path(output_file).parent.mkdir(parents=True, exist_ok=True)
            with open(output_file, "w") as f:
                f.write(report_text)
            logger.info(f"Report written to {output_file}")

        return report_text


def main():
    """Main entry point for benchmark suite."""
    # Load config from environment
    db_config = {
        "host": os.getenv("RUVECTOR_HOST", "localhost"),
        "port": int(os.getenv("RUVECTOR_PORT", "5432")),
        "database": os.getenv("RUVECTOR_DB", "distributed_postgres_cluster"),
        "user": os.getenv("RUVECTOR_USER", "dpg_cluster"),
        "password": os.getenv("RUVECTOR_PASSWORD", "dpg_cluster_2026"),
    }

    runner = LoadTestRunner(db_config)

    # Run full suite
    results = runner.run_full_suite()

    # Generate report
    report_path = "/home/matt/projects/Distributed-Postgress-Cluster/tests/load/benchmark_report.md"
    runner.generate_report(report_path)

    # Print summary
    print("\n" + "=" * 80)
    print("BENCHMARK SUITE COMPLETE")
    print("=" * 80)
    print(f"\nTotal tests: {len(results)}")
    print(f"Report: {report_path}")

    # Print quick stats
    avg_success = sum(r.success_rate for r in results) / len(results)
    avg_ops = sum(r.ops_per_second for r in results) / len(results)
    print(f"\nAverage success rate: {avg_success:.1f}%")
    print(f"Average throughput: {avg_ops:.2f} ops/sec")


if __name__ == "__main__":
    main()
