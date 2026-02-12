#!/usr/bin/env python3
"""Enhanced Health Check Service with Multi-Channel Alerting

This service extends the basic health check with:
- Multi-channel alerting (Slack, Email, PagerDuty)
- Alert levels (INFO, WARNING, CRITICAL)
- JSON output for monitoring systems (Prometheus, Datadog)
- Metrics tracking and deduplication
- Configurable thresholds via environment variables

Exit Codes:
- 0: Healthy
- 1: Warning (non-critical issues)
- 2: Critical (requires immediate attention)
"""
# Standard library imports
import hashlib
import json
import os
import sys
import time
from datetime import datetime, timedelta
from enum import Enum
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent))

# Third-party imports
from dotenv import load_dotenv

# Local imports
from src.db.pool import DatabaseConfigurationError, DatabaseConnectionError, DualDatabasePools


class AlertLevel(Enum):
    """Alert severity levels."""

    INFO = "info"
    WARNING = "warning"
    CRITICAL = "critical"


class HealthCheckMetrics:
    """Tracks health check metrics and history."""

    def __init__(self, state_file: Path):
        self.state_file = state_file
        self.state = self._load_state()

    def _load_state(self) -> Dict:
        """Load persisted state from file."""
        if self.state_file.exists():
            try:
                with open(self.state_file, "r") as f:
                    return json.load(f)
            except Exception:
                pass
        return {
            "last_alerts": {},
            "error_counts": {},
            "last_healthy": None,
            "uptime_start": datetime.utcnow().isoformat(),
        }

    def _save_state(self):
        """Persist state to file."""
        try:
            self.state_file.parent.mkdir(parents=True, exist_ok=True)
            with open(self.state_file, "w") as f:
                json.dump(self.state, f, indent=2)
        except Exception as e:
            print(f"Warning: Failed to save state: {e}", file=sys.stderr)

    def should_alert(self, alert_key: str, level: AlertLevel, cooldown_minutes: int = 15) -> bool:
        """Check if alert should be sent (deduplication)."""
        now = datetime.utcnow()
        last_alert = self.state["last_alerts"].get(alert_key)

        if not last_alert:
            return True

        last_time = datetime.fromisoformat(last_alert["time"])
        last_level = AlertLevel(last_alert["level"])

        # Always alert on escalation
        if level.value == "critical" and last_level.value != "critical":
            return True

        # Check cooldown
        if now - last_time > timedelta(minutes=cooldown_minutes):
            return True

        return False

    def record_alert(self, alert_key: str, level: AlertLevel):
        """Record that an alert was sent."""
        self.state["last_alerts"][alert_key] = {
            "time": datetime.utcnow().isoformat(),
            "level": level.value,
        }
        self._save_state()

    def increment_error(self, error_type: str) -> int:
        """Increment error counter and return new count."""
        count = self.state["error_counts"].get(error_type, 0) + 1
        self.state["error_counts"][error_type] = count
        self._save_state()
        return count

    def reset_errors(self, error_type: str):
        """Reset error counter."""
        if error_type in self.state["error_counts"]:
            del self.state["error_counts"][error_type]
            self._save_state()

    def record_healthy(self):
        """Record successful health check."""
        self.state["last_healthy"] = datetime.utcnow().isoformat()
        self._save_state()

    def get_uptime_seconds(self) -> float:
        """Get service uptime in seconds."""
        start = datetime.fromisoformat(self.state["uptime_start"])
        return (datetime.utcnow() - start).total_seconds()


