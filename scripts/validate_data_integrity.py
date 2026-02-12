#!/usr/bin/env python3
"""Data Integrity Validation Script

Validates data integrity after backups, restores, or migrations.
"""

# Standard library imports
import os
import sys
from pathlib import Path

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent))

# Third-party imports
from dotenv import load_dotenv

# Local imports
from src.db.pool import DualDatabasePools

# Load environment
env_path = Path(__file__).parent.parent / ".env"
if env_path.exists():
    load_dotenv(env_path)


def check_table_exists(cur, schema: str, table: str) -> bool:
    """Check if a table exists."""
    cur.execute(
        """
        SELECT EXISTS (
            SELECT FROM information_schema.tables
            WHERE table_schema = %s
            AND table_name = %s
        );
    """,
        (schema, table),
    )
    return cur.fetchone()["exists"]


def check_extension(cur, extension: str) -> bool:
    """Check if an extension is installed."""
    cur.execute(
        """
        SELECT EXISTS (
            SELECT FROM pg_extension
            WHERE extname = %s
        );
    """,
        (extension,),
    )
    return cur.fetchone()["exists"]


def check_index(cur, index_name: str) -> bool:
    """Check if an index exists."""
    cur.execute(
        """
        SELECT EXISTS (
            SELECT FROM pg_indexes
            WHERE indexname = %s
        );
    """,
        (index_name,),
    )
    return cur.fetchone()["exists"]


def check_null_embeddings(cur, schema: str, table: str) -> int:
    """Check for NULL embeddings."""
    if not check_table_exists(cur, schema, table):
        return 0

    cur.execute(f"SELECT COUNT(*) FROM {schema}.{table} WHERE embedding IS NULL;")
    return cur.fetchone()["count"]


def check_invalid_vectors(cur, schema: str, table: str) -> int:
    """Check for invalid vector data."""
    if not check_table_exists(cur, schema, table):
        return 0

    # Check for vectors with unexpected dimensions or invalid values
    cur.execute(
        f"""
        SELECT COUNT(*)
        FROM {schema}.{table}
        WHERE embedding IS NOT NULL
          AND (
              LENGTH(embedding::text) < 5
              OR embedding::text NOT LIKE '[%]'
          );
    """
    )
    return cur.fetchone()["count"]


def check_referential_integrity(cur) -> list:
    """Check foreign key constraints."""
    cur.execute(
        """
        SELECT
            conname AS constraint_name,
            conrelid::regclass AS table_name,
            confrelid::regclass AS referenced_table
        FROM pg_constraint
        WHERE contype = 'f'
          AND connamespace::regnamespace::text IN ('public', 'claude_flow');
    """
    )

    issues = []
    constraints = cur.fetchall()

    for constraint in constraints:
        # This would require complex queries to validate actual data
        # For now, just verify constraints exist
        pass

    return issues


def validate_project_database(pools: DualDatabasePools) -> dict:
    """Validate project database integrity."""
    print("\n🔍 Validating Project Database...")

    results = {
        "status": "healthy",
        "checks": {},
        "issues": [],
    }

    with pools.project_cursor() as cur:
        # Check RuVector extension
        print("  Checking RuVector extension...")
        if check_extension(cur, "ruvector"):
            results["checks"]["ruvector_extension"] = "✓ PASS"
        else:
            results["checks"]["ruvector_extension"] = "✗ FAIL"
            results["issues"].append("RuVector extension not installed")
            results["status"] = "degraded"

        # Check schemas
        print("  Checking schemas...")
        for schema in ["public", "claude_flow"]:
            cur.execute(
                """
                SELECT EXISTS (
                    SELECT FROM information_schema.schemata
                    WHERE schema_name = %s
                );
            """,
                (schema,),
            )
            exists = cur.fetchone()["exists"]

            if exists:
                results["checks"][f"{schema}_schema"] = "✓ PASS"
            else:
                results["checks"][f"{schema}_schema"] = "✗ FAIL"
                results["issues"].append(f"Schema '{schema}' not found")
                results["status"] = "degraded"

        # Check critical tables
        print("  Checking critical tables...")
        critical_tables = [
            ("public", "memory_entries"),
            ("public", "patterns"),
            ("public", "trajectories"),
            ("claude_flow", "embeddings"),
            ("claude_flow", "patterns"),
            ("claude_flow", "agents"),
        ]

        for schema, table in critical_tables:
            if check_table_exists(cur, schema, table):
                results["checks"][f"{schema}.{table}"] = "✓ PASS"

                # Count rows
                cur.execute(f"SELECT COUNT(*) FROM {schema}.{table};")
                count = cur.fetchone()["count"]
                results["checks"][f"{schema}.{table}_count"] = count
            else:
                results["checks"][f"{schema}.{table}"] = "⚠ MISSING"
                results["issues"].append(f"Table '{schema}.{table}' not found")

        # Check for NULL embeddings
        print("  Checking for NULL embeddings...")
        null_count = check_null_embeddings(cur, "public", "memory_entries")
        if null_count > 0:
            results["checks"]["null_embeddings"] = f"⚠ WARN ({null_count} NULL)"
            results["issues"].append(f"{null_count} NULL embeddings in memory_entries")
        else:
            results["checks"]["null_embeddings"] = "✓ PASS"

        # Check for invalid vectors
        print("  Checking for invalid vectors...")
        invalid_count = check_invalid_vectors(cur, "public", "memory_entries")
        if invalid_count > 0:
            results["checks"]["invalid_vectors"] = f"✗ FAIL ({invalid_count} invalid)"
            results["issues"].append(f"{invalid_count} invalid vectors in memory_entries")
            results["status"] = "degraded"
        else:
            results["checks"]["invalid_vectors"] = "✓ PASS"

        # Check HNSW indexes
        print("  Checking HNSW indexes...")
        cur.execute(
            """
            SELECT COUNT(*) as count
            FROM pg_indexes
            WHERE schemaname IN ('public', 'claude_flow')
              AND indexdef LIKE '%hnsw%';
        """
        )
        hnsw_count = cur.fetchone()["count"]

        if hnsw_count >= 6:
            results["checks"]["hnsw_indexes"] = f"✓ PASS ({hnsw_count} indexes)"
        else:
            results["checks"]["hnsw_indexes"] = f"⚠ WARN ({hnsw_count} indexes, expected ≥6)"
            results["issues"].append(f"Only {hnsw_count} HNSW indexes found (expected ≥6)")

    return results


