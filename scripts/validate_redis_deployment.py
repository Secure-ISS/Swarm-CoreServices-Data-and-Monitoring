#!/usr/bin/env python3
"""
Redis Cache Deployment Validation
Comprehensive validation of Redis deployment and configuration.
"""

# Standard library imports
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

# Third-party imports
from dotenv import load_dotenv

load_dotenv()


def check_docker_container():
    """Validate Redis Docker container."""
    print("\n1️⃣  Docker Container Status")
    print("-" * 70)

    try:
        # Check if container exists
        result = subprocess.run(
            [
                "docker",
                "ps",
                "-a",
                "--filter",
                "name=redis-cache",
                "--format",
                "{{.Names}}\t{{.Status}}",
            ],
            capture_output=True,
            text=True,
        )

        if "redis-cache" in result.stdout:
            status = result.stdout.split("\t")[1] if "\t" in result.stdout else "Unknown"
            print(f"   Container: redis-cache")
            print(f"   Status: {status}")

            # Check if running
            if "Up" in status:
                print("   ✅ Container is running")

                # Test connectivity
                ping_result = subprocess.run(
                    ["docker", "exec", "redis-cache", "redis-cli", "ping"],
                    capture_output=True,
                    text=True,
                )

                if ping_result.stdout.strip() == "PONG":
                    print("   ✅ Redis responding to ping")
                    return True
                else:
                    print("   ❌ Redis not responding")
                    return False
            else:
                print("   ❌ Container exists but not running")
                return False
        else:
            print("   ❌ Container not found")
            return False

    except Exception as e:
        print(f"   ❌ Error: {e}")
        return False


def check_environment_config():
    """Validate environment configuration."""
    print("\n2️⃣  Environment Configuration")
    print("-" * 70)

    required_vars = {
        "REDIS_HOST": "localhost",
        "REDIS_PORT": "6379",
        "REDIS_DB": "0",
        "REDIS_TTL": "300",
    }

    all_ok = True
    for var, expected in required_vars.items():
        value = os.getenv(var)
        if value:
            print(f"   {var}: {value}")
            if value == expected:
                print(f"      ✅ Default value")
            else:
                print(f"      ℹ️  Custom value")
        else:
            print(f"   {var}: NOT SET")
            print(f"      ⚠️  Using default: {expected}")

    return True


def check_python_module():
    """Validate Python cache module."""
    print("\n3️⃣  Python Cache Module")
    print("-" * 70)

    try:
        # Local imports
        from src.db.cache import get_cache

        print("   ✅ Module import successful")

        # Test cache initialization
        cache = get_cache()

        if cache.redis is None:
            print("   ❌ Redis connection failed")
            return False

        print("   ✅ Cache initialized")

        # Test basic operations
        cache.redis.set("validation_test", "success", ex=10)
        value = cache.redis.get("validation_test")

        if value == "success":
            print("   ✅ Basic operations working")
            return True
        else:
            print("   ❌ Operation validation failed")
            return False

    except ImportError as e:
        print(f"   ❌ Import failed: {e}")
        return False
    except Exception as e:
        print(f"   ❌ Error: {e}")
        return False


def check_cache_functionality():
    """Validate cache decorator functionality."""
    print("\n4️⃣  Cache Decorator Functionality")
    print("-" * 70)

    try:
        # Standard library imports
        import random
        import time

        # Local imports
        from src.db.cache import get_cache

        cache = get_cache()

        # Mock function
        def mock_query(namespace, vector, top_k=10):
            time.sleep(0.05)  # Simulate query
            return [{"id": i, "data": random.random()} for i in range(top_k)]

        # Wrap with cache
        cached_query = cache.cache_vector_search(ttl=60)(mock_query)

        # Reset stats
        cache.stats = {"hits": 0, "misses": 0, "errors": 0}

        # First call (miss)
        vector = [0.1] * 100
        start = time.time()
        result1 = cached_query("test", vector, top_k=5)
        time1 = time.time() - start

        # Second call (hit)
        start = time.time()
        result2 = cached_query("test", vector, top_k=5)
        time2 = time.time() - start

        stats = cache.get_stats()

        print(f"   First call (miss): {time1*1000:.2f}ms")
        print(f"   Second call (hit): {time2*1000:.2f}ms")
        print(f"   Cache hits: {stats['hits']}")
        print(f"   Cache misses: {stats['misses']}")

        if stats["hits"] > 0 and time2 < time1:
            print("   ✅ Cache decorator working")
            return True
        else:
            print("   ❌ Cache decorator not working as expected")
            return False

    except Exception as e:
        print(f"   ❌ Error: {e}")
        return False


