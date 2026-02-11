# Bulk Operations with PostgreSQL COPY

## Overview

The bulk operations module (`src/db/bulk_ops.py`) provides optimized bulk insert operations using PostgreSQL's COPY protocol with StringIO buffers. This achieves significant performance improvements over individual INSERT statements.

## Performance Results

Based on comprehensive benchmarking:

| Entries | Individual INSERTs | Bulk COPY | Speedup |
|---------|-------------------|-----------|---------|
| 10      | 687 entries/sec   | 744 entries/sec | 1.1x |
| 100     | 746 entries/sec   | 1,718 entries/sec | 2.3x |
| 1,000   | 696 entries/sec   | 1,821 entries/sec | 2.6x |

**Peak Performance:**
- Bulk COPY: ~1,828 entries/sec
- Individual INSERTs: ~696 entries/sec
- **Overall speedup: 2.6x faster for large batches**

## Features

### 1. Multiple Table Support

Three bulk insert functions for different table types:
- `bulk_insert_memory_entries()` - For memory_entries table
- `bulk_insert_patterns()` - For patterns table
- `bulk_insert_trajectories()` - For trajectories table

### 2. Conflict Resolution

Two strategies for handling duplicate entries:
- `on_conflict='skip'` - Skip conflicting entries (ON CONFLICT DO NOTHING)
- `on_conflict='update'` - Update conflicting entries (ON CONFLICT DO UPDATE)

### 3. Comprehensive Validation

- Empty entry list validation
- Required field validation
- Embedding dimension validation (must be 384-dimensional)
- Automatic input sanitization for COPY protocol

### 4. Transaction Safety

- All operations wrapped in transactions
- Automatic rollback on any error
- Temporary tables for conflict handling
- Proper error propagation with custom exceptions

### 5. Performance Monitoring

- Automatic timing of all operations
- Detailed logging with throughput metrics
- Benchmark comparison utilities

## Usage Examples

### Basic Bulk Insert

```python
from db.pool import get_pools
from db.bulk_ops import bulk_insert_memory_entries

pools = get_pools()

# Prepare entries
entries = [
    {
        'namespace': 'improvements',
        'key': f'entry_{i}',
        'value': f'Value {i}',
        'embedding': [0.1] * 384,  # 384-dimensional vector
        'metadata': {'index': i},
        'tags': ['bulk', 'test']
    }
    for i in range(1000)
]

# Bulk insert
with pools.project_cursor() as cur:
    count = bulk_insert_memory_entries(cur, entries)
    print(f"Inserted {count} entries")
```

### Conflict Handling

```python
# Skip duplicates
with pools.project_cursor() as cur:
    count = bulk_insert_memory_entries(
        cur,
        entries,
        on_conflict='skip'  # Skip existing entries
    )

# Update existing
with pools.project_cursor() as cur:
    count = bulk_insert_memory_entries(
        cur,
        entries,
        on_conflict='update'  # Update existing entries
    )
```

### Bulk Insert Patterns

```python
from db.bulk_ops import bulk_insert_patterns

patterns = [
    {
        'name': f'pattern_{i}',
        'pattern_type': 'optimization',
        'description': f'Pattern description {i}',
        'embedding': [0.2] * 384,
        'confidence': 0.8,
        'usage_count': 10,
        'success_count': 8,
        'metadata': {'category': 'performance'}
    }
    for i in range(100)
]

with pools.project_cursor() as cur:
    count = bulk_insert_patterns(cur, patterns)
    print(f"Inserted {count} patterns")
```

### Bulk Insert Trajectories

```python
from db.bulk_ops import bulk_insert_trajectories

trajectories = [
    {
        'trajectory_id': f'traj_{i // 10}',
        'step_number': i % 10,
        'action': 'move_forward',
        'state': {'position': i, 'velocity': i * 0.5},
        'reward': 1.0,
        'embedding': [0.3] * 384,
        'metadata': {'batch': 'training'}
    }
    for i in range(100)
]

with pools.project_cursor() as cur:
    count = bulk_insert_trajectories(cur, trajectories)
    print(f"Inserted {count} trajectories")
```

## Error Handling

The module provides comprehensive error handling with custom exceptions:

