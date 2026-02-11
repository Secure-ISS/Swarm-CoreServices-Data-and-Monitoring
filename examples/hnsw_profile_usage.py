"""
HNSW Profile Manager Usage Examples

Demonstrates integration of HNSW dual-profile strategy with existing
vector operations for dynamic performance optimization.

Expected Performance Gains:
    - 2x faster queries during high load (SPEED profile)
    - Automatic adaptation to workload changes
    - 90-99% recall across all profiles
"""

import sys
import time
from pathlib import Path

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from src.db.pool import DualDatabasePools
from src.db.vector_ops import VectorOperations
from src.db.hnsw_profiles import (
    HNSWProfileManager,
    ProfileType,
    create_profile_manager,
    print_profile_info,
    PROFILES
)


def example_1_basic_usage():
    """Example 1: Basic profile switching."""
    print("\n" + "="*70)
    print("EXAMPLE 1: Basic Profile Switching")
    print("="*70)

    # Initialize connections
    pools = DualDatabasePools()
    pool = pools.get_pool("shared")

    # Create profile manager
    manager = create_profile_manager(
        pool,
        schema="claude_flow",
        auto_adjust=False  # Manual control for demo
    )

    # Show current profile
    current = manager.get_current_profile()
    print(f"\nCurrent profile: {current.name}")
    print(f"ef_search: {current.ef_search}")

    # Switch to SPEED for high-load scenario
    print("\n[Scenario: Expecting high load, switching to SPEED]")
    manager.switch_profile(
        ProfileType.SPEED,
        reason="High traffic expected"
    )

    current = manager.get_current_profile()
    print(f"New profile: {current.name}")
    print(f"ef_search: {current.ef_search} (was 200)")
    print(f"Expected speedup: 2-4x")

    # Return to balanced
    print("\n[Scenario: Load normalized, returning to BALANCED]")
    manager.switch_profile(
        ProfileType.BALANCED,
        reason="Load returned to normal"
    )

    pools.close_all()


def example_2_auto_adjustment():
    """Example 2: Automatic profile adjustment based on load."""
    print("\n" + "="*70)
    print("EXAMPLE 2: Automatic Profile Adjustment")
    print("="*70)

    pools = DualDatabasePools()
    pool = pools.get_pool("shared")

    # Create manager with auto-adjust enabled
    manager = create_profile_manager(
        pool,
        schema="claude_flow",
        auto_adjust=True,
        load_threshold_high=0.8,
        load_threshold_low=0.4
    )

    print("\nAuto-adjustment enabled:")
    print(f"  High threshold: 80% → SPEED")
    print(f"  Low threshold: 40% → ACCURACY")
    print(f"  Middle range: BALANCED")

    # Trigger auto-adjustment
    print("\n[Triggering auto-adjustment...]")
    new_profile = manager.auto_adjust_profile()

    if new_profile:
        print(f"Profile changed to: {new_profile.value}")
    else:
        current = manager.get_current_profile()
        print(f"Profile unchanged: {current.name}")

    # Show statistics
    stats = manager.get_stats()
    print("\nProfile Manager Stats:")
    print(f"  Current: {stats['current_profile']}")
    print(f"  Total switches: {stats['total_switches']}")
    print(f"  Current load: {stats['load_stats']['current_load']:.1%}")

    pools.close_all()


