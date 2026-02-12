#!/usr/bin/env python3
"""
Validate database migration files for syntax, order, and conflicts.
"""

# Standard library imports
import argparse
import os
import re
import sys
from pathlib import Path
from typing import Dict, List, Tuple

# Third-party imports
import sqlparse


class MigrationValidator:
    """Validates database migration files."""

    def __init__(self, migrations_path: str):
        self.migrations_path = Path(migrations_path)
        self.errors: List[str] = []
        self.warnings: List[str] = []

    def validate_all(
        self,
        check_syntax: bool = True,
        check_order: bool = True,
        check_reversibility: bool = True,
        check_conflicts: bool = False,
        base_branch: str = None,
    ) -> bool:
        """Run all validation checks."""

        print("=" * 70)
        print("DATABASE MIGRATION VALIDATION")
        print("=" * 70)

        if check_syntax:
            print("\n[1/5] Checking SQL syntax...")
            self.check_sql_syntax()

        if check_order:
            print("\n[2/5] Checking migration order...")
            self.check_migration_order()

        if check_reversibility:
            print("\n[3/5] Checking reversibility...")
            self.check_reversibility()

        if check_conflicts:
            print("\n[4/5] Checking for conflicts...")
            self.check_conflicts(base_branch)

        print("\n[5/5] Checking naming conventions...")
        self.check_naming_conventions()

        self._print_summary()

        return len(self.errors) == 0

    def check_sql_syntax(self) -> None:
        """Validate SQL syntax in migration files."""

        sql_files = self._get_sql_files()

        for sql_file in sql_files:
            try:
                with open(sql_file, "r") as f:
                    content = f.read()

                # Parse SQL
                parsed = sqlparse.parse(content)

                if not parsed:
                    self.warnings.append(f"{sql_file.name}: Empty or invalid SQL")
                    continue

                # Check for common issues
                for statement in parsed:
                    stmt_str = str(statement).strip().upper()

                    # Check for dangerous operations
                    if "DROP DATABASE" in stmt_str:
                        self.errors.append(f"{sql_file.name}: Contains DROP DATABASE")

                    if "TRUNCATE" in stmt_str and "CASCADE" not in stmt_str:
                        self.warnings.append(f"{sql_file.name}: TRUNCATE without CASCADE")

                print(f"  ✓ {sql_file.name}")

            except Exception as e:
                self.errors.append(f"{sql_file.name}: Syntax error - {e}")

    def check_migration_order(self) -> None:
        """Check migration files are in correct order."""

        migration_files = self._get_migration_files()

        if not migration_files:
            self.warnings.append("No migration files found")
            return

        # Extract version numbers
        versions = []
        for file in migration_files:
            match = re.match(r"(\d+)_.*", file.name)
            if match:
                versions.append((int(match.group(1)), file))
            else:
                self.errors.append(
                    f"{file.name}: Invalid naming (should start with version number)"
                )

        # Check sequential order
        versions.sort(key=lambda x: x[0])

        for i in range(len(versions) - 1):
            current_version = versions[i][0]
            next_version = versions[i + 1][0]

            if next_version != current_version + 1:
                self.warnings.append(
                    f"Gap in migration versions: {current_version} -> {next_version}"
                )

        print(f"  ✓ Found {len(versions)} migrations in sequence")

    def check_reversibility(self) -> None:
        """Check that migrations have corresponding down migrations."""

        migration_files = self._get_migration_files()

        for migration in migration_files:
            # Check for upgrade/downgrade functions (Alembic style)
            with open(migration, "r") as f:
                content = f.read()

            has_upgrade = "def upgrade()" in content or "def up(" in content
            has_downgrade = "def downgrade()" in content or "def down(" in content

            if has_upgrade and not has_downgrade:
                self.errors.append(f"{migration.name}: Missing downgrade function")

            # Check for down migration file (SQL style)
            if migration.suffix == ".sql":
                down_file = migration.parent / migration.name.replace("_up", "_down")
                if not down_file.exists() and "_up" in migration.name:
                    self.warnings.append(f"{migration.name}: No corresponding down migration")

        print(f"  ✓ Checked {len(migration_files)} migrations for reversibility")

    def check_conflicts(self, base_branch: str = None) -> None:
        """Check for conflicting migrations (multiple branches)."""

        if not base_branch:
            print("  ⊘ Skipped (no base branch specified)")
            return

        # Standard library imports
        import subprocess

        try:
            # Get migration files in base branch
            result = subprocess.run(
                ["git", "ls-tree", "-r", "--name-only", base_branch, str(self.migrations_path)],
                capture_output=True,
                text=True,
                check=True,
            )

            base_migrations = set(result.stdout.strip().split("\n"))

            # Get current migration files
            current_migrations = {
                str(f.relative_to(self.migrations_path.parent)) for f in self._get_migration_files()
            }

            # Find new migrations
            new_migrations = current_migrations - base_migrations

            if len(new_migrations) > 1:
                self.warnings.append(
                    f"Multiple new migrations detected: {', '.join(new_migrations)}"
                )

            print(f"  ✓ Found {len(new_migrations)} new migration(s)")

        except subprocess.CalledProcessError:
            self.warnings.append("Could not check for conflicts (git error)")

    def check_naming_conventions(self) -> None:
        """Check migration file naming conventions."""

        migration_files = self._get_migration_files()

        for migration in migration_files:
            name = migration.stem

            # Check format: YYYYMMDDHHMMSS_description or 001_description
            if not re.match(r"^\d+_[a-z0-9_]+$", name.lower()):
                self.warnings.append(
                    f"{migration.name}: Non-standard naming " "(should be: version_description)"
                )

            # Check for spaces
            if " " in name:
                self.errors.append(f"{migration.name}: Contains spaces (use underscores)")

            # Check description
            parts = name.split("_", 1)
            if len(parts) > 1 and len(parts[1]) < 3:
                self.warnings.append(f"{migration.name}: Description too short")

        print(f"  ✓ Checked {len(migration_files)} migration names")

    def _get_migration_files(self) -> List[Path]:
        """Get all migration files."""
        if not self.migrations_path.exists():
            return []

        return sorted(self.migrations_path.glob("**/*.py"), key=lambda f: f.name) + sorted(
            self.migrations_path.glob("**/*.sql"), key=lambda f: f.name
        )

    def _get_sql_files(self) -> List[Path]:
        """Get all SQL migration files."""
        if not self.migrations_path.exists():
            return []

        return sorted(self.migrations_path.glob("**/*.sql"), key=lambda f: f.name)

    def _print_summary(self) -> None:
        """Print validation summary."""

        print("\n" + "=" * 70)
        print("VALIDATION SUMMARY")
        print("=" * 70)

        if self.errors:
            print(f"\n❌ ERRORS ({len(self.errors)}):")
            for error in self.errors:
                print(f"  • {error}")

        if self.warnings:
            print(f"\n⚠️  WARNINGS ({len(self.warnings)}):")
            for warning in self.warnings:
                print(f"  • {warning}")

        if not self.errors and not self.warnings:
            print("\n✅ All checks passed!")
        elif not self.errors:
            print("\n✅ No errors (warnings only)")
        else:
            print(f"\n❌ Validation failed with {len(self.errors)} error(s)")

        print()


def main():
    parser = argparse.ArgumentParser(description="Validate database migration files")
    parser.add_argument("--path", required=True, help="Path to migrations directory")
    parser.add_argument("--check-syntax", action="store_true", help="Check SQL syntax")
    parser.add_argument("--check-order", action="store_true", help="Check migration order")
    parser.add_argument(
        "--check-reversibility", action="store_true", help="Check migration reversibility"
    )
    parser.add_argument(
        "--check-conflicts", action="store_true", help="Check for migration conflicts"
    )
    parser.add_argument(
        "--check-dependencies", action="store_true", help="Check migration dependencies"
    )
    parser.add_argument(
        "--base-branch",
        default="origin/main",
        help="Base branch for conflict detection (default: origin/main)",
    )

    args = parser.parse_args()

    validator = MigrationValidator(args.path)

    success = validator.validate_all(
        check_syntax=args.check_syntax,
        check_order=args.check_order,
        check_reversibility=args.check_reversibility,
        check_conflicts=args.check_conflicts,
        base_branch=args.base_branch if args.check_conflicts else None,
    )

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
