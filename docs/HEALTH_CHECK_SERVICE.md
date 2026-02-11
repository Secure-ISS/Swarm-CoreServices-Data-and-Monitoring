# PostgreSQL Health Check Service

Automated health monitoring with multi-channel alerting for the Distributed PostgreSQL Cluster.

## Overview

The health check service runs every 5 minutes via systemd timer and monitors:

- Docker container status
- Database connectivity (project + shared databases)
- Response times
- Error rates
- Service uptime

**Exit Codes:**
- `0` - Healthy (all checks passed)
- `1` - Warning (non-critical issues, e.g., Docker container issues)
- `2` - Critical (database connectivity failures)

## Features

### 1. Multi-Channel Alerting

Supports three alert channels (configurable):

- **Slack** - Webhook notifications with color-coded attachments
- **Email** - SMTP email alerts
- **PagerDuty** - Critical incident creation

### 2. Alert Levels

- **INFO** - Informational messages
- **WARNING** - Non-critical issues (degraded performance, Docker issues)
- **CRITICAL** - Critical failures requiring immediate attention

### 3. Alert Deduplication

- Prevents alert spam with configurable cooldown (default: 15 minutes)
- Escalates alerts on severity increase (WARNING → CRITICAL)
- Tracks alert history in state file

### 4. Metrics Tracking

- Response times for each check
- Error counts per error type
- Last successful health check timestamp
- Service uptime

### 5. Monitoring Integration

Supports multiple output formats:

- **Human** - Readable console output
- **JSON** - Structured data for log aggregation
- **Prometheus** - Metrics in Prometheus exposition format

## Installation

### 1. Configure Alerts (Optional)

Add alerting configuration to `.env`:

```bash
# Slack Webhook
HEALTH_CHECK_SLACK_WEBHOOK=https://hooks.slack.com/services/YOUR/WEBHOOK/URL

# Email Configuration
HEALTH_CHECK_EMAIL_TO=ops@example.com
HEALTH_CHECK_EMAIL_FROM=noreply@example.com
HEALTH_CHECK_SMTP_HOST=smtp.gmail.com
HEALTH_CHECK_SMTP_PORT=587
HEALTH_CHECK_SMTP_USER=your-email@gmail.com
HEALTH_CHECK_SMTP_PASSWORD=your-app-password

# PagerDuty
HEALTH_CHECK_PAGERDUTY_KEY=your-integration-key

# Thresholds
HEALTH_CHECK_RESPONSE_TIME_WARNING=1.0      # seconds
HEALTH_CHECK_RESPONSE_TIME_CRITICAL=5.0     # seconds
HEALTH_CHECK_ERROR_COUNT_WARNING=3
HEALTH_CHECK_ERROR_COUNT_CRITICAL=10
HEALTH_CHECK_ALERT_COOLDOWN=15              # minutes

# Output Format
HEALTH_CHECK_OUTPUT_FORMAT=human            # human, json, prometheus

# State File
HEALTH_CHECK_STATE_FILE=/tmp/postgres-health-check.state.json
```

### 2. Install systemd Service

```bash
sudo ./scripts/install-health-service.sh
```

This script will:
- Copy systemd service and timer files
- Reload systemd daemon
- Enable and start the timer
- Show service status and schedule

### 3. Verify Installation

```bash
# Check timer status
systemctl status postgres-health-check.timer

# View scheduled runs
systemctl list-timers postgres-health-check.timer

# View logs
journalctl -u postgres-health-check.service -f
```

## Usage

### Manual Health Check

Run health check manually:

```bash
# Human-readable output
./scripts/health_check_service.py

# JSON output
HEALTH_CHECK_OUTPUT_FORMAT=json ./scripts/health_check_service.py

# Prometheus metrics
HEALTH_CHECK_OUTPUT_FORMAT=prometheus ./scripts/health_check_service.py
```

### Systemd Commands

```bash
# Start timer (automatic on boot after installation)
sudo systemctl start postgres-health-check.timer

# Stop timer
sudo systemctl stop postgres-health-check.timer

# Trigger immediate health check
sudo systemctl start postgres-health-check.service

# View real-time logs
journalctl -u postgres-health-check.service -f

# View recent logs
journalctl -u postgres-health-check.service -n 50

# Check timer schedule
systemctl list-timers postgres-health-check.timer

# Disable timer
sudo systemctl disable postgres-health-check.timer
```

## Alert Configuration

### Slack Setup

1. Create a Slack App with Incoming Webhooks
2. Add webhook URL to `.env`:
   ```bash
   HEALTH_CHECK_SLACK_WEBHOOK=https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXX
   ```

### Email Setup

Configure SMTP settings in `.env`:

**Gmail Example:**
```bash
HEALTH_CHECK_EMAIL_TO=ops@example.com
HEALTH_CHECK_EMAIL_FROM=noreply@example.com
HEALTH_CHECK_SMTP_HOST=smtp.gmail.com
HEALTH_CHECK_SMTP_PORT=587
HEALTH_CHECK_SMTP_USER=your-email@gmail.com
HEALTH_CHECK_SMTP_PASSWORD=your-app-password  # Generate from Google Account settings
```

**SendGrid Example:**
```bash
HEALTH_CHECK_SMTP_HOST=smtp.sendgrid.net
HEALTH_CHECK_SMTP_PORT=587
HEALTH_CHECK_SMTP_USER=apikey
HEALTH_CHECK_SMTP_PASSWORD=SG.xxxxxxxxxxxx
```

