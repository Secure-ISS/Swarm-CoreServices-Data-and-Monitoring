# Monitoring Stack

Comprehensive monitoring infrastructure for Distributed PostgreSQL Cluster using Prometheus, Grafana, and AlertManager.

## Quick Start

```bash
# Start monitoring stack
cd /home/matt/projects/Distributed-Postgress-Cluster
./scripts/start_monitoring.sh

# Or manually
docker compose -f docker/monitoring/docker-compose.yml up -d

# Check status
docker compose -f docker/monitoring/docker-compose.yml ps
```

## Services

| Service | Port | Description |
|---------|------|-------------|
| Prometheus | 9090 | Metrics collection and storage |
| Grafana | 3000 | Visualization platform (admin/admin) |
| AlertManager | 9093 | Alert routing and notifications |
| PostgreSQL Exporter | 9187 | Database metrics |
| Redis Exporter | 9121 | Cache metrics |
| Node Exporter | 9100 | System metrics |
| App Exporter | 9999 | Custom application metrics |

## Access URLs

- **Prometheus**: http://localhost:9090
- **Grafana**: http://localhost:3000 (username: admin, password: admin)
- **AlertManager**: http://localhost:9093

## Configuration

### Environment Variables

Copy and configure:
```bash
cp config/monitoring.env.example .env
# Edit .env with your notification settings
```

Required variables:
- `SLACK_WEBHOOK_URL` - Slack notifications
- `SMTP_*` - Email notifications
- `PAGERDUTY_SERVICE_KEY` - PagerDuty integration

### Custom Metrics

Add custom PostgreSQL queries in:
```
config/prometheus/postgres-queries.yaml
```

### Alert Rules

Add custom alerts in:
```
config/prometheus/alerts/
├── database-alerts.yml
├── ruvector-alerts.yml
├── redis-alerts.yml
├── system-alerts.yml
└── application-alerts.yml
```

### Dashboards

Grafana dashboards in:
```
config/grafana/dashboards/
```

## Health Checks

Check exporter health:
```bash
# PostgreSQL metrics
curl http://localhost:9187/metrics

# Redis metrics
curl http://localhost:9121/metrics

# System metrics
curl http://localhost:9100/metrics

# Application metrics
curl http://localhost:9999/metrics
```

Check Prometheus targets:
```bash
curl http://localhost:9090/api/v1/targets
```

## Metrics Overview

### Database Metrics
- Connection statistics
- Transaction rates
- Cache hit ratios
- Replication lag
- Table/index sizes
- Query performance

### RuVector Metrics
- Vector counts
- Search latency
- HNSW index statistics
- Operation throughput
- Memory usage

### Redis Metrics
- Memory usage
- Hit/miss rates
- Key statistics
- Client connections
- Eviction counts

### System Metrics
- CPU usage
- Memory usage
- Disk I/O
- Network traffic
- Filesystem usage

## Alerts

Total: 60 alert rules
- Critical: 18 rules
- Warning: 42 rules

Alert categories:
- Database (16 rules)
- RuVector (9 rules)
- Redis (11 rules)
- System (13 rules)
- Application (11 rules)

## Troubleshooting

### Service won't start
```bash
# Check logs
docker compose -f docker/monitoring/docker-compose.yml logs <service>

# Check configuration
docker exec dpg-prometheus promtool check config /etc/prometheus/prometheus.yml

# Restart service
docker compose -f docker/monitoring/docker-compose.yml restart <service>
```

### No metrics in Grafana
1. Check Prometheus targets: http://localhost:9090/targets
2. Verify datasource in Grafana
3. Check time range in dashboard

### Alerts not firing
```bash
# Check AlertManager status
curl http://localhost:9093/api/v2/status

# View active alerts
curl http://localhost:9090/api/v1/alerts

# Test notification
docker exec dpg-alertmanager amtool config routes test
```

## Documentation

Complete documentation:
- [Monitoring Guide](../../docs/MONITORING.md) - Comprehensive guide
- [Runbooks](../../docs/RUNBOOKS.md) - Alert troubleshooting
- [Summary](../../docs/MONITORING_SUMMARY.md) - Implementation overview

## Architecture

```
┌─────────────┐
│   Grafana   │  Visualization
└──────┬──────┘
       │
┌──────▼──────────┐
│   Prometheus    │  Metrics Collection
└──┬───┬───┬───┬──┘
   │   │   │   │
   │   │   │   └──────────┐
   │   │   │              │
┌──▼──┐ ┌▼─┐ ┌▼─┐ ┌──────▼──┐
│ PG  │ │R │ │N │ │   App   │
│Exprt│ │E │ │E │ │ Exporter│
└──┬──┘ └┬─┘ └┬─┘ └────┬────┘
   │     │    │        │
┌──▼─────▼────▼────────▼──┐
│   Target Services       │
│ PostgreSQL │ Redis │ .. │
└─────────────────────────┘
```

## Maintenance

### Regular tasks
- Review alert thresholds weekly
- Update dashboards as needed
- Clean up old metrics monthly
- Test disaster recovery quarterly

### Monitoring the monitors
- Prometheus scrape health
- AlertManager notification success
- Grafana response times
- Exporter uptime

## Support

- Issues: Report to DevOps team
- Runbooks: See [RUNBOOKS.md](../../docs/RUNBOOKS.md)
- Documentation: See [MONITORING.md](../../docs/MONITORING.md)
