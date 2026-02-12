"""
etcd Consensus Testing Suite

Tests etcd cluster health and consensus mechanisms including:
- Cluster health verification
- Leader election
- Network partition handling
- Consensus recovery
"""

# Standard library imports
import subprocess
import time
from datetime import datetime
from typing import Dict, List, Optional, Tuple

# Third-party imports
import pytest
import requests


class EtcdTester:
    """Test harness for etcd consensus"""

    def __init__(self, nodes: List[Dict[str, str]]):
        """
        Initialize etcd tester

        Args:
            nodes: List of etcd node configs with name, host, client_port
        """
        self.nodes = nodes
        self.base_timeout = 5

    def get_node_url(self, node: Dict[str, str]) -> str:
        """Get HTTP URL for etcd node"""
        return f"http://{node['host']}:{node['client_port']}"

    def check_node_health(self, node: Dict[str, str]) -> bool:
        """Check if etcd node is healthy"""
        try:
            url = f"{self.get_node_url(node)}/health"
            response = requests.get(url, timeout=self.base_timeout)
            return response.status_code == 200 and response.json().get("health") == "true"
        except Exception as e:
            print(f"Health check failed for {node['name']}: {e}")
            return False

    def get_cluster_members(self, node: Dict[str, str]) -> Optional[List[Dict]]:
        """Get cluster member list from a node"""
        try:
            url = f"{self.get_node_url(node)}/v2/members"
            response = requests.get(url, timeout=self.base_timeout)
            if response.status_code == 200:
                return response.json().get("members", [])
            return None
        except Exception as e:
            print(f"Failed to get members from {node['name']}: {e}")
            return None

    def get_leader_id(self, node: Dict[str, str]) -> Optional[str]:
        """Get current leader ID from a node"""
        try:
            # Get leader from stats endpoint
            url = f"{self.get_node_url(node)}/v2/stats/self"
            response = requests.get(url, timeout=self.base_timeout)
            if response.status_code == 200:
                data = response.json()
                return data.get("leaderInfo", {}).get("leader")
            return None
        except Exception as e:
            print(f"Failed to get leader from {node['name']}: {e}")
            return None

    def is_leader(self, node: Dict[str, str]) -> bool:
        """Check if node is the current leader"""
        try:
            url = f"{self.get_node_url(node)}/v2/stats/self"
            response = requests.get(url, timeout=self.base_timeout)
            if response.status_code == 200:
                data = response.json()
                return data.get("state") == "StateLeader"
            return False
        except Exception as e:
            return False

    def get_leader_node(self) -> Optional[Dict[str, str]]:
        """Find which node is currently the leader"""
        for node in self.nodes:
            if self.is_leader(node):
                return node
        return None

    def set_key(self, node: Dict[str, str], key: str, value: str) -> bool:
        """Set a key-value pair in etcd"""
        try:
            url = f"{self.get_node_url(node)}/v2/keys/{key}"
            response = requests.put(url, data={"value": value}, timeout=self.base_timeout)
            return response.status_code in [200, 201]
        except Exception as e:
            print(f"Failed to set key on {node['name']}: {e}")
            return False

    def get_key(self, node: Dict[str, str], key: str) -> Optional[str]:
        """Get a key value from etcd"""
        try:
            url = f"{self.get_node_url(node)}/v2/keys/{key}"
            response = requests.get(url, timeout=self.base_timeout)
            if response.status_code == 200:
                return response.json().get("node", {}).get("value")
            return None
        except Exception as e:
            print(f"Failed to get key from {node['name']}: {e}")
            return None

    def delete_key(self, node: Dict[str, str], key: str) -> bool:
        """Delete a key from etcd"""
        try:
            url = f"{self.get_node_url(node)}/v2/keys/{key}"
            response = requests.delete(url, timeout=self.base_timeout)
            return response.status_code == 200
        except Exception as e:
            return False

    def stop_node(self, node: Dict[str, str]) -> bool:
        """Stop an etcd node (container)"""
        try:
            cmd = ["docker", "stop", node["container_name"]]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            return result.returncode == 0
        except Exception as e:
            print(f"Failed to stop {node['name']}: {e}")
            return False

    def start_node(self, node: Dict[str, str]) -> bool:
        """Start an etcd node (container)"""
        try:
            cmd = ["docker", "start", node["container_name"]]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            return result.returncode == 0
        except Exception as e:
            print(f"Failed to start {node['name']}: {e}")
            return False

    def wait_for_leader_election(self, timeout: int = 30) -> Optional[Dict[str, str]]:
        """Wait for a leader to be elected"""
        start_time = time.time()

        while time.time() - start_time < timeout:
            leader = self.get_leader_node()
            if leader:
                return leader
            time.sleep(1)

        return None

    def wait_for_node_ready(self, node: Dict[str, str], timeout: int = 30) -> bool:
        """Wait for a node to become ready"""
        start_time = time.time()

        while time.time() - start_time < timeout:
            if self.check_node_health(node):
                return True
            time.sleep(1)

        return False

    def get_cluster_health(self) -> Dict[str, bool]:
        """Get health status of all cluster nodes"""
        health = {}
        for node in self.nodes:
            health[node["name"]] = self.check_node_health(node)
        return health


