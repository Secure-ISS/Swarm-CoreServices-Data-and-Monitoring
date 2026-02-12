"""
Pytest configuration and shared fixtures for HA tests
"""

# Standard library imports
import os
import time
from typing import Dict, List

# Third-party imports
import pytest


def pytest_configure(config):
    """Register custom markers"""
    config.addinivalue_line(
        "markers", "slow: marks tests as slow (deselect with '-m \"not slow\"')"
    )
    config.addinivalue_line(
        "markers", "requires_cluster: marks tests that require full cluster setup"
    )
    config.addinivalue_line("markers", "destructive: marks tests that may disrupt cluster")


@pytest.fixture(scope="session")
def cluster_config():
    """Provide cluster configuration"""
    return {
        "patroni_nodes": [
            {
                "name": "pg-node-1",
                "host": "localhost",
                "port": "5432",
                "container_name": "patroni-node-1",
            },
            {
                "name": "pg-node-2",
                "host": "localhost",
                "port": "5433",
                "container_name": "patroni-node-2",
            },
            {
                "name": "pg-node-3",
                "host": "localhost",
                "port": "5434",
                "container_name": "patroni-node-3",
            },
        ],
        "etcd_nodes": [
            {
                "name": "etcd-1",
                "host": "localhost",
                "client_port": "2379",
                "container_name": "etcd-node-1",
            },
            {
                "name": "etcd-2",
                "host": "localhost",
                "client_port": "2381",
                "container_name": "etcd-node-2",
            },
            {
                "name": "etcd-3",
                "host": "localhost",
                "client_port": "2383",
                "container_name": "etcd-node-3",
            },
        ],
        "failover_timeout": 30,
        "replication_lag_threshold": 5.0,
    }


@pytest.fixture
def test_cleanup():
    """Cleanup fixture to run after each test"""
    yield
    # Cleanup code here if needed
    time.sleep(1)
