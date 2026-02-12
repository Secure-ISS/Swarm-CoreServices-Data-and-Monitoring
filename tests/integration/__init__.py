"""Integration tests for distributed PostgreSQL cluster.

This package contains comprehensive integration tests for:
- Citus sharding and distributed queries
- Patroni HA failover scenarios
- HAProxy routing (primary vs replicas)
- Redis caching layer
- RuVector operations across shards
- Backup and restore procedures
- Security (SSL/TLS, authentication)
- Connection management and pool exhaustion
- Data consistency across shards
- Automatic failover and recovery
- Cache invalidation and coherence
"""

__version__ = "1.0.0"