class AlertManager:
    """Manages multi-channel alerting."""

    def __init__(self, metrics: HealthCheckMetrics):
        self.metrics = metrics
        self.slack_webhook = os.getenv("HEALTH_CHECK_SLACK_WEBHOOK")
        self.email_to = os.getenv("HEALTH_CHECK_EMAIL_TO")
        self.pagerduty_key = os.getenv("HEALTH_CHECK_PAGERDUTY_KEY")
        self.alert_cooldown = int(os.getenv("HEALTH_CHECK_ALERT_COOLDOWN", "15"))

    def send_alert(
        self, title: str, message: str, level: AlertLevel, details: Optional[Dict] = None
    ):
        """Send alert through configured channels."""
        alert_key = hashlib.md5(f"{title}:{level.value}".encode()).hexdigest()

        # Check if we should send (deduplication)
        if not self.metrics.should_alert(alert_key, level, self.alert_cooldown):
            return

        # Send to enabled channels
        sent = False
        if self.slack_webhook:
            self._send_slack(title, message, level, details)
            sent = True

        if self.email_to:
            self._send_email(title, message, level, details)
            sent = True

        if self.pagerduty_key and level == AlertLevel.CRITICAL:
            self._send_pagerduty(title, message, details)
            sent = True

        if sent:
            self.metrics.record_alert(alert_key, level)

    def _send_slack(self, title: str, message: str, level: AlertLevel, details: Optional[Dict]):
        """Send Slack notification."""
        try:
            # Third-party imports
            import requests

            emoji_map = {
                AlertLevel.INFO: ":information_source:",
                AlertLevel.WARNING: ":warning:",
                AlertLevel.CRITICAL: ":rotating_light:",
            }

            color_map = {
                AlertLevel.INFO: "#36a64f",
                AlertLevel.WARNING: "#ff9900",
                AlertLevel.CRITICAL: "#ff0000",
            }

            payload = {
                "attachments": [
                    {
                        "color": color_map[level],
                        "title": f"{emoji_map[level]} {title}",
                        "text": message,
                        "fields": [
                            {"title": "Level", "value": level.value.upper(), "short": True},
                            {
                                "title": "Time",
                                "value": datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC"),
                                "short": True,
                            },
                        ],
                        "footer": "Distributed PostgreSQL Cluster Health Check",
                    }
                ]
            }

            if details:
                payload["attachments"][0]["fields"].extend(
                    [{"title": k, "value": str(v), "short": True} for k, v in details.items()]
                )

            requests.post(self.slack_webhook, json=payload, timeout=10)
        except Exception as e:
            print(f"Failed to send Slack alert: {e}", file=sys.stderr)

    def _send_email(self, title: str, message: str, level: AlertLevel, details: Optional[Dict]):
        """Send email notification."""
        try:
            # Standard library imports
            import smtplib
            from email.mime.multipart import MIMEMultipart
            from email.mime.text import MIMEText

            smtp_host = os.getenv("HEALTH_CHECK_SMTP_HOST", "localhost")
            smtp_port = int(os.getenv("HEALTH_CHECK_SMTP_PORT", "25"))
            smtp_user = os.getenv("HEALTH_CHECK_SMTP_USER")
            smtp_pass = os.getenv("HEALTH_CHECK_SMTP_PASSWORD")
            from_addr = os.getenv("HEALTH_CHECK_EMAIL_FROM", "noreply@localhost")

            msg = MIMEMultipart()
            msg["From"] = from_addr
            msg["To"] = self.email_to
            msg["Subject"] = f"[{level.value.upper()}] {title}"

            body = f"{message}\n\n"
            body += f"Level: {level.value.upper()}\n"
            body += f"Time: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}\n"

            if details:
                body += "\nDetails:\n"
                for k, v in details.items():
                    body += f"  {k}: {v}\n"

            msg.attach(MIMEText(body, "plain"))

            with smtplib.SMTP(smtp_host, smtp_port) as server:
                if smtp_user and smtp_pass:
                    server.starttls()
                    server.login(smtp_user, smtp_pass)
                server.send_message(msg)

        except Exception as e:
            print(f"Failed to send email alert: {e}", file=sys.stderr)

    def _send_pagerduty(self, title: str, message: str, details: Optional[Dict]):
        """Send PagerDuty incident."""
        try:
            # Third-party imports
            import requests

            payload = {
                "routing_key": self.pagerduty_key,
                "event_action": "trigger",
                "payload": {
                    "summary": title,
                    "severity": "critical",
                    "source": "distributed-postgres-cluster",
                    "custom_details": details or {},
                },
            }

            requests.post("https://events.pagerduty.com/v2/enqueue", json=payload, timeout=10)
        except Exception as e:
            print(f"Failed to send PagerDuty alert: {e}", file=sys.stderr)


