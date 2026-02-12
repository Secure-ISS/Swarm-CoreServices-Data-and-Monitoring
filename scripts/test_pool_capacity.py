#!/usr/bin/env python3
"""
Connection Pool Capacity Test

Tests if the connection pool can handle 35+ concurrent agents.

Usage:
    python scripts/test_pool_capacity.py [num_agents]
"""

# Standard library imports
import asyncio
import logging
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import List, Tuple

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

# Local imports
from db.pool import DatabaseConnectionError, get_pools

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)


def simulate_agent_work(agent_id: int, duration_ms: int = 100) -> Tuple[int, bool, str]:
    """Simulate an agent performing database work.

    Args:
        agent_id: Agent identifier
        duration_ms: How long to hold the connection (ms)

    Returns:
        Tuple of (agent_id, success, error_message)
    """
    try:
        pools = get_pools()
        start = time.time()

        # Get connection and perform work
        with pools.project_cursor() as cur:
            cur.execute("SELECT 1 as test")
            cur.fetchone()

            # Simulate work
            time.sleep(duration_ms / 1000.0)

        elapsed = (time.time() - start) * 1000
        logger.debug(f"Agent {agent_id}: completed in {elapsed:.1f}ms")
        return (agent_id, True, "")

    except Exception as e:
        error_msg = f"Agent {agent_id}: failed with {type(e).__name__}: {e}"
        logger.error(error_msg)
        return (agent_id, False, str(e))


def test_concurrent_agents(num_agents: int = 35, work_duration_ms: int = 100) -> dict:
    """Test concurrent agent connections.

    Args:
        num_agents: Number of concurrent agents to simulate
        work_duration_ms: How long each agent holds connection

    Returns:
        Dict with test results
    """
    logger.info(f"Starting concurrent test with {num_agents} agents")
    logger.info(f"Each agent will hold connection for {work_duration_ms}ms")

    start_time = time.time()
    results = {
        "total": num_agents,
        "successful": 0,
        "failed": 0,
        "errors": [],
        "duration_sec": 0,
        "pool_exhausted": False,
    }

    # Run agents concurrently
    with ThreadPoolExecutor(max_workers=num_agents) as executor:
        futures = [
            executor.submit(simulate_agent_work, i, work_duration_ms) for i in range(num_agents)
        ]

        for future in as_completed(futures):
            agent_id, success, error = future.result()
            if success:
                results["successful"] += 1
            else:
                results["failed"] += 1
                results["errors"].append(error)
                if "pool" in error.lower() or "connection" in error.lower():
                    results["pool_exhausted"] = True

    results["duration_sec"] = time.time() - start_time

    return results


def test_sequential_burst(num_bursts: int = 5, agents_per_burst: int = 10) -> dict:
    """Test sequential bursts of concurrent agents.

    Args:
        num_bursts: Number of sequential bursts
        agents_per_burst: Agents per burst

    Returns:
        Dict with test results
    """
    logger.info(f"Testing {num_bursts} bursts of {agents_per_burst} agents")

    all_results = []

    for burst in range(num_bursts):
        logger.info(f"Burst {burst + 1}/{num_bursts}")
        result = test_concurrent_agents(agents_per_burst, work_duration_ms=50)
        all_results.append(result)

        # Brief pause between bursts
        time.sleep(0.1)

    # Aggregate results
    aggregate = {
        "total_bursts": num_bursts,
        "agents_per_burst": agents_per_burst,
        "total_agents": sum(r["total"] for r in all_results),
        "successful": sum(r["successful"] for r in all_results),
        "failed": sum(r["failed"] for r in all_results),
        "pool_exhausted": any(r["pool_exhausted"] for r in all_results),
        "total_duration_sec": sum(r["duration_sec"] for r in all_results),
        "avg_burst_duration_sec": sum(r["duration_sec"] for r in all_results) / num_bursts,
    }

    return aggregate


def print_results(test_name: str, results: dict):
    """Print formatted test results."""
    print(f"\n{'='*60}")
    print(f"Test: {test_name}")
    print(f"{'='*60}")

    if "total_bursts" in results:
        # Burst test results
        print(f"Bursts: {results['total_bursts']} x {results['agents_per_burst']} agents")
        print(f"Total Agents: {results['total_agents']}")
        print(f"Successful: {results['successful']}")
        print(f"Failed: {results['failed']}")
        print(f"Success Rate: {results['successful']/results['total_agents']*100:.1f}%")
        print(f"Total Duration: {results['total_duration_sec']:.2f}s")
        print(f"Avg Burst Duration: {results['avg_burst_duration_sec']:.2f}s")
        print(f"Pool Exhausted: {'YES ❌' if results['pool_exhausted'] else 'NO ✓'}")
    else:
        # Concurrent test results
        print(f"Total Agents: {results['total']}")
        print(f"Successful: {results['successful']}")
        print(f"Failed: {results['failed']}")
        print(f"Success Rate: {results['successful']/results['total']*100:.1f}%")
        print(f"Duration: {results['duration_sec']:.2f}s")
        print(f"Pool Exhausted: {'YES ❌' if results['pool_exhausted'] else 'NO ✓'}")

        if results["errors"]:
            print(f"\nErrors ({len(results['errors'])}):")
            for i, error in enumerate(results["errors"][:5], 1):
                print(f"  {i}. {error[:80]}...")
            if len(results["errors"]) > 5:
                print(f"  ... and {len(results['errors']) - 5} more")


def main():
    """Run pool capacity tests."""
    # Standard library imports
    import argparse

    parser = argparse.ArgumentParser(description="Test connection pool capacity")
    parser.add_argument(
        "num_agents",
        type=int,
        nargs="?",
        default=35,
        help="Number of concurrent agents (default: 35)",
    )
    parser.add_argument(
        "--duration", type=int, default=100, help="Connection hold duration in ms (default: 100)"
    )
    parser.add_argument(
        "--burst", action="store_true", help="Run burst test instead of single concurrent test"
    )

    args = parser.parse_args()

    try:
        # Get current pool configuration
        pools = get_pools()
        health = pools.health_check()

        print(f"\n{'='*60}")
        print("Connection Pool Configuration")
        print(f"{'='*60}")
        print(f"Project DB: {health['project']['database']}")
        print(f"  Status: {health['project']['status']}")
        print(f"  RuVector: {health['project'].get('ruvector_version', 'Not installed')}")
        print(f"Shared DB: {health['shared']['database']}")
        print(f"  Status: {health['shared']['status']}")
        print(f"  RuVector: {health['shared'].get('ruvector_version', 'Not installed')}")

        if args.burst:
            # Burst test
            results = test_sequential_burst(num_bursts=5, agents_per_burst=args.num_agents)
            print_results(f"Sequential Burst Test ({args.num_agents} agents/burst)", results)
        else:
            # Single concurrent test
            results = test_concurrent_agents(args.num_agents, args.duration)
            print_results(f"Concurrent Connection Test ({args.num_agents} agents)", results)

        # Return exit code based on results
        if "pool_exhausted" in results and results["pool_exhausted"]:
            print("\n❌ FAILED: Pool exhaustion detected")
            return 1
        elif "failed" in results and results["failed"] > 0:
            print(f"\n⚠️  WARNING: {results['failed']} agents failed")
            return 1
        else:
            print("\n✓ SUCCESS: All agents completed successfully")
            return 0

    except DatabaseConnectionError as e:
        logger.error(f"Database connection failed: {e}")
        return 1
    except Exception as e:
        logger.error(f"Test failed: {e}", exc_info=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
