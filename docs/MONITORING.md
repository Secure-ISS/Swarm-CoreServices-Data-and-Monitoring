# Monitoring Guide - Distributed PostgreSQL Cluster

## Overview

This guide covers the comprehensive monitoring stack for the Distributed PostgreSQL Cluster, including Prometheus, Grafana, AlertManager, and custom exporters.

## Table of Contents

- [Architecture](#architecture)
- [Components](#components)
- [Metrics](#metrics)
- [Alerts](#alerts)
- [Dashboards](#dashboards)
- [Configuration](#configuration)
- [Deployment](#deployment)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)

## Architecture

The monitoring stack consists of the following components:

```
┌─────────────────────────────────────────────────────────────┐
│                     Grafana (Port 3000)                     │
│              Visualization & Dashboard Platform              │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│                   Prometheus (Port 9090)                     │
│              Metrics Collection & Storage                    │
└─────┬──────┬──────┬──────┬──────┬──────┬──────────────────┘
      │      │      │      │      │      │
      │      │      │      │      │      └──────────────┐
      │      │      │      │      │                     │
┌─────▼──┐ ┌─▼────┐ ┌─▼────┐ ┌─▼────┐ ┌─▼────┐ ┌────▼────┐
│Postgres│ │Redis │ │ Node │ │ App  │ │Alert │ │ Health  │
│Exporter│ │Export│ │Export│ │Export│ │Manage│ │Checks   │
│:9187   │ │:9121 │ │:9100 │ │:9999 │ │:9093 │ │         │
└────────┘ └──────┘ └──────┘ └──────┘ └──────┘ └─────────┘
     │         │         │         │         │
     │         │         │         │         │
┌────▼─────────▼─────────▼─────────▼─────────▼─────────────┐
│              Target Services & Infrastructure             │
│   PostgreSQL  │  Redis  │  System  │  Application         │
└───────────────────────────────────────────────────────────┘
```

### Data Flow

1. **Collection**: Exporters scrape metrics from target services
2. **Storage**: Prometheus stores time-series data (30 days retention)
3. **Evaluation**: Alert rules evaluated every 15s
4. **Alerting**: AlertManager routes notifications to appropriate channels
5. **Visualization**: Grafana queries Prometheus and renders dashboards

## Components

### 1. Prometheus (Port 9090)

**Purpose**: Metrics collection and storage

**Features**:
- 15s scrape interval (configurable per job)
- 30-day retention
- 10GB storage limit
- Alert rule evaluation
- Remote write/read support (optional)

**Configuration**: `/config/prometheus/prometheus.yml`

**Access**: http://localhost:9090

### 2. Grafana (Port 3000)

**Purpose**: Visualization and dashboards

**Features**:
- Pre-configured datasources
- Pre-provisioned dashboards
- Role-based access control
- Alert annotations
- Automated provisioning

**Configuration**: `/config/grafana/provisioning/`

**Access**: http://localhost:3000 (admin/admin)

**Dashboards**:
- DPG Cluster Overview
- PostgreSQL Performance
- RuVector Metrics
- Redis Performance
- System Metrics
- Application Performance

### 3. AlertManager (Port 9093)

**Purpose**: Alert routing and notifications

**Features**:
- Multi-channel notifications (Slack, Email, PagerDuty)
- Alert grouping and deduplication
- Inhibition rules
- Silence management
- Time-based routing

**Configuration**: `/config/alertmanager/config.yml`

**Access**: http://localhost:9093

### 4. PostgreSQL Exporter (Port 9187)

**Purpose**: Database metrics collection

**Metrics Exposed**:
- Connection statistics
- Transaction rates
- Cache hit ratios
- Replication lag
- Table/index statistics
- RuVector-specific metrics

**Configuration**: `/config/prometheus/postgres-queries.yaml`

### 5. Redis Exporter (Port 9121)

**Purpose**: Cache metrics collection

**Metrics Exposed**:
- Memory usage
- Key statistics
- Hit/miss rates
- Eviction counts
- Client connections
- Persistence status

### 6. Node Exporter (Port 9100)

**Purpose**: System metrics collection

**Metrics Exposed**:
- CPU usage
- Memory usage
- Disk I/O
- Network traffic
- Filesystem usage
- System load

### 7. Custom Application Exporter (Port 9999)

**Purpose**: Application and RuVector-specific metrics

**Metrics Exposed**:
- RuVector search latency
- HNSW index statistics
- Vector operation performance
- Connection pool metrics
- Custom business metrics

**Code**: `/docker/monitoring/exporter.py`

## Metrics

### Database Metrics

#### Connection Metrics
- `pg_stat_activity_count` - Active connections by state
- `dpg_db_connections_active` - Number of active connections
- `dpg_db_connections_idle` - Number of idle connections
- `dpg_db_connections_waiting` - Connections waiting for backend

#### Performance Metrics
- `pg_stat_database_xact_commit` - Committed transactions
- `pg_stat_database_xact_rollback` - Rolled back transactions
- `dpg_cache_hit_ratio` - Database cache hit ratio (0-1)
- `dpg_query_duration_seconds` - Query execution time histogram

#### Replication Metrics
- `pg_replication_lag` - Replication lag in seconds
- `pg_replication_status` - Replication streaming status (1/0)

#### Storage Metrics
- `dpg_table_size_bytes` - Table size in bytes
- `dpg_table_rows` - Estimated row count
- `dpg_index_size_bytes` - Index size in bytes
- `dpg_table_bloat_ratio` - Table bloat ratio (0-1)

### RuVector Metrics

#### Vector Operations
- `ruvector_vector_count` - Number of vectors per table
- `ruvector_search_latency_seconds` - Search latency histogram
- `ruvector_index_operations_total` - Index operations counter

#### Index Metrics
- `ruvector_index_size_bytes` - HNSW index size
- `pg_stat_user_indexes_idx_scan` - Index scan count
- `pg_stat_user_indexes_idx_tup_fetch` - Tuples fetched by index

### Redis Metrics

- `dpg_redis_memory_used_bytes` - Memory usage
- `dpg_redis_keys_total` - Total key count
- `dpg_redis_hit_rate` - Cache hit rate (0-1)
- `dpg_redis_evicted_keys_total` - Evicted keys counter
- `redis_connected_clients` - Connected clients
- `redis_blocked_clients` - Blocked clients

### System Metrics

- `node_cpu_seconds_total` - CPU time by mode
- `node_memory_MemAvailable_bytes` - Available memory
- `node_filesystem_avail_bytes` - Available disk space
- `node_disk_io_time_seconds_total` - Disk I/O time
- `node_network_receive_bytes_total` - Network RX bytes
- `node_network_transmit_bytes_total` - Network TX bytes

## Alerts

### Alert Severity Levels

- **Critical**: Immediate action required, service disruption
- **Warning**: Attention needed, potential issues
- **Info**: Informational, no action required

### Alert Categories

#### Database Alerts
- `PostgreSQLDown` - Database instance down (Critical)
- `PostgreSQLTooManyConnections` - Connection limit approaching (Warning)
- `PostgreSQLConnectionPoolExhausted` - No available connections (Critical)
- `PostgreSQLLowCacheHitRatio` - Poor cache performance (Warning)
- `PostgreSQLReplicationLag` - Replication delay (Warning/Critical)
- `PostgreSQLDeadTuplesHigh` - High dead tuple ratio (Warning)
- `PostgreSQLDiskSpaceLow` - Low disk space (Warning/Critical)

#### RuVector Alerts
- `RuVectorSearchLatencyHigh` - Slow vector searches (Warning)
- `RuVectorSearchLatencyCritical` - Very slow searches (Critical)
- `RuVectorIndexGrowthHigh` - Rapid index growth (Warning)
- `RuVectorCountAnomaly` - Unexpected vector count change (Warning)
- `RuVectorOperationErrors` - Vector operation failures (Critical)

#### Redis Alerts
- `RedisDown` - Redis instance down (Critical)
- `RedisMemoryUsageHigh` - High memory usage (Warning/Critical)
- `RedisHitRateLow` - Poor cache performance (Warning)
- `RedisEvictionsHigh` - High eviction rate (Warning)

#### System Alerts
- `HighCPUUsage` - CPU usage >80% (Warning)
- `CriticalCPUUsage` - CPU usage >95% (Critical)
- `HighMemoryUsage` - Memory usage >85% (Warning)
- `DiskSpaceLow` - Disk space <20% (Warning/Critical)
- `HighDiskIO` - Disk I/O >80% (Warning)

#### Application Alerts
- `HighErrorRate` - Error rate >5% (Critical)
- `SlowResponseTime` - P95 latency >1s (Warning)
- `ServiceDegradation` - Success rate <95% (Warning)
- `HealthCheckFailing` - Health check failures (Critical)

### Alert Routing

Alerts are routed based on:
1. **Severity**: Critical alerts → PagerDuty + Slack + Email
2. **Category**: Database → #dpg-database, Performance → #dpg-performance
3. **Component**: RuVector → #dpg-ruvector
4. **Time**: Business hours vs. off-hours routing

### Notification Channels

Configure these environment variables:

```bash
# Slack
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK/URL

# Email
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_FROM=alerts@dpg-cluster.local
SMTP_USERNAME=your-email@gmail.com
SMTP_PASSWORD=your-app-password
CRITICAL_EMAIL_LIST=oncall@dpg-cluster.local,devops@dpg-cluster.local
DATABASE_TEAM_EMAIL=database@dpg-cluster.local
SECURITY_TEAM_EMAIL=security@dpg-cluster.local

# PagerDuty
PAGERDUTY_SERVICE_KEY=your-pagerduty-integration-key
```

## Dashboards

### DPG Cluster Overview

**Purpose**: High-level cluster health

**Panels**:
- Service status indicators
- Active connections
- Transaction rate
- Cache hit ratios
- System resource usage

**Refresh**: 10s

**URL**: http://localhost:3000/d/dpg-overview

### PostgreSQL Performance

**Panels**:
- Connection pool utilization
- Query performance (P50/P95/P99)
- Transaction rates
- Cache statistics
- Table sizes and growth
- Index efficiency
- Checkpoint activity

### RuVector Metrics

**Panels**:
- Vector search latency (P50/P95/P99)
- HNSW index sizes
- Vector counts per table
- Index operation rates
- Search throughput
- Memory usage

### Redis Performance

**Panels**:
- Memory usage and trends
- Hit/miss rates
- Eviction rates
- Key count
- Client connections
- Command statistics

### System Metrics

**Panels**:
- CPU usage by core
- Memory usage breakdown
- Disk I/O rates
- Network traffic
- Filesystem usage
- System load

## Configuration

### Prometheus Configuration

Edit `/config/prometheus/prometheus.yml`:

```yaml
global:
  scrape_interval: 15s      # How often to scrape targets
  evaluation_interval: 15s  # How often to evaluate rules

scrape_configs:
  - job_name: 'postgresql'
    static_configs:
      - targets: ['postgres-exporter:9187']
    scrape_interval: 10s    # Override for this job
```

### Custom PostgreSQL Queries

Add custom queries in `/config/prometheus/postgres-queries.yaml`:

```yaml
my_custom_metric:
  query: |
    SELECT
      schemaname,
      tablename,
      COUNT(*) as custom_count
    FROM my_table
    GROUP BY schemaname, tablename
  metrics:
    - schemaname:
        usage: "LABEL"
    - tablename:
        usage: "LABEL"
    - custom_count:
        usage: "GAUGE"
```

### Alert Rules

Add custom alerts in `/config/prometheus/alerts/*.yml`:

```yaml
groups:
  - name: my-alerts
    rules:
      - alert: MyCustomAlert
        expr: my_metric > 100
        for: 5m
        labels:
          severity: warning
          category: application
        annotations:
          summary: "Custom alert fired"
          description: "my_metric is {{ $value }}"
```

### Grafana Dashboards

Dashboards can be:
1. **Provisioned**: Place JSON in `/config/grafana/dashboards/`
2. **Created in UI**: Export as JSON for version control
3. **Imported**: Use dashboard ID from grafana.com

## Deployment

### Start Monitoring Stack

```bash
# Start the monitoring stack
docker compose -f docker/monitoring/docker-compose.yml up -d

# Check status
docker compose -f docker/monitoring/docker-compose.yml ps

# View logs
docker compose -f docker/monitoring/docker-compose.yml logs -f
```

### Start with Application Stack

```bash
# Start both dev and monitoring stacks
docker compose -f docker-compose.dev.yml up -d
docker compose -f docker/monitoring/docker-compose.yml up -d

# Verify all services
docker ps | grep dpg
```

### Access Services

- Prometheus: http://localhost:9090
- Grafana: http://localhost:3000 (admin/admin)
- AlertManager: http://localhost:9093
- PostgreSQL Exporter: http://localhost:9187/metrics
- Redis Exporter: http://localhost:9121/metrics
- Node Exporter: http://localhost:9100/metrics
- App Exporter: http://localhost:9999/metrics

### Health Checks

```bash
# Check Prometheus targets
curl http://localhost:9090/api/v1/targets

# Check AlertManager status
curl http://localhost:9093/api/v2/status

# Check exporter metrics
curl http://localhost:9187/metrics  # PostgreSQL
curl http://localhost:9121/metrics  # Redis
curl http://localhost:9999/metrics  # Application
```

## Troubleshooting

### Common Issues

#### 1. Exporter Can't Connect to Database

**Symptoms**: Metrics show `pg_up 0`

**Solution**:
```bash
# Check network connectivity
docker exec dpg-postgres-exporter ping dpg-postgres-dev

# Verify credentials
docker exec dpg-postgres-exporter env | grep DATA_SOURCE

# Check PostgreSQL logs
docker logs dpg-postgres-dev
```

#### 2. No Data in Grafana

**Symptoms**: Empty dashboards

**Solution**:
1. Check Prometheus is scraping: http://localhost:9090/targets
2. Verify datasource: Grafana → Configuration → Data Sources
3. Test query in Prometheus: http://localhost:9090/graph
4. Check time range in Grafana

#### 3. Alerts Not Firing

**Symptoms**: No notifications despite issues

**Solution**:
```bash
# Check AlertManager status
curl http://localhost:9093/api/v2/status

# View active alerts in Prometheus
curl http://localhost:9090/api/v1/alerts

# Check AlertManager config
docker exec dpg-alertmanager amtool config show

# Test alert routing
docker exec dpg-alertmanager amtool config routes test
```

#### 4. High Memory Usage

**Symptoms**: Prometheus using excessive memory

**Solution**:
1. Reduce retention: `--storage.tsdb.retention.time=15d`
2. Reduce scrape frequency in high-cardinality jobs
3. Use recording rules for expensive queries
4. Increase memory limits in docker-compose.yml

#### 5. Missing Metrics

**Symptoms**: Specific metrics not appearing

**Solution**:
1. Check exporter is running: `docker ps | grep exporter`
2. Verify metric exists: `curl http://localhost:9187/metrics | grep metric_name`
3. Check Prometheus config: Job configured correctly?
4. Check labels: Metric may be filtered by labels

### Debug Commands

```bash
# Check Prometheus configuration
docker exec dpg-prometheus promtool check config /etc/prometheus/prometheus.yml

# Check alert rules
docker exec dpg-prometheus promtool check rules /etc/prometheus/alerts/*.yml

# View Prometheus logs
docker logs dpg-prometheus --tail 100 -f

# View AlertManager logs
docker logs dpg-alertmanager --tail 100 -f

# Check custom exporter logs
docker logs dpg-app-exporter --tail 100 -f

# Reload Prometheus config (without restart)
curl -X POST http://localhost:9090/-/reload

# Test AlertManager webhook
curl -X POST http://localhost:9093/api/v2/alerts \
  -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"Test","severity":"info"}}]'
```

## Best Practices

### 1. Metric Naming

Follow Prometheus naming conventions:
- Use base unit (seconds, bytes, ratio)
- Use `_total` suffix for counters
- Use descriptive names: `dpg_db_connections_active` not `connections`
- Group by prefix: `dpg_`, `ruvector_`, `redis_`

### 2. Label Usage

- Keep cardinality low (<1000 unique combinations)
- Use consistent label names across metrics
- Don't use high-cardinality data (IDs, timestamps) as labels
- Add `job` and `instance` labels automatically

### 3. Alert Design

- Set appropriate thresholds based on baseline
- Use `for:` clause to avoid alert flapping
- Include runbook links in annotations
- Group related alerts
- Use inhibition rules to reduce noise

### 4. Dashboard Design

- Start with overview, drill down to details
- Use consistent color schemes
- Add threshold lines on graphs
- Include rate() for counters
- Use templating for dynamic dashboards
- Set appropriate time ranges and refresh intervals

### 5. Performance Optimization

- Use recording rules for expensive queries
- Set appropriate scrape intervals (15s default)
- Limit retention period (30 days default)
- Use remote write for long-term storage
- Monitor Prometheus itself

### 6. Security

- Use strong passwords for Grafana
- Enable HTTPS for public access
- Restrict network access to monitoring ports
- Use read-only credentials for exporters
- Rotate API keys regularly

### 7. Maintenance

- Regularly review and update alert thresholds
- Archive old dashboards
- Clean up unused metrics
- Document custom metrics and alerts
- Test disaster recovery procedures

### 8. Monitoring the Monitors

Monitor the monitoring stack itself:
- Prometheus scrape duration
- AlertManager notification success rate
- Grafana response time
- Exporter uptime
- Disk space usage

## Resources

### Documentation
- [Prometheus Docs](https://prometheus.io/docs/)
- [Grafana Docs](https://grafana.com/docs/)
- [AlertManager Docs](https://prometheus.io/docs/alerting/latest/alertmanager/)
- [PostgreSQL Exporter](https://github.com/prometheus-community/postgres_exporter)
- [Redis Exporter](https://github.com/oliver006/redis_exporter)

### Dashboards
- [Grafana Dashboard Library](https://grafana.com/grafana/dashboards/)
- [PostgreSQL Dashboard](https://grafana.com/grafana/dashboards/9628)
- [Redis Dashboard](https://grafana.com/grafana/dashboards/11835)
- [Node Exporter Dashboard](https://grafana.com/grafana/dashboards/1860)

### Community
- [Prometheus Community](https://prometheus.io/community/)
- [Grafana Community](https://community.grafana.com/)
- [Stack Overflow](https://stackoverflow.com/questions/tagged/prometheus)

## Support

For issues or questions:
1. Check logs: `docker logs <container-name>`
2. Review documentation
3. Search existing issues
4. Contact: devops@dpg-cluster.local
