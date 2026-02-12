"""Error handling best practices.

Demonstrates:
- Catching specific exceptions
- Proper error recovery
- Validation
- Logging errors
"""

# Standard library imports
import logging
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Local imports
from src.db import get_pools
from src.db.pool import DatabaseConfigurationError, DatabaseConnectionError
from src.db.vector_ops import (
    InvalidEmbeddingError,
    VectorOperationError,
    search_memory,
    store_memory,
)

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def example_1_invalid_embedding():
    """Example: Handling invalid embedding dimensions."""
    print("Example 1: Invalid Embedding Dimensions")
    print("-" * 50)

    pools = get_pools()
    namespace = "example_error"

    # Try to store with wrong dimensions
    try:
        wrong_embedding = [0.1] * 512  # Should be 384!

        with pools.project_cursor() as cur:
            store_memory(cur, namespace, "test_key", "test value", embedding=wrong_embedding)

    except InvalidEmbeddingError as e:
        logger.error(f"Embedding error: {e}")
        print(f"✓ Caught InvalidEmbeddingError: {e}")
        print("  Solution: Use 384-dimensional embeddings\n")


def example_2_connection_error():
    """Example: Handling connection errors."""
    print("Example 2: Connection Error Handling")
    print("-" * 50)

    try:
        # Try to connect with wrong credentials
        os.environ["RUVECTOR_PASSWORD"] = "wrong_password"

        # Local imports
        from src.db.pool import DualDatabasePools

        pools = DualDatabasePools()

    except DatabaseConnectionError as e:
        logger.error(f"Connection failed: {e}")
        print(f"✓ Caught DatabaseConnectionError")
        print("  Solution: Check database is running and credentials are correct\n")

    finally:
        # Restore correct password
        os.environ["RUVECTOR_PASSWORD"] = "dpg_cluster_2026"


def example_3_database_operation_error():
    """Example: Handling database operation errors."""
    print("Example 3: Database Operation Errors")
    print("-" * 50)

    pools = get_pools()
    namespace = "example_error"

    try:
        # Try to search with invalid parameters
        invalid_embedding = [0.1] * 100  # Wrong dimensions

        with pools.project_cursor() as cur:
            results = search_memory(cur, namespace, invalid_embedding, limit=10)

    except InvalidEmbeddingError as e:
        logger.error(f"Invalid query embedding: {e}")
        print(f"✓ Caught InvalidEmbeddingError in search")
        print("  Solution: Ensure query embedding is 384 dimensions\n")


def example_4_input_validation():
    """Example: Input validation before database operations."""
    print("Example 4: Input Validation")
    print("-" * 50)

    pools = get_pools()

    def store_with_validation(namespace, key, value, embedding=None):
        """Store with proper input validation."""
        # Validate inputs
        if not namespace or not key or not value:
            raise ValueError("namespace, key, and value are required")

        if embedding:
            if not isinstance(embedding, (list, tuple)):
                raise TypeError("embedding must be a list or tuple")

            if len(embedding) != 384:
                raise ValueError(f"embedding must be 384 dimensions, got {len(embedding)}")

            # Check for invalid values
            if not all(isinstance(x, (int, float)) for x in embedding):
                raise TypeError("embedding values must be numeric")

        # If validation passes, store
        with pools.project_cursor() as cur:
            store_memory(cur, namespace, key, value, embedding=embedding)

    # Test validation
    try:
        store_with_validation("", "key", "value")
    except ValueError as e:
        print(f"✓ Caught validation error: {e}")

    try:
        store_with_validation("test", "key", "value", embedding=[0.1] * 100)
    except ValueError as e:
        print(f"✓ Caught validation error: {e}")

    print("  Validation prevents invalid database operations\n")


def example_5_graceful_degradation():
    """Example: Graceful degradation when features fail."""
    print("Example 5: Graceful Degradation")
    print("-" * 50)

    pools = get_pools()
    namespace = "example_error"

    def store_with_fallback(namespace, key, value, embedding=None):
        """Store with fallback if embedding fails."""
        try:
            # Try to store with embedding
            with pools.project_cursor() as cur:
                store_memory(cur, namespace, key, value, embedding=embedding)
            return True, "Stored with embedding"

        except InvalidEmbeddingError as e:
            logger.warning(f"Invalid embedding, storing without: {e}")
            # Fallback: store without embedding
            try:
                with pools.project_cursor() as cur:
                    store_memory(cur, namespace, key, value, embedding=None)
                return True, "Stored without embedding"
            except Exception as e2:
                logger.error(f"Fallback also failed: {e2}")
                return False, str(e2)

    # Test with invalid embedding
    success, message = store_with_fallback(
        namespace, "test_key", "test value", embedding=[0.1] * 100  # Invalid!
    )

    print(f"✓ Operation result: {message}")
    print("  System continues to function despite errors\n")

    # Cleanup
    with pools.project_cursor() as cur:
        cur.execute("DELETE FROM memory_entries WHERE namespace = %s", (namespace,))


def main():
    """Run error handling examples."""
    print("=== Error Handling Examples ===\n")

    example_1_invalid_embedding()
    example_2_connection_error()
    example_3_database_operation_error()
    example_4_input_validation()
    example_5_graceful_degradation()

    print("=== Done! ===")
    print("\nKey Takeaways:")
    print("  - Catch specific exceptions, not generic Exception")
    print("  - Validate inputs before database operations")
    print("  - Log errors for debugging")
    print("  - Implement graceful degradation")
    print("  - Provide clear error messages to users")


if __name__ == "__main__":
    main()
