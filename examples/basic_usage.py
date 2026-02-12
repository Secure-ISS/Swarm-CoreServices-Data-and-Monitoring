"""Basic CRUD operations example.

Demonstrates:
- Storing memory entries
- Retrieving by key
- Listing entries
- Deleting entries
"""

# Standard library imports
import os
import sys

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Local imports
from src.db import get_pools
from src.db.vector_ops import (
    count_memories,
    delete_memory,
    list_memories,
    retrieve_memory,
    store_memory,
)


def main():
    """Run basic CRUD examples."""
    print("=== Basic CRUD Operations ===\n")

    # Get database pools
    pools = get_pools()

    # Example namespace
    namespace = "example_basic"

    # 1. Store entries
    print("1. Storing entries...")
    entries = [
        ("user_1", "John Doe", {"email": "john@example.com"}, ["active", "premium"]),
        ("user_2", "Jane Smith", {"email": "jane@example.com"}, ["active"]),
        ("user_3", "Bob Wilson", {"email": "bob@example.com"}, ["inactive"]),
    ]

    for key, value, metadata, tags in entries:
        with pools.project_cursor() as cur:
            store_memory(cur, namespace, key, value, metadata=metadata, tags=tags)
        print(f"  ✓ Stored {key}")

    # 2. Retrieve specific entry
    print("\n2. Retrieving user_1...")
    with pools.project_cursor() as cur:
        entry = retrieve_memory(cur, namespace, "user_1")
        if entry:
            print(f"  Key: {entry['key']}")
            print(f"  Value: {entry['value']}")
            print(f"  Metadata: {entry['metadata']}")
            print(f"  Tags: {entry['tags']}")
            print(f"  Created: {entry['created_at']}")

    # 3. List all entries in namespace
    print("\n3. Listing all entries...")
    with pools.project_cursor() as cur:
        entries = list_memories(cur, namespace, limit=10)
        for entry in entries:
            tags_str = ", ".join(entry["tags"]) if entry["tags"] else "none"
            print(f"  - {entry['key']}: {entry['value']} (tags: {tags_str})")

    # 4. Count entries
    print("\n4. Counting entries...")
    with pools.project_cursor() as cur:
        count = count_memories(cur, namespace)
        print(f"  Total entries in '{namespace}': {count}")

    # 5. Update entry (store with same key)
    print("\n5. Updating user_1...")
    with pools.project_cursor() as cur:
        store_memory(
            cur,
            namespace,
            "user_1",
            "John Doe (updated)",
            metadata={"email": "john.doe@example.com", "updated": True},
            tags=["active", "premium", "verified"],
        )
        print("  ✓ Updated user_1")

    # Verify update
    with pools.project_cursor() as cur:
        entry = retrieve_memory(cur, namespace, "user_1")
        print(f"  New value: {entry['value']}")
        print(f"  New metadata: {entry['metadata']}")

    # 6. Delete entry
    print("\n6. Deleting user_3...")
    with pools.project_cursor() as cur:
        deleted = delete_memory(cur, namespace, "user_3")
        if deleted:
            print("  ✓ Deleted user_3")
        else:
            print("  ✗ user_3 not found")

    # Verify deletion
    with pools.project_cursor() as cur:
        count = count_memories(cur, namespace)
        print(f"  Remaining entries: {count}")

    # 7. Cleanup (optional)
    print("\n7. Cleanup...")
    with pools.project_cursor() as cur:
        cur.execute("DELETE FROM memory_entries WHERE namespace = %s", (namespace,))
        print(f"  ✓ Cleaned up namespace '{namespace}'")

    print("\n=== Done! ===")


if __name__ == "__main__":
    main()