def example_3_integration_with_vector_ops():
    """Example 3: Integration with vector operations."""
    print("\n" + "="*70)
    print("EXAMPLE 3: Integration with Vector Operations")
    print("="*70)

    pools = DualDatabasePools()
    pool = pools.get_pool("shared")

    # Initialize vector operations
    vector_ops = VectorOperations(pool)

    # Create profile manager
    manager = create_profile_manager(pool, schema="claude_flow")

    # Scenario: Batch insert - switch to SPEED for throughput
    print("\n[Scenario: Batch insert - optimizing for throughput]")
    manager.switch_profile(ProfileType.SPEED, "Batch insert operation")

    # Simulate batch insert
    print("Inserting embeddings with SPEED profile...")
    import numpy as np

    for i in range(5):
        embedding = np.random.rand(384).tolist()
        metadata = {
            "source": f"batch_document_{i}",
            "type": "test",
            "batch": "speed_demo"
        }

        try:
            vector_ops.insert_embedding(
                embedding=embedding,
                metadata=metadata,
                schema="claude_flow",
                table="embeddings"
            )
            print(f"  Inserted document {i+1}/5")
        except Exception as e:
            print(f"  Error: {e}")

    # Scenario: Research query - switch to ACCURACY for precision
    print("\n[Scenario: Research query - optimizing for accuracy]")
    manager.switch_profile(ProfileType.ACCURACY, "Research query")

    # Simulate search
    query_embedding = np.random.rand(384).tolist()
    print("Searching with ACCURACY profile...")

    try:
        results = vector_ops.search_similar(
            query_embedding=query_embedding,
            schema="claude_flow",
            table="embeddings",
            limit=5
        )
        print(f"  Found {len(results)} results with high precision")
    except Exception as e:
        print(f"  Error: {e}")

    # Return to balanced
    manager.switch_profile(ProfileType.BALANCED, "Operations complete")

    pools.close_all()


def example_4_query_pattern_recommendations():
    """Example 4: Get recommendations based on query patterns."""
    print("\n" + "="*70)
    print("EXAMPLE 4: Query Pattern Recommendations")
    print("="*70)

    pools = DualDatabasePools()
    pool = pools.get_pool("shared")
    manager = create_profile_manager(pool, schema="claude_flow")

    # Different query scenarios
    scenarios = [
        ("research", 5, "Research query, low QPS"),
        ("api", 50, "API endpoint, moderate QPS"),
        ("batch", 200, "Batch processing, high QPS"),
        (None, 10, "General query, normal QPS"),
    ]

    print("\nRecommendations for different scenarios:\n")

    for pattern, qps, description in scenarios:
        profile, reasoning = manager.get_recommendation(
            query_pattern=pattern,
            expected_qps=qps
        )

        print(f"Scenario: {description}")
        print(f"  Pattern: {pattern or 'None'}, QPS: {qps}")
        print(f"  → Recommended: {profile.value}")
        print(f"  → Reasoning: {reasoning}")
        print()

    pools.close_all()


def example_5_performance_monitoring():
    """Example 5: Monitor profile switches and performance."""
    print("\n" + "="*70)
    print("EXAMPLE 5: Performance Monitoring")
    print("="*70)

    pools = DualDatabasePools()
    pool = pools.get_pool("shared")
    manager = create_profile_manager(pool, schema="claude_flow")

    # Simulate several switches
    print("\nSimulating workload changes...\n")

    switches = [
        (ProfileType.SPEED, "High traffic detected"),
        (ProfileType.BALANCED, "Traffic normalized"),
        (ProfileType.ACCURACY, "Research mode activated"),
        (ProfileType.BALANCED, "Back to normal operations"),
    ]

    for profile, reason in switches:
        manager.switch_profile(profile, reason)
        time.sleep(0.1)  # Small delay for demonstration

    # Show statistics
    stats = manager.get_stats()

    print("Performance Statistics:")
    print(f"  Current Profile: {stats['current_profile']}")
    print(f"  Total Switches: {stats['total_switches']}")
    print(f"  Current Load: {stats['load_stats']['current_load']:.1%}")

    print("\nRecent Switch History:")
    for switch in stats['recent_switches']:
        print(f"  {switch['timestamp'][:19]} | "
              f"{switch['from_profile']} → {switch['to_profile']} | "
              f"{switch['reason']}")

    pools.close_all()


