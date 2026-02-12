"""
High Availability Testing Suite

Comprehensive testing for Patroni HA implementation including:
- Automatic failover
- Replication integrity
- Consensus mechanisms
- Integration scenarios
"""

__all__ = [
    "test_patroni_failover",
    "test_replication",
    "test_etcd_consensus",
    "test_ha_integration",
]