class HealthChecker:
    """Enhanced health checker with metrics and alerting."""

    def __init__(self, metrics: HealthCheckMetrics, alert_manager: AlertManager):
        self.metrics = metrics
        self.alerts = alert_manager
        self.thresholds = {
            "response_time_warning": float(os.getenv("HEALTH_CHECK_RESPONSE_TIME_WARNING", "1.0")),
            "response_time_critical": float(
                os.getenv("HEALTH_CHECK_RESPONSE_TIME_CRITICAL", "5.0")
            ),
            "error_count_warning": int(os.getenv("HEALTH_CHECK_ERROR_COUNT_WARNING", "3")),
            "error_count_critical": int(os.getenv("HEALTH_CHECK_ERROR_COUNT_CRITICAL", "10")),
        }

    def check_docker_container(self) -> Tuple[bool, Optional[str], float]:
        """Check Docker container status."""
        # Standard library imports
        import subprocess

        start_time = time.time()
        try:
            result = subprocess.run(
                ["docker", "ps", "--filter", "publish=5432", "--format", "{{.Names}}"],
                capture_output=True,
                text=True,
                check=True,
                timeout=5,
            )
            response_time = time.time() - start_time

            containers = [c for c in result.stdout.strip().split("\n") if c]

            if containers:
                self.metrics.reset_errors("docker")
                return True, None, response_time
            else:
                error = "No PostgreSQL container running on port 5432"
                count = self.metrics.increment_error("docker")

                if count >= self.thresholds["error_count_critical"]:
                    self.alerts.send_alert(
                        "Docker Container Critical",
                        error,
                        AlertLevel.CRITICAL,
                        {"error_count": count},
                    )
                elif count >= self.thresholds["error_count_warning"]:
                    self.alerts.send_alert(
                        "Docker Container Warning",
                        error,
                        AlertLevel.WARNING,
                        {"error_count": count},
                    )

                return False, error, response_time

        except FileNotFoundError:
            return None, "Docker not installed", 0
        except subprocess.TimeoutExpired:
            error = "Docker command timeout"
            self.alerts.send_alert("Docker Timeout", error, AlertLevel.WARNING)
            return False, error, 5.0
        except Exception as e:
            return False, str(e), 0

    def check_database_pools(self) -> Tuple[bool, Dict, float]:
        """Check database pool health."""
        start_time = time.time()
        try:
            pools = DualDatabasePools()
            health = pools.health_check()
            response_time = time.time() - start_time
            pools.close()

            project_ok = health.get("project", {}).get("status") == "healthy"
            shared_ok = health.get("shared", {}).get("status") == "healthy"

            # Check response time
            if response_time >= self.thresholds["response_time_critical"]:
                self.alerts.send_alert(
                    "Database Response Time Critical",
                    f"Health check took {response_time:.2f}s",
                    AlertLevel.CRITICAL,
                    {
                        "response_time": f"{response_time:.2f}s",
                        "threshold": f"{self.thresholds['response_time_critical']}s",
                    },
                )
            elif response_time >= self.thresholds["response_time_warning"]:
                self.alerts.send_alert(
                    "Database Response Time Warning",
                    f"Health check took {response_time:.2f}s",
                    AlertLevel.WARNING,
                    {
                        "response_time": f"{response_time:.2f}s",
                        "threshold": f"{self.thresholds['response_time_warning']}s",
                    },
                )

            # Check database health
            if not project_ok or not shared_ok:
                count = self.metrics.increment_error("database")
                errors = []

                if not project_ok:
                    errors.append(f"Project DB: {health['project'].get('error', 'unknown')}")
                if not shared_ok:
                    errors.append(f"Shared DB: {health['shared'].get('error', 'unknown')}")

                error_msg = "; ".join(errors)

                if count >= self.thresholds["error_count_critical"]:
                    self.alerts.send_alert(
                        "Database Health Critical",
                        error_msg,
                        AlertLevel.CRITICAL,
                        {"error_count": count, "response_time": f"{response_time:.2f}s"},
                    )
                elif count >= self.thresholds["error_count_warning"]:
                    self.alerts.send_alert(
                        "Database Health Warning",
                        error_msg,
                        AlertLevel.WARNING,
                        {"error_count": count, "response_time": f"{response_time:.2f}s"},
                    )

                return False, health, response_time
            else:
                self.metrics.reset_errors("database")
                return True, health, response_time

        except Exception as e:
            response_time = time.time() - start_time
            count = self.metrics.increment_error("database")

            if count >= self.thresholds["error_count_critical"]:
                self.alerts.send_alert(
                    "Database Connection Critical",
                    str(e),
                    AlertLevel.CRITICAL,
                    {"error_count": count},
                )

            return False, {"error": str(e)}, response_time

    def run_health_check(self) -> Tuple[int, Dict]:
        """Run complete health check and return exit code and metrics."""
        results = {
            "timestamp": datetime.utcnow().isoformat(),
            "checks": {},
            "metrics": {},
            "uptime_seconds": self.metrics.get_uptime_seconds(),
        }

        # Check Docker
        docker_ok, docker_error, docker_time = self.check_docker_container()
        results["checks"]["docker"] = {
            "status": "healthy" if docker_ok else ("skipped" if docker_ok is None else "unhealthy"),
            "error": docker_error,
            "response_time_seconds": docker_time,
        }

        # Check database pools
        db_ok, db_health, db_time = self.check_database_pools()
        results["checks"]["database"] = {
            "status": "healthy" if db_ok else "unhealthy",
            "health": db_health,
            "response_time_seconds": db_time,
        }

        # Calculate overall status
        critical = not db_ok
        warning = docker_ok is False and not critical

        results["metrics"] = {
            "total_response_time_seconds": docker_time + db_time,
            "error_counts": self.metrics.state["error_counts"],
            "last_healthy": self.metrics.state.get("last_healthy"),
        }

        if not critical and not warning:
            self.metrics.record_healthy()
            results["status"] = "healthy"
            exit_code = 0
        elif warning:
            results["status"] = "warning"
            exit_code = 1
        else:
            results["status"] = "critical"
            exit_code = 2

        return exit_code, results