def validate_shared_database(pools: DualDatabasePools) -> dict:
    """Validate shared database integrity."""
    print("\n🔍 Validating Shared Database...")

    results = {
        "status": "healthy",
        "checks": {},
        "issues": [],
    }

    with pools.shared_cursor() as cur:
        # Check RuVector extension
        print("  Checking RuVector extension...")
        if check_extension(cur, "ruvector"):
            results["checks"]["ruvector_extension"] = "✓ PASS"
        else:
            results["checks"]["ruvector_extension"] = "✗ FAIL"
            results["issues"].append("RuVector extension not installed")
            results["status"] = "degraded"

        # Check memory_entries table
        print("  Checking memory_entries table...")
        if check_table_exists(cur, "public", "memory_entries"):
            results["checks"]["memory_entries_table"] = "✓ PASS"

            # Count entries
            cur.execute("SELECT COUNT(*) FROM memory_entries;")
            count = cur.fetchone()["count"]
            results["checks"]["memory_entries_count"] = count

            # Check for NULL embeddings
            null_count = check_null_embeddings(cur, "public", "memory_entries")
            if null_count > 0:
                results["checks"]["null_embeddings"] = f"⚠ WARN ({null_count} NULL)"
                results["issues"].append(f"{null_count} NULL embeddings in shared database")
            else:
                results["checks"]["null_embeddings"] = "✓ PASS"
        else:
            results["checks"]["memory_entries_table"] = "⚠ MISSING"
            results["issues"].append("memory_entries table not found in shared database")

    return results


def main():
    """Run all data integrity checks."""
    print("=" * 60)
    print("Data Integrity Validation")
    print("=" * 60)

    try:
        pools = DualDatabasePools()
        print("✓ Connected to databases")

        # Validate both databases
        project_results = validate_project_database(pools)
        shared_results = validate_shared_database(pools)

        # Summary
        print("\n" + "=" * 60)
        print("Validation Summary")
        print("=" * 60)

        print("\nProject Database:")
        print(f"  Status: {project_results['status'].upper()}")
        print(f"  Total Checks: {len(project_results['checks'])}")
        print(f"  Issues Found: {len(project_results['issues'])}")

        print("\nShared Database:")
        print(f"  Status: {shared_results['status'].upper()}")
        print(f"  Total Checks: {len(shared_results['checks'])}")
        print(f"  Issues Found: {len(shared_results['issues'])}")

        # List all issues
        all_issues = project_results["issues"] + shared_results["issues"]
        if all_issues:
            print("\n" + "=" * 60)
            print("Issues Detected")
            print("=" * 60)
            for i, issue in enumerate(all_issues, 1):
                print(f"{i}. {issue}")

        # Detailed results
        print("\n" + "=" * 60)
        print("Detailed Results")
        print("=" * 60)

        print("\nProject Database Checks:")
        for check, result in project_results["checks"].items():
            print(f"  {check}: {result}")

        print("\nShared Database Checks:")
        for check, result in shared_results["checks"].items():
            print(f"  {check}: {result}")

        # Overall status
        if (
            project_results["status"] == "healthy"
            and shared_results["status"] == "healthy"
            and not all_issues
        ):
            print("\n🎉 Data integrity validation PASSED - all checks successful!")
            return 0
        elif project_results["status"] == "degraded" or shared_results["status"] == "degraded":
            print("\n⚠ Data integrity validation completed with ISSUES")
            print("Review issues above and take corrective action")
            return 1
        else:
            print("\n✓ Data integrity validation PASSED with warnings")
            print("Review warnings above")
            return 0

    except Exception as e:
        print(f"\n✗ Validation failed: {e}")
        # Standard library imports
        import traceback

        traceback.print_exc()
        return 1
    finally:
        if "pools" in locals():
            pools.close()


if __name__ == "__main__":
    sys.exit(main())
