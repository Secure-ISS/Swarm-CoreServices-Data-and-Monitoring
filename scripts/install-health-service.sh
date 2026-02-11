#!/bin/bash
set -euo pipefail

# Installation script for PostgreSQL Health Check systemd service
# This script installs and enables the health check timer

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=" | tr '=' '-' | head -c 60; echo
echo "🏥 PostgreSQL Health Check Service Installer"
echo "=" | tr '=' '-' | head -c 60; echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ This script must be run as root (use sudo)"
    echo "Usage: sudo $0"
    exit 1
fi

# Verify systemd files exist
echo "📁 Verifying systemd files..."
if [ ! -f "$SCRIPT_DIR/systemd/postgres-health-check.service" ]; then
    echo "❌ Service file not found: $SCRIPT_DIR/systemd/postgres-health-check.service"
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/systemd/postgres-health-check.timer" ]; then
    echo "❌ Timer file not found: $SCRIPT_DIR/systemd/postgres-health-check.timer"
    exit 1
fi

# Verify health check script exists
if [ ! -f "$SCRIPT_DIR/health_check_service.py" ]; then
    echo "❌ Health check script not found: $SCRIPT_DIR/health_check_service.py"
    exit 1
fi

# Make health check script executable
chmod +x "$SCRIPT_DIR/health_check_service.py"
echo "✓ Made health check script executable"

# Copy systemd files
echo
echo "📋 Installing systemd files..."
cp "$SCRIPT_DIR/systemd/postgres-health-check.service" /etc/systemd/system/
echo "✓ Copied postgres-health-check.service"

cp "$SCRIPT_DIR/systemd/postgres-health-check.timer" /etc/systemd/system/
echo "✓ Copied postgres-health-check.timer"

# Reload systemd daemon
echo
echo "🔄 Reloading systemd daemon..."
systemctl daemon-reload
echo "✓ Systemd daemon reloaded"

# Enable and start timer
echo
echo "🚀 Enabling and starting health check timer..."
systemctl enable postgres-health-check.timer
echo "✓ Timer enabled (will start on boot)"

systemctl start postgres-health-check.timer
echo "✓ Timer started"

# Show status
echo
echo "=" | tr '=' '-' | head -c 60; echo
echo "📊 Service Status"
echo "=" | tr '=' '-' | head -c 60; echo
systemctl status postgres-health-check.timer --no-pager

echo
echo "=" | tr '=' '-' | head -c 60; echo
echo "📅 Timer Schedule"
echo "=" | tr '=' '-' | head -c 60; echo
systemctl list-timers postgres-health-check.timer --no-pager

# Show recent logs
echo
echo "=" | tr '=' '-' | head -c 60; echo
echo "📜 Recent Logs (last 10 lines)"
echo "=" | tr '=' '-' | head -c 60; echo
journalctl -u postgres-health-check.service -n 10 --no-pager || echo "(No logs yet - timer will trigger first run in 2 minutes)"

# Configuration reminder
echo
echo "=" | tr '=' '-' | head -c 60; echo
echo "🔧 Configuration"
echo "=" | tr '=' '-' | head -c 60; echo
echo "To configure alerting, add these to your .env file:"
echo
echo "# Slack Webhook"
echo "HEALTH_CHECK_SLACK_WEBHOOK=https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
echo
echo "# Email Configuration"
echo "HEALTH_CHECK_EMAIL_TO=ops@example.com"
echo "HEALTH_CHECK_EMAIL_FROM=noreply@example.com"
echo "HEALTH_CHECK_SMTP_HOST=smtp.gmail.com"
echo "HEALTH_CHECK_SMTP_PORT=587"
echo "HEALTH_CHECK_SMTP_USER=your-email@gmail.com"
echo "HEALTH_CHECK_SMTP_PASSWORD=your-app-password"
echo
echo "# PagerDuty"
echo "HEALTH_CHECK_PAGERDUTY_KEY=your-integration-key"
echo
echo "# Thresholds"
echo "HEALTH_CHECK_RESPONSE_TIME_WARNING=1.0"
echo "HEALTH_CHECK_RESPONSE_TIME_CRITICAL=5.0"
echo "HEALTH_CHECK_ERROR_COUNT_WARNING=3"
echo "HEALTH_CHECK_ERROR_COUNT_CRITICAL=10"
echo "HEALTH_CHECK_ALERT_COOLDOWN=15"
echo
echo "# Output Format (human, json, prometheus)"
echo "HEALTH_CHECK_OUTPUT_FORMAT=human"
echo
echo "# State File"
echo "HEALTH_CHECK_STATE_FILE=/tmp/postgres-health-check.state.json"
echo

echo "=" | tr '=' '-' | head -c 60; echo
echo "✅ Installation Complete!"
echo "=" | tr '=' '-' | head -c 60; echo
echo
echo "Useful commands:"
echo "  Check timer status:    systemctl status postgres-health-check.timer"
echo "  View logs:             journalctl -u postgres-health-check.service -f"
echo "  Trigger manual run:    sudo systemctl start postgres-health-check.service"
echo "  Stop timer:            sudo systemctl stop postgres-health-check.timer"
echo "  Disable timer:         sudo systemctl disable postgres-health-check.timer"
echo
echo "The health check will run every 5 minutes starting 2 minutes after boot."
echo