def check_automation_scripts():
    """Validate automation scripts exist and are executable."""
    print("\n5️⃣  Automation Scripts")
    print("-" * 70)

    scripts = {
        "start_redis.sh": "Redis startup script",
        "test_redis_cache.py": "Integration tests",
        "benchmark_redis_realistic.py": "Performance benchmark",
    }

    all_ok = True
    for script, description in scripts.items():
        path = os.path.join("scripts", script)
        if os.path.exists(path):
            is_executable = os.access(path, os.X_OK)
            print(f"   {script}: {'✅' if is_executable else '⚠️'} {description}")
            if not is_executable:
                print(f"      Note: Not executable (chmod +x {path})")
        else:
            print(f"   {script}: ❌ Not found")
            all_ok = False

    return all_ok


def check_documentation():
    """Validate documentation files exist."""
    print("\n6️⃣  Documentation")
    print("-" * 70)

    docs = {
        "docs/REDIS_CACHE.md": "Complete usage guide",
        "docs/REDIS_DEPLOYMENT_SUMMARY.md": "Deployment summary",
        "examples/cache_integration_example.py": "Integration examples",
    }

    all_ok = True
    for doc, description in docs.items():
        if os.path.exists(doc):
            size = os.path.getsize(doc)
            print(f"   {doc}: ✅ {description} ({size} bytes)")
        else:
            print(f"   {doc}: ❌ Not found")
            all_ok = False

    return all_ok


def check_redis_info():
    """Get Redis server information."""
    print("\n7️⃣  Redis Server Information")
    print("-" * 70)

    try:
        # Get Redis version
        result = subprocess.run(
            ["docker", "exec", "redis-cache", "redis-cli", "INFO", "server"],
            capture_output=True,
            text=True,
        )

        if result.returncode == 0:
            for line in result.stdout.split("\n"):
                if "redis_version" in line or "uptime_in_seconds" in line:
                    print(f"   {line.strip()}")

        # Get memory info
        result = subprocess.run(
            ["docker", "exec", "redis-cache", "redis-cli", "INFO", "memory"],
            capture_output=True,
            text=True,
        )

        if result.returncode == 0:
            for line in result.stdout.split("\n"):
                if "used_memory_human" in line or "used_memory_peak_human" in line:
                    print(f"   {line.strip()}")

        # Get stats
        result = subprocess.run(
            ["docker", "exec", "redis-cache", "redis-cli", "DBSIZE"], capture_output=True, text=True
        )

        if result.returncode == 0:
            print(f"   keys: {result.stdout.strip()}")

        print("   ✅ Redis info retrieved")
        return True

    except Exception as e:
        print(f"   ❌ Error: {e}")
        return False


def main():
    """Run all validation checks."""
    print("=" * 70)
    print("Redis Cache Deployment Validation")
    print("=" * 70)

    results = {
        "Docker Container": check_docker_container(),
        "Environment Config": check_environment_config(),
        "Python Module": check_python_module(),
        "Cache Functionality": check_cache_functionality(),
        "Automation Scripts": check_automation_scripts(),
        "Documentation": check_documentation(),
        "Redis Information": check_redis_info(),
    }

    # Summary
    print("\n" + "=" * 70)
    print("Validation Summary")
    print("=" * 70)

    for check, passed in results.items():
        status = "✅ PASS" if passed else "❌ FAIL"
        print(f"{status}: {check}")

    passed = sum(1 for v in results.values() if v)
    total = len(results)
    percentage = (passed / total * 100) if total > 0 else 0

    print(f"\n📊 Overall: {passed}/{total} checks passed ({percentage:.1f}%)")

    if passed == total:
        print("\n🎉 All validation checks passed!")
        print("   Redis cache is fully deployed and operational")
        print("\n✅ SUCCESS CRITERIA MET:")
        print("   ✓ Redis container running")
        print("   ✓ Configuration valid")
        print("   ✓ Cache functionality working")
        print("   ✓ Documentation complete")
        print("\nNext steps:")
        print("   1. Integrate cache into your vector search queries")
        print("   2. Monitor cache hit rates in production")
        print("   3. Review docs/REDIS_CACHE.md for usage examples")
        return 0
    else:
        print(f"\n⚠️  {total - passed} check(s) failed")
        print("   Review the output above for details")
        return 1


if __name__ == "__main__":
    sys.exit(main())
