# Health Check Service Architecture

## System Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        systemd Timer                                 │
│                    (Every 5 minutes)                                 │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│              postgres-health-check.service                           │
│              (oneshot, runs health_check_service.py)                 │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    health_check_service.py                           │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                      HealthChecker                             │ │
│  │                                                                │ │
│  │  ┌──────────────────┐        ┌──────────────────┐            │ │
│  │  │ Docker Check     │        │ Database Check   │            │ │
│  │  │ - Container up?  │        │ - Project DB     │            │ │
│  │  │ - Port 5432      │        │ - Shared DB      │            │ │
│  │  │ - Response time  │        │ - RuVector ext   │            │ │
│  │  └──────────────────┘        └──────────────────┘            │ │
│  │                                                                │ │
│  │  Response Times → Thresholds Check → Alert Level              │ │
│  │  Error Counts   → Threshold Check  → Alert Deduplication      │ │
│  └────────────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                    HealthCheckMetrics                          │ │
│  │                                                                │ │
│  │  State File: /tmp/postgres-health-check.state.json            │ │
│  │  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐  │ │
│  │  │ Last Alerts    │  │ Error Counts   │  │ Uptime Track   │  │ │
│  │  │ - Alert hashes │  │ - docker: N    │  │ - Start time   │  │ │
│  │  │ - Timestamps   │  │ - database: N  │  │ - Last healthy │  │ │
│  │  │ - Alert levels │  │ - schema: N    │  │ - Duration     │  │ │
│  │  └────────────────┘  └────────────────┘  └────────────────┘  │ │
│  │                                                                │ │
│  │  Alert Deduplication (15min cooldown):                        │ │
│  │  - Hash: md5(title + level)                                   │ │
│  │  - Check last alert time                                      │ │
│  │  - Escalate on severity increase                              │ │
│  └────────────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                      AlertManager                              │ │
│  │                                                                │ │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────────────────┐  │ │
│  │  │   Slack    │  │   Email    │  │     PagerDuty          │  │ │
│  │  │            │  │            │  │  (Critical only)       │  │ │
│  │  │ Webhook    │  │ SMTP       │  │  Incident API          │  │ │
│  │  │ POST       │  │ TLS        │  │  Routing key           │  │ │
│  │  └────────────┘  └────────────┘  └────────────────────────┘  │ │
│  │                                                                │ │
│  │  Alert Levels:                                                 │ │
│  │  🔵 INFO      - Informational messages                        │ │
│  │  🟡 WARNING   - Non-critical (Docker down, slow response)     │ │
│  │  🔴 CRITICAL  - Requires attention (DB down, threshold hit)   │ │
│  └────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          Output Formats                              │
│  ┌────────────┐  ┌────────────────┐  ┌──────────────────────────┐  │
│  │   Human    │  │     JSON       │  │     Prometheus           │  │
│  │            │  │                │  │                          │  │
│  │ Console    │  │ Structured     │  │ # HELP ...               │  │
│  │ ✓/✗/⚠     │  │ {              │  │ # TYPE gauge             │  │
│  │ Timestamps │  │   "status": ..│  │ postgres_health_status 0 │  │
│  │ Metrics    │  │   "checks": ..│  │ postgres_health_rt 0.12  │  │
│  └────────────┘  └────────────────┘  └──────────────────────────┘  │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Monitoring Integration                            │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐        │
│  │  Prometheus    │  │    Datadog     │  │  systemd       │        │
│  │  - Scrape      │  │  - JSON parse  │  │  - Journal     │        │
│  │  - Alerts      │  │  - Metrics     │  │  - Logs        │        │
│  │  - Grafana     │  │  - Dashboards  │  │  - Status      │        │
│  └────────────────┘  └────────────────┘  └────────────────┘        │
└─────────────────────────────────────────────────────────────────────┘
```

## Component Details

### 1. systemd Timer
- **Schedule:** OnBootSec=2min, OnUnitActiveSec=5min, OnCalendar=*:0/5
- **Persistent:** Yes (catches up missed runs)
- **Type:** Monotonic + Calendar

### 2. systemd Service
- **Type:** oneshot (exits after each run)
- **User:** matt (non-privileged)
- **Security:** PrivateTmp, NoNewPrivileges, ProtectSystem=strict
- **Resources:** 512MB memory, 50% CPU quota
- **Logging:** systemd journal with SyslogIdentifier

### 3. Health Checker
- **Docker Check:** Subprocess to `docker ps`
- **Database Check:** psycopg2 pool health check
- **Thresholds:**
  - Response time: 1.0s (warning), 5.0s (critical)
  - Error count: 3 (warning), 10 (critical)
- **Metrics:** Response times, error counts, uptime

### 4. State Persistence
- **Format:** JSON
- **Location:** /tmp/postgres-health-check.state.json (configurable)
- **Contents:**
  - Last alerts (hash → {time, level})
  - Error counts (type → count)
  - Last healthy timestamp
  - Uptime start time
- **Purpose:** Alert deduplication, trend tracking

### 5. Alert Manager
- **Channels:** Slack, Email, PagerDuty
- **Deduplication:** 15min cooldown per alert hash
- **Escalation:** Always alert on severity increase
- **Slack:** Webhook POST with color-coded attachments
- **Email:** SMTP with TLS, MIMEText
- **PagerDuty:** Events API v2, critical only

### 6. Output Formats
- **Human:** Console output with emojis and colors
- **JSON:** Structured data for parsing
- **Prometheus:** Metrics in exposition format

## Data Flow

```
Timer → Service → Script → Health Check
                              ↓
                         [Thresholds]
                              ↓
                    ┌─────────┴─────────┐
                    ▼                   ▼
              [Metrics State]     [Alert Manager]
                    │                   │
                    ▼                   ▼
            [Persistence]        [Slack/Email/PD]
                    │
                    ▼
            [Next Run Uses State]
```

## Alert Decision Tree

```
Check Result
    │
    ├─ Docker Down?
    │   ├─ Error Count >= 10? → CRITICAL alert
    │   ├─ Error Count >= 3?  → WARNING alert
    │   └─ Error Count < 3    → Log only
    │
    ├─ Database Error?
    │   ├─ Error Count >= 10? → CRITICAL alert
    │   ├─ Error Count >= 3?  → WARNING alert
    │   └─ Error Count < 3    → Log only
    │
    ├─ Response Time > 5s?    → CRITICAL alert
    ├─ Response Time > 1s?    → WARNING alert
    │
    └─ All OK?
        ├─ Reset error counts
        └─ Record healthy timestamp
```

## Exit Code Logic

```python
if database_error:
    exit_code = 2  # CRITICAL
elif docker_error or slow_response:
    exit_code = 1  # WARNING
else:
    exit_code = 0  # HEALTHY
```

## Threshold Configuration

From `.env`:

```bash
HEALTH_CHECK_RESPONSE_TIME_WARNING=1.0      # seconds
HEALTH_CHECK_RESPONSE_TIME_CRITICAL=5.0     # seconds
HEALTH_CHECK_ERROR_COUNT_WARNING=3          # consecutive errors
HEALTH_CHECK_ERROR_COUNT_CRITICAL=10        # consecutive errors
HEALTH_CHECK_ALERT_COOLDOWN=15              # minutes
```

## Security Model

```
systemd Hardening
    ├─ PrivateTmp=yes         → Isolated /tmp
    ├─ NoNewPrivileges=yes    → No setuid escalation
    ├─ ProtectSystem=strict   → Read-only /usr, /boot
    ├─ ProtectHome=read-only  → Read-only /home
    ├─ MemoryLimit=512M       → Resource limit
    └─ CPUQuota=50%           → CPU throttling

Script Isolation
    ├─ Non-root user (matt)
    ├─ Environment from .env only
    └─ No network access except:
        ├─ PostgreSQL (localhost:5432)
        ├─ Slack webhook (if configured)
        ├─ SMTP server (if configured)
        └─ PagerDuty API (if configured)
```

## Performance Characteristics

| Metric | Target | Typical | Maximum |
|--------|--------|---------|---------|
| Total Check Time | <1s | 0.1-0.5s | <5s |
| Memory Usage | <50MB | 20-30MB | 512MB |
| CPU Usage | <5% | 1-2% | 50% |
| Disk I/O | Minimal | ~1KB | ~10KB |

## Monitoring Points

### systemd Metrics
- `systemctl status postgres-health-check.timer`
- `journalctl -u postgres-health-check.service`
- `systemctl list-timers`

### Health Check Metrics
- Exit code (0/1/2)
- Response times
- Error counts
- Uptime
- Last healthy timestamp

### Alert Metrics
- Alert frequency
- Alert levels
- Cooldown effectiveness
- Channel delivery success

## Failure Modes & Recovery

| Failure | Detection | Recovery |
|---------|-----------|----------|
| Timer not running | `systemctl status` | `systemctl start postgres-health-check.timer` |
| Script fails | Journal logs, exit code | Check .env, permissions |
| Alert not sent | Journal logs, manual test | Check webhook/SMTP config |
| False positives | Error count threshold | Increase thresholds in .env |
| State file corrupt | Script creates new state | Delete state file |
| Database down | Exit code 2, CRITICAL alert | Check Docker, PostgreSQL |

## Integration Examples

### Prometheus
```yaml
scrape_configs:
  - job_name: 'postgres-health'
    static_configs:
      - targets: ['localhost:9090']
    scrape_interval: 5m
```

### Datadog
```bash
HEALTH_CHECK_OUTPUT_FORMAT=json ./health_check_service.py | \
  jq '{metric: "postgres.health", points: [[now, .status]]}' | \
  curl -X POST "https://api.datadoghq.com/api/v1/series" \
    -H "DD-API-KEY: $DATADOG_API_KEY" -d @-
```

### Grafana Dashboard
- Import JSON output
- Graph response times
- Track error counts
- Show uptime percentage

## Files & Locations

| File | Location | Purpose |
|------|----------|---------|
| Service script | /home/matt/projects/.../scripts/health_check_service.py | Main logic |
| Service unit | /etc/systemd/system/postgres-health-check.service | systemd service |
| Timer unit | /etc/systemd/system/postgres-health-check.timer | systemd timer |
| State file | /tmp/postgres-health-check.state.json | Persistence |
| Configuration | /home/matt/projects/.../.env | Environment config |
| Logs | journalctl -u postgres-health-check.service | systemd journal |
