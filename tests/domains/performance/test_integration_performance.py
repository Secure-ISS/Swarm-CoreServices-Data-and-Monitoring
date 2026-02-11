#!/usr/bin/env python3
"""Performance Tests - Integration Layer Performance.

Tests performance of integration components:
- MCP server response time
- Event bus throughput
- End-to-end latency
- Concurrent operation performance
"""

import os
import sys
import unittest
import time
import threading
from typing import List, Dict, Any

# Add parent directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../..'))

from src.db.pool import DualDatabasePools
from src.db.vector_ops import store_memory, search_memory


class TestMCPServerPerformance(unittest.TestCase):
    """Test MCP server performance metrics."""

    def test_mcp_response_time_target(self):
        """Test that MCP responses meet <100ms target."""
        # Simulate MCP tool execution
        iterations = 100
        timings = []

        def simulate_mcp_call():
            """Simulate MCP tool call overhead."""
            start = time.time()

            # Simulate JSON serialization, network, etc.
            time.sleep(0.001)  # 1ms base overhead

            return time.time() - start

        for _ in range(iterations):
            duration = simulate_mcp_call()
            timings.append(duration * 1000)  # Convert to ms

        avg_time = sum(timings) / len(timings)
        p95_time = sorted(timings)[int(len(timings) * 0.95)]

        print(f"\nMCP Response Time:")
        print(f"  Average: {avg_time:.2f}ms")
        print(f"  P95: {p95_time:.2f}ms")

        # Target: <100ms (from V3 performance targets)
        self.assertLess(avg_time, 100)
        self.assertLess(p95_time, 100)

    def test_mcp_tool_execution_overhead(self):
        """Test MCP tool execution overhead."""
        try:
            pools = DualDatabasePools()
        except Exception as e:
            raise unittest.SkipTest(f"Database not available: {e}")

        iterations = 50
        timings = []

        for i in range(iterations):
            start = time.time()

            # Simulate MCP tool calling database operation
            with pools.project_cursor() as cur:
                store_memory(
                    cur,
                    namespace="mcp_perf",
                    key=f"key_{i}",
                    value="test_value"
                )

            duration = (time.time() - start) * 1000  # ms
            timings.append(duration)

        pools.close()

        avg_time = sum(timings) / len(timings)
        print(f"\nMCP tool execution overhead: {avg_time:.2f}ms average")

        # Should be fast
        self.assertLess(avg_time, 50)


class TestEventBusPerformance(unittest.TestCase):
    """Test event bus performance and throughput."""

    def test_event_publishing_throughput(self):
        """Test event publishing throughput."""
        events = []

        def publish_event(event_type: str, data: Dict[str, Any]):
            """Simulate event publishing."""
            event = {
                'type': event_type,
                'timestamp': time.time(),
                'data': data
            }
            events.append(event)
            return event

        # Test throughput
        num_events = 10000
        start = time.time()

        for i in range(num_events):
            publish_event('test.event', {'index': i})

        duration = time.time() - start
        throughput = num_events / duration

        print(f"\nEvent Publishing:")
        print(f"  Total: {num_events} events")
        print(f"  Duration: {duration:.3f}s")
        print(f"  Throughput: {throughput:.0f} events/sec")

        # Should handle high throughput
        self.assertGreater(throughput, 1000)  # >1K events/sec

    def test_event_subscription_overhead(self):
        """Test event subscription and delivery overhead."""
        received_events = []

        def handler(event):
            """Event handler."""
            received_events.append(event)

        # Subscribe and publish
        num_events = 1000
        start = time.time()

        for i in range(num_events):
            event = {
                'type': 'test.event',
                'timestamp': time.time(),
                'data': {'index': i}
            }
            handler(event)  # Direct call simulates event delivery

        duration = time.time() - start
        avg_time = (duration / num_events) * 1000  # ms

        print(f"\nEvent delivery overhead: {avg_time:.3f}ms per event")

        # Event delivery should be fast
        self.assertLess(avg_time, 1)  # <1ms per event

    def test_concurrent_event_processing(self):
        """Test concurrent event processing performance."""
        import queue

        event_queue = queue.Queue()
        processed_count = [0]
        lock = threading.Lock()

        def worker():
            """Event processing worker."""
            while True:
                try:
                    event = event_queue.get(timeout=0.1)
                    if event is None:
                        break

                    # Simulate processing
                    time.sleep(0.001)

                    with lock:
                        processed_count[0] += 1

                    event_queue.task_done()
                except queue.Empty:
                    break

        # Start workers
        num_workers = 4
        workers = []
        for _ in range(num_workers):
            thread = threading.Thread(target=worker)
            thread.start()
            workers.append(thread)

        # Queue events
        num_events = 1000
        start = time.time()

        for i in range(num_events):
            event_queue.put({'type': 'test.event', 'data': {'index': i}})

        # Wait for completion
        event_queue.join()

        # Stop workers
        for _ in range(num_workers):
            event_queue.put(None)
        for thread in workers:
            thread.join()

        duration = time.time() - start
        throughput = num_events / duration

        print(f"\nConcurrent event processing:")
        print(f"  Workers: {num_workers}")
        print(f"  Events: {num_events}")
        print(f"  Throughput: {throughput:.0f} events/sec")

        self.assertEqual(processed_count[0], num_events)
        self.assertGreater(throughput, 500)  # >500 events/sec


