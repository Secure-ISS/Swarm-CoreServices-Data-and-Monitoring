# Examples

Practical code examples for working with the Distributed PostgreSQL Cluster.

## Quick Start

```bash
# 1. Setup environment
source venv/bin/activate
source .env

# 2. Start database
./scripts/start_database.sh

# 3. Run examples
python3 examples/basic_usage.py
python3 examples/vector_search.py
python3 examples/batch_operations.py
```

## Available Examples

### Basic Operations

- **[basic_usage.py](basic_usage.py)** - CRUD operations (create, read, update, delete)
- **[vector_search.py](vector_search.py)** - Vector similarity search
- **[connection_pooling.py](connection_pooling.py)** - Connection pool management
- **[error_handling.py](error_handling.py)** - Proper error handling patterns

### Advanced Operations

- **[batch_operations.py](batch_operations.py)** - Efficient batch inserts
- **[pagination.py](pagination.py)** - Paginating large result sets
- **[metadata_filtering.py](metadata_filtering.py)** - Complex metadata queries
- **[tag_search.py](tag_search.py)** - Tag-based filtering

### Python Integration

- **[python_basic.py](python_basic.py)** - Pure Python example
- **[python_embeddings.py](python_embeddings.py)** - Generate embeddings with sentence-transformers
- **[python_concurrent.py](python_concurrent.py)** - Concurrent operations with threading

### Node.js Integration

- **[nodejs_basic.js](nodejs_basic.js)** - Basic operations in Node.js
- **[nodejs_vector_search.js](nodejs_vector_search.js)** - Vector search in Node.js

## Requirements

### Python Examples

```bash
pip install -r requirements.txt
# psycopg2-binary
# python-dotenv
# sentence-transformers  # For embedding examples
```

### Node.js Examples

```bash
npm install pg dotenv
```

## Example Data

Each example generates its own test data. To clean up:

```sql
DELETE FROM memory_entries WHERE namespace LIKE 'example_%';
```

## Troubleshooting

See [docs/TROUBLESHOOTING_DEVELOPER.md](../docs/TROUBLESHOOTING_DEVELOPER.md) for help.
