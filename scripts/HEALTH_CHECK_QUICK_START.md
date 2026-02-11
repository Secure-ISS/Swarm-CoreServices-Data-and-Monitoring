# Health Check Service - Quick Start

## Installation (30 seconds)

```bash
# Install systemd service
sudo ./scripts/install-health-service.sh

# Verify it's running
systemctl status postgres-health-check.timer
```

Done! Health checks now run every 5 minutes automatically.

## Optional: Enable Alerts

Edit `.env` and uncomment alert configuration:

```bash
# Slack
HEALTH_CHECK_SLACK_WEBHOOK=https://hooks.slack.com/services/YOUR/WEBHOOK

# Email
HEALTH_CHECK_EMAIL_TO=ops@example.com

# PagerDuty (critical alerts only)
HEALTH_CHECK_PAGERDUTY_KEY=your-key
```

## Commands

```bash
# View logs
journalctl -u postgres-health-check.service -f

# Manual test
./scripts/health_check_service.py

# Check schedule
systemctl list-timers postgres-health-check.timer

# Trigger now
sudo systemctl start postgres-health-check.service
```

## What It Monitors

- Docker container (port 5432)
- Project database connectivity
- Shared database connectivity
- Response times
- Error rates

## Exit Codes

- 0 = Healthy
- 1 = Warning (Docker issues, slow responses)
- 2 = Critical (Database down)

## Full Documentation

See [HEALTH_CHECK_SERVICE.md](../docs/HEALTH_CHECK_SERVICE.md) for complete details.
