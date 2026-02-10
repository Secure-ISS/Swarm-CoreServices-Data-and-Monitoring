#!/usr/bin/env python3
"""Example demonstrating distributed PostgreSQL connection pooling.

This example shows how to use the DistributedDatabasePool for various
common database operations with automatic routing and failover.
"""

import os
import sys
import time
from typing import List

# Add parent directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from src.db.distributed_pool import (
    DistributedDatabasePool,
    DatabaseNode,
    NodeRole,
    QueryType,
    create_pool_from_env
)


def example_1_basic_setup():
    """Example 1: Basic pool setup with single coordinator."""
    print("\n=== Example 1: Basic Setup ===\n")

    coordinator = DatabaseNode(
        host='localhost',
        port=5432,
        database='distributed_postgres_cluster',
        user='dpg_cluster',
        password='dpg_cluster_2026',
        role=NodeRole.COORDINATOR
    )

    pool = DistributedDatabasePool(coordinator_node=coordinator)

    # Write query
    with pool.cursor(QueryType.WRITE) as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS example_users (
                id SERIAL PRIMARY KEY,
                name VARCHAR(100),
                email VARCHAR(100),
                created_at TIMESTAMP DEFAULT NOW()
            )
        """)
        print("✓ Created example_users table")

    # Insert data
    with pool.cursor(QueryType.WRITE) as cur:
        cur.execute(
            "INSERT INTO example_users (name, email) VALUES (%s, %s) RETURNING id",
            ("Alice Johnson", "alice@example.com")
        )
        user_id = cur.fetchone()['id']
        print(f"✓ Inserted user with id={user_id}")

    # Read data
    with pool.cursor(QueryType.READ) as cur:
        cur.execute("SELECT * FROM example_users ORDER BY id DESC LIMIT 5")
        users = cur.fetchall()
        print(f"✓ Retrieved {len(users)} users")
        for user in users:
            print(f"  - {user['name']} ({user['email']})")

    # Cleanup
    pool.close()
    print("\n✓ Pool closed")


def example_2_read_write_splitting():
    """Example 2: Read/write splitting with replicas."""
    print("\n=== Example 2: Read/Write Splitting ===\n")

    coordinator = DatabaseNode(
        host='localhost',
        port=5432,
        database='distributed_postgres_cluster',
        user='dpg_cluster',
        password='dpg_cluster_2026',
        role=NodeRole.COORDINATOR
    )

    # In production, these would be different servers
    # For demo, we use same server but mark as replica
    replica_1 = DatabaseNode(
        host='localhost',
        port=5432,
        database='distributed_postgres_cluster',
        user='dpg_cluster',
        password='dpg_cluster_2026',
        role=NodeRole.REPLICA
    )

    pool = DistributedDatabasePool(
        coordinator_node=coordinator,
        replica_nodes=[replica_1]
    )

    # Write goes to coordinator
    print("Writing to coordinator...")
    with pool.cursor(QueryType.WRITE) as cur:
        cur.execute(
            "INSERT INTO example_users (name, email) VALUES (%s, %s)",
            ("Bob Smith", "bob@example.com")
        )
    print("✓ Write completed")

    # Reads go to replicas (round-robin)
    print("\nReading from replicas...")
    for i in range(3):
        with pool.cursor(QueryType.READ) as cur:
            cur.execute("SELECT COUNT(*) as count FROM example_users")
            result = cur.fetchone()
            print(f"  Read {i+1}: {result['count']} users")

    # Get statistics
    stats = pool.get_statistics()
    print(f"\nStatistics:")
    print(f"  Total queries: {stats['total']}")
    print(f"  Reads: {stats['reads']}")
    print(f"  Writes: {stats['writes']}")

    pool.close()


def example_3_shard_aware_routing():
    """Example 3: Shard-aware query routing."""
    print("\n=== Example 3: Shard-Aware Routing ===\n")

    coordinator = DatabaseNode(
        host='localhost',
        port=5432,
        database='distributed_postgres_cluster',
        user='dpg_cluster',
        password='dpg_cluster_2026',
        role=NodeRole.COORDINATOR
    )

    # In production, these would be separate worker nodes
    # For demo purposes, we simulate with same database
    worker_0 = DatabaseNode(
        host='localhost',
        port=5432,
        database='distributed_postgres_cluster',
        user='dpg_cluster',
        password='dpg_cluster_2026',
        role=NodeRole.WORKER,
        shard_id=0
    )

    worker_1 = DatabaseNode(
        host='localhost',
        port=5432,
        database='distributed_postgres_cluster',
        user='dpg_cluster',
        password='dpg_cluster_2026',
        role=NodeRole.WORKER,
        shard_id=1
    )

    pool = DistributedDatabasePool(
        coordinator_node=coordinator,
        worker_nodes=[worker_0, worker_1]
    )

    # Create sharded table
    with pool.cursor(QueryType.DDL) as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS sharded_orders (
                order_id BIGINT PRIMARY KEY,
                user_id BIGINT,
                amount DECIMAL(10,2),
                created_at TIMESTAMP DEFAULT NOW()
            )
        """)
        print("✓ Created sharded_orders table")

    # Insert with shard keys
    user_ids = [1001, 1002, 1003, 1004, 1005]

    for user_id in user_ids:
        # Query automatically routes to correct shard based on user_id
        with pool.cursor(QueryType.WRITE, shard_key=user_id) as cur:
            cur.execute(
                "INSERT INTO sharded_orders (order_id, user_id, amount) VALUES (%s, %s, %s)",
                (user_id * 100, user_id, 99.99)
            )
        print(f"✓ Inserted order for user {user_id} (routed to shard)")

    # Query with shard key
    target_user = 1003
    with pool.cursor(QueryType.READ, shard_key=target_user) as cur:
        cur.execute(
            "SELECT * FROM sharded_orders WHERE user_id = %s",
            (target_user,)
        )
        orders = cur.fetchall()
        print(f"\n✓ Retrieved {len(orders)} orders for user {target_user}")

    pool.close()


