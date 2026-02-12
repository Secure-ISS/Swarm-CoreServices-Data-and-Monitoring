"""
Unit tests for HNSW profile manager.

Tests cover:
    - Profile switching
    - Auto-adjustment logic
    - Load calculation
    - Recommendation engine
    - Thread safety
    - Error handling
"""

# Standard library imports
import sys
import threading
import time
from pathlib import Path
from unittest.mock import MagicMock, Mock, patch

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent))

# Local imports
from src.db.hnsw_profiles import (
    PROFILES,
    HNSWProfile,
    HNSWProfileManager,
    ProfileType,
    create_profile_manager,
)


class TestProfileDefinitions:
    """Test profile configurations."""

    def test_all_profiles_exist(self):
        """Test that all expected profiles are defined."""
        assert ProfileType.ACCURACY in PROFILES
        assert ProfileType.BALANCED in PROFILES
        assert ProfileType.SPEED in PROFILES

    def test_profile_parameters(self):
        """Test profile parameters are correct."""
        # ACCURACY
        accuracy = PROFILES[ProfileType.ACCURACY]
        assert accuracy.m == 32
        assert accuracy.ef_construction == 400
        assert accuracy.ef_search == 400

        # BALANCED
        balanced = PROFILES[ProfileType.BALANCED]
        assert balanced.m == 24
        assert balanced.ef_construction == 200
        assert balanced.ef_search == 200

        # SPEED
        speed = PROFILES[ProfileType.SPEED]
        assert speed.m == 16
        assert speed.ef_construction == 100
        assert speed.ef_search == 50

    def test_profile_ordering(self):
        """Test profiles are ordered by speed."""
        accuracy = PROFILES[ProfileType.ACCURACY]
        balanced = PROFILES[ProfileType.BALANCED]
        speed = PROFILES[ProfileType.SPEED]

        # ef_search should decrease (faster)
        assert accuracy.ef_search > balanced.ef_search > speed.ef_search

    def test_profile_metadata(self):
        """Test all profiles have required metadata."""
        for profile in PROFILES.values():
            assert profile.name
            assert profile.expected_latency_ms
            assert profile.use_case
            assert profile.description


class TestProfileManager:
    """Test HNSWProfileManager class."""

    def setup_method(self):
        """Set up test fixtures."""
        # Mock connection pool
        self.mock_pool = Mock()
        self.mock_pool.maxconn = 10
        self.mock_pool._used = set()

        # Mock connection
        self.mock_conn = Mock()
        self.mock_cursor = Mock()
        self.mock_conn.cursor.return_value.__enter__ = Mock(return_value=self.mock_cursor)
        self.mock_conn.cursor.return_value.__exit__ = Mock(return_value=False)

        self.mock_pool.getconn.return_value = self.mock_conn

        # Create manager
        self.manager = HNSWProfileManager(
            pool=self.mock_pool, schema="claude_flow", auto_adjust=False
        )

    def test_initialization(self):
        """Test manager initializes with correct defaults."""
        assert self.manager._current_profile == ProfileType.BALANCED
        assert self.manager.schema == "claude_flow"
        assert self.manager.auto_adjust is False

    def test_get_current_profile(self):
        """Test getting current profile."""
        profile = self.manager.get_current_profile()
        assert isinstance(profile, HNSWProfile)
        assert profile.name == "balanced"

    def test_get_specific_profile(self):
        """Test getting specific profile."""
        accuracy = self.manager.get_profile(ProfileType.ACCURACY)
        assert accuracy.name == "accuracy"

        speed = self.manager.get_profile(ProfileType.SPEED)
        assert speed.name == "speed"

    def test_list_profiles(self):
        """Test listing all profiles."""
        profiles = self.manager.list_profiles()
        assert len(profiles) == 3
        assert "accuracy" in profiles
        assert "balanced" in profiles
        assert "speed" in profiles

    def test_switch_profile_success(self):
        """Test successful profile switch."""
        result = self.manager.switch_profile(ProfileType.SPEED, reason="Test switch")

        assert result is True
        assert self.manager._current_profile == ProfileType.SPEED

        # Verify SQL was executed
        self.mock_cursor.execute.assert_called()

    def test_switch_profile_same(self):
        """Test switching to same profile is no-op."""
        current = self.manager._current_profile
        result = self.manager.switch_profile(current, "Same profile")

        assert result is True
        # Should not execute SQL
        self.mock_cursor.execute.assert_not_called()

    def test_switch_profile_records_history(self):
        """Test profile switches are recorded."""
        initial_switches = len(self.manager._switch_history)

        self.manager.switch_profile(ProfileType.SPEED, "Test")
        self.manager.switch_profile(ProfileType.ACCURACY, "Test")

        assert len(self.manager._switch_history) == initial_switches + 2

        last_switch = self.manager._switch_history[-1]
        assert last_switch["to_profile"] == "accuracy"
        assert last_switch["from_profile"] == "speed"