### PagerDuty Setup

1. Create a PagerDuty integration
2. Get the Integration Key
3. Add to `.env`:
   ```bash
   HEALTH_CHECK_PAGERDUTY_KEY=your-integration-key
   ```

**Note:** PagerDuty alerts are only sent for CRITICAL level issues.

## Monitoring Integration

### Prometheus

Export metrics in Prometheus format:

```bash
# Configure output format
export HEALTH_CHECK_OUTPUT_FORMAT=prometheus

# Add to prometheus.yml
scrape_configs:
  - job_name: 'postgres-health'
    static_configs:
      - targets: ['localhost:9090']
    scrape_interval: 5m
```

**Available Metrics:**
- `postgres_health_status` - Overall health (0=healthy, 1=warning, 2=critical)
- `postgres_health_response_time_seconds` - Total response time
- `postgres_health_uptime_seconds` - Service uptime
- `postgres_health_error_count_{type}` - Error counts by type

### Datadog

Send metrics via JSON output:

```bash
# Configure JSON output
export HEALTH_CHECK_OUTPUT_FORMAT=json

# Parse and send to Datadog
./scripts/health_check_service.py | \
  jq '{metric: "postgres.health.status", points: [[now, .status]]}' | \
  curl -X POST "https://api.datadoghq.com/api/v1/series" \
    -H "Content-Type: application/json" \
    -H "DD-API-KEY: ${DATADOG_API_KEY}" \
    -d @-
```

## Thresholds

Customize alert thresholds in `.env`:

```bash
# Response Time Thresholds (seconds)
HEALTH_CHECK_RESPONSE_TIME_WARNING=1.0
HEALTH_CHECK_RESPONSE_TIME_CRITICAL=5.0

# Error Count Thresholds
HEALTH_CHECK_ERROR_COUNT_WARNING=3      # Alert after 3 consecutive errors
HEALTH_CHECK_ERROR_COUNT_CRITICAL=10    # Critical alert after 10 errors

# Alert Cooldown (minutes)
HEALTH_CHECK_ALERT_COOLDOWN=15          # Wait 15 min before re-alerting
```

## State File

Health check state is persisted to disk (default: `/tmp/postgres-health-check.state.json`):

```json
{
  "last_alerts": {
    "alert-hash": {
      "time": "2026-02-11T18:00:00.000Z",
      "level": "warning"
    }
  },
  "error_counts": {
    "docker": 2,
    "database": 0
  },
  "last_healthy": "2026-02-11T17:55:00.000Z",
  "uptime_start": "2026-02-11T17:00:00.000Z"
}
```

To reset state:
```bash
rm /tmp/postgres-health-check.state.json
```

## Troubleshooting

### Service Not Running

```bash
# Check service status
sudo systemctl status postgres-health-check.service

# Check timer status
sudo systemctl status postgres-health-check.timer

# View errors
journalctl -u postgres-health-check.service -n 50 --no-pager
```

### Alerts Not Sending

1. Verify configuration in `.env`
2. Check logs for alert errors:
   ```bash
   journalctl -u postgres-health-check.service | grep -i "alert"
   ```
3. Test manually:
   ```bash
   # Load env and run
   source .env
   ./scripts/health_check_service.py
   ```

### Permission Issues

Ensure service user has access:
```bash
# Check systemd service file
cat /etc/systemd/system/postgres-health-check.service | grep User

# Ensure user can read .env and run script
sudo -u matt ./scripts/health_check_service.py
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    systemd Timer (5min)                      │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│              health_check_service.py                         │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  HealthChecker                                         │ │
│  │   - Check Docker container                             │ │
│  │   - Check database pools                               │ │
│  │   - Measure response times                             │ │
│  │   - Track error counts                                 │ │
│  └────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  HealthCheckMetrics                                    │ │
│  │   - State persistence                                  │ │
│  │   - Alert deduplication                                │ │
│  │   - Error tracking                                     │ │
│  │   - Uptime calculation                                 │ │
│  └────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  AlertManager                                          │ │
│  │   - Slack notifications                                │ │
│  │   - Email alerts                                       │ │
│  │   - PagerDuty incidents                                │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│              Output (human/json/prometheus)                  │
│              Exit Code (0/1/2)                               │
│              systemd Journal Logs                            │
└─────────────────────────────────────────────────────────────┘
```

## Performance

- **Check Duration:** <1s typical, <5s maximum
- **Memory Usage:** <50MB
- **CPU Usage:** <5% during check
- **Disk I/O:** Minimal (state file only)

## Security

The systemd service runs with security hardening:

- `PrivateTmp=yes` - Isolated /tmp directory
- `NoNewPrivileges=yes` - No privilege escalation
- `ProtectSystem=strict` - Read-only system directories
- `ProtectHome=read-only` - Read-only home directory
- Resource limits (512MB memory, 50% CPU)

## Files

- `/home/matt/projects/Distributed-Postgress-Cluster/scripts/health_check_service.py` - Main service script
- `/etc/systemd/system/postgres-health-check.service` - systemd service unit
- `/etc/systemd/system/postgres-health-check.timer` - systemd timer unit
- `/tmp/postgres-health-check.state.json` - State persistence (configurable)

## Related Documentation

- [Error Handling Guide](ERROR_HANDLING.md)
- [Database Health Check](../scripts/db_health_check.py)
- [Database Startup](../scripts/start_database.sh)