def main():
    """Run health check service."""
    # Load environment
    env_path = Path(__file__).parent.parent / ".env"
    if env_path.exists():
        load_dotenv(env_path)

    # Initialize metrics and alerting
    state_file = Path(os.getenv("HEALTH_CHECK_STATE_FILE", "/tmp/postgres-health-check.state.json"))
    metrics = HealthCheckMetrics(state_file)
    alert_manager = AlertManager(metrics)
    checker = HealthChecker(metrics, alert_manager)

    # Run health check
    exit_code, results = checker.run_health_check()

    # Output results
    output_format = os.getenv("HEALTH_CHECK_OUTPUT_FORMAT", "human")

    if output_format == "json":
        print(json.dumps(results, indent=2))
    elif output_format == "prometheus":
        # Prometheus metrics format
        print(
            f"# HELP postgres_health_status Overall health status (0=healthy, 1=warning, 2=critical)"
        )
        print(f"# TYPE postgres_health_status gauge")
        print(f"postgres_health_status {exit_code}")

        print(f"# HELP postgres_health_response_time_seconds Response time in seconds")
        print(f"# TYPE postgres_health_response_time_seconds gauge")
        print(
            f"postgres_health_response_time_seconds {results['metrics']['total_response_time_seconds']}"
        )

        print(f"# HELP postgres_health_uptime_seconds Service uptime in seconds")
        print(f"# TYPE postgres_health_uptime_seconds counter")
        print(f"postgres_health_uptime_seconds {results['uptime_seconds']}")

        for error_type, count in results["metrics"]["error_counts"].items():
            print(f"# HELP postgres_health_error_count_{error_type} Error count for {error_type}")
            print(f"# TYPE postgres_health_error_count_{error_type} counter")
            print(f"postgres_health_error_count_{error_type} {count}")
    else:
        # Human-readable format
        print("=" * 60)
        print("🏥 PostgreSQL Health Check Service")
        print("=" * 60)
        print(f"Status: {results['status'].upper()}")
        print(f"Timestamp: {results['timestamp']}")
        print(f"Uptime: {results['uptime_seconds']:.0f}s")
        print()

        for check_name, check_data in results["checks"].items():
            status_emoji = {"healthy": "✓", "warning": "⚠", "unhealthy": "✗", "skipped": "⊘"}
            print(f"{status_emoji[check_data['status']]} {check_name}: {check_data['status']}")
            if check_data.get("error"):
                print(f"  Error: {check_data['error']}")
            if check_data.get("response_time_seconds"):
                print(f"  Response Time: {check_data['response_time_seconds']:.3f}s")

        print()
        print("Metrics:")
        print(f"  Total Response Time: {results['metrics']['total_response_time_seconds']:.3f}s")
        if results["metrics"]["error_counts"]:
            print("  Error Counts:")
            for error_type, count in results["metrics"]["error_counts"].items():
                print(f"    {error_type}: {count}")

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
