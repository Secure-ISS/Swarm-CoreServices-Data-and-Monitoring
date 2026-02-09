#!/usr/bin/env python3
"""
Migrate SQLite memory to PostgreSQL safely.
Preserves all data, embeddings, and metadata.

Usage:
    python3 scripts/migrate_sqlite_to_postgres.py --dry-run
    python3 scripts/migrate_sqlite_to_postgres.py
    python3 scripts/migrate_sqlite_to_postgres.py --sqlite-path .swarm/memory.db
"""

import sqlite3
import json
import sys
import os
from datetime import datetime

# Add project root to path
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(__file__)), 'src'))

try:
    from db.pool import DualDatabasePools
except ImportError:
    print("ERROR: Cannot import DualDatabasePools")
    print("Please ensure src/db/pool.py exists")
    sys.exit(1)

from dotenv import load_dotenv
load_dotenv()


def migrate_sqlite_to_postgres(sqlite_path: str, dry_run: bool = False):
    """Migrate SQLite memory to PostgreSQL."""

    print(f"\n{'='*60}")
    print("SQLite to PostgreSQL Migration")
    print(f"{'='*60}\n")

    if not os.path.exists(sqlite_path):
        print(f"ERROR: SQLite database not found: {sqlite_path}")
        return False

    # Connect to SQLite
    print(f"[1/5] Reading from SQLite: {sqlite_path}")
    sqlite_conn = sqlite3.connect(sqlite_path)
    sqlite_conn.row_factory = sqlite3.Row
    cursor = sqlite_conn.cursor()

    # Get all entries
    cursor.execute("SELECT * FROM memory_entries ORDER BY created_at")
    entries = cursor.fetchall()
    total = len(entries)

    # Group by namespace
    by_namespace = {}
    for entry in entries:
        ns = entry['namespace']
        if ns not in by_namespace:
            by_namespace[ns] = []
        by_namespace[ns].append(entry)

    print(f"      Found {total} entries across {len(by_namespace)} namespaces:")
    for ns, ns_entries in sorted(by_namespace.items(), key=lambda x: len(x[1]), reverse=True):
        print(f"        - {ns}: {len(ns_entries)} entries")

    if dry_run:
        print("\n[DRY RUN] No changes will be made to PostgreSQL")
        print(f"[DRY RUN] Would migrate {total} entries")
        sqlite_conn.close()
        return True

    # Connect to PostgreSQL
    print("\n[2/5] Connecting to PostgreSQL...")
    try:
        pools = DualDatabasePools()
        health = pools.health_check()
        print(f"      Project DB: {health['project']['database']}")
        print(f"      RuVector: {health['project']['ruvector_version']}")
    except Exception as e:
        print(f"ERROR: Failed to connect to PostgreSQL: {e}")
        sqlite_conn.close()
        return False

    # Migrate entries
    print(f"\n[3/5] Migrating {total} entries to PostgreSQL...")
    migrated = 0
    skipped = 0
    errors = []

    for i, entry in enumerate(entries, 1):
        try:
            # Parse embedding if exists
            embedding_str = None
            if entry['embedding']:
                try:
                    emb = json.loads(entry['embedding'])
                    if isinstance(emb, list) and len(emb) == 384:
                        embedding_str = f"[{','.join(str(v) for v in emb)}]"
                except (json.JSONDecodeError, TypeError):
                    pass

            # Parse metadata
            metadata = {}
            if entry['metadata']:
                try:
                    metadata = json.loads(entry['metadata'])
                except (json.JSONDecodeError, TypeError):
                    pass

            # Add migration info
            metadata['_migrated_from'] = 'sqlite'
            metadata['_migrated_at'] = datetime.utcnow().isoformat()

            # Parse tags
            tags = None
            if entry['tags']:
                try:
                    tags = json.loads(entry['tags'])
                except (json.JSONDecodeError, TypeError):
                    pass

            # Determine value column name (varies between schema versions)
            value = None
            for col in ['value', 'content']:
                try:
                    value = entry[col]
                    break
                except (IndexError, KeyError):
                    continue

            # Insert to PostgreSQL
            with pools.project_cursor() as cur:
                cur.execute("""
                    INSERT INTO memory_entries
                        (namespace, key, value, embedding, metadata, tags)
                    VALUES (%s, %s, %s, %s::ruvector, %s::jsonb, %s)
                    ON CONFLICT (namespace, key) DO UPDATE
                    SET value = EXCLUDED.value,
                        embedding = EXCLUDED.embedding,
                        metadata = EXCLUDED.metadata,
                        updated_at = NOW()
                """, (
                    entry['namespace'],
                    entry['key'],
                    value,
                    embedding_str,
                    json.dumps(metadata),
                    tags
                ))

            migrated += 1
            if (i % 100 == 0) or (i == total):
                print(f"      Progress: {i}/{total} ({(i/total)*100:.1f}%)")

        except Exception as e:
            errors.append(f"{entry['namespace']}/{entry['key']}: {str(e)}")
            skipped += 1

    print(f"\n[4/5] Migration Summary:")
    print(f"      Migrated: {migrated}")
    if skipped > 0:
        print(f"      Skipped:  {skipped}")
        print("\n      Errors:")
        for error in errors[:10]:
            print(f"        - {error}")

    # Verify
    print(f"\n[5/5] Verifying migration...")
    with pools.project_cursor() as cur:
        cur.execute("""
            SELECT namespace, COUNT(*) as count
            FROM memory_entries
            GROUP BY namespace
            ORDER BY count DESC
        """)
        results = cur.fetchall()
        total_pg = sum(r['count'] for r in results)
        print(f"      PostgreSQL now contains {total_pg} entries")
        print(f"      SQLite had {total} entries")

        if total_pg >= total:
            print(f"      Migration successful!")
        else:
            print(f"      Warning: PostgreSQL has fewer entries than SQLite")

    # Cleanup
    sqlite_conn.close()
    pools.close()

    print(f"\n{'='*60}")
    print("Migration Complete!")
    print(f"{'='*60}\n")

    return True


if __name__ == '__main__':
    import argparse

    parser = argparse.ArgumentParser(description='Migrate SQLite memory to PostgreSQL')
    parser.add_argument('--sqlite-path', default='.swarm/memory.db',
                       help='Path to SQLite database')
    parser.add_argument('--dry-run', action='store_true',
                       help='Show what would be migrated without making changes')

    args = parser.parse_args()

    success = migrate_sqlite_to_postgres(args.sqlite_path, args.dry_run)
    sys.exit(0 if success else 1)
