#!/usr/bin/env python3
"""Comprehensive Vector Search Benchmarking Suite

Benchmarks:
- Single-shard vector search
- Cross-shard vector search
- Bulk insert operations
- Concurrent query performance
"""
import asyncio
import asyncpg
import numpy as np
import time
import sys
import os
from pathlib import Path
from typing import List, Dict
import json
from datetime import datetime

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent.parent))
from dotenv import load_dotenv

# Load environment
load_dotenv(Path(__file__).parent.parent.parent / '.env')


class VectorSearchBenchmark:
    """Comprehensive vector search benchmarking."""

    def __init__(self, connection_string: str):
        self.conn_string = connection_string
        self.results = []
        self.pool = None

    async def setup(self):
        """Setup benchmark database connection pool."""
        print("🔧 Setting up connection pool...")
        self.pool = await asyncpg.create_pool(
            self.conn_string,
            min_size=10,
            max_size=50,
            command_timeout=60
        )
        print("   ✓ Connection pool ready")

    async def teardown(self):
        """Cleanup connection pool."""
        if self.pool:
            await self.pool.close()
            print("\n🔧 Connection pool closed")

    async def benchmark_single_shard_search(self, iterations=1000):
        """Benchmark single-shard vector search.

        Simulates typical query pattern: search within one namespace.
        Target: <10ms p95 latency
        """
        print(f"\n{'='*60}")
        print(f"🔍 Single-Shard Vector Search")
        print(f"{'='*60}")
        print(f"Iterations: {iterations}")
        print(f"Operation: Vector similarity search in single namespace")

        latencies = []

        for i in range(iterations):
            # Generate random query embedding (384-dimensional)
            query_embedding = np.random.randn(384).tolist()
            namespace = "benchmark-namespace"

            start = time.perf_counter()

            try:
                async with self.pool.acquire() as conn:
                    embedding_str = f"[{','.join(str(v) for v in query_embedding)}]"
                    results = await conn.fetch("""
                        SELECT namespace, key, value, metadata,
                               1 - (embedding <=> $1::ruvector) as similarity
                        FROM memory_entries
                        WHERE namespace = $2
                          AND embedding IS NOT NULL
                        ORDER BY embedding <=> $1::ruvector
                        LIMIT 10
                    """, embedding_str, namespace)

                latency = (time.perf_counter() - start) * 1000  # ms
                latencies.append(latency)

            except Exception as e:
                print(f"\n   ⚠ Query {i+1} failed: {e}")
                continue

            if (i + 1) % 100 == 0:
                print(f"   Progress: {i+1}/{iterations} ({(i+1)/iterations*100:.1f}%)")

        # Calculate statistics
        if not latencies:
            print("   ✗ No successful queries")
            return None

        latencies.sort()
        stats = {
            'operation': 'single_shard_search',
            'iterations': len(latencies),
            'min_ms': latencies[0],
            'max_ms': latencies[-1],
            'mean_ms': np.mean(latencies),
            'median_ms': np.median(latencies),
            'p50_ms': np.percentile(latencies, 50),
            'p95_ms': np.percentile(latencies, 95),
            'p99_ms': np.percentile(latencies, 99),
            'p99_9_ms': np.percentile(latencies, 99.9),
            'qps': len(latencies) / (sum(latencies) / 1000)
        }

        self.results.append(stats)
        self._print_stats(stats)

        return stats

    async def benchmark_cross_shard_search(self, iterations=500):
        """Benchmark cross-shard vector search.

        Simulates queries spanning multiple namespaces (shards).
        Target: <25ms p95 latency
        """
        print(f"\n{'='*60}")
        print(f"🔍 Cross-Shard Vector Search")
        print(f"{'='*60}")
        print(f"Iterations: {iterations}")
        print(f"Operation: Vector search across 5 namespaces")

        latencies = []

        for i in range(iterations):
            query_embedding = np.random.randn(384).tolist()
            # Query across 5 different namespaces (likely different shards)
            namespaces = [f"benchmark-namespace-{j}" for j in range(5)]

            start = time.perf_counter()

            try:
                async with self.pool.acquire() as conn:
                    embedding_str = f"[{','.join(str(v) for v in query_embedding)}]"
                    results = await conn.fetch("""
                        SELECT namespace, key, value, metadata,
                               1 - (embedding <=> $1::ruvector) as similarity
                        FROM memory_entries
                        WHERE namespace = ANY($2)
                          AND embedding IS NOT NULL
                        ORDER BY embedding <=> $1::ruvector
                        LIMIT 20
                    """, embedding_str, namespaces)

                latency = (time.perf_counter() - start) * 1000
                latencies.append(latency)

            except Exception as e:
                print(f"\n   ⚠ Query {i+1} failed: {e}")
                continue

            if (i + 1) % 50 == 0:
                print(f"   Progress: {i+1}/{iterations} ({(i+1)/iterations*100:.1f}%)")

        if not latencies:
            print("   ✗ No successful queries")
            return None

        latencies.sort()
        stats = {
            'operation': 'cross_shard_search',
            'iterations': len(latencies),
            'namespaces': 5,
            'min_ms': latencies[0],
            'max_ms': latencies[-1],
            'mean_ms': np.mean(latencies),
            'median_ms': np.median(latencies),
            'p50_ms': np.percentile(latencies, 50),
            'p95_ms': np.percentile(latencies, 95),
            'p99_ms': np.percentile(latencies, 99),
            'p99_9_ms': np.percentile(latencies, 99.9),
            'qps': len(latencies) / (sum(latencies) / 1000)
        }

        self.results.append(stats)
        self._print_stats(stats)

        return stats

    async def benchmark_bulk_insert(self, batch_size=100, iterations=100):
        """Benchmark bulk insert operations.

        Tests write throughput and transaction performance.
        Target: >1000 TPS
        """
        print(f"\n{'='*60}")
        print(f"📥 Bulk Insert")
        print(f"{'='*60}")
        print(f"Iterations: {iterations}")
        print(f"Batch size: {batch_size}")
        print(f"Total inserts: {batch_size * iterations}")

        latencies = []

        for i in range(iterations):
            # Generate batch of entries
            batch = []
            for j in range(batch_size):
                embedding = np.random.randn(384).tolist()
                batch.append({
                    'namespace': 'benchmark-namespace',
                    'key': f'bulk-insert-{i}-{j}',
                    'value': f'Benchmark value {i}-{j}',
                    'embedding': embedding,
                    'metadata': {'batch': i, 'index': j}
                })

            start = time.perf_counter()

            try:
                async with self.pool.acquire() as conn:
                    async with conn.transaction():
                        for item in batch:
                            embedding_str = f"[{','.join(str(v) for v in item['embedding'])}]"
                            await conn.execute("""
                                INSERT INTO memory_entries
                                    (namespace, key, value, embedding, metadata)
                                VALUES ($1, $2, $3, $4::ruvector, $5::jsonb)
                                ON CONFLICT (namespace, key) DO UPDATE
                                SET value = EXCLUDED.value,
                                    embedding = EXCLUDED.embedding,
                                    metadata = EXCLUDED.metadata,
                                    updated_at = NOW()
                            """, item['namespace'], item['key'], item['value'],
                                embedding_str, json.dumps(item['metadata']))

                latency = (time.perf_counter() - start) * 1000
                latencies.append(latency)

            except Exception as e:
                print(f"\n   ⚠ Batch {i+1} failed: {e}")
                continue

            if (i + 1) % 10 == 0:
                print(f"   Progress: {i+1}/{iterations} ({(i+1)/iterations*100:.1f}%)")

        if not latencies:
            print("   ✗ No successful batches")
            return None

        latencies.sort()
        total_rows = batch_size * len(latencies)
        total_time_sec = sum(latencies) / 1000

        stats = {
            'operation': 'bulk_insert',
            'batch_size': batch_size,
            'iterations': len(latencies),
            'total_rows': total_rows,
            'min_ms': latencies[0],
            'max_ms': latencies[-1],
            'mean_ms': np.mean(latencies),
            'median_ms': np.median(latencies),
            'p50_ms': np.percentile(latencies, 50),
            'p95_ms': np.percentile(latencies, 95),
            'p99_ms': np.percentile(latencies, 99),
            'throughput_tps': total_rows / total_time_sec,
            'throughput_rows_per_sec': total_rows / total_time_sec
        }

        self.results.append(stats)
        self._print_stats(stats)

        return stats

    async def benchmark_concurrent_queries(self, concurrency=50, queries_per_client=20):
        """Benchmark concurrent query performance.

        Simulates multiple clients querying simultaneously.
        Target: Handle 100+ concurrent connections
        """
        print(f"\n{'='*60}")
        print(f"🔀 Concurrent Query Performance")
        print(f"{'='*60}")
        print(f"Concurrent clients: {concurrency}")
        print(f"Queries per client: {queries_per_client}")
        print(f"Total queries: {concurrency * queries_per_client}")

        async def client_workload(client_id: int) -> List[float]:
            """Execute queries for one client."""
            latencies = []
            for i in range(queries_per_client):
                query_embedding = np.random.randn(384).tolist()
                namespace = f"benchmark-namespace-{client_id % 10}"

                start = time.perf_counter()

                try:
                    async with self.pool.acquire() as conn:
                        embedding_str = f"[{','.join(str(v) for v in query_embedding)}]"
                        await conn.fetch("""
                            SELECT namespace, key, value,
                                   1 - (embedding <=> $1::ruvector) as similarity
                            FROM memory_entries
                            WHERE namespace = $2
                              AND embedding IS NOT NULL
                            ORDER BY embedding <=> $1::ruvector
                            LIMIT 10
                        """, embedding_str, namespace)

                    latency = (time.perf_counter() - start) * 1000
                    latencies.append(latency)

                except Exception as e:
                    print(f"\n   ⚠ Client {client_id}, query {i+1} failed: {e}")
                    continue

            return latencies

        # Execute all clients concurrently
        start_time = time.perf_counter()
        tasks = [client_workload(i) for i in range(concurrency)]
        results = await asyncio.gather(*tasks)
        total_duration = time.perf_counter() - start_time

        # Aggregate all latencies
        all_latencies = []
        for client_latencies in results:
            all_latencies.extend(client_latencies)

        if not all_latencies:
            print("   ✗ No successful queries")
            return None

        all_latencies.sort()
        successful_queries = len(all_latencies)

        stats = {
            'operation': 'concurrent_queries',
            'concurrency': concurrency,
            'queries_per_client': queries_per_client,
            'total_queries': successful_queries,
            'total_duration_sec': total_duration,
            'min_ms': all_latencies[0],
            'max_ms': all_latencies[-1],
            'mean_ms': np.mean(all_latencies),
            'median_ms': np.median(all_latencies),
            'p50_ms': np.percentile(all_latencies, 50),
            'p95_ms': np.percentile(all_latencies, 95),
            'p99_ms': np.percentile(all_latencies, 99),
            'throughput_qps': successful_queries / total_duration
        }

        self.results.append(stats)
        self._print_stats(stats)

        return stats

    def _print_stats(self, stats: Dict):
        """Print benchmark statistics in formatted table."""
        print("\n   📊 Results:")
        print(f"   {'─'*56}")

        if 'min_ms' in stats:
            print(f"   {'Latency (ms)':<30} {'Value':>20}")
            print(f"   {'─'*56}")
            print(f"   {'  Min':<30} {stats['min_ms']:>20.2f}")
            print(f"   {'  Max':<30} {stats['max_ms']:>20.2f}")
            print(f"   {'  Mean':<30} {stats['mean_ms']:>20.2f}")
            print(f"   {'  Median':<30} {stats['median_ms']:>20.2f}")
            print(f"   {'  p50':<30} {stats['p50_ms']:>20.2f}")
            print(f"   {'  p95':<30} {stats['p95_ms']:>20.2f}")
            print(f"   {'  p99':<30} {stats['p99_ms']:>20.2f}")
            if 'p99_9_ms' in stats:
                print(f"   {'  p99.9':<30} {stats['p99_9_ms']:>20.2f}")

        if 'qps' in stats:
            print(f"   {'─'*56}")
            print(f"   {'Throughput (QPS)':<30} {stats['qps']:>20.0f}")

        if 'throughput_tps' in stats:
            print(f"   {'─'*56}")
            print(f"   {'Throughput (TPS)':<30} {stats['throughput_tps']:>20.0f}")
            print(f"   {'Throughput (rows/sec)':<30} {stats['throughput_rows_per_sec']:>20.0f}")

        if 'throughput_qps' in stats:
            print(f"   {'─'*56}")
            print(f"   {'Concurrent Throughput (QPS)':<30} {stats['throughput_qps']:>20.0f}")
            print(f"   {'Total Duration (sec)':<30} {stats['total_duration_sec']:>20.2f}")

        print(f"   {'─'*56}")

    def save_results(self, filepath: str):
        """Save benchmark results to JSON."""
        output = {
            'timestamp': datetime.now().isoformat(),
            'connection': {
                'host': os.getenv('RUVECTOR_HOST', 'localhost'),
                'port': int(os.getenv('RUVECTOR_PORT', '5432')),
                'database': os.getenv('RUVECTOR_DB')
            },
            'results': self.results
        }

        # Ensure directory exists
        Path(filepath).parent.mkdir(parents=True, exist_ok=True)

        with open(filepath, 'w') as f:
            json.dump(output, f, indent=2)

        print(f"\n📊 Results saved to {filepath}")

    def print_summary(self):
        """Print summary of all benchmark results."""
        print(f"\n{'='*60}")
        print("📋 Benchmark Summary")
        print(f"{'='*60}")

        for result in self.results:
            op = result['operation']
            print(f"\n{op.replace('_', ' ').title()}:")
            if 'p95_ms' in result:
                print(f"  p95 latency: {result['p95_ms']:.2f} ms")
            if 'qps' in result:
                print(f"  Throughput:  {result['qps']:.0f} QPS")
            if 'throughput_tps' in result:
                print(f"  Throughput:  {result['throughput_tps']:.0f} TPS")

        print(f"\n{'='*60}")


