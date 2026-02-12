#!/usr/bin/env python3
"""Integration Tests for Health Monitoring System

This test suite validates:
1. Health check service functionality
2. Alert deduplication logic
3. Error threshold triggering
4. State persistence
5. Output format validation
6. Mock alert channel testing
"""
# Standard library imports
import json
import os
import sys
import tempfile
import time
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import MagicMock, Mock, patch

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent))

# Third-party imports
from dotenv import load_dotenv

# Import health check components
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))
# Third-party imports
from health_check_service import AlertLevel, AlertManager, HealthChecker, HealthCheckMetrics


class TestHealthCheckMetrics:
    """Test suite for health check metrics and state management."""

    def test_state_persistence(self):
        """Test state file creation and persistence."""
        with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".json") as f:
            state_file = Path(f.name)

        try:
            metrics = HealthCheckMetrics(state_file)

            # Verify initial state
            assert "last_alerts" in metrics.state
            assert "error_counts" in metrics.state
            assert "last_healthy" in metrics.state
            assert "uptime_start" in metrics.state

            # Record some data
            metrics.increment_error("database")
            metrics.record_alert("test-alert", AlertLevel.WARNING)
            metrics.record_healthy()

            # Verify state saved
            assert state_file.exists()

            # Load state in new instance
            metrics2 = HealthCheckMetrics(state_file)
            assert metrics2.state["error_counts"]["database"] == 1
            assert "test-alert" in metrics2.state["last_alerts"]

            print("✓ State persistence test passed")

        finally:
            if state_file.exists():
                state_file.unlink()

    def test_alert_deduplication(self):
        """Test alert deduplication with cooldown period."""
        with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".json") as f:
            state_file = Path(f.name)

        try:
            metrics = HealthCheckMetrics(state_file)

            # First alert should be sent
            assert metrics.should_alert("test-key", AlertLevel.WARNING, cooldown_minutes=15)

            # Record the alert
            metrics.record_alert("test-key", AlertLevel.WARNING)

            # Same alert within cooldown should be suppressed
            assert not metrics.should_alert("test-key", AlertLevel.WARNING, cooldown_minutes=15)

            # Escalation should always trigger
            assert metrics.should_alert("test-key", AlertLevel.CRITICAL, cooldown_minutes=15)

            # Record critical alert
            metrics.record_alert("test-key", AlertLevel.CRITICAL)

            # Same critical alert should be suppressed
            assert not metrics.should_alert("test-key", AlertLevel.CRITICAL, cooldown_minutes=15)

            print("✓ Alert deduplication test passed")

        finally:
            if state_file.exists():
                state_file.unlink()

    def test_error_counting(self):
        """Test error counter increment and reset."""
        with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".json") as f:
            state_file = Path(f.name)

        try:
            metrics = HealthCheckMetrics(state_file)

            # Increment errors
            count1 = metrics.increment_error("database")
            assert count1 == 1

            count2 = metrics.increment_error("database")
            assert count2 == 2

            # Different error type
            count3 = metrics.increment_error("docker")
            assert count3 == 1

            # Reset specific error
            metrics.reset_errors("database")
            assert "database" not in metrics.state["error_counts"]
            assert "docker" in metrics.state["error_counts"]

            print("✓ Error counting test passed")

        finally:
            if state_file.exists():
                state_file.unlink()

    def test_uptime_tracking(self):
        """Test uptime calculation."""
        with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".json") as f:
            state_file = Path(f.name)

        try:
            metrics = HealthCheckMetrics(state_file)

            # Wait a bit
            time.sleep(0.1)

            # Check uptime
            uptime = metrics.get_uptime_seconds()
            assert uptime >= 0.1
            assert uptime < 1.0  # Should be very short

            print(f"✓ Uptime tracking test passed (uptime: {uptime:.3f}s)")

        finally:
            if state_file.exists():
                state_file.unlink()