class TestLoadCalculation:
    """Test load calculation and recommendation logic."""

    def setup_method(self):
        """Set up test fixtures."""
        self.mock_pool = Mock()
        self.mock_pool.maxconn = 10
        self.mock_pool._used = set()

        # Mock connection
        self.mock_conn = Mock()
        self.mock_cursor = Mock()
        self.mock_conn.cursor.return_value.__enter__ = Mock(return_value=self.mock_cursor)
        self.mock_conn.cursor.return_value.__exit__ = Mock(return_value=False)

        self.mock_pool.getconn.return_value = self.mock_conn

        self.manager = HNSWProfileManager(
            pool=self.mock_pool, auto_adjust=True, load_threshold_high=0.8, load_threshold_low=0.4
        )

    def test_recommend_profile_low_load(self):
        """Test recommendation with low load."""
        # < 40% → ACCURACY
        profile = self.manager._recommend_profile(0.3)
        assert profile == ProfileType.ACCURACY

    def test_recommend_profile_medium_load(self):
        """Test recommendation with medium load."""
        # 40-80% → BALANCED
        profile = self.manager._recommend_profile(0.5)
        assert profile == ProfileType.BALANCED

    def test_recommend_profile_high_load(self):
        """Test recommendation with high load."""
        # > 80% → SPEED
        profile = self.manager._recommend_profile(0.9)
        assert profile == ProfileType.SPEED

    def test_get_recommendation_by_pattern(self):
        """Test recommendations based on query pattern."""
        # Research pattern → ACCURACY
        profile, reason = self.manager.get_recommendation(query_pattern="research")
        assert profile == ProfileType.ACCURACY
        assert "research" in reason.lower()

        # Batch pattern → SPEED
        profile, reason = self.manager.get_recommendation(query_pattern="batch")
        assert profile == ProfileType.SPEED
        assert "batch" in reason.lower()

    def test_get_recommendation_by_qps(self):
        """Test recommendations based on QPS."""
        # High QPS → SPEED
        profile, reason = self.manager.get_recommendation(expected_qps=150)
        assert profile == ProfileType.SPEED
        assert "QPS" in reason or "qps" in reason.lower()

        # Low QPS → ACCURACY
        profile, reason = self.manager.get_recommendation(expected_qps=5)
        assert profile == ProfileType.ACCURACY


class TestAutoAdjustment:
    """Test automatic profile adjustment."""

    def setup_method(self):
        """Set up test fixtures."""
        self.mock_pool = Mock()
        self.mock_pool.maxconn = 10
        self.mock_pool._used = set()

        # Mock connection
        self.mock_conn = Mock()
        self.mock_cursor = Mock()
        self.mock_conn.cursor.return_value.__enter__ = Mock(return_value=self.mock_cursor)
        self.mock_conn.cursor.return_value.__exit__ = Mock(return_value=False)

        self.mock_pool.getconn.return_value = self.mock_conn

        self.manager = HNSWProfileManager(pool=self.mock_pool, auto_adjust=True)

    def test_auto_adjust_disabled(self):
        """Test auto-adjust returns None when disabled."""
        self.manager.auto_adjust = False
        result = self.manager.auto_adjust_profile()
        assert result is None

    @patch.object(HNSWProfileManager, "_calculate_load_ratio")
    def test_auto_adjust_switches_on_high_load(self, mock_load):
        """Test auto-adjust switches to SPEED on high load."""
        mock_load.return_value = 0.85  # > 80%

        result = self.manager.auto_adjust_profile()

        assert result == ProfileType.SPEED
        assert self.manager._current_profile == ProfileType.SPEED

    @patch.object(HNSWProfileManager, "_calculate_load_ratio")
    def test_auto_adjust_no_change_when_optimal(self, mock_load):
        """Test auto-adjust doesn't switch when already optimal."""
        # Already BALANCED, load is 50%
        self.manager._current_profile = ProfileType.BALANCED
        mock_load.return_value = 0.5

        result = self.manager.auto_adjust_profile()

        assert result is None
        assert self.manager._current_profile == ProfileType.BALANCED