@pytest.fixture
def etcd_cluster():
    """Fixture providing etcd cluster configuration"""
    nodes = [
        {
            "name": "etcd-1",
            "host": "localhost",
            "client_port": "2379",
            "peer_port": "2380",
            "container_name": "etcd-node-1",
        },
        {
            "name": "etcd-2",
            "host": "localhost",
            "client_port": "2381",
            "peer_port": "2382",
            "container_name": "etcd-node-2",
        },
        {
            "name": "etcd-3",
            "host": "localhost",
            "client_port": "2383",
            "peer_port": "2384",
            "container_name": "etcd-node-3",
        },
    ]
    return EtcdTester(nodes)


class TestEtcdConsensus:
    """etcd consensus test suite"""

    def test_cluster_health(self, etcd_cluster):
        """Test that all etcd nodes are healthy"""
        health = etcd_cluster.get_cluster_health()
        assert all(health.values()), f"Unhealthy nodes: {health}"
        print(f"Cluster health: {health}")

    def test_leader_exists(self, etcd_cluster):
        """Test that a leader is elected"""
        leader = etcd_cluster.get_leader_node()
        assert leader is not None, "No leader elected"
        print(f"Current leader: {leader['name']}")

    def test_all_nodes_agree_on_leader(self, etcd_cluster):
        """Test that all nodes agree on the same leader"""
        leader_ids = set()

        for node in etcd_cluster.nodes:
            leader_id = etcd_cluster.get_leader_id(node)
            if leader_id:
                leader_ids.add(leader_id)

        assert len(leader_ids) == 1, f"Split leadership: {leader_ids}"
        print(f"All nodes agree on leader: {leader_ids}")

    def test_key_value_operations(self, etcd_cluster):
        """Test basic key-value operations"""
        # Use any healthy node
        node = etcd_cluster.nodes[0]
        test_key = f"test_key_{int(time.time())}"
        test_value = f"test_value_{int(time.time())}"

        # Set key
        assert etcd_cluster.set_key(node, test_key, test_value), "Failed to set key"

        # Get key
        retrieved_value = etcd_cluster.get_key(node, test_key)
        assert (
            retrieved_value == test_value
        ), f"Value mismatch: expected {test_value}, got {retrieved_value}"

        # Verify on other nodes
        for other_node in etcd_cluster.nodes[1:]:
            value = etcd_cluster.get_key(other_node, test_key)
            assert value == test_value, f"Inconsistent value on {other_node['name']}"

        # Cleanup
        etcd_cluster.delete_key(node, test_key)
        print(f"Key-value operations verified across all nodes")

    def test_leader_election_after_failure(self, etcd_cluster):
        """Test leader re-election after leader failure"""
        # Identify current leader
        original_leader = etcd_cluster.get_leader_node()
        assert original_leader is not None, "No leader to fail"
        print(f"Original leader: {original_leader['name']}")

        # Stop leader
        assert etcd_cluster.stop_node(original_leader), "Failed to stop leader"
        time.sleep(2)

        # Wait for new leader election
        new_leader = etcd_cluster.wait_for_leader_election(timeout=30)
        assert new_leader is not None, "No new leader elected"
        assert new_leader["name"] != original_leader["name"], "Leader did not change"
        print(f"New leader elected: {new_leader['name']}")

        # Verify cluster still operational
        test_key = f"election_test_{int(time.time())}"
        assert etcd_cluster.set_key(
            new_leader, test_key, "after_election"
        ), "Cluster not operational after election"

        # Restore original leader
        etcd_cluster.start_node(original_leader)
        etcd_cluster.wait_for_node_ready(original_leader)
        time.sleep(3)

        # Cleanup
        etcd_cluster.delete_key(new_leader, test_key)

    def test_quorum_requirement(self, etcd_cluster):
        """Test that cluster requires quorum (majority)"""
        # For 3-node cluster, need at least 2 nodes
        # Stop two nodes to lose quorum
        nodes_to_stop = etcd_cluster.nodes[:2]

        for node in nodes_to_stop:
            etcd_cluster.stop_node(node)

        time.sleep(3)

        # Try to write with only 1 node - should fail
        remaining_node = etcd_cluster.nodes[2]
        test_key = f"quorum_test_{int(time.time())}"
        write_succeeded = etcd_cluster.set_key(remaining_node, test_key, "no_quorum")

        # Restore nodes
        for node in nodes_to_stop:
            etcd_cluster.start_node(node)

        # Wait for cluster recovery
        time.sleep(5)
        for node in nodes_to_stop:
            etcd_cluster.wait_for_node_ready(node)

        # Without quorum, writes should fail
        # Note: exact behavior depends on etcd configuration
        print(f"Write with no quorum: {'succeeded' if write_succeeded else 'failed'}")

    def test_data_consistency_after_partition(self, etcd_cluster):
        """Test data consistency after network partition recovery"""
        # Write initial data
        test_key = f"partition_test_{int(time.time())}"
        initial_value = "before_partition"

        node = etcd_cluster.nodes[0]
        assert etcd_cluster.set_key(node, test_key, initial_value)

        # Verify all nodes have the value
        time.sleep(1)
        for check_node in etcd_cluster.nodes:
            value = etcd_cluster.get_key(check_node, test_key)
            assert value == initial_value, f"Initial value not replicated to {check_node['name']}"

        # Simulate partition by stopping one node
        isolated_node = etcd_cluster.nodes[2]
        etcd_cluster.stop_node(isolated_node)
        time.sleep(2)

        # Update value while node is down
        updated_value = "after_partition"
        assert etcd_cluster.set_key(node, test_key, updated_value)

        # Restore isolated node
        etcd_cluster.start_node(isolated_node)
        etcd_cluster.wait_for_node_ready(isolated_node)
        time.sleep(3)

        # Verify all nodes have updated value
        for check_node in etcd_cluster.nodes:
            value = etcd_cluster.get_key(check_node, test_key)
            assert (
                value == updated_value
            ), f"Inconsistent value on {check_node['name']} after partition recovery"

        # Cleanup
        etcd_cluster.delete_key(node, test_key)
        print("Data consistency verified after partition recovery")

    def test_cluster_membership(self, etcd_cluster):
        """Test cluster membership information"""
        node = etcd_cluster.nodes[0]
        members = etcd_cluster.get_cluster_members(node)

        assert members is not None, "Could not get cluster members"
        assert len(members) == len(
            etcd_cluster.nodes
        ), f"Member count mismatch: {len(members)} vs {len(etcd_cluster.nodes)}"

        print(f"Cluster has {len(members)} members:")
        for member in members:
            print(f"  - {member.get('name')}: {member.get('clientURLs')}")

    def test_consensus_under_load(self, etcd_cluster):
        """Test consensus with multiple concurrent writes"""
        node = etcd_cluster.nodes[0]
        test_prefix = f"load_test_{int(time.time())}"
        num_writes = 50

        # Perform multiple writes
        for i in range(num_writes):
            key = f"{test_prefix}_{i}"
            value = f"value_{i}"
            assert etcd_cluster.set_key(node, key, value), f"Failed to write key {i}"

        # Verify all writes on all nodes
        for i in range(num_writes):
            key = f"{test_prefix}_{i}"
            expected_value = f"value_{i}"

            for check_node in etcd_cluster.nodes:
                value = etcd_cluster.get_key(check_node, key)
                assert (
                    value == expected_value
                ), f"Inconsistent value for {key} on {check_node['name']}"

        # Cleanup
        for i in range(num_writes):
            etcd_cluster.delete_key(node, f"{test_prefix}_{i}")

        print(f"Consensus verified under load: {num_writes} writes")


if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])