class TestAlertManager:
    """Test suite for alert manager and notification channels."""

    def test_slack_alert_format(self):
        """Test Slack alert formatting (mocked)."""
        with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".json") as f:
            state_file = Path(f.name)

        try:
            metrics = HealthCheckMetrics(state_file)

            with patch.dict(
                os.environ, {"HEALTH_CHECK_SLACK_WEBHOOK": "https://hooks.slack.com/test"}
            ):
                alert_manager = AlertManager(metrics)

                # Mock requests.post
                with patch("requests.post") as mock_post:
                    alert_manager._send_slack(
                        "Test Alert", "Test message", AlertLevel.WARNING, {"key": "value"}
                    )

                    # Verify post was called
                    assert mock_post.called

                    # Verify payload structure
                    call_args = mock_post.call_args
                    payload = call_args[1]["json"]

                    assert "attachments" in payload
                    assert len(payload["attachments"]) == 1

                    attachment = payload["attachments"][0]
                    assert attachment["color"] == "#ff9900"  # Warning color
                    assert "Test Alert" in attachment["title"]
                    assert attachment["text"] == "Test message"

                    # Check fields
                    fields = attachment["fields"]
                    field_titles = [f["title"] for f in fields]
                    assert "Level" in field_titles
                    assert "Time" in field_titles
                    assert "key" in field_titles

                    print("✓ Slack alert format test passed")

        finally:
            if state_file.exists():
                state_file.unlink()

    def test_email_alert_format(self):
        """Test email alert formatting (mocked)."""
        with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".json") as f:
            state_file = Path(f.name)

        try:
            metrics = HealthCheckMetrics(state_file)

            with patch.dict(
                os.environ,
                {
                    "HEALTH_CHECK_EMAIL_TO": "ops@example.com",
                    "HEALTH_CHECK_EMAIL_FROM": "noreply@example.com",
                },
            ):
                alert_manager = AlertManager(metrics)

                # Mock smtplib.SMTP
                with patch("smtplib.SMTP") as mock_smtp:
                    mock_server = MagicMock()
                    mock_smtp.return_value.__enter__.return_value = mock_server

                    alert_manager._send_email(
                        "Test Alert", "Test message", AlertLevel.CRITICAL, {"error": "Test error"}
                    )

                    # Verify SMTP was used
                    assert mock_smtp.called
                    assert mock_server.send_message.called

                    # Verify message
                    msg = mock_server.send_message.call_args[0][0]
                    assert msg["To"] == "ops@example.com"
                    assert "[CRITICAL]" in msg["Subject"]

                    print("✓ Email alert format test passed")

        finally:
            if state_file.exists():
                state_file.unlink()

    def test_pagerduty_alert_format(self):
        """Test PagerDuty alert formatting (mocked)."""
        with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".json") as f:
            state_file = Path(f.name)

        try:
            metrics = HealthCheckMetrics(state_file)

            with patch.dict(os.environ, {"HEALTH_CHECK_PAGERDUTY_KEY": "test-key"}):
                alert_manager = AlertManager(metrics)

                # Mock requests.post
                with patch("requests.post") as mock_post:
                    alert_manager._send_pagerduty(
                        "Test Alert", "Test message", {"severity": "critical"}
                    )

                    # Verify post was called
                    assert mock_post.called

                    # Verify payload structure
                    call_args = mock_post.call_args
                    payload = call_args[1]["json"]

                    assert payload["routing_key"] == "test-key"
                    assert payload["event_action"] == "trigger"
                    assert payload["payload"]["summary"] == "Test Alert"
                    assert payload["payload"]["severity"] == "critical"

                    print("✓ PagerDuty alert format test passed")

        finally:
            if state_file.exists():
                state_file.unlink()