```python
from db.bulk_ops import (
    bulk_insert_memory_entries,
    InvalidEmbeddingError,
    VectorOperationError
)

try:
    with pools.project_cursor() as cur:
        count = bulk_insert_memory_entries(cur, entries)

except ValueError as e:
    # Missing required fields or empty entry list
    print(f"Validation error: {e}")

except InvalidEmbeddingError as e:
    # Wrong embedding dimensions
    print(f"Embedding error: {e}")

except VectorOperationError as e:
    # Database operation failed
    print(f"Database error: {e}")
```

## When to Use Bulk Operations

### Use Bulk COPY for:
- ✓ Inserting 10+ entries at once
- ✓ Initial data loading
- ✓ Batch processing pipelines
- ✓ Migration scripts
- ✓ High-throughput scenarios

### Use Individual INSERTs for:
- ✓ Single entry operations
- ✓ Interactive applications
- ✓ Simple CRUD operations
- ✓ < 10 entries

## Implementation Details

### StringIO Buffer

All bulk operations use StringIO buffers to prepare data in PostgreSQL COPY format:

```python
buffer = StringIO()
for entry in entries:
    # Format as tab-separated values
    buffer.write(f"{namespace}\t{key}\t{value}\t...\n")
buffer.seek(0)

# COPY from buffer
cursor.copy_from(buffer, temp_table, columns=(...))
```

### Temporary Tables

Conflict handling uses temporary tables to safely merge data:

```python
# Create temp table
CREATE TEMPORARY TABLE temp_xyz (...) ON COMMIT DROP

# COPY into temp
COPY temp_xyz FROM buffer

# Insert with conflict handling
INSERT INTO target SELECT * FROM temp_xyz
ON CONFLICT (...) DO UPDATE/NOTHING
```

### Data Format Validation

All data is validated and escaped for COPY protocol:
- Embeddings: `[0.1,0.2,0.3]` format
- JSON: Escaped with `\\`, `\n`, `\t` handling
- Arrays: `{tag1,tag2,tag3}` format
- NULL: `\N` marker

## Testing

Run the comprehensive test suite:

```bash
python3 src/test_bulk_ops.py
```

Test coverage:
- ✓ Basic bulk insert (100 entries)
- ✓ Conflict handling (skip mode)
- ✓ Conflict handling (update mode)
- ✓ Input validation
- ✓ Bulk pattern inserts (50 entries)
- ✓ Bulk trajectory inserts (100 entries)
- ✓ Performance benchmarks (10, 100, 1000 entries)

## Files

| File | Description |
|------|-------------|
| `/home/matt/projects/Distributed-Postgress-Cluster/src/db/bulk_ops.py` | Main implementation |
| `/home/matt/projects/Distributed-Postgress-Cluster/src/test_bulk_ops.py` | Test suite with benchmarks |
| `/home/matt/projects/Distributed-Postgress-Cluster/src/db/__init__.py` | Exports for easy importing |
| `/home/matt/projects/Distributed-Postgress-Cluster/docs/BULK_OPERATIONS.md` | This documentation |

## Integration with Existing Code

The bulk operations module integrates seamlessly with existing database code:

```python
from db import (
    get_pools,
    store_memory,  # Individual insert
    bulk_insert_memory_entries  # Bulk insert
)

pools = get_pools()

# Use individual insert for small operations
with pools.project_cursor() as cur:
    store_memory(cur, 'test', 'key1', 'value1', embedding=[...])

# Use bulk insert for large batches
with pools.project_cursor() as cur:
    bulk_insert_memory_entries(cur, large_entry_list)
```

## Memory Storage

Implementation details have been stored in the memory system:

```bash
# View implementation details
npx @claude-flow/cli@latest memory retrieve --key bulk-ops-implementation --namespace improvements

# View performance results
npx @claude-flow/cli@latest memory retrieve --key bulk-ops-performance --namespace improvements
```

## Future Enhancements

Potential improvements for even better performance:

1. **Parallel Processing**: Split large batches across multiple connections
2. **Streaming**: Support for streaming large datasets without loading into memory
3. **Auto-batching**: Automatic batch size optimization based on data size
4. **Compression**: Optional compression for large text/JSON fields
5. **Progress Callbacks**: Progress reporting for very large batches

## References

- PostgreSQL COPY documentation: https://www.postgresql.org/docs/current/sql-copy.html
- RuVector extension: https://github.com/ruvnet/ruvector
- Error handling guide: `/home/matt/projects/Distributed-Postgress-Cluster/docs/ERROR_HANDLING.md`