async def main():
    """Run all benchmarks."""
    print("="*60)
    print("🚀 Vector Search Benchmark Suite")
    print("="*60)
    print(f"\nTimestamp: {datetime.now().isoformat()}")

    # Build connection string
    conn_string = (
        f"postgresql://{os.getenv('RUVECTOR_USER')}:"
        f"{os.getenv('RUVECTOR_PASSWORD')}@"
        f"{os.getenv('RUVECTOR_HOST', 'localhost')}:"
        f"{os.getenv('RUVECTOR_PORT', '5432')}/"
        f"{os.getenv('RUVECTOR_DB')}"
    )

    benchmark = VectorSearchBenchmark(conn_string)

    try:
        await benchmark.setup()

        # Run benchmarks
        await benchmark.benchmark_single_shard_search(iterations=1000)
        await benchmark.benchmark_cross_shard_search(iterations=500)
        await benchmark.benchmark_concurrent_queries(concurrency=50, queries_per_client=20)
        await benchmark.benchmark_bulk_insert(batch_size=100, iterations=100)

        # Print summary
        benchmark.print_summary()

        # Save results
        output_path = Path(__file__).parent.parent.parent / 'reports' / 'benchmark_results.json'
        benchmark.save_results(str(output_path))

        print("\n✅ All benchmarks completed successfully")

    except Exception as e:
        print(f"\n❌ Benchmark failed: {e}")
        import traceback
        traceback.print_exc()
        return 1

    finally:
        await benchmark.teardown()

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
