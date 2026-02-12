"""Vector operations for memory storage and retrieval with RuVector.

Provides functions for storing, retrieving, and searching vector embeddings
in both project-specific and shared knowledge databases.
"""

# Standard library imports
import json
import logging
from typing import Any, Dict, List, Literal, Optional

# Third-party imports
from psycopg2 import DatabaseError, DataError, IntegrityError

# Configure logging
logger = logging.getLogger(__name__)


class VectorOperationError(Exception):
    """Raised when vector operation fails."""

    pass


class InvalidEmbeddingError(Exception):
    """Raised when embedding dimensions are invalid."""

    pass


def store_memory(
    cursor,
    namespace: str,
    key: str,
    value: str,
    embedding: Optional[List[float]] = None,
    metadata: Optional[Dict] = None,
    tags: Optional[List[str]] = None,
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

    Raises:
        InvalidEmbeddingError: If embedding dimensions != 384
        VectorOperationError: If database operation fails
    """
    # Validate inputs
    if not namespace or not key or not value:
        raise ValueError("namespace, key, and value are required")

    embedding_str = None
    if embedding:
        if len(embedding) != 384:
            raise InvalidEmbeddingError(f"Expected 384-dimensional embedding, got {len(embedding)}")
        try:
            embedding_str = f"[{','.join(str(v) for v in embedding)}]"
        except Exception as e:
            raise InvalidEmbeddingError(f"Invalid embedding format: {e}") from e

    try:
        cursor.execute(
            """
            INSERT INTO memory_entries
                (namespace, key, value, embedding, metadata, tags)
            VALUES (%s, %s, %s, %s::ruvector, %s::jsonb, %s)
            ON CONFLICT (namespace, key) DO UPDATE
            SET value = EXCLUDED.value,
                embedding = EXCLUDED.embedding,
                metadata = EXCLUDED.metadata,
                tags = EXCLUDED.tags,
                updated_at = NOW()
        """,
            (namespace, key, value, embedding_str, json.dumps(metadata or {}), tags),
        )
        logger.debug(f"Stored memory: {namespace}/{key}")
    except IntegrityError as e:
        logger.error(f"Integrity error storing memory: {e}")
        raise VectorOperationError(f"Cannot store memory (integrity violation): {e}") from e
    except DataError as e:
        logger.error(f"Data error storing memory: {e}")
        raise VectorOperationError(f"Invalid data format: {e}") from e
    except DatabaseError as e:
        logger.error(f"Database error storing memory: {e}")
        raise VectorOperationError(f"Database operation failed: {e}") from e


def search_memory(
    cursor,
    namespace: str,
    query_embedding: List[float],
    limit: int = 10,
    min_similarity: float = 0.7,
) -> List[Dict[str, Any]]:
    """Search memories by vector similarity using HNSW index.

    Args:
        cursor: Database cursor
        namespace: Namespace to search within
        query_embedding: 384-dimensional query vector
        limit: Maximum number of results (1-1000)
        min_similarity: Minimum cosine similarity (0-1)

    Returns:
        List of matching memory entries with similarity scores

    Raises:
        InvalidEmbeddingError: If query embedding dimensions != 384
        VectorOperationError: If search operation fails
    """
    # Validate inputs
    if not namespace:
        raise ValueError("namespace is required")

    if len(query_embedding) != 384:
        raise InvalidEmbeddingError(
            f"Expected 384-dimensional embedding, got {len(query_embedding)}"
        )

    if not 0 <= min_similarity <= 1:
        raise ValueError(f"min_similarity must be between 0 and 1, got {min_similarity}")

    if not 1 <= limit <= 1000:
        raise ValueError(f"limit must be between 1 and 1000, got {limit}")

    try:
        embedding_str = f"[{','.join(str(v) for v in query_embedding)}]"
    except Exception as e:
        raise InvalidEmbeddingError(f"Invalid embedding format: {e}") from e

    try:
        # Use SQL format to properly cast the vector
        query = f"""
            SELECT
                namespace, key, value, metadata, tags,
                1 - (embedding <=> '{embedding_str}'::ruvector(384)) as similarity,
                created_at
            FROM memory_entries
            WHERE namespace = %s
              AND embedding IS NOT NULL
              AND (1 - (embedding <=> '{embedding_str}'::ruvector(384))) >= %s
            ORDER BY embedding <=> '{embedding_str}'::ruvector(384)
            LIMIT %s
        """
        cursor.execute(query, (namespace, min_similarity, limit))

        results = [dict(row) for row in cursor.fetchall()]
        logger.debug(f"Search found {len(results)} results in {namespace}")
        return results

    except DataError as e:
        logger.error(f"Data error in search: {e}")
        raise VectorOperationError(f"Invalid search parameters: {e}") from e
    except DatabaseError as e:
        logger.error(f"Database error in search: {e}")
        raise VectorOperationError(f"Search operation failed: {e}") from e


def retrieve_memory(cursor, namespace: str, key: str) -> Optional[Dict[str, Any]]:
    """Retrieve a specific memory entry by namespace and key.

    Args:
        cursor: Database cursor
        namespace: Namespace of the memory
        key: Key of the memory

    Returns:
        Memory entry dict or None if not found

    Raises:
        VectorOperationError: If database operation fails
    """
    if not namespace or not key:
        raise ValueError("namespace and key are required")

    try:
        cursor.execute(
            """
            SELECT namespace, key, value, metadata, tags, created_at, updated_at
            FROM memory_entries
            WHERE namespace = %s AND key = %s
        """,
            (namespace, key),
        )

        result = cursor.fetchone()
        if result:
            logger.debug(f"Retrieved memory: {namespace}/{key}")
        return dict(result) if result else None

    except DatabaseError as e:
        logger.error(f"Database error retrieving memory: {e}")
        raise VectorOperationError(f"Retrieve operation failed: {e}") from e


def list_memories(
    cursor, namespace: str, limit: int = 100, offset: int = 0
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
    cursor.execute(
        """
        SELECT namespace, key, value, metadata, tags, created_at, updated_at
        FROM memory_entries
        WHERE namespace = %s
        ORDER BY created_at DESC
        LIMIT %s OFFSET %s
    """,
        (namespace, limit, offset),
    )

    return [dict(row) for row in cursor.fetchall()]


def delete_memory(cursor, namespace: str, key: str) -> bool:
    """Delete a memory entry.

    Args:
        cursor: Database cursor
        namespace: Namespace of the memory
        key: Key of the memory

    Returns:
        True if deleted, False if not found

    Raises:
        VectorOperationError: If database operation fails
    """
    if not namespace or not key:
        raise ValueError("namespace and key are required")

    try:
        cursor.execute(
            """
            DELETE FROM memory_entries
            WHERE namespace = %s AND key = %s
            RETURNING id
        """,
            (namespace, key),
        )

        deleted = cursor.fetchone() is not None
        if deleted:
            logger.debug(f"Deleted memory: {namespace}/{key}")
        return deleted

    except DatabaseError as e:
        logger.error(f"Database error deleting memory: {e}")
        raise VectorOperationError(f"Delete operation failed: {e}") from e


def count_memories(cursor, namespace: Optional[str] = None) -> int:
    """Count memory entries, optionally filtered by namespace.

    Args:
        cursor: Database cursor
        namespace: Optional namespace filter

    Returns:
        Count of memory entries
    """
    if namespace:
        cursor.execute(
            """
            SELECT COUNT(*) as count
            FROM memory_entries
            WHERE namespace = %s
        """,
            (namespace,),
        )
    else:
        cursor.execute("SELECT COUNT(*) as count FROM memory_entries")

    result = cursor.fetchone()
    return result["count"] if result else 0