def example_4_distributed_transaction():
    """Example 4: Distributed transaction across shards."""
    print("\n=== Example 4: Distributed Transaction (2PC) ===\n")

    coordinator = DatabaseNode(
        host='localhost',
        port=5432,
        database='distributed_postgres_cluster',
        user='dpg_cluster',
        password='dpg_cluster_2026',
        role=NodeRole.COORDINATOR
    )

    worker_0 = DatabaseNode(
        host='localhost',
        port=5432,
        database='distributed_postgres_cluster',
        user='dpg_cluster',
        password='dpg_cluster_2026',
        role=NodeRole.WORKER,
        shard_id=0
    )

    worker_1 = DatabaseNode(
        host='localhost',
        port=5432,
        database='distributed_postgres_cluster',
        user='dpg_cluster',
        password='dpg_cluster_2026',
        role=NodeRole.WORKER,
        shard_id=1
    )

    pool = DistributedDatabasePool(
        coordinator_node=coordinator,
        worker_nodes=[worker_0, worker_1]
    )

    # Create wallet table
    with pool.cursor(QueryType.DDL) as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS user_wallets (
                user_id BIGINT PRIMARY KEY,
                balance DECIMAL(10,2) DEFAULT 0
            )
        """)

    # Initialize balances
    for user_id in [2001, 2002]:
        with pool.cursor(QueryType.WRITE, shard_key=user_id) as cur:
            cur.execute(
                "INSERT INTO user_wallets (user_id, balance) VALUES (%s, %s) "
                "ON CONFLICT (user_id) DO UPDATE SET balance = EXCLUDED.balance",
                (user_id, 1000.00)
            )

    print("✓ Initialized wallets: user 2001 and 2002 each have $1000")

    # Perform distributed transaction (transfer between users on different shards)
    print("\nPerforming distributed transfer ($100 from user 2001 to user 2002)...")

    try:
        with pool.distributed_transaction([2001, 2002]) as cursors:
            # Deduct from user 2001
            for shard_id, cur in cursors.items():
                if shard_id == pool._get_shard_for_key(2001):
                    cur.execute(
                        "UPDATE user_wallets SET balance = balance - %s WHERE user_id = %s",
                        (100.00, 2001)
                    )
                    print(f"  ✓ Deducted $100 from user 2001 (shard {shard_id})")

            # Add to user 2002
            for shard_id, cur in cursors.items():
                if shard_id == pool._get_shard_for_key(2002):
                    cur.execute(
                        "UPDATE user_wallets SET balance = balance + %s WHERE user_id = %s",
                        (100.00, 2002)
                    )
                    print(f"  ✓ Added $100 to user 2002 (shard {shard_id})")

        print("\n✓ Distributed transaction committed successfully")

    except Exception as e:
        print(f"\n✗ Distributed transaction failed: {e}")

    # Verify balances
    for user_id in [2001, 2002]:
        with pool.cursor(QueryType.READ, shard_key=user_id) as cur:
            cur.execute("SELECT balance FROM user_wallets WHERE user_id = %s", (user_id,))
            result = cur.fetchone()
            print(f"  User {user_id} balance: ${result['balance']}")

    pool.close()


def example_5_health_monitoring():
    """Example 5: Health monitoring and statistics."""
    print("\n=== Example 5: Health Monitoring ===\n")

    pool = create_pool_from_env()

    # Perform some queries
    with pool.cursor(QueryType.READ) as cur:
        cur.execute("SELECT 1")

    with pool.cursor(QueryType.WRITE) as cur:
        cur.execute("SELECT NOW()")

    # Get health status
    print("Health Check:")
    health = pool.health_check()

    print(f"\nCoordinator: {health['coordinator']['host']}:{health['coordinator']['port']}")
    print(f"  Status: {'✓ Healthy' if health['coordinator']['healthy'] else '✗ Unhealthy'}")

    if health['workers']:
        print("\nWorkers:")
        for worker in health['workers']:
            status = '✓ Healthy' if worker['healthy'] else '✗ Unhealthy'
            print(f"  Shard {worker['shard_id']}: {worker['host']}:{worker['port']} - {status}")

    if health['replicas']:
        print("\nReplicas:")
        for replica in health['replicas']:
            status = '✓ Healthy' if replica['healthy'] else '✗ Unhealthy'
            print(f"  {replica['host']}:{replica['port']} - {status}")

    # Get statistics
    stats = health['statistics']
    print("\nStatistics:")
    print(f"  Total queries: {stats['total']}")
    print(f"  Read queries: {stats['reads']}")
    print(f"  Write queries: {stats['writes']}")
    print(f"  Errors: {stats['errors']}")
    print(f"  Retries: {stats['retries']}")

    pool.close()


def example_6_retry_and_failover():
    """Example 6: Automatic retry and failover."""
    print("\n=== Example 6: Retry and Failover ===\n")

    from src.db.distributed_pool import RetryConfig

    coordinator = DatabaseNode(
        host='localhost',
        port=5432,
        database='distributed_postgres_cluster',
        user='dpg_cluster',
        password='dpg_cluster_2026',
        role=NodeRole.COORDINATOR
    )

    # Configure aggressive retry
    retry_config = RetryConfig(
        max_retries=5,
        initial_backoff=0.1,
        max_backoff=2.0,
        backoff_multiplier=2.0,
        jitter=True
    )

    pool = DistributedDatabasePool(
        coordinator_node=coordinator,
        retry_config=retry_config
    )

    print("Configured pool with aggressive retry (max 5 retries)")

    # This will succeed
    try:
        with pool.cursor(QueryType.READ) as cur:
            cur.execute("SELECT 1 as test")
            result = cur.fetchone()
            print(f"✓ Query succeeded: {result['test']}")
    except Exception as e:
        print(f"✗ Query failed: {e}")

    # Simulate connection issues by using invalid credentials
    # (In production, this would handle temporary network issues)
    print("\nSimulating connection retry (this will fail after retries)...")

    bad_node = DatabaseNode(
        host='localhost',
        port=9999,  # Invalid port
        database='distributed_postgres_cluster',
        user='dpg_cluster',
        password='dpg_cluster_2026',
        role=NodeRole.COORDINATOR
    )

    try:
        bad_pool = DistributedDatabasePool(
            coordinator_node=bad_node,
            retry_config=retry_config
        )
    except Exception as e:
        print(f"✓ Failed as expected after retries: {type(e).__name__}")

    pool.close()
    print("\n✓ Example completed")


def example_7_environment_config():
    """Example 7: Environment-based configuration."""
    print("\n=== Example 7: Environment Configuration ===\n")

    # Show current environment variables
    print("Environment variables:")
    env_vars = [
        'COORDINATOR_HOST', 'COORDINATOR_PORT', 'COORDINATOR_DB',
        'WORKER_HOSTS', 'REPLICA_HOSTS'
    ]

    for var in env_vars:
        value = os.getenv(var, '(not set)')
        print(f"  {var}={value}")

    print("\nCreating pool from environment...")

    try:
        pool = create_pool_from_env()
        print("✓ Pool created successfully")

        # Test connection
        with pool.cursor(QueryType.READ) as cur:
            cur.execute("SELECT current_database(), current_user")
            result = cur.fetchone()
            print(f"✓ Connected to: {result['current_database']} as {result['current_user']}")

        pool.close()

    except Exception as e:
        print(f"✗ Failed to create pool: {e}")
        print("\nSet environment variables in .env file:")
        print("""