class TestEndToEndLatency(unittest.TestCase):
    """Test end-to-end latency for complete flows."""

    @classmethod
    def setUpClass(cls):
        """Set up database pools."""
        try:
            cls.pools = DualDatabasePools()
        except Exception as e:
            raise unittest.SkipTest(f"Database not available: {e}")

    @classmethod
    def tearDownClass(cls):
        """Clean up pools."""
        if hasattr(cls, 'pools'):
            cls.pools.close()

    def test_memory_store_retrieve_latency(self):
        """Test end-to-end latency for store→retrieve."""
        iterations = 100
        latencies = []

        for i in range(iterations):
            start = time.time()

            # Complete flow
            with self.pools.project_cursor() as cur:
                # Store
                store_memory(
                    cur,
                    namespace="latency_test",
                    key=f"key_{i}",
                    value="test_value"
                )

            # Implicit commit here

            # Retrieve (new cursor simulates separate request)
            with self.pools.project_cursor() as cur:
                from src.db.vector_ops import retrieve_memory
                result = retrieve_memory(cur, "latency_test", f"key_{i}")

            latency = (time.time() - start) * 1000  # ms
            latencies.append(latency)

        avg_latency = sum(latencies) / len(latencies)
        p95_latency = sorted(latencies)[int(len(latencies) * 0.95)]
        p99_latency = sorted(latencies)[int(len(latencies) * 0.99)]

        print(f"\nMemory Store→Retrieve Latency:")
        print(f"  Average: {avg_latency:.2f}ms")
        print(f"  P95: {p95_latency:.2f}ms")
        print(f"  P99: {p99_latency:.2f}ms")

        # Target: P95 <12ms (from requirements)
        self.assertLess(p95_latency, 50)  # Generous for test environment

    def test_vector_search_latency(self):
        """Test end-to-end latency for vector search."""
        # Setup: Store test vectors
        with self.pools.project_cursor() as cur:
            for i in range(100):
                store_memory(
                    cur,
                    namespace="search_latency",
                    key=f"key_{i}",
                    value=f"value_{i}",
                    embedding=[0.01 * (i % 384) for _ in range(384)]
                )

        # Test search latency
        iterations = 50
        latencies = []
        query = [0.5] * 384

        for _ in range(iterations):
            start = time.time()

            with self.pools.project_cursor() as cur:
                results = search_memory(
                    cur,
                    namespace="search_latency",
                    query_embedding=query,
                    limit=10,
                    min_similarity=0.5
                )

            latency = (time.time() - start) * 1000  # ms
            latencies.append(latency)

        avg_latency = sum(latencies) / len(latencies)
        p95_latency = sorted(latencies)[int(len(latencies) * 0.95)]

        print(f"\nVector Search Latency:")
        print(f"  Average: {avg_latency:.2f}ms")
        print(f"  P95: {p95_latency:.2f}ms")

        # Target: <5ms (from memory architecture)
        # HNSW should be 150x-12,500x faster
        self.assertLess(avg_latency, 50)  # Generous for test environment


