# Patroni Monitoring Setup Guide

## Table of Contents

1. [Overview](#overview)
2. [Prometheus Metrics](#prometheus-metrics)
3. [Key Metrics to Watch](#key-metrics-to-watch)
4. [Grafana Dashboard Setup](#grafana-dashboard-setup)
5. [Alert Rules](#alert-rules)
6. [Integration with Health Check System](#integration-with-health-check-system)
7. [Troubleshooting](#troubleshooting)

---

## Overview

### Monitoring Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   Monitoring Stack                           │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐   │
│  │ Coordinator  │   │ Coordinator  │   │ Coordinator  │   │
│  │      1       │   │      2       │   │      3       │   │
│  ├──────────────┤   ├──────────────┤   ├──────────────┤   │
│  │ Patroni REST │   │ Patroni REST │   │ Patroni REST │   │
│  │ API :8008    │   │ API :8008    │   │ API :8008    │   │
│  ├──────────────┤   ├──────────────┤   ├──────────────┤   │
│  │pg_exporter   │   │pg_exporter   │   │pg_exporter   │   │
│  │    :9187     │   │    :9187     │   │    :9187     │   │
│  └──────┬───────┘   └──────┬───────┘   └──────┬───────┘   │
│         │                  │                  │            │
│         └──────────────────┼──────────────────┘            │
│                            │                               │
│                    ┌───────▼────────┐                      │
│                    │   Prometheus   │                      │
│                    │   Scrapes every│                      │
│                    │   15 seconds   │                      │
│                    └───────┬────────┘                      │
│                            │                               │
│                    ┌───────▼────────┐                      │
│                    │    Grafana     │                      │
│                    │   Dashboards   │                      │
│                    │   Alertmanager │                      │
│                    └────────────────┘                      │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Components

| Component | Port | Purpose |
|-----------|------|---------|
| **Patroni REST API** | 8008 | Cluster topology, health checks |
| **postgres_exporter** | 9187 | PostgreSQL metrics (queries, connections) |
| **node_exporter** | 9100 | System metrics (CPU, memory, disk) |
| **Prometheus** | 9090 | Metric storage and querying |
| **Grafana** | 3000 | Visualization dashboards |
| **Alertmanager** | 9093 | Alert routing and notifications |

---

## Prometheus Metrics

### Patroni Metrics (REST API)

Patroni exposes metrics via REST API on port 8008:

```bash
# Health check endpoint
curl http://coordinator-1:8008/health

# Cluster status
curl http://coordinator-1:8008/cluster | jq .

# Leader status
curl http://coordinator-1:8008/leader

# Replica status
curl http://coordinator-1:8008/replica

# Patroni metrics endpoint (if patroni_exporter installed)
curl http://coordinator-1:8009/metrics
```

### PostgreSQL Exporter Setup

```bash
# Install postgres_exporter on each PostgreSQL node
docker run -d \
  --name postgres_exporter \
  --network postgres-net \
  -p 9187:9187 \
  -e DATA_SOURCE_NAME="postgresql://monitor:monitor_password@localhost:5432/postgres?sslmode=disable" \
  prometheuscommunity/postgres-exporter:latest
```

**Create monitoring user**:
```sql
-- Run on each PostgreSQL node
CREATE USER monitor WITH PASSWORD 'monitor_password';
GRANT pg_monitor TO monitor;

-- Grant specific permissions
GRANT CONNECT ON DATABASE postgres TO monitor;
GRANT CONNECT ON DATABASE distributed_postgres_cluster TO monitor;
GRANT pg_read_all_stats TO monitor;
```

### Prometheus Configuration

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: 'distributed-postgres'
    environment: 'production'

# Alertmanager configuration
alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - 'alertmanager:9093'

# Load alert rules
rule_files:
  - '/etc/prometheus/alerts/*.yml'

# Scrape configurations
scrape_configs:
  # PostgreSQL metrics
  - job_name: 'postgresql'
    static_configs:
      - targets:
          - 'coordinator-1:9187'
          - 'coordinator-2:9187'
          - 'coordinator-3:9187'
          - 'worker-1-1:9187'
          - 'worker-1-2:9187'
          - 'worker-2-1:9187'
          - 'worker-2-2:9187'
          - 'worker-3-1:9187'
          - 'worker-3-2:9187'
        labels:
          cluster: 'postgres-cluster'

  # Patroni health checks
  - job_name: 'patroni'
    metrics_path: '/metrics'
    static_configs:
      - targets:
          - 'coordinator-1:8008'
          - 'coordinator-2:8008'
          - 'coordinator-3:8008'
        labels:
          cluster: 'postgres-cluster-coordinators'
          role: 'coordinator'
      - targets:
          - 'worker-1-1:8008'
          - 'worker-1-2:8008'
        labels:
          cluster: 'postgres-cluster-shard-1'
          role: 'worker'

  # Node metrics (system resources)
  - job_name: 'node'
    static_configs:
      - targets:
          - 'coordinator-1:9100'
          - 'coordinator-2:9100'
          - 'coordinator-3:9100'
          - 'worker-1-1:9100'
          - 'worker-1-2:9100'

  # etcd metrics
  - job_name: 'etcd'
    static_configs:
      - targets:
          - 'etcd-1:2379'
          - 'etcd-2:2379'
          - 'etcd-3:2379'
    metrics_path: '/metrics'

  # HAProxy metrics
  - job_name: 'haproxy'
    static_configs:
      - targets:
          - 'haproxy:8404'
    metrics_path: '/metrics'

# Service discovery (optional, for dynamic environments)
  - job_name: 'postgresql-discovery'
    dns_sd_configs:
      - names:
          - 'tasks.postgres-coordinator'
        type: 'A'
        port: 9187
```

### Deploy Prometheus

```bash
# Docker Compose deployment
docker run -d \
  --name prometheus \
  --network postgres-net \
  -p 9090:9090 \
  -v $(pwd)/config/monitoring/prometheus.yml:/etc/prometheus/prometheus.yml \
  -v $(pwd)/config/monitoring/alerts:/etc/prometheus/alerts \
  -v prometheus-data:/prometheus \
  prom/prometheus:latest \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.retention.time=30d
```

---

## Key Metrics to Watch

### Cluster Health Metrics

#### 1. **Patroni Cluster State**

```promql
# Number of healthy cluster members
count(up{job="patroni"} == 1) by (cluster)

# Alert if less than 3 coordinators healthy
count(up{job="patroni",cluster="postgres-cluster-coordinators"} == 1) < 3
```

#### 2. **Leader Availability**

```promql
# Leader availability (should always be 1)
patroni_postgres_running{role="master"} == 1

# Time since last leader election
time() - patroni_postgres_timeline_change_timestamp_seconds
```

#### 3. **Replication Lag**

**Most Critical Metric**:
```promql
# Replication lag in bytes
pg_stat_replication_replay_lag_bytes

# Replication lag in seconds
pg_stat_replication_replay_lag_seconds

# Maximum lag across all replicas
max(pg_stat_replication_replay_lag_bytes) by (instance)

# Alert if lag > 100MB or 60 seconds
pg_stat_replication_replay_lag_bytes > 104857600
OR
pg_stat_replication_replay_lag_seconds > 60
```

### PostgreSQL Performance Metrics

#### 1. **Connection Pool Utilization**

```promql
# Current connections
pg_stat_database_numbackends

# Connection usage percentage
(sum(pg_stat_database_numbackends) / pg_settings_max_connections) * 100

# Active vs idle connections
pg_stat_activity_count{state="active"}
pg_stat_activity_count{state="idle"}
```

#### 2. **Query Performance**

```promql
# Queries per second
rate(pg_stat_database_xact_commit[1m]) + rate(pg_stat_database_xact_rollback[1m])

# Average query duration
rate(pg_stat_statements_total_time_seconds[5m]) / rate(pg_stat_statements_calls[5m])

# Long-running queries (> 5 minutes)
pg_stat_activity_max_tx_duration{state="active"} > 300
```

#### 3. **Cache Hit Ratio**

```promql
# Buffer cache hit ratio (should be > 95%)
(
  sum(pg_stat_database_blks_hit) /
  (sum(pg_stat_database_blks_hit) + sum(pg_stat_database_blks_read))
) * 100

# Alert if cache hit ratio < 90%
(
  sum(pg_stat_database_blks_hit) /
  (sum(pg_stat_database_blks_hit) + sum(pg_stat_database_blks_read))
) * 100 < 90
```

#### 4. **Lock Monitoring**

```promql
# Number of blocked queries
pg_stat_activity_count{wait_event_type="Lock"}

# Deadlocks
rate(pg_stat_database_deadlocks[5m])
```

#### 5. **Checkpoint Frequency**

```promql
# Checkpoints per minute
rate(pg_stat_bgwriter_checkpoints_timed[1m]) + rate(pg_stat_bgwriter_checkpoints_req[1m])

# Checkpoint write time
rate(pg_stat_bgwriter_checkpoint_write_time[5m])

# Alert if > 1 checkpoint per minute (too frequent)
rate(pg_stat_bgwriter_checkpoints_req[1m]) > 1
```

### System Resource Metrics

#### 1. **CPU Usage**

```promql
# CPU usage percentage
100 - (avg(irate(node_cpu_seconds_total{mode="idle"}[5m])) by (instance) * 100)

# Alert if CPU > 80%
100 - (avg(irate(node_cpu_seconds_total{mode="idle"}[5m])) by (instance) * 100) > 80
```

#### 2. **Memory Usage**

```promql
# Memory usage percentage
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100

# PostgreSQL shared buffers usage
pg_settings_shared_buffers_bytes
```

#### 3. **Disk Space**

```promql
# Disk usage percentage
(1 - (node_filesystem_avail_bytes{mountpoint="/var/lib/postgresql/data"} / node_filesystem_size_bytes)) * 100

# Alert if disk space < 10%
(node_filesystem_avail_bytes{mountpoint="/var/lib/postgresql/data"} / node_filesystem_size_bytes) * 100 < 10
```

#### 4. **Disk I/O**

```promql
# Read/write throughput
rate(node_disk_read_bytes_total[5m])
rate(node_disk_written_bytes_total[5m])

# I/O wait time
rate(node_cpu_seconds_total{mode="iowait"}[5m])
```

### Citus-Specific Metrics

```promql
# Distributed query count
citus_dist_stat_activity_total{query_type="distributed"}

# Shard count per worker
citus_shard_placement_count

# Cross-shard queries
citus_stat_statements_executor_type{executor="real-time"}
```

---

## Grafana Dashboard Setup

### Dashboard Installation

```bash
# Install Grafana
docker run -d \
  --name grafana \
  --network postgres-net \
  -p 3000:3000 \
  -v grafana-data:/var/lib/grafana \
  -e GF_SECURITY_ADMIN_PASSWORD=admin \
  grafana/grafana:latest

# Access Grafana
# http://localhost:3000
# Username: admin
# Password: admin (change on first login)
```

### Add Prometheus Data Source

1. Navigate to **Configuration > Data Sources**
2. Click **Add data source**
3. Select **Prometheus**
4. Configure:
   - **URL**: `http://prometheus:9090`
   - **Access**: Server (default)
   - **Scrape interval**: 15s
5. Click **Save & Test**

### Dashboard Panels

#### Panel 1: Cluster Overview

```json
{
  "title": "Patroni Cluster Status",
  "targets": [
    {
      "expr": "patroni_postgres_running",
      "legendFormat": "{{instance}} - {{role}}"
    }
  ],
  "type": "stat",
  "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0}
}
```

#### Panel 2: Replication Lag

```json
{
  "title": "Replication Lag (MB)",
  "targets": [
    {
      "expr": "pg_stat_replication_replay_lag_bytes / 1024 / 1024",
      "legendFormat": "{{application_name}} -> {{client_addr}}"
    }
  ],
  "type": "graph",
  "yaxes": [{"format": "decbytes"}],
  "gridPos": {"h": 8, "w": 12, "x": 0, "y": 4}
}
```

#### Panel 3: Connection Count

```json
{
  "title": "Active Connections",
  "targets": [
    {
      "expr": "pg_stat_database_numbackends",
      "legendFormat": "{{datname}}"
    },
    {
      "expr": "pg_settings_max_connections",
      "legendFormat": "Max Connections"
    }
  ],
  "type": "graph",
  "gridPos": {"h": 8, "w": 12, "x": 12, "y": 4}
}
```

#### Panel 4: Query Performance

```json
{
  "title": "Queries per Second",
  "targets": [
    {
      "expr": "rate(pg_stat_database_xact_commit[1m]) + rate(pg_stat_database_xact_rollback[1m])",
      "legendFormat": "{{datname}}"
    }
  ],
  "type": "graph",
  "gridPos": {"h": 8, "w": 12, "x": 0, "y": 12}
}
```

#### Panel 5: Cache Hit Ratio

```json
{
  "title": "Cache Hit Ratio (%)",
  "targets": [
    {
      "expr": "(sum(pg_stat_database_blks_hit) / (sum(pg_stat_database_blks_hit) + sum(pg_stat_database_blks_read))) * 100",
      "legendFormat": "Cache Hit Ratio"
    }
  ],
  "type": "gauge",
  "thresholds": [
    {"value": 0, "color": "red"},
    {"value": 90, "color": "yellow"},
    {"value": 95, "color": "green"}
  ],
  "gridPos": {"h": 6, "w": 6, "x": 12, "y": 12}
}
```

### Full Dashboard JSON

Save as `/config/monitoring/grafana/dashboards/patroni-cluster.json`:

```json
{
  "dashboard": {
    "title": "Patroni PostgreSQL Cluster",
    "panels": [
      // Include all panels above
    ],
    "refresh": "10s",
    "time": {"from": "now-1h", "to": "now"},
    "timezone": "browser"
  }
}
```

Import dashboard:
1. Navigate to **Dashboards > Import**
2. Upload `patroni-cluster.json`
3. Select Prometheus data source
4. Click **Import**

---

## Alert Rules

### Prometheus Alert Rules

Save as `/config/monitoring/alerts/patroni-alerts.yml`:

```yaml
groups:
  - name: patroni_cluster
    interval: 15s
    rules:
      # Critical: No leader for 30 seconds
      - alert: PatroniNoLeader
        expr: count(patroni_postgres_running{role="master"} == 1) == 0
        for: 30s
        labels:
          severity: critical
        annotations:
          summary: "Patroni cluster has no leader"
          description: "Cluster {{ $labels.cluster }} has no leader for more than 30 seconds. Immediate action required."

      # Critical: High replication lag
      - alert: PatroniReplicationLagHigh
        expr: pg_stat_replication_replay_lag_bytes > 104857600  # 100MB
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "High replication lag detected"
          description: "Replica {{ $labels.application_name }} has {{ $value | humanize1024 }}B lag from leader."

      # Critical: Cluster member down
      - alert: PatroniMemberDown
        expr: up{job="patroni"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Patroni member is down"
          description: "Patroni member {{ $labels.instance }} is unreachable for more than 1 minute."

      # Critical: etcd quorum lost
      - alert: EtcdQuorumLost
        expr: count(up{job="etcd"} == 1) < 2
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "etcd quorum lost"
          description: "etcd cluster has fewer than 2 healthy members. Leader election impossible."

      # Critical: Connection pool saturation
      - alert: PostgreSQLConnectionPoolFull
        expr: (sum(pg_stat_database_numbackends) / pg_settings_max_connections) * 100 > 90
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "PostgreSQL connection pool near capacity"
          description: "{{ $labels.instance }} is using {{ $value | humanize }}% of max_connections."

      # Warning: Moderate replication lag
      - alert: PatroniReplicationLagWarning
        expr: pg_stat_replication_replay_lag_bytes > 10485760  # 10MB
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Moderate replication lag detected"
          description: "Replica {{ $labels.application_name }} has {{ $value | humanize1024 }}B lag."

      # Warning: Low cache hit ratio
      - alert: PostgreSQLLowCacheHitRatio
        expr: |
          (
            sum(pg_stat_database_blks_hit) /
            (sum(pg_stat_database_blks_hit) + sum(pg_stat_database_blks_read))
          ) * 100 < 90
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Low PostgreSQL cache hit ratio"
          description: "Cache hit ratio is {{ $value | humanize }}% (should be > 95%)."

      # Warning: Long-running queries
      - alert: PostgreSQLLongRunningQuery
        expr: pg_stat_activity_max_tx_duration{state="active"} > 600  # 10 minutes
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Long-running query detected"
          description: "Query on {{ $labels.instance }} has been running for {{ $value | humanizeDuration }}."

      # Warning: High checkpoint frequency
      - alert: PostgreSQLFrequentCheckpoints
        expr: rate(pg_stat_bgwriter_checkpoints_req[1m]) > 1
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Frequent PostgreSQL checkpoints"
          description: "{{ $labels.instance }} is checkpointing more than once per minute. Consider tuning max_wal_size."

      # Warning: Disk space low
      - alert: DiskSpaceLow
        expr: |
          (node_filesystem_avail_bytes{mountpoint="/var/lib/postgresql/data"} /
           node_filesystem_size_bytes) * 100 < 20
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Low disk space on PostgreSQL data directory"
          description: "{{ $labels.instance }} has {{ $value | humanize }}% disk space remaining."

      # Critical: Disk space critical
      - alert: DiskSpaceCritical
        expr: |
          (node_filesystem_avail_bytes{mountpoint="/var/lib/postgresql/data"} /
           node_filesystem_size_bytes) * 100 < 10
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Critical disk space on PostgreSQL data directory"
          description: "{{ $labels.instance }} has only {{ $value | humanize }}% disk space remaining."

      # Warning: Blocking queries
      - alert: PostgreSQLBlockingQueries
        expr: pg_stat_activity_count{wait_event_type="Lock"} > 5
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Multiple queries blocked by locks"
          description: "{{ $labels.instance }} has {{ $value }} queries blocked by locks."
```

### Alertmanager Configuration

Save as `/config/monitoring/alertmanager.yml`:

```yaml
global:
  resolve_timeout: 5m
  smtp_smarthost: 'smtp.example.com:587'
  smtp_from: 'alerts@example.com'
  smtp_auth_username: 'alerts@example.com'
  smtp_auth_password: 'password'

# Alert routing
route:
  group_by: ['alertname', 'cluster']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 12h
  receiver: 'default'
  routes:
    # Critical alerts to PagerDuty
    - match:
        severity: critical
      receiver: pagerduty
      continue: true
    # Warnings to Slack
    - match:
        severity: warning
      receiver: slack

# Alert receivers
receivers:
  - name: 'default'
    email_configs:
      - to: 'dba-team@example.com'
        headers:
          Subject: '[PostgreSQL Alert] {{ .GroupLabels.alertname }}'

  - name: 'pagerduty'
    pagerduty_configs:
      - service_key: 'YOUR_PAGERDUTY_KEY'
        description: '{{ .GroupLabels.alertname }}'

  - name: 'slack'
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK'
        channel: '#postgres-alerts'
        title: '{{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
```

---

## Integration with Health Check System

### Unified Monitoring Dashboard

Integrate Patroni monitoring with existing health check service:

```python
# /scripts/health_check_service.py (add Patroni checks)

import requests
import psycopg2

def check_patroni_cluster(patroni_endpoints):
    """Check Patroni cluster health"""
    results = []
    for endpoint in patroni_endpoints:
        try:
            # Check Patroni health
            response = requests.get(f"http://{endpoint}:8008/health", timeout=5)
            is_healthy = response.status_code == 200

            # Get cluster info
            cluster_info = requests.get(f"http://{endpoint}:8008/cluster", timeout=5).json()

            results.append({
                "endpoint": endpoint,
                "healthy": is_healthy,
                "role": cluster_info.get("role"),
                "state": cluster_info.get("state"),
                "timeline": cluster_info.get("timeline")
            })
        except Exception as e:
            results.append({
                "endpoint": endpoint,
                "healthy": False,
                "error": str(e)
            })

    return results

def check_replication_lag(db_config):
    """Check PostgreSQL replication lag"""
    try:
        conn = psycopg2.connect(**db_config)
        cursor = conn.cursor()
        cursor.execute("""
            SELECT
                application_name,
                pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes,
                EXTRACT(EPOCH FROM (now() - replay_timestamp))::int AS lag_seconds
            FROM pg_stat_replication
        """)
        results = cursor.fetchall()
        cursor.close()
        conn.close()

        return [
            {
                "replica": row[0],
                "lag_bytes": row[1],
                "lag_seconds": row[2]
            }
            for row in results
        ]
    except Exception as e:
        return {"error": str(e)}
```

### Health Check API Endpoints

```python
from flask import Flask, jsonify

app = Flask(__name__)

@app.route('/health/patroni')
def patroni_health():
    """Patroni cluster health endpoint"""
    endpoints = ["coordinator-1", "coordinator-2", "coordinator-3"]
    results = check_patroni_cluster(endpoints)

    all_healthy = all(r.get("healthy", False) for r in results)
    has_leader = any(r.get("role") == "master" for r in results)

    return jsonify({
        "status": "healthy" if (all_healthy and has_leader) else "unhealthy",
        "cluster": results,
        "leader": has_leader
    })

@app.route('/health/replication')
def replication_health():
    """Replication lag health endpoint"""
    db_config = {
        "host": "pg-coordinator",
        "user": "monitor",
        "password": "monitor_password",
        "database": "postgres"
    }
    results = check_replication_lag(db_config)

    max_lag_bytes = max((r.get("lag_bytes", 0) for r in results), default=0)
    max_lag_seconds = max((r.get("lag_seconds", 0) for r in results), default=0)

    status = "healthy"
    if max_lag_bytes > 104857600:  # 100MB
        status = "critical"
    elif max_lag_bytes > 10485760:  # 10MB
        status = "warning"

    return jsonify({
        "status": status,
        "max_lag_mb": max_lag_bytes / 1024 / 1024,
        "max_lag_seconds": max_lag_seconds,
        "replicas": results
    })
```

---

## Troubleshooting

### Prometheus Not Scraping Metrics

**Symptoms**:
- Targets show "DOWN" in Prometheus UI
- No metrics available in Grafana

**Diagnosis**:
```bash
# Check Prometheus targets
curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.health != "up")'

# Test metric endpoint directly
curl http://coordinator-1:9187/metrics

# Check Prometheus logs
docker logs prometheus
```

**Resolution**:
```bash
# Verify network connectivity
ping coordinator-1

# Verify exporter is running
docker ps | grep postgres_exporter

# Reload Prometheus config
curl -X POST http://localhost:9090/-/reload

# Restart Prometheus
docker restart prometheus
```

---

### Grafana Showing No Data

**Symptoms**:
- Dashboards display "No data" or "N/A"
- Queries return empty results

**Diagnosis**:
```bash
# Test Prometheus data source
curl http://localhost:9090/api/v1/query?query=up

# Check Grafana logs
docker logs grafana

# Verify time range in dashboard
# Ensure it's set to "Last 1 hour" or appropriate range
```

**Resolution**:
1. Verify Prometheus data source URL in Grafana settings
2. Check that Prometheus is scraping metrics successfully
3. Adjust time range in dashboard
4. Verify metric names match dashboard queries

---

## Additional Resources

- [Patroni Operations Guide](PATRONI_OPERATIONS.md)
- [Failover Runbook](FAILOVER_RUNBOOK.md)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Dashboards](https://grafana.com/grafana/dashboards/)

---

**Document Version**: 1.0
**Last Updated**: 2026-02-12
**Maintained By**: Database Operations Team
**Review Schedule**: Quarterly
