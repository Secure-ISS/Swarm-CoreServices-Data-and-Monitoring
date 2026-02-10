#!/usr/bin/env python3
"""Database Health Check and Startup Script

This script checks database connectivity, validates configuration,
and provides detailed health status for RuVector PostgreSQL setup.
"""
import sys
import os
from pathlib import Path

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from dotenv import load_dotenv
from src.db.pool import (
    DualDatabasePools,
    DatabaseConnectionError,
    DatabaseConfigurationError
)


def check_docker_container():
    """Check if PostgreSQL Docker container is running."""
    import subprocess

    print("🐳 Checking Docker container...")
    try:
        result = subprocess.run(
            ["docker", "ps", "--filter", "publish=5432", "--format", "{{.Names}}"],
            capture_output=True,
            text=True,
            check=True
        )

        containers = result.stdout.strip().split('\n')
        containers = [c for c in containers if c]

        if containers:
            print(f"   ✓ Found PostgreSQL container(s): {', '.join(containers)}")
            return True
        else:
            print("   ✗ No PostgreSQL container running on port 5432")
            print("   💡 Start container with:")
            print("      docker run -d --name ruvector-db \\")
            print("        -e POSTGRES_PASSWORD=your_password \\")
            print("        -p 5432:5432 \\")
            print("        ruvnet/ruvector-postgres")
            return False

    except FileNotFoundError:
        print("   ⚠ Docker not found - skipping container check")
        return None
    except subprocess.CalledProcessError:
        print("   ⚠ Docker command failed - skipping container check")
        return None


def check_environment():
    """Check environment variable configuration."""
    print("\n🔧 Checking environment configuration...")

    required_project = {
        'RUVECTOR_DB': 'distributed_postgres_cluster',
        'RUVECTOR_USER': 'dpg_cluster',
        'RUVECTOR_PASSWORD': 'dpg_cluster_2026',
        'RUVECTOR_HOST': 'localhost',
        'RUVECTOR_PORT': '5432'
    }

    required_shared = {
        'SHARED_KNOWLEDGE_DB': 'claude_flow_shared',
        'SHARED_KNOWLEDGE_USER': 'shared_user',
        'SHARED_KNOWLEDGE_PASSWORD': 'shared_knowledge_2026',
        'SHARED_KNOWLEDGE_HOST': 'localhost',
        'SHARED_KNOWLEDGE_PORT': '5432'
    }

    all_ok = True

    print("   Project Database:")
    for key, expected in required_project.items():
        value = os.getenv(key)
        if not value:
            print(f"      ✗ {key} not set")
            all_ok = False
        elif key.endswith('PASSWORD'):
            print(f"      ✓ {key} = ***")
        else:
            match = "✓" if value == expected else "⚠"
            print(f"      {match} {key} = {value}")

    print("   Shared Database:")
    for key, expected in required_shared.items():
        value = os.getenv(key)
        if not value:
            print(f"      ✗ {key} not set")
            all_ok = False
        elif key.endswith('PASSWORD'):
            print(f"      ✓ {key} = ***")
        else:
            match = "✓" if value == expected else "⚠"
            print(f"      {match} {key} = {value}")

    return all_ok


def check_database_pools():
    """Check database pool initialization and health."""
    print("\n💾 Checking database connections...")

    try:
        pools = DualDatabasePools()
        print("   ✓ Connection pools initialized")

        # Run health check
        health = pools.health_check()

        print("\n   Project Database:")
        project_health = health.get('project', {})
        if project_health.get('status') == 'healthy':
            print(f"      ✓ Status: {project_health['status']}")
            print(f"      ✓ Database: {project_health['database']}")
            print(f"      ✓ User: {project_health['user']}")
            print(f"      ✓ RuVector: {project_health['ruvector_version']}")
        else:
            print(f"      ✗ Status: {project_health.get('status', 'unknown')}")
            print(f"      ✗ Error: {project_health.get('error', 'unknown')}")

        print("\n   Shared Database:")
        shared_health = health.get('shared', {})
        if shared_health.get('status') == 'healthy':
            print(f"      ✓ Status: {shared_health['status']}")
            print(f"      ✓ Database: {shared_health['database']}")
            print(f"      ✓ User: {shared_health['user']}")
            print(f"      ✓ RuVector: {shared_health['ruvector_version']}")
        else:
            print(f"      ✗ Status: {shared_health.get('status', 'unknown')}")
            print(f"      ✗ Error: {shared_health.get('error', 'unknown')}")

        pools.close()

        # Return overall health
        return (
            project_health.get('status') == 'healthy' and
            shared_health.get('status') == 'healthy'
        )

    except DatabaseConfigurationError as e:
        print(f"   ✗ Configuration error: {e}")
        return False
    except DatabaseConnectionError as e:
        print(f"   ✗ Connection error: {e}")
        return False
    except Exception as e:
        print(f"   ✗ Unexpected error: {e}")
        return False


def check_schemas():
    """Check if required database schemas exist."""
    print("\n📊 Checking database schemas...")

    try:
        from src.db.pool import DualDatabasePools
        pools = DualDatabasePools()

        # Check project database schemas
        with pools.project_cursor() as cur:
            cur.execute("""
                SELECT schema_name
                FROM information_schema.schemata
                WHERE schema_name IN ('public', 'claude_flow')
                ORDER BY schema_name
            """)
            schemas = [row['schema_name'] for row in cur.fetchall()]

            print("   Project Database Schemas:")
            for schema in ['public', 'claude_flow']:
                if schema in schemas:
                    print(f"      ✓ {schema}")
                else:
                    print(f"      ✗ {schema} (missing)")

            # Count HNSW indexes
            cur.execute("""
                SELECT COUNT(*) as count
                FROM pg_indexes
                WHERE schemaname IN ('public', 'claude_flow')
                  AND indexdef LIKE '%hnsw%'
            """)
            index_count = cur.fetchone()['count']
            print(f"      ✓ HNSW Indexes: {index_count}")

        pools.close()
        return 'public' in schemas and 'claude_flow' in schemas

    except Exception as e:
        print(f"   ✗ Schema check failed: {e}")
        return False


def main():
    """Run all health checks."""
    print("=" * 60)
    print("🏥 RuVector PostgreSQL Health Check")
    print("=" * 60)

    # Load .env file
    env_path = Path(__file__).parent.parent / '.env'
    if env_path.exists():
        load_dotenv(env_path)
        print(f"✓ Loaded environment from {env_path}")
    else:
        print(f"⚠ No .env file found at {env_path}")

    # Run checks
    docker_ok = check_docker_container()
    env_ok = check_environment()
    db_ok = check_database_pools()
    schema_ok = check_schemas()

    # Summary
    print("\n" + "=" * 60)
    print("📋 Health Check Summary")
    print("=" * 60)

    checks = {
        "Docker Container": docker_ok,
        "Environment Config": env_ok,
        "Database Connections": db_ok,
        "Database Schemas": schema_ok
    }

    all_passed = all(v is True for v in checks.values())

    for check, status in checks.items():
        if status is True:
            print(f"✓ {check}")
        elif status is False:
            print(f"✗ {check}")
        else:
            print(f"⚠ {check} (skipped)")

    print("=" * 60)

    if all_passed:
        print("\n🎉 All checks passed! Database is healthy.")
        return 0
    else:
        print("\n⚠ Some checks failed. Review the output above.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