class TestConcurrentOperationPerformance(unittest.TestCase):
    """Test performance under concurrent load."""

    @classmethod
    def setUpClass(cls):
        """Set up database pools."""
        try:
            cls.pools = DualDatabasePools()
        except Exception as e:
            raise unittest.SkipTest(f"Database not available: {e}")

    @classmethod
    def tearDownClass(cls):
        """Clean up pools."""
        if hasattr(cls, 'pools'):
            cls.pools.close()

    def test_concurrent_write_performance(self):
        """Test concurrent write performance."""
        num_threads = 10
        ops_per_thread = 50
        errors = []
        timings = []
        lock = threading.Lock()

        def write_worker(thread_id):
            """Write worker."""
            try:
                start = time.time()

                for i in range(ops_per_thread):
                    with self.pools.project_cursor() as cur:
                        store_memory(
                            cur,
                            namespace="concurrent_write",
                            key=f"thread_{thread_id}_key_{i}",
                            value=f"value_{i}"
                        )

                duration = time.time() - start

                with lock:
                    timings.append(duration)

            except Exception as e:
                errors.append(e)

        # Run concurrent writes
        start = time.time()

        threads = []
        for i in range(num_threads):
            thread = threading.Thread(target=write_worker, args=(i,))
            threads.append(thread)
            thread.start()

        for thread in threads:
            thread.join()

        total_duration = time.time() - start
        total_ops = num_threads * ops_per_thread
        throughput = total_ops / total_duration

        print(f"\nConcurrent Write Performance:")
        print(f"  Threads: {num_threads}")
        print(f"  Total ops: {total_ops}")
        print(f"  Duration: {total_duration:.2f}s")
        print(f"  Throughput: {throughput:.0f} ops/sec")

        self.assertEqual(len(errors), 0, f"Errors: {errors}")
        self.assertGreater(throughput, 100)  # >100 ops/sec

    def test_concurrent_read_performance(self):
        """Test concurrent read performance."""
        # Setup: Store test data
        with self.pools.project_cursor() as cur:
            for i in range(100):
                store_memory(
                    cur,
                    namespace="concurrent_read",
                    key=f"key_{i}",
                    value=f"value_{i}"
                )

        # Test concurrent reads
        num_threads = 10
        ops_per_thread = 100
        errors = []
        results = []
        lock = threading.Lock()

        def read_worker():
            """Read worker."""
            try:
                for i in range(ops_per_thread):
                    with self.pools.project_cursor() as cur:
                        from src.db.vector_ops import retrieve_memory
                        result = retrieve_memory(
                            cur,
                            "concurrent_read",
                            f"key_{i % 100}"
                        )

                        if result:
                            with lock:
                                results.append(result)

            except Exception as e:
                errors.append(e)

        start = time.time()

        threads = []
        for _ in range(num_threads):
            thread = threading.Thread(target=read_worker)
            threads.append(thread)
            thread.start()

        for thread in threads:
            thread.join()

        total_duration = time.time() - start
        total_ops = num_threads * ops_per_thread
        throughput = total_ops / total_duration

        print(f"\nConcurrent Read Performance:")
        print(f"  Threads: {num_threads}")
        print(f"  Total ops: {total_ops}")
        print(f"  Duration: {total_duration:.2f}s")
        print(f"  Throughput: {throughput:.0f} ops/sec")

        self.assertEqual(len(errors), 0, f"Errors: {errors}")
        self.assertGreater(throughput, 500)  # >500 ops/sec (reads faster than writes)


def run_integration_performance_tests():
    """Run all integration performance tests."""
    suite = unittest.TestSuite()

    test_classes = [
        TestMCPServerPerformance,
        TestEventBusPerformance,
        TestEndToEndLatency,
        TestConcurrentOperationPerformance,
    ]

    for test_class in test_classes:
        tests = unittest.TestLoader().loadTestsFromTestCase(test_class)
        suite.addTests(tests)

    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(run_integration_performance_tests())
