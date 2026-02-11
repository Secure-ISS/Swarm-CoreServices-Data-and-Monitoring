# systemd Health Check Service

Automated PostgreSQL health monitoring with multi-channel alerting.

## Files

- `postgres-health-check.service` - systemd service unit
- `postgres-health-check.timer` - systemd timer (runs every 5 minutes)

## Installation

```bash
sudo ../install-health-service.sh
```

## Configuration

The service runs with these settings:

- **User:** matt
- **Working Directory:** /home/matt/projects/Distributed-Postgress-Cluster
- **Environment:** Loads from .env file
- **Schedule:** Every 5 minutes (2 minutes after boot, then every 5 minutes)
- **Logging:** systemd journal

## Security Hardening

- Private /tmp directory
- No privilege escalation
- Read-only system directories
- Memory limit: 512MB
- CPU quota: 50%

## Usage

```bash
# View status
systemctl status postgres-health-check.timer

# View logs
journalctl -u postgres-health-check.service -f

# Trigger manual run
sudo systemctl start postgres-health-check.service

# Stop timer
sudo systemctl stop postgres-health-check.timer

# Disable timer
sudo systemctl disable postgres-health-check.timer
```

## Exit Codes

- 0 - Healthy
- 1 - Warning (non-critical)
- 2 - Critical (requires attention)

## See Also

- [Health Check Service Documentation](../../docs/HEALTH_CHECK_SERVICE.md)
- [Health Check Service Script](../health_check_service.py)
