# Health Monitoring System - Deployment Guide

**Version**: 1.0
**Date**: 2026-02-11
**Status**: Production Ready

---

## Table of Contents

1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Installation](#installation)
4. [Configuration](#configuration)
5. [Alert Channel Setup](#alert-channel-setup)
6. [Systemd Service Deployment](#systemd-service-deployment)
7. [Monitoring Integration](#monitoring-integration)
8. [Testing](#testing)
9. [Troubleshooting](#troubleshooting)
10. [Maintenance](#maintenance)

---

## Overview

The health monitoring system provides comprehensive monitoring for the Distributed PostgreSQL Cluster with:

### Features
- Docker container health checks
- Database connectivity monitoring
- Schema validation
- Response time tracking
- Multi-channel alerting (Slack, Email, PagerDuty)
- Alert deduplication (15-minute cooldown)
- Multiple output formats (human, JSON, Prometheus)
- State persistence across restarts
- Configurable thresholds
- Systemd integration with 5-minute intervals

### Architecture
```
┌─────────────────────┐
│  Systemd Timer      │  Triggers every 5 minutes
│  (5min interval)    │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────────────────────────────────┐
│  Health Check Service                           │
│  (scripts/health_check_service.py)              │
├─────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌───────────────┐           │
│  │ Docker Check │  │ Database Pool │           │
│  │   (0.079s)   │  │  Check (0.03s)│           │
│  └──────┬───────┘  └───────┬───────┘           │
│         │                  │                    │
│         ▼                  ▼                    │
│  ┌────────────────────────────────┐            │
│  │  Metrics & State Tracking      │            │
│  │  (/tmp/postgres-health.json)   │            │
│  └────────────┬───────────────────┘            │
│               │                                 │
│               ▼                                 │
│  ┌────────────────────────────────┐            │
│  │  Alert Manager                 │            │
│  │  (Deduplication + Thresholds)  │            │
│  └────────────┬───────────────────┘            │
└───────────────┼─────────────────────────────────┘
                │
                ├────────┬──────────┬──────────┐
                ▼        ▼          ▼          ▼
            ┌──────┐ ┌─────┐  ┌────────┐  ┌──────────┐
            │ Slack│ │Email│  │PagerDuty│ │Prometheus│
            └──────┘ └─────┘  └────────┘  └──────────┘
```

---

## Quick Start

### 1. Manual Test
```bash
# Run health check once
python3 scripts/health_check_service.py

# Check output
# Exit code 0 = healthy, 1 = warning, 2 = critical
echo $?
```

### 2. Install Systemd Service
```bash
# Copy files
sudo cp scripts/systemd/postgres-health-check.service /etc/systemd/system/
sudo cp scripts/systemd/postgres-health-check.timer /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable and start timer
sudo systemctl enable postgres-health-check.timer
sudo systemctl start postgres-health-check.timer

# Verify timer is active
sudo systemctl status postgres-health-check.timer
```

### 3. View Logs
```bash
# Follow logs in real-time
journalctl -u postgres-health-check.service -f

# View last 50 lines
journalctl -u postgres-health-check.service -n 50
```

---

## Installation

### Prerequisites
- Python 3.8+
- Docker (for container monitoring)
- PostgreSQL with RuVector extension
- Root/sudo access (for systemd installation)

### Python Dependencies
Already included in project dependencies:
```bash
pip install python-dotenv psycopg2-binary requests
```

### File Structure
```
Distributed-Postgress-Cluster/
├── scripts/
│   ├── health_check_service.py       # Main health check service
│   ├── db_health_check.py            # Standalone health check
│   └── systemd/
│       ├── postgres-health-check.service  # Systemd service
│       └── postgres-health-check.timer    # Systemd timer
├── tests/
│   ├── test_health_monitoring.py     # Integration tests
│   └── validation-health.md          # Validation report
├── docs/
│   └── HEALTH_MONITORING_DEPLOYMENT.md  # This file
└── .env                              # Configuration
```

---

## Configuration

### Environment Variables

All configuration is in `.env` file:

```bash
# ============================================
# Health Check Service Configuration
# ============================================

# Alert Channels (Optional - Uncomment to Enable)
#HEALTH_CHECK_SLACK_WEBHOOK=https://hooks.slack.com/services/YOUR/WEBHOOK/URL
#HEALTH_CHECK_EMAIL_TO=ops@example.com
#HEALTH_CHECK_EMAIL_FROM=noreply@example.com
#HEALTH_CHECK_PAGERDUTY_KEY=your-integration-key

# Email Configuration (Optional)
#HEALTH_CHECK_SMTP_HOST=smtp.gmail.com
#HEALTH_CHECK_SMTP_PORT=587
#HEALTH_CHECK_SMTP_USER=your-email@gmail.com
#HEALTH_CHECK_SMTP_PASSWORD=your-app-password

# Thresholds
HEALTH_CHECK_RESPONSE_TIME_WARNING=1.0      # Seconds
HEALTH_CHECK_RESPONSE_TIME_CRITICAL=5.0     # Seconds
HEALTH_CHECK_ERROR_COUNT_WARNING=3          # Count
HEALTH_CHECK_ERROR_COUNT_CRITICAL=10        # Count
HEALTH_CHECK_ALERT_COOLDOWN=15              # Minutes

# Output Format (human, json, prometheus)
HEALTH_CHECK_OUTPUT_FORMAT=human

# State File Location
HEALTH_CHECK_STATE_FILE=/tmp/postgres-health-check.state.json
```

### Threshold Tuning

| Threshold | Default | Recommended | Purpose |
|-----------|---------|-------------|---------|
| `RESPONSE_TIME_WARNING` | 1.0s | 1.0-2.0s | Detect slow responses |
| `RESPONSE_TIME_CRITICAL` | 5.0s | 3.0-5.0s | Critical performance |
| `ERROR_COUNT_WARNING` | 3 | 3-5 | Early warning |
| `ERROR_COUNT_CRITICAL` | 10 | 8-12 | Persistent failure |
| `ALERT_COOLDOWN` | 15min | 10-30min | Reduce alert spam |

---

## Alert Channel Setup

### Slack Integration

1. **Create Incoming Webhook**
   - Go to: https://api.slack.com/messaging/webhooks
   - Create new app → Enable Incoming Webhooks
   - Add webhook to workspace → Select channel
   - Copy webhook URL

2. **Configure Environment**
   ```bash
   # In .env file
   HEALTH_CHECK_SLACK_WEBHOOK=https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXX
   ```

3. **Test**
   ```bash
   # Trigger test alert (will be sent immediately)
   python3 scripts/health_check_service.py
   ```

**Slack Message Format**:
```
🚨 Database Health Critical
Database health check failed: Connection refused

Level: CRITICAL
Time: 2026-02-11 10:53:33 UTC
Error Count: 10
Response Time: 5.23s
```

---

### Email Integration

1. **Gmail Setup** (Recommended for testing)
   - Enable 2-factor authentication
   - Generate app password: https://myaccount.google.com/apppasswords
   - Use app password (not regular password)

2. **Configure Environment**
   ```bash
   # In .env file
   HEALTH_CHECK_EMAIL_TO=ops@example.com
   HEALTH_CHECK_EMAIL_FROM=postgres-monitor@example.com
   HEALTH_CHECK_SMTP_HOST=smtp.gmail.com
   HEALTH_CHECK_SMTP_PORT=587
   HEALTH_CHECK_SMTP_USER=your-email@gmail.com
   HEALTH_CHECK_SMTP_PASSWORD=your-16-char-app-password
   ```

3. **Test**
   ```bash
   python3 scripts/health_check_service.py
   ```

**Email Format**:
```
Subject: [CRITICAL] Database Health Critical

Database health check failed: Connection refused

Level: CRITICAL
Time: 2026-02-11 10:53:33 UTC

Details:
  error_count: 10
  response_time: 5.23s
```

---

### PagerDuty Integration

1. **Create Integration**
   - Go to: Services → Service Directory → Select service
   - Integrations tab → Add integration
   - Integration Type: Events API v2
   - Copy integration key

2. **Configure Environment**
   ```bash
   # In .env file
   HEALTH_CHECK_PAGERDUTY_KEY=your-32-char-integration-key
   ```

3. **Test**
   ```bash
   # Note: PagerDuty only triggers on CRITICAL alerts
   python3 scripts/health_check_service.py
   ```

**PagerDuty Incident**:
- Title: Database Health Critical
- Severity: Critical
- Source: distributed-postgres-cluster
- Custom Details: error_count, response_time, etc.

---

## Systemd Service Deployment

### Service File Review

**`postgres-health-check.service`**:
```ini
[Unit]
Description=Distributed PostgreSQL Cluster Health Check
After=network.target docker.service
Wants=docker.service

[Service]
Type=oneshot
User=matt                    # ← Change to your user
WorkingDirectory=/home/matt/projects/Distributed-Postgress-Cluster  # ← Change path
EnvironmentFile=/home/matt/projects/Distributed-Postgress-Cluster/.env

# Security hardening
PrivateTmp=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/tmp /var/log

# Resource limits
MemoryMax=512M              # Note: Use MemoryMax (MemoryLimit deprecated)
CPUQuota=50%
TasksMax=10

[Install]
WantedBy=multi-user.target
```

**`postgres-health-check.timer`**:
```ini
[Unit]
Description=Distributed PostgreSQL Cluster Health Check Timer
Requires=postgres-health-check.service

[Timer]
OnBootSec=2min              # Run 2 minutes after boot
OnUnitActiveSec=5min        # Run every 5 minutes
OnCalendar=*:0/5            # Also run on calendar (every 5 minutes)
Persistent=true             # Catch up missed runs

[Install]
WantedBy=timers.target
```

### Installation Steps

1. **Edit Service File**
   ```bash
   # Update User, WorkingDirectory, EnvironmentFile paths
   nano scripts/systemd/postgres-health-check.service
   ```

2. **Copy Files**
   ```bash
   sudo cp scripts/systemd/postgres-health-check.service /etc/systemd/system/
   sudo cp scripts/systemd/postgres-health-check.timer /etc/systemd/system/
   ```

3. **Reload Systemd**
   ```bash
   sudo systemctl daemon-reload
   ```

4. **Enable Timer**
   ```bash
   # Enable (starts automatically on boot)
   sudo systemctl enable postgres-health-check.timer

   # Start now
   sudo systemctl start postgres-health-check.timer
   ```

5. **Verify Installation**
   ```bash
   # Check timer status
   sudo systemctl status postgres-health-check.timer

   # List active timers
   systemctl list-timers postgres-health-check.timer

   # Manually trigger service
   sudo systemctl start postgres-health-check.service

   # Check service logs
   journalctl -u postgres-health-check.service -n 50
   ```

### Uninstallation

```bash
# Stop and disable timer
sudo systemctl stop postgres-health-check.timer
sudo systemctl disable postgres-health-check.timer

# Remove files
sudo rm /etc/systemd/system/postgres-health-check.service
sudo rm /etc/systemd/system/postgres-health-check.timer

# Reload systemd
sudo systemctl daemon-reload
```

---

## Monitoring Integration

### Prometheus Metrics

**Expose metrics via file-based scraping**:

```bash
# Add to crontab (or use timer)
*/5 * * * * HEALTH_CHECK_OUTPUT_FORMAT=prometheus python3 /path/to/health_check_service.py > /var/lib/node_exporter/textfile_collector/postgres_health.prom
```

**Prometheus configuration** (`prometheus.yml`):
```yaml
scrape_configs:
  - job_name: 'postgres-health'
    static_configs:
      - targets: ['localhost:9100']
    honor_labels: true
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'postgres_health_.*'
        action: keep
```

**Exported Metrics**:
- `postgres_health_status` (gauge: 0=healthy, 1=warning, 2=critical)
- `postgres_health_response_time_seconds` (gauge)
- `postgres_health_uptime_seconds` (counter)
- `postgres_health_error_count_<type>` (counter per error type)

### Grafana Dashboard

**Sample PromQL Queries**:

```promql
# Overall health status
postgres_health_status

# Response time (last 1h)
rate(postgres_health_response_time_seconds[1h])

# Uptime
postgres_health_uptime_seconds

# Error rate
sum(rate(postgres_health_error_count_database[5m]))
```

**Alert Rules** (`alerts.yml`):
```yaml
groups:
  - name: postgres_health
    rules:
      - alert: PostgresUnhealthy
        expr: postgres_health_status >= 2
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "PostgreSQL cluster unhealthy"
          description: "Health check status: {{ $value }}"

      - alert: PostgresSlowResponse
        expr: postgres_health_response_time_seconds > 1.0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "PostgreSQL slow responses"
          description: "Response time: {{ $value }}s"
```

### JSON Output for Log Aggregation

```bash
# Configure in .env
HEALTH_CHECK_OUTPUT_FORMAT=json

# Output to file for Filebeat/Logstash
python3 scripts/health_check_service.py > /var/log/postgres-health.json
```

**Elasticsearch Index Mapping**:
```json
{
  "mappings": {
    "properties": {
      "timestamp": { "type": "date" },
      "status": { "type": "keyword" },
      "checks": { "type": "nested" },
      "metrics": {
        "properties": {
          "total_response_time_seconds": { "type": "float" },
          "error_counts": { "type": "object" }
        }
      }
    }
  }
}
```

---

## Testing

### Manual Testing

```bash
# 1. Run health check
python3 scripts/health_check_service.py

# 2. Check exit code
echo $?  # 0=healthy, 1=warning, 2=critical

# 3. Check state file
cat /tmp/postgres-health-check.state.json | python3 -m json.tool

# 4. Test different output formats
HEALTH_CHECK_OUTPUT_FORMAT=json python3 scripts/health_check_service.py
HEALTH_CHECK_OUTPUT_FORMAT=prometheus python3 scripts/health_check_service.py
```

### Integration Tests

```bash
# Run comprehensive test suite
python3 tests/test_health_monitoring.py

# Expected output:
# ============================================================
# 📊 Test Summary
# ============================================================
# Total Tests: 12
# Passed: 12
# Failed: 0
# Success Rate: 100.0%
# 🎉 All tests passed!
```

### Alert Testing

**Slack Test**:
```bash
# Configure webhook in .env, then run
python3 scripts/health_check_service.py

# Check Slack channel for message
```

**Email Test**:
```bash
# Configure SMTP in .env, then run
python3 scripts/health_check_service.py

# Check inbox
```

**Failure Simulation**:
```bash
# Stop Docker container
docker stop ruvector-db

# Run health check (should trigger alerts after threshold)
python3 scripts/health_check_service.py
python3 scripts/health_check_service.py  # Run again
python3 scripts/health_check_service.py  # And again (3rd failure = warning)

# Restart container
docker start ruvector-db

# Verify recovery
python3 scripts/health_check_service.py  # Should be healthy
```

---

## Troubleshooting

### Issue: Service Not Running

**Symptoms**:
```bash
$ systemctl status postgres-health-check.timer
● postgres-health-check.timer - inactive (dead)
```

**Solutions**:
```bash
# Check timer is enabled
sudo systemctl enable postgres-health-check.timer

# Start timer
sudo systemctl start postgres-health-check.timer

# Check for errors
journalctl -u postgres-health-check.timer -xe
```

---

### Issue: No Alerts Received

**Symptoms**: Health check runs but no Slack/Email alerts

**Debug Steps**:
1. **Check configuration**:
   ```bash
   # Verify environment variables loaded
   grep HEALTH_CHECK .env
   ```

2. **Check state file**:
   ```bash
   cat /tmp/postgres-health-check.state.json | python3 -m json.tool
   # Look for 'last_alerts' - if present, cooldown may be active
   ```

3. **Test manually with forced failure**:
   ```bash
   # Stop database
   docker stop ruvector-db

   # Lower thresholds
   HEALTH_CHECK_ERROR_COUNT_WARNING=1 python3 scripts/health_check_service.py
   ```

4. **Check alert channel logs**:
   ```bash
   journalctl -u postgres-health-check.service | grep -i "failed to send"
   ```

---

### Issue: Permission Denied

**Symptoms**:
```
PermissionError: [Errno 13] Permission denied: '/tmp/postgres-health-check.state.json'
```

**Solution**:
```bash
# Ensure write permissions
chmod 666 /tmp/postgres-health-check.state.json

# Or change state file location in .env
HEALTH_CHECK_STATE_FILE=/home/matt/.local/postgres-health-check.state.json
```

---

### Issue: High Memory Usage

**Symptoms**: Service using >512MB RAM

**Debug**:
```bash
# Check current usage
sudo systemctl status postgres-health-check.service | grep Memory

# View memory over time
journalctl -u postgres-health-check.service | grep Memory
```

**Solution**:
```bash
# Increase limit in service file
sudo nano /etc/systemd/system/postgres-health-check.service
# Change: MemoryMax=1G

sudo systemctl daemon-reload
sudo systemctl restart postgres-health-check.timer
```

---

### Issue: Database Connection Fails

**Symptoms**:
```
✗ database: unhealthy
  Error: connection refused
```

**Debug**:
```bash
# 1. Check environment variables
python3 -c "
from dotenv import load_dotenv
import os
load_dotenv()
print('Host:', os.getenv('RUVECTOR_HOST'))
print('Port:', os.getenv('RUVECTOR_PORT'))
print('DB:', os.getenv('RUVECTOR_DB'))
print('User:', os.getenv('RUVECTOR_USER'))
"

# 2. Test database connection manually
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster

# 3. Check Docker container
docker ps | grep 5432

# 4. Check database logs
docker logs ruvector-db -n 50
```

---

## Maintenance

### Log Rotation

**Manual rotation**:
```bash
# Rotate logs (journald handles this automatically)
sudo journalctl --vacuum-time=30d
sudo journalctl --vacuum-size=500M
```

**Configure journald** (`/etc/systemd/journald.conf`):
```ini
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=100M
SystemMaxFiles=5
MaxRetentionSec=30day
```

### State File Cleanup

The state file grows slowly (tracks alerts, errors). Clean periodically:

```bash
# View current state
cat /tmp/postgres-health-check.state.json | python3 -m json.tool

# Backup and reset
cp /tmp/postgres-health-check.state.json /tmp/postgres-health-check.state.json.bak
echo '{"last_alerts": {}, "error_counts": {}, "last_healthy": null}' > /tmp/postgres-health-check.state.json
```

### Performance Tuning

**Reduce check interval** (if needed):
```bash
# Edit timer file
sudo nano /etc/systemd/system/postgres-health-check.timer

# Change: OnUnitActiveSec=10min (instead of 5min)

sudo systemctl daemon-reload
sudo systemctl restart postgres-health-check.timer
```

**Optimize database queries**:
- Health check uses `health_check()` method from `DualDatabasePools`
- Ensure HNSW indexes exist (checked automatically)
- Monitor query performance: `scripts/db_health_check.py`

### Monitoring the Monitor

**Create alert for health check failures**:

```bash
# Add to monitoring system (Nagios, Zabbix, etc.)
# Check: Last successful run within 10 minutes

# Query journald
journalctl -u postgres-health-check.service --since "10 minutes ago" | grep "Status: HEALTHY"
```

---

## Appendix

### Exit Codes

| Code | Status | Meaning |
|------|--------|---------|
| 0 | Healthy | All checks passed |
| 1 | Warning | Non-critical issues (e.g., Docker not running) |
| 2 | Critical | Critical issues (database unreachable) |

### State File Schema

```json
{
  "last_alerts": {
    "<alert-hash>": {
      "time": "2026-02-11T10:53:33.123456",
      "level": "warning"
    }
  },
  "error_counts": {
    "docker": 2,
    "database": 0
  },
  "last_healthy": "2026-02-11T10:55:00.000000",
  "uptime_start": "2026-02-11T10:00:00.000000"
}
```

### Alert Deduplication Algorithm

```python
def should_alert(alert_key, level, cooldown_minutes=15):
    last_alert = get_last_alert(alert_key)

    # First alert: always send
    if not last_alert:
        return True

    # Escalation: always send (WARNING → CRITICAL)
    if level > last_alert.level:
        return True

    # Cooldown check
    if now - last_alert.time > cooldown:
        return True

    # Otherwise: suppress
    return False
```

### Useful Commands

```bash
# View all timers
systemctl list-timers --all

# Force immediate run
sudo systemctl start postgres-health-check.service

# View last 100 log lines
journalctl -u postgres-health-check.service -n 100

# Follow logs live
journalctl -u postgres-health-check.service -f

# Export logs to file
journalctl -u postgres-health-check.service > health-check.log

# Check timer configuration
systemctl cat postgres-health-check.timer

# View timer next run
systemctl list-timers postgres-health-check.timer
```

---

## Support

### Documentation
- Main README: `/docs/README.md`
- Error Handling: `/docs/ERROR_HANDLING.md`
- Validation Report: `/tests/validation-health.md`

### Testing
- Integration Tests: `tests/test_health_monitoring.py`
- Manual Tests: `scripts/db_health_check.py`

### Contact
- Issues: [GitHub Issues](https://github.com/yourusername/distributed-postgres-cluster/issues)
- Email: ops@example.com

---

**Revision History**:
- 2026-02-11 v1.0 - Initial deployment guide (QA Specialist Agent)
