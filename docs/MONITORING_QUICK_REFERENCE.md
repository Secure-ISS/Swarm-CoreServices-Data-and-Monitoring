# Monitoring Quick Reference

## Access URLs

| Service | URL | Credentials |
|---------|-----|-------------|
| Prometheus | http://localhost:9090 | None |
| Grafana | http://localhost:3000 | admin/admin |
| AlertManager | http://localhost:9093 | None |

## Start/Stop

```bash
# Start monitoring stack
./scripts/start_monitoring.sh

# Or manually
docker compose -f docker/monitoring/docker-compose.yml up -d

# Stop
docker compose -f docker/monitoring/docker-compose.yml down

# Restart
docker compose -f docker/monitoring/docker-compose.yml restart

# View logs
docker compose -f docker/monitoring/docker-compose.yml logs -f [service]
```

## Common Commands

### Check Service Status
```bash
docker compose -f docker/monitoring/docker-compose.yml ps
docker ps | grep dpg
```

### View Metrics
```bash
# PostgreSQL
curl http://localhost:9187/metrics

# Redis
curl http://localhost:9121/metrics

# System
curl http://localhost:9100/metrics

# Application (RuVector)
curl http://localhost:9999/metrics
```

### Prometheus

```bash
# Check targets
curl http://localhost:9090/api/v1/targets

# Check alerts
curl http://localhost:9090/api/v1/alerts

# Reload config
curl -X POST http://localhost:9090/-/reload

# Validate config
docker exec dpg-prometheus promtool check config /etc/prometheus/prometheus.yml
```

### AlertManager

```bash
# Check status
curl http://localhost:9093/api/v2/status

# View alerts
curl http://localhost:9093/api/v2/alerts

# Test routing
docker exec dpg-alertmanager amtool config routes test

# Show config
docker exec dpg-alertmanager amtool config show
```

### Grafana

```bash
# List datasources
curl -u admin:admin http://localhost:3000/api/datasources

# List dashboards
curl -u admin:admin http://localhost:3000/api/search

# Test datasource
curl -u admin:admin http://localhost:3000/api/datasources/1/health
```

## Key Metrics

### Database
- `pg_up` - PostgreSQL is up (1) or down (0)
- `dpg_db_connections_active` - Active connections
- `dpg_cache_hit_ratio` - Cache hit ratio (0-1)
- `pg_replication_lag` - Replication lag (seconds)

### RuVector
- `ruvector_vector_count` - Number of vectors
- `ruvector_search_latency_seconds` - Search latency
- `ruvector_index_size_bytes` - HNSW index size

### Redis
- `redis_up` - Redis is up (1) or down (0)
- `dpg_redis_memory_used_bytes` - Memory usage
- `dpg_redis_hit_rate` - Hit rate (0-1)

### System
- `node_cpu_seconds_total` - CPU time
- `node_memory_MemAvailable_bytes` - Available memory
- `node_filesystem_avail_bytes` - Available disk

## Common Queries

### Database Connections
```promql
sum(dpg_db_connections_active)
```

### Transaction Rate
```promql
rate(pg_stat_database_xact_commit[5m])
```

### Cache Hit Ratio
```promql
dpg_cache_hit_ratio
```

### Vector Search P95 Latency
```promql
histogram_quantile(0.95, rate(ruvector_search_latency_seconds_bucket[5m]))
```

### Redis Memory Usage %
```promql
(dpg_redis_memory_used_bytes / redis_memory_max_bytes) * 100
```

### CPU Usage %
```promql
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

## Alert Severity

| Level | Response Time | Examples |
|-------|---------------|----------|
| **Critical** | Immediate | Service down, pool exhausted, high error rate |
| **Warning** | 15-30 min | High resource usage, low cache hit, replication lag |
| **Info** | Next business day | Configuration changes, routine maintenance |

## Troubleshooting

### Service Down
```bash
# Check status
docker ps -a | grep dpg-prometheus

# View logs
docker logs dpg-prometheus --tail 100

