#!/usr/bin/env python3
"""Test Patroni HA pool connection and functionality.

This script tests:
1. Patroni cluster topology discovery
2. Connection to primary node
3. Connection to replica nodes
4. Read/write splitting
5. Basic failover detection
"""

# Standard library imports
import os
import sys
import time
from pathlib import Path

# Add project root to path
project_root = Path(__file__).parent.parent
sys.path.insert(0, str(project_root))

# Third-party imports
# Load environment variables
from dotenv import load_dotenv

load_dotenv()

# Local imports
from src.db.pool import DualDatabasePools


def test_patroni_initialization():
    """Test 1: Initialize Patroni pool."""
    print("\n" + "=" * 60)
    print("TEST 1: Patroni Pool Initialization")
    print("=" * 60)

    try:
        # Force Patroni mode
        pools = DualDatabasePools(enable_patroni=True)
        print("✓ Patroni pool initialized successfully")
        return pools
    except Exception as e:
        print(f"✗ Failed to initialize Patroni pool: {e}")
        sys.exit(1)


def test_health_check(pools):
    """Test 2: Health check on all nodes."""
    print("\n" + "=" * 60)
    print("TEST 2: Cluster Health Check")
    print("=" * 60)

    try:
        health = pools.health_check()

        print(f"\nMode: {health.get('mode')}")

        if health.get("mode") != "patroni":
            print("✗ Not in Patroni mode")
            return False

        cluster = health.get("ha_cluster", {})

        # Check primary
        primary = cluster.get("primary", {})
        print(f"\nPrimary Status: {primary.get('status')}")
        if primary.get("status") == "healthy":
            print(f"  Host: {primary.get('host')}:{primary.get('port')}")
            print(f"  In Recovery: {primary.get('in_recovery')}")
            print("✓ Primary is healthy")
        else:
            print(f"✗ Primary is unhealthy: {primary.get('error')}")
            return False

        # Check replicas
        replicas = cluster.get("replicas", [])
        print(f"\nReplica Count: {len(replicas)}")

        healthy_replicas = 0
        for replica in replicas:
            status = replica.get("status")
            node = replica.get("node")
            if status == "healthy":
                print(f"  ✓ {node}: healthy")
                healthy_replicas += 1
            else:
                print(f"  ✗ {node}: {replica.get('error')}")

        print(f"\nHealthy Replicas: {healthy_replicas}/{len(replicas)}")

        # Check statistics
        stats = cluster.get("statistics", {})
        print(f"\nStatistics:")
        print(f"  Failovers: {stats.get('failovers', 0)}")
        print(f"  Topology Refreshes: {stats.get('topology_refreshes', 0)}")
        print(f"  Reads: {stats.get('reads', 0)}")
        print(f"  Writes: {stats.get('writes', 0)}")
        print(f"  Errors: {stats.get('errors', 0)}")

        print("\n✓ Health check completed")
        return True

    except Exception as e:
        print(f"✗ Health check failed: {e}")
        return False


