"""Generate real embeddings using sentence-transformers.

Demonstrates:
- Loading embedding model
- Generating 384-dimensional embeddings
- Storing with real embeddings
- Semantic search

Requires: pip install sentence-transformers
"""

# Standard library imports
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Local imports
from src.db import get_pools
from src.db.vector_ops import search_memory, store_memory

try:
    # Third-party imports
    from sentence_transformers import SentenceTransformer
except ImportError:
    print("Error: sentence-transformers not installed")
    print("Install with: pip install sentence-transformers")
    sys.exit(1)


def main():
    """Run embedding examples."""
    print("=== Real Embeddings with sentence-transformers ===\n")

    # 1. Load model
    print("1. Loading embedding model...")
    print("  Model: sentence-transformers/all-MiniLM-L6-v2 (384 dims)")
    model = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2")
    print("  ✓ Model loaded\n")

    # 2. Generate embeddings for documents
    print("2. Generating embeddings for documents...")
    documents = [
        "Python is a high-level programming language",
        "Machine learning enables computers to learn from data",
        "PostgreSQL is a powerful relational database",
        "Vector databases store high-dimensional embeddings",
        "Natural language processing deals with text analysis",
    ]

    embeddings = model.encode(documents)
    print(f"  ✓ Generated {len(embeddings)} embeddings")
    print(f"  Dimensions: {len(embeddings[0])}")  # Should be 384

    # 3. Store documents with embeddings
    print("\n3. Storing documents with embeddings...")
    pools = get_pools()
    namespace = "example_embeddings"

    for i, (doc, emb) in enumerate(zip(documents, embeddings)):
        with pools.project_cursor() as cur:
            store_memory(
                cur,
                namespace,
                f"doc_{i}",
                doc,
                embedding=emb.tolist(),
                metadata={"source": "example", "index": i},
            )
        print(f"  ✓ Stored doc_{i}")

    # 4. Semantic search
    print("\n4. Performing semantic search...")
    queries = [
        "programming languages and software",
        "artificial intelligence and data",
        "database systems",
    ]

    for query in queries:
        print(f"\n  Query: '{query}'")

        # Generate query embedding
        query_emb = model.encode([query])[0]

        # Search
        with pools.project_cursor() as cur:
            results = search_memory(
                cur, namespace, query_emb.tolist(), limit=3, min_similarity=0.0  # Get all results
            )

        print(f"  Top {len(results)} results:")
        for i, result in enumerate(results, 1):
            print(f"    {i}. {result['value'][:50]}...")
            print(f"       Similarity: {result['similarity']:.3f}")

    # 5. Cleanup
    print("\n5. Cleanup...")
    with pools.project_cursor() as cur:
        cur.execute("DELETE FROM memory_entries WHERE namespace = %s", (namespace,))
        print(f"  ✓ Cleaned up namespace '{namespace}'")

    print("\n=== Done! ===")
    print("\nKey Points:")
    print("  - sentence-transformers produces 384-dim embeddings")
    print("  - Compatible with RuVector ruvector(384)")
    print("  - Semantic search finds conceptually similar documents")
    print("  - Model: all-MiniLM-L6-v2 is fast and accurate")


if __name__ == "__main__":
    main()