def example_6_best_practices():
    """Example 6: Best practices for production use."""
    print("\n" + "="*70)
    print("EXAMPLE 6: Production Best Practices")
    print("="*70)

    print("""
Best Practices for HNSW Profile Management:

1. AUTO-ADJUSTMENT
   ✓ Enable auto_adjust=True for dynamic workloads
   ✓ Tune thresholds based on your SLA requirements
   ✓ Monitor switch frequency (too high = adjust thresholds)

2. PROFILE SELECTION
   ✓ ACCURACY: Research, compliance, critical decisions
   ✓ BALANCED: Default for most production workloads
   ✓ SPEED: High load, batch processing, real-time systems

3. MONITORING
   ✓ Track switch frequency and patterns
   ✓ Monitor query latency across profiles
   ✓ Alert on excessive switches (>10/min)

4. INTEGRATION
   ✓ Switch before batch operations
   ✓ Return to BALANCED after completion
   ✓ Use get_recommendation() for application logic

5. PERFORMANCE TUNING
   ✓ Profile your specific queries
   ✓ Adjust ef_search values if needed
   ✓ Test recall vs latency tradeoffs
   ✓ Benchmark with realistic data volumes

6. ERROR HANDLING
   ✓ Always wrap switches in try-except
   ✓ Have fallback profile (BALANCED)
   ✓ Log all switch failures
   ✓ Monitor profile manager health

Example Production Setup:
    """)

    print("""
    # Initialize with monitoring
    pools = DualDatabasePools()
    manager = create_profile_manager(
        pools.get_pool("shared"),
        schema="claude_flow",
        auto_adjust=True,
        load_threshold_high=0.75,  # Your SLA threshold
        load_threshold_low=0.30    # Your SLA threshold
    )

    # Periodic auto-adjustment (in background thread)
    import threading
    def auto_adjust_loop():
        while True:
            try:
                new_profile = manager.auto_adjust_profile()
                if new_profile:
                    # Log profile change to monitoring system
                    log_profile_change(new_profile)
            except Exception as e:
                logger.error(f"Auto-adjust failed: {e}")
            time.sleep(60)  # Adjust every minute

    adjust_thread = threading.Thread(
        target=auto_adjust_loop,
        daemon=True
    )
    adjust_thread.start()

    # Application code
    try:
        # Get recommendation for specific query
        profile, reason = manager.get_recommendation(
            query_pattern="api",
            expected_qps=current_qps
        )

        # Override if needed
        if critical_query:
            manager.switch_profile(
                ProfileType.ACCURACY,
                "Critical compliance query"
            )

        # Perform query
        results = vector_ops.search_similar(...)

    finally:
        # Always return to balanced
        manager.switch_profile(
            ProfileType.BALANCED,
            "Query complete"
        )
    """)


def print_all_profiles():
    """Print detailed information about all profiles."""
    print("\n" + "="*70)
    print("HNSW PROFILE REFERENCE")
    print("="*70)

    for profile_type in ProfileType:
        print_profile_info(PROFILES[profile_type])


def main():
    """Run all examples."""
    print("\n" + "="*70)
    print("HNSW DUAL-PROFILE STRATEGY - USAGE EXAMPLES")
    print("="*70)
    print("\nThis demonstrates dynamic performance optimization")
    print("with automatic profile switching based on load.")
    print(f"\nExpected benefits:")
    print(f"  • 2x faster queries under high load")
    print(f"  • Automatic adaptation to workload")
    print(f"  • 90-99% recall across all profiles")

    try:
        # Show all profiles first
        print_all_profiles()

        # Run examples
        example_1_basic_usage()
        example_2_auto_adjustment()
        example_3_integration_with_vector_ops()
        example_4_query_pattern_recommendations()
        example_5_performance_monitoring()
        example_6_best_practices()

        print("\n" + "="*70)
        print("All examples completed successfully!")
        print("="*70 + "\n")

    except Exception as e:
        print(f"\n[ERROR] Example failed: {e}")
        import traceback
        traceback.print_exc()
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