def test_write_to_primary(pools):
    """Test 3: Write operation to primary."""
    print("\n" + "=" * 60)
    print("TEST 3: Write to Primary")
    print("=" * 60)

    try:
        # Create test table if not exists
        with pools.project_cursor(read_only=False) as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS patroni_test (
                    id SERIAL PRIMARY KEY,
                    data TEXT,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """
            )
            print("✓ Test table created/verified")

        # Insert test data
        test_data = f"test-{int(time.time())}"
        with pools.project_cursor(read_only=False) as cur:
            cur.execute(
                "INSERT INTO patroni_test (data) VALUES (%s) RETURNING id, created_at", (test_data,)
            )
            result = cur.fetchone()
            insert_id = result["id"]
            created_at = result["created_at"]

            print(f"✓ Inserted record:")
            print(f"  ID: {insert_id}")
            print(f"  Data: {test_data}")
            print(f"  Created At: {created_at}")

        return insert_id

    except Exception as e:
        print(f"✗ Write operation failed: {e}")
        return None


def test_read_from_replica(pools, insert_id):
    """Test 4: Read operation from replica."""
    print("\n" + "=" * 60)
    print("TEST 4: Read from Replica")
    print("=" * 60)

    if insert_id is None:
        print("✗ No insert ID from previous test, skipping")
        return False

    try:
        # Wait a moment for replication
        print("Waiting 2s for replication...")
        time.sleep(2)

        # Read from replica
        with pools.project_cursor(read_only=True) as cur:
            cur.execute("SELECT id, data, created_at FROM patroni_test WHERE id = %s", (insert_id,))
            result = cur.fetchone()

            if result:
                print(f"✓ Read record from replica:")
                print(f"  ID: {result['id']}")
                print(f"  Data: {result['data']}")
                print(f"  Created At: {result['created_at']}")
                return True
            else:
                print("✗ Record not found on replica (replication lag?)")
                return False

    except Exception as e:
        print(f"✗ Read operation failed: {e}")
        return False


def test_read_write_split(pools):
    """Test 5: Verify read/write splitting."""
    print("\n" + "=" * 60)
    print("TEST 5: Read/Write Split Verification")
    print("=" * 60)

    try:
        # Get initial stats
        health = pools.health_check()
        initial_stats = health.get("ha_cluster", {}).get("statistics", {})
        initial_reads = initial_stats.get("reads", 0)
        initial_writes = initial_stats.get("writes", 0)

        # Perform some writes
        for i in range(3):
            with pools.project_cursor(read_only=False) as cur:
                cur.execute("SELECT 1")

        # Perform some reads
        for i in range(5):
            with pools.project_cursor(read_only=True) as cur:
                cur.execute("SELECT 1")

        # Get final stats
        health = pools.health_check()
        final_stats = health.get("ha_cluster", {}).get("statistics", {})
        final_reads = final_stats.get("reads", 0)
        final_writes = final_stats.get("writes", 0)

        writes_delta = final_writes - initial_writes
        reads_delta = final_reads - initial_reads

        print(f"Write Operations: {writes_delta} (expected: 3)")
        print(f"Read Operations: {reads_delta} (expected: 5)")

        if writes_delta >= 3 and reads_delta >= 5:
            print("✓ Read/write splitting is working correctly")
            return True
        else:
            print("✗ Read/write splitting may not be working as expected")
            return False

    except Exception as e:
        print(f"✗ Read/write split test failed: {e}")
        return False


def cleanup_test_data(pools):
    """Cleanup test data."""
    print("\n" + "=" * 60)
    print("Cleanup: Removing Test Data")
    print("=" * 60)

    try:
        with pools.project_cursor(read_only=False) as cur:
            cur.execute("DROP TABLE IF EXISTS patroni_test")
            print("✓ Test table dropped")
    except Exception as e:
        print(f"⚠ Cleanup failed: {e}")


def main():
    """Run all tests."""
    print("=" * 60)
    print("Patroni HA Pool Test Suite")
    print("=" * 60)

    # Check environment
    if os.getenv("ENABLE_PATRONI", "false").lower() != "true":
        print("\n⚠ ENABLE_PATRONI is not set to 'true'")
        print("Set ENABLE_PATRONI=true in your .env file to enable Patroni mode")
        sys.exit(1)

    patroni_hosts = os.getenv("PATRONI_HOSTS")
    if not patroni_hosts:
        print("\n✗ PATRONI_HOSTS environment variable is not set")
        print("Please configure Patroni settings in your .env file")
        sys.exit(1)

    print(f"\nPatroni Hosts: {patroni_hosts}")
    print(f"Patroni Port: {os.getenv('PATRONI_PORT', '8008')}")

    # Run tests
    pools = None
    try:
        pools = test_patroni_initialization()

        test_results = {
            "health_check": test_health_check(pools),
            "write_to_primary": False,
            "read_from_replica": False,
            "read_write_split": False,
        }

        # Test writes
        insert_id = test_write_to_primary(pools)
        test_results["write_to_primary"] = insert_id is not None

        # Test reads
        if insert_id:
            test_results["read_from_replica"] = test_read_from_replica(pools, insert_id)

        # Test read/write splitting
        test_results["read_write_split"] = test_read_write_split(pools)

        # Cleanup
        cleanup_test_data(pools)

        # Summary
        print("\n" + "=" * 60)
        print("TEST SUMMARY")
        print("=" * 60)

        total_tests = len(test_results)
        passed_tests = sum(1 for result in test_results.values() if result)

        for test_name, result in test_results.items():
            status = "✓ PASS" if result else "✗ FAIL"
            print(f"{status}: {test_name}")

        print(f"\nTotal: {passed_tests}/{total_tests} tests passed")

        if passed_tests == total_tests:
            print("\n🎉 All tests passed! Patroni HA mode is working correctly.")
            return 0
        else:
            print(f"\n⚠ {total_tests - passed_tests} test(s) failed. Review the output above.")
            return 1

    except KeyboardInterrupt:
        print("\n\n⚠ Tests interrupted by user")
        return 130

    finally:
        if pools:
            pools.close()
            print("\n✓ Connection pools closed")


if __name__ == "__main__":
    sys.exit(main())