class TestStatistics:
    """Test statistics and monitoring."""

    def setup_method(self):
        """Set up test fixtures."""
        self.mock_pool = Mock()
        self.mock_pool.maxconn = 10
        self.mock_pool._used = set()

        # Mock connection
        self.mock_conn = Mock()
        self.mock_cursor = Mock()
        self.mock_conn.cursor.return_value.__enter__ = Mock(return_value=self.mock_cursor)
        self.mock_conn.cursor.return_value.__exit__ = Mock(return_value=False)

        self.mock_pool.getconn.return_value = self.mock_conn

        self.manager = HNSWProfileManager(pool=self.mock_pool)

    def test_get_stats_structure(self):
        """Test stats have correct structure."""
        stats = self.manager.get_stats()

        assert "current_profile" in stats
        assert "total_switches" in stats
        assert "recent_switches" in stats
        assert "query_stats" in stats
        assert "load_stats" in stats

    def test_stats_track_switches(self):
        """Test stats track profile switches."""
        self.manager.switch_profile(ProfileType.SPEED, "Test")
        self.manager.switch_profile(ProfileType.ACCURACY, "Test")

        stats = self.manager.get_stats()
        assert stats["total_switches"] >= 2

    def test_reset_stats(self):
        """Test resetting statistics."""
        # Generate some stats
        self.manager.switch_profile(ProfileType.SPEED, "Test")

        # Reset
        self.manager.reset_stats()

        stats = self.manager.get_stats()
        assert stats["total_switches"] == 0
        assert len(stats["recent_switches"]) == 0


class TestThreadSafety:
    """Test thread safety of profile manager."""

    def setup_method(self):
        """Set up test fixtures."""
        self.mock_pool = Mock()
        self.mock_pool.maxconn = 10
        self.mock_pool._used = set()

        # Mock connection
        self.mock_conn = Mock()
        self.mock_cursor = Mock()
        self.mock_conn.cursor.return_value.__enter__ = Mock(return_value=self.mock_cursor)
        self.mock_conn.cursor.return_value.__exit__ = Mock(return_value=False)

        self.mock_pool.getconn.return_value = self.mock_conn

        self.manager = HNSWProfileManager(pool=self.mock_pool)

    def test_concurrent_switches(self):
        """Test concurrent profile switches are safe."""
        results = []
        errors = []

        def switch_profile():
            try:
                for i in range(10):
                    profile = ProfileType.SPEED if i % 2 == 0 else ProfileType.ACCURACY
                    result = self.manager.switch_profile(profile, f"Thread switch {i}")
                    results.append(result)
            except Exception as e:
                errors.append(e)

        # Create multiple threads
        threads = [threading.Thread(target=switch_profile) for _ in range(5)]

        # Start all threads
        for t in threads:
            t.start()

        # Wait for completion
        for t in threads:
            t.join()

        # Check no errors occurred
        assert len(errors) == 0

        # Check manager is in valid state
        current = self.manager.get_current_profile()
        assert current.name in ["accuracy", "balanced", "speed"]


class TestErrorHandling:
    """Test error handling."""

    def setup_method(self):
        """Set up test fixtures."""
        self.mock_pool = Mock()
        self.mock_pool.maxconn = 10

    def test_switch_profile_handles_db_error(self):
        """Test switch handles database errors gracefully."""
        # Mock connection that raises error
        self.mock_pool.getconn.side_effect = Exception("DB error")

        manager = HNSWProfileManager(pool=self.mock_pool)

        # Should return False, not raise
        result = manager.switch_profile(ProfileType.SPEED, "Test")
        assert result is False

        # Should stay on current profile
        assert manager._current_profile == ProfileType.BALANCED


def run_tests():
    """Run all tests."""
    # Third-party imports
    import pytest

    return pytest.main([__file__, "-v", "--tb=short"])


if __name__ == "__main__":
    run_tests()