COORDINATOR_HOST=localhost
COORDINATOR_PORT=5432
COORDINATOR_DB=distributed_postgres_cluster
COORDINATOR_USER=dpg_cluster
COORDINATOR_PASSWORD=dpg_cluster_2026
        """)


def main():
    """Run all examples."""
    print("=" * 70)
    print("Distributed PostgreSQL Connection Pool Examples")
    print("=" * 70)

    examples = [
        ("Basic Setup", example_1_basic_setup),
        ("Read/Write Splitting", example_2_read_write_splitting),
        ("Shard-Aware Routing", example_3_shard_aware_routing),
        ("Distributed Transactions", example_4_distributed_transaction),
        ("Health Monitoring", example_5_health_monitoring),
        ("Retry and Failover", example_6_retry_and_failover),
        ("Environment Configuration", example_7_environment_config),
    ]

    print("\nAvailable examples:")
    for i, (name, _) in enumerate(examples, 1):
        print(f"  {i}. {name}")

    print("\nRunning all examples...\n")

    for name, example_func in examples:
        try:
            example_func()
        except KeyboardInterrupt:
            print("\n\nExamples interrupted by user")
            sys.exit(0)
        except Exception as e:
            print(f"\n✗ Example '{name}' failed with error: {e}")
            import traceback
            traceback.print_exc()

        time.sleep(1)  # Pause between examples

    print("\n" + "=" * 70)
    print("All examples completed!")
    print("=" * 70)


if __name__ == "__main__":
    main()
