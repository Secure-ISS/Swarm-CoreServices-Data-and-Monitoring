"""Database connection pools and vector operations for RuVector + PostgreSQL."""
from .pool import DualDatabasePools, DatabasePools, get_pools, close_pools
from .vector_ops import store_memory, search_memory, retrieve_memory, list_memories, delete_memory, count_memories
from .distributed_pool import (
    DistributedDatabasePool,
    DatabaseNode,
    NodeRole,
    QueryType,
    RetryConfig,
    create_pool_from_env,
    get_distributed_pool,
    close_distributed_pool
)

__all__ = [
    # Standard pools
    'DualDatabasePools',
    'DatabasePools',
    'get_pools',
    'close_pools',
    # Vector operations
    'store_memory',
    'search_memory',
    'retrieve_memory',
    'list_memories',
    'delete_memory',
    'count_memories',
    # Distributed pools
    'DistributedDatabasePool',
    'DatabaseNode',
    'NodeRole',
    'QueryType',
    'RetryConfig',
    'create_pool_from_env',
    'get_distributed_pool',
    'close_distributed_pool',
]
