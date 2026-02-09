"""Vector operations for memory storage and retrieval with RuVector.

Provides functions for storing, retrieving, and searching vector embeddings
in both project-specific and shared knowledge databases.
"""
from typing import List, Dict, Any, Optional, Literal
import json


def store_memory(
    cursor,
    namespace: str,
    key: str,
    value: str,
    embedding: Optional[List[float]] = None,
    metadata: Optional[Dict] = None,
    tags: Optional[List[str]] = None
) -> None:
    """Store a memory entry with optional vector embedding.

    Args:
        cursor: Database cursor (from pool.project_cursor() or pool.shared_cursor())
        namespace: Namespace for organizing memories
        key: Unique key within the namespace
        value: The content to store
        embedding: Optional 384-dimensional vector embedding
        metadata: Optional JSON metadata
        tags: Optional list of tags
    """
    embedding_str = None
    if embedding and len(embedding) == 384:
        embedding_str = f"[{','.join(str(v) for v in embedding)}]"

    cursor.execute("""
        INSERT INTO memory_entries
            (namespace, key, value, embedding, metadata, tags)
        VALUES (%s, %s, %s, %s::ruvector, %s::jsonb, %s)
        ON CONFLICT (namespace, key) DO UPDATE
        SET value = EXCLUDED.value,
            embedding = EXCLUDED.embedding,
            metadata = EXCLUDED.metadata,
            tags = EXCLUDED.tags,
            updated_at = NOW()
    """, (
        namespace, key, value, embedding_str,
        json.dumps(metadata or {}), tags
    ))


def search_memory(
    cursor,
    namespace: str,
    query_embedding: List[float],
    limit: int = 10,
    min_similarity: float = 0.7
) -> List[Dict[str, Any]]:
    """Search memories by vector similarity using HNSW index.

    Args:
        cursor: Database cursor
        namespace: Namespace to search within
        query_embedding: 384-dimensional query vector
        limit: Maximum number of results
        min_similarity: Minimum cosine similarity (0-1)

    Returns:
        List of matching memory entries with similarity scores
    """
    if len(query_embedding) != 384:
        raise ValueError(f"Expected 384-dimensional embedding, got {len(query_embedding)}")

    embedding_str = f"[{','.join(str(v) for v in query_embedding)}]"

    cursor.execute("""
        SELECT
            namespace, key, value, metadata, tags,
            1 - (embedding <=> %s::ruvector) as similarity,
            created_at
        FROM memory_entries
        WHERE namespace = %s
          AND embedding IS NOT NULL
          AND (1 - (embedding <=> %s::ruvector)) >= %s
        ORDER BY embedding <=> %s::ruvector
        LIMIT %s
    """, (
        embedding_str, namespace,
        embedding_str, min_similarity,
        embedding_str, limit
    ))

    return [dict(row) for row in cursor.fetchall()]


def retrieve_memory(
    cursor,
    namespace: str,
    key: str
) -> Optional[Dict[str, Any]]:
    """Retrieve a specific memory entry by namespace and key.

    Args:
        cursor: Database cursor
        namespace: Namespace of the memory
        key: Key of the memory

    Returns:
        Memory entry dict or None if not found
    """
    cursor.execute("""
        SELECT namespace, key, value, metadata, tags, created_at, updated_at
        FROM memory_entries
        WHERE namespace = %s AND key = %s
    """, (namespace, key))

    result = cursor.fetchone()
    return dict(result) if result else None


def list_memories(
    cursor,
    namespace: str,
    limit: int = 100,
    offset: int = 0
) -> List[Dict[str, Any]]:
    """List memory entries in a namespace.

    Args:
        cursor: Database cursor
        namespace: Namespace to list
        limit: Maximum number of entries
        offset: Offset for pagination

    Returns:
        List of memory entries
    """
    cursor.execute("""
        SELECT namespace, key, value, metadata, tags, created_at, updated_at
        FROM memory_entries
        WHERE namespace = %s
        ORDER BY created_at DESC
        LIMIT %s OFFSET %s
    """, (namespace, limit, offset))

    return [dict(row) for row in cursor.fetchall()]


def delete_memory(
    cursor,
    namespace: str,
    key: str
) -> bool:
    """Delete a memory entry.

    Args:
        cursor: Database cursor
        namespace: Namespace of the memory
        key: Key of the memory

    Returns:
        True if deleted, False if not found
    """
    cursor.execute("""
        DELETE FROM memory_entries
        WHERE namespace = %s AND key = %s
        RETURNING id
    """, (namespace, key))

    return cursor.fetchone() is not None


def count_memories(
    cursor,
    namespace: Optional[str] = None
) -> int:
    """Count memory entries, optionally filtered by namespace.

    Args:
        cursor: Database cursor
        namespace: Optional namespace filter

    Returns:
        Count of memory entries
    """
    if namespace:
        cursor.execute("""
            SELECT COUNT(*) as count
            FROM memory_entries
            WHERE namespace = %s
        """, (namespace,))
    else:
        cursor.execute("SELECT COUNT(*) as count FROM memory_entries")

    result = cursor.fetchone()
    return result['count'] if result else 0