# Restart
docker restart dpg-prometheus
```

### No Data in Grafana
1. Check Prometheus targets: http://localhost:9090/targets
2. Verify time range in Grafana
3. Test query in Prometheus directly

### Alerts Not Firing
```bash
# Check alert rules
docker exec dpg-prometheus promtool check rules /etc/prometheus/alerts/*.yml

# View active alerts
curl http://localhost:9090/api/v1/alerts
```

### High Memory Usage
```bash
# Check container stats
docker stats dpg-prometheus

# Reduce retention
# Edit prometheus.yml: --storage.tsdb.retention.time=15d
```

## Configuration Files

| Component | Config File |
|-----------|-------------|
| Prometheus | /config/prometheus/prometheus.yml |
| Alert Rules | /config/prometheus/alerts/*.yml |
| PostgreSQL Queries | /config/prometheus/postgres-queries.yaml |
| AlertManager | /config/alertmanager/config.yml |
| Grafana Datasources | /config/grafana/provisioning/datasources/ |
| Grafana Dashboards | /config/grafana/provisioning/dashboards/ |

## Health Checks

```bash
# PostgreSQL
docker exec dpg-postgres-dev pg_isready

# Redis
docker exec dpg-redis-dev redis-cli ping

# Prometheus
curl http://localhost:9090/-/healthy

# Grafana
curl http://localhost:3000/api/health

# AlertManager
curl http://localhost:9093/-/healthy
```

## Exporters

| Exporter | Port | Metrics |
|----------|------|---------|
| PostgreSQL | 9187 | Database, connections, queries |
| Redis | 9121 | Memory, keys, clients |
| Node | 9100 | CPU, memory, disk, network |
| Application | 9999 | RuVector, custom metrics |

## Documentation

- Full Guide: `/docs/MONITORING.md`
- Runbooks: `/docs/RUNBOOKS.md`
- Summary: `/docs/MONITORING_SUMMARY.md`
- Docker README: `/docker/monitoring/README.md`

## Support

### Emergency Contacts
- Critical Issues: oncall@dpg-cluster.local
- DevOps Team: devops@dpg-cluster.local
- PagerDuty: Configured in AlertManager

### Common Issues
1. **Service won't start**: Check logs, verify config
2. **No metrics**: Check Prometheus targets
3. **Alerts not firing**: Verify alert rules, check AlertManager
4. **High memory**: Reduce retention, check cardinality

### Useful Links
- Prometheus Docs: https://prometheus.io/docs/
- Grafana Docs: https://grafana.com/docs/
- PromQL Reference: https://prometheus.io/docs/prometheus/latest/querying/basics/

## Testing

### Test Alert
```bash
# Stop service to trigger alert
docker stop dpg-postgres-dev

# Wait 1 minute, check alerts
curl http://localhost:9090/api/v1/alerts

# Restart service
docker start dpg-postgres-dev
```

### Test Notification
```bash
# Send test alert to AlertManager
curl -X POST http://localhost:9093/api/v2/alerts \
  -H 'Content-Type: application/json' \
  -d '[{
    "labels": {
      "alertname": "TestAlert",
      "severity": "info"
    },
    "annotations": {
      "summary": "Test alert from monitoring stack"
    }
  }]'
```

## Performance Tuning

### Prometheus
- Reduce scrape interval for less critical jobs
- Use recording rules for expensive queries
- Adjust retention period
- Enable remote write for long-term storage

### Grafana
- Limit time range for heavy dashboards
- Use query caching
- Optimize panel queries
- Pre-load frequently used dashboards

### Exporters
- Adjust scrape_timeout if needed
- Filter high-cardinality metrics
- Use blackbox exporter for external services

## Maintenance

### Daily
- Monitor alert volume
- Check service health

### Weekly
- Review alert thresholds
- Check disk usage
- Update dashboards

### Monthly
- Review and clean up old alerts
- Update documentation
- Test disaster recovery

---

**Version**: 1.0.0
**Last Updated**: 2026-02-12
**Maintainer**: DevOps Team