class TestHealthChecker:
    """Test suite for health checker logic."""

    def test_docker_check_success(self):
        """Test successful Docker container check."""
        with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".json") as f:
            state_file = Path(f.name)

        try:
            metrics = HealthCheckMetrics(state_file)
            alert_manager = AlertManager(metrics)
            checker = HealthChecker(metrics, alert_manager)

            # Mock subprocess to return container
            with patch("subprocess.run") as mock_run:
                mock_run.return_value.stdout = "ruvector-db\n"

                ok, error, response_time = checker.check_docker_container()

                assert ok is True
                assert error is None
                assert response_time > 0
                assert "docker" not in metrics.state["error_counts"]

                print("✓ Docker check success test passed")

        finally:
            if state_file.exists():
                state_file.unlink()

    def test_docker_check_failure(self):
        """Test Docker container check failure."""
        with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".json") as f:
            state_file = Path(f.name)

        try:
            metrics = HealthCheckMetrics(state_file)
            alert_manager = AlertManager(metrics)
            checker = HealthChecker(metrics, alert_manager)

            # Mock subprocess to return no containers
            with patch("subprocess.run") as mock_run:
                mock_run.return_value.stdout = "\n"

                ok, error, response_time = checker.check_docker_container()

                assert ok is False
                assert error is not None
                assert "docker" in metrics.state["error_counts"]
                assert metrics.state["error_counts"]["docker"] == 1

                print("✓ Docker check failure test passed")

        finally:
            if state_file.exists():
                state_file.unlink()

    def test_threshold_warning(self):
        """Test warning threshold triggering."""
        with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".json") as f:
            state_file = Path(f.name)

        try:
            metrics = HealthCheckMetrics(state_file)
            alert_manager = AlertManager(metrics)

            # Lower threshold for testing
            with patch.dict(os.environ, {"HEALTH_CHECK_ERROR_COUNT_WARNING": "2"}):
                checker = HealthChecker(metrics, alert_manager)

                # Trigger multiple failures
                with patch("subprocess.run") as mock_run:
                    mock_run.return_value.stdout = "\n"

                    # First failure - no alert
                    checker.check_docker_container()
                    assert metrics.state["error_counts"]["docker"] == 1

                    # Second failure - WARNING alert should be sent
                    with patch.object(alert_manager, "send_alert") as mock_alert:
                        checker.check_docker_container()
                        assert metrics.state["error_counts"]["docker"] == 2
                        assert mock_alert.called

                        # Verify alert level
                        call_args = mock_alert.call_args[0]
                        assert call_args[2] == AlertLevel.WARNING

                print("✓ Warning threshold test passed")

        finally:
            if state_file.exists():
                state_file.unlink()

    def test_threshold_critical(self):
        """Test critical threshold triggering."""
        with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".json") as f:
            state_file = Path(f.name)

        try:
            metrics = HealthCheckMetrics(state_file)
            alert_manager = AlertManager(metrics)

            # Lower threshold for testing
            with patch.dict(
                os.environ,
                {"HEALTH_CHECK_ERROR_COUNT_WARNING": "2", "HEALTH_CHECK_ERROR_COUNT_CRITICAL": "3"},
            ):
                checker = HealthChecker(metrics, alert_manager)

                with patch("subprocess.run") as mock_run:
                    mock_run.return_value.stdout = "\n"

                    # Trigger failures up to critical
                    for i in range(3):
                        with patch.object(alert_manager, "send_alert") as mock_alert:
                            checker.check_docker_container()

                            if i == 2:  # Third failure
                                assert metrics.state["error_counts"]["docker"] == 3
                                assert mock_alert.called

                                # Verify alert level
                                call_args = mock_alert.call_args[0]
                                assert call_args[2] == AlertLevel.CRITICAL

                print("✓ Critical threshold test passed")

        finally:
            if state_file.exists():
                state_file.unlink()


class TestOutputFormats:
    """Test suite for output format validation."""

    def test_json_output(self):
        """Test JSON output format."""
        with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".json") as f:
            state_file = Path(f.name)

        try:
            metrics = HealthCheckMetrics(state_file)
            alert_manager = AlertManager(metrics)
            checker = HealthChecker(metrics, alert_manager)

            # Mock successful checks
            with patch("subprocess.run") as mock_run:
                mock_run.return_value.stdout = "ruvector-db\n"

                with patch.object(checker, "check_database_pools") as mock_db:
                    mock_db.return_value = (True, {"project": {"status": "healthy"}}, 0.05)

                    exit_code, results = checker.run_health_check()

                    # Verify JSON structure
                    assert "timestamp" in results
                    assert "checks" in results
                    assert "metrics" in results
                    assert "uptime_seconds" in results
                    assert "status" in results

                    # Verify status
                    assert results["status"] == "healthy"
                    assert exit_code == 0

                    # Verify checks
                    assert "docker" in results["checks"]
                    assert "database" in results["checks"]

                    print("✓ JSON output format test passed")

        finally:
            if state_file.exists():
                state_file.unlink()


def run_all_tests():
    """Run all test suites."""
    print("=" * 60)
    print("🧪 Health Monitoring System Integration Tests")
    print("=" * 60)

    # Load environment
    env_path = Path(__file__).parent.parent / ".env"
    if env_path.exists():
        load_dotenv(env_path)

    test_classes = [TestHealthCheckMetrics, TestAlertManager, TestHealthChecker, TestOutputFormats]

    total_tests = 0
    passed_tests = 0

    for test_class in test_classes:
        print(f"\n{'=' * 60}")
        print(f"Testing: {test_class.__name__}")
        print("=" * 60)

        instance = test_class()
        test_methods = [m for m in dir(instance) if m.startswith("test_")]

        for method_name in test_methods:
            total_tests += 1
            try:
                method = getattr(instance, method_name)
                method()
                passed_tests += 1
            except Exception as e:
                print(f"✗ {method_name} failed: {e}")
                # Standard library imports
                import traceback

                traceback.print_exc()

    # Summary
    print("\n" + "=" * 60)
    print("📊 Test Summary")
    print("=" * 60)
    print(f"Total Tests: {total_tests}")
    print(f"Passed: {passed_tests}")
    print(f"Failed: {total_tests - passed_tests}")
    print(f"Success Rate: {passed_tests/total_tests*100:.1f}%")

    if passed_tests == total_tests:
        print("\n🎉 All tests passed!")
        return 0
    else:
        print("\n⚠ Some tests failed.")
        return 1


if __name__ == "__main__":
    sys.exit(run_all_tests())
