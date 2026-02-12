"""Vector similarity search example.

Demonstrates:
- Storing entries with embeddings
- Searching by vector similarity
- Similarity thresholds
- Result ranking
"""

# Standard library imports
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Local imports
from src.db import get_pools
from src.db.vector_ops import search_memory, store_memory


def generate_random_embedding():
    """Generate random 384-dimensional embedding for demo."""
    return [random.random() for _ in range(384)]


def generate_similar_embedding(base_embedding, similarity=0.9):
    """Generate embedding similar to base_embedding."""
    noise_amount = 1.0 - similarity
    return [base * (1 - noise_amount) + random.random() * noise_amount for base in base_embedding]


def main():
    """Run vector search examples."""
    print("=== Vector Similarity Search ===\n")

    pools = get_pools()
    namespace = "example_vector"

    # 1. Store documents with embeddings
    print("1. Storing documents with embeddings...")

    # Base embedding for similar documents
    base_embedding = generate_random_embedding()

    documents = [
        {
            "key": "doc_1",
            "value": "Introduction to machine learning and AI",
            "embedding": base_embedding,  # Will have high similarity
            "tags": ["ml", "ai", "intro"],
        },
        {
            "key": "doc_2",
            "value": "Advanced deep learning techniques",
            "embedding": generate_similar_embedding(base_embedding, 0.95),
            "tags": ["ml", "deep-learning", "advanced"],
        },
        {
            "key": "doc_3",
            "value": "Natural language processing fundamentals",
            "embedding": generate_similar_embedding(base_embedding, 0.85),
            "tags": ["nlp", "ml", "fundamentals"],
        },
        {
            "key": "doc_4",
            "value": "Computer vision applications",
            "embedding": generate_similar_embedding(base_embedding, 0.75),
            "tags": ["cv", "applications"],
        },
        {
            "key": "doc_5",
            "value": "Cooking recipes and culinary techniques",
            "embedding": generate_random_embedding(),  # Unrelated
            "tags": ["cooking", "recipes"],
        },
    ]

    for doc in documents:
        with pools.project_cursor() as cur:
            store_memory(
                cur,
                namespace,
                doc["key"],
                doc["value"],
                embedding=doc["embedding"],
                tags=doc["tags"],
            )
        print(f"  ✓ Stored {doc['key']}")

    # 2. Search with high similarity threshold
    print("\n2. Searching with similarity >= 0.8...")
    query_embedding = base_embedding  # Search for similar to doc_1

    with pools.project_cursor() as cur:
        results = search_memory(cur, namespace, query_embedding, limit=5, min_similarity=0.8)

    print(f"  Found {len(results)} results:")
    for result in results:
        print(f"    - {result['key']}: {result['value'][:40]}...")
        print(f"      Similarity: {result['similarity']:.3f}")
        print(f"      Tags: {', '.join(result['tags'])}")

    # 3. Search with lower threshold
    print("\n3. Searching with similarity >= 0.5...")
    with pools.project_cursor() as cur:
        results = search_memory(cur, namespace, query_embedding, limit=10, min_similarity=0.5)

    print(f"  Found {len(results)} results:")
    for i, result in enumerate(results, 1):
        print(f"    {i}. {result['key']}: similarity={result['similarity']:.3f}")

    # 4. Search for different query
    print("\n4. Searching with random query (unrelated)...")
    random_query = generate_random_embedding()

    with pools.project_cursor() as cur:
        results = search_memory(cur, namespace, random_query, limit=5, min_similarity=0.7)

    if results:
        print(f"  Found {len(results)} results:")
        for result in results:
            print(f"    - {result['key']}: similarity={result['similarity']:.3f}")
    else:
        print("  No results found with similarity >= 0.7")

    # 5. Cleanup
    print("\n5. Cleanup...")
    with pools.project_cursor() as cur:
        cur.execute("DELETE FROM memory_entries WHERE namespace = %s", (namespace,))
        print(f"  ✓ Cleaned up namespace '{namespace}'")

    print("\n=== Done! ===")


if __name__ == "__main__":
    main()
