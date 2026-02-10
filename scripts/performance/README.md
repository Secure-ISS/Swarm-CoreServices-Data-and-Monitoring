# Performance Testing & Monitoring Scripts

Comprehensive suite for benchmarking, load testing, and monitoring the distributed PostgreSQL cluster.

---

## 📋 Contents

1. **Benchmarking**: `benchmark_vector_search.py`
2. **Load Testing**: `load_test_locust.py`
3. **Metrics Collection**: `metrics_collector.py`
4. **Monitoring Dashboards**: `grafana_dashboard.json`
5. **Alert Rules**: `prometheus_alerts.yml`

---

## 🚀 Quick Start

### 1. Install Dependencies

```bash
# Install Python dependencies
pip install -r requirements.txt

# Additional dependencies for load testing
pip install locust

# Prometheus client for metrics
pip install prometheus-client
```

### 2. Run Benchmarks

```bash
# Run full benchmark suite
python scripts/performance/benchmark_vector_search.py

# Results saved to: reports/benchmark_results.json
```

**Expected Output**:
```
🚀 Vector Search Benchmark Suite
============================================================

🔍 Single-Shard Vector Search
   Progress: 1000/1000 (100.0%)

   📊 Results:
   ────────────────────────────────────────────────────────
   Latency (ms)                         Value
   ────────────────────────────────────────────────────────
     Min                                   2.34
     Max                                  45.67
     Mean                                  8.12
     p95                                  15.23
     p99                                  23.45
   ────────────────────────────────────────────────────────
   Throughput (QPS)                     2500
```

### 3. Start Metrics Collector

```bash
# Start Prometheus metrics exporter on port 9090
python scripts/performance/metrics_collector.py

# Metrics available at: http://localhost:9090/metrics
```

### 4. Run Load Tests

```bash
# Interactive mode (web UI on port 8089)
locust -f scripts/performance/load_test_locust.py \
    --host http://localhost:5432

# Then open: http://localhost:8089

# Or run headless
locust -f scripts/performance/load_test_locust.py \
    --host http://localhost:5432 \
    --users 100 \
    --spawn-rate 10 \
    --run-time 5m \
    --headless \
    --html reports/load_test_results.html
```

---

## 📊 Benchmark Suite

### benchmark_vector_search.py

**Purpose**: Comprehensive benchmarking of vector search operations.

**Benchmarks**:
1. **Single-Shard Search** (1000 iterations)
   - Target: <10ms p95 latency
   - Simulates most common query pattern

2. **Cross-Shard Search** (500 iterations)
   - Target: <25ms p95 latency
   - Queries across 5 namespaces

3. **Concurrent Queries** (50 clients, 20 queries each)
   - Target: >100 concurrent connections
   - Tests connection pool performance

4. **Bulk Insert** (100 batches of 100 rows)
   - Target: >1000 TPS
   - Tests write throughput

**Usage**:
```bash
# Run with defaults
python scripts/performance/benchmark_vector_search.py

# Customize iterations (for quick tests)
# Edit the main() function parameters
```

**Output**:
- Console: Formatted results table
- File: `reports/benchmark_results.json`

**Sample Results**:
```json
{
  "timestamp": "2026-02-10T12:34:56",
  "results": [
    {
      "operation": "single_shard_search",
      "iterations": 1000,
      "p50_ms": 7.23,
      "p95_ms": 12.45,
      "p99_ms": 18.67,
      "qps": 2500
    }
  ]
}
```

---

## 🔥 Load Testing

### load_test_locust.py

**Purpose**: Realistic load testing with concurrent users.

**User Types**:
1. **VectorSearchUser** (primary workload)
   - Task weights:
     - `vector_search_single_shard`: 10x (most common)
     - `vector_search_cross_shard`: 3x
     - `retrieve_memory`: 2x
     - `insert_memory`: 1x (least common)

2. **BulkInsertUser** (background workload)
   - Simulates periodic batch operations

**Usage**:

```bash
# Interactive mode
locust -f scripts/performance/load_test_locust.py \
    --host http://localhost:5432

# Headless mode (automated)
locust -f scripts/performance/load_test_locust.py \
    --host http://localhost:5432 \
    --users 100 \              # 100 concurrent users
    --spawn-rate 10 \          # Add 10 users/sec
    --run-time 5m \            # Run for 5 minutes
    --headless \               # No web UI
    --html reports/load_test.html \  # Generate report
    --csv reports/load_test          # CSV data

# Stress test (high load)
locust -f scripts/performance/load_test_locust.py \
    --host http://localhost:5432 \
    --users 500 \
    --spawn-rate 50 \
    --run-time 10m \
    --headless
```

**Load Test Scenarios**:

| Scenario | Users | Spawn Rate | Duration | Purpose |
|----------|-------|------------|----------|---------|
| Baseline | 50 | 5 | 5m | Establish baseline performance |
| Normal Load | 100 | 10 | 10m | Simulate normal traffic |
| Peak Load | 300 | 30 | 10m | Simulate peak hours |
| Stress Test | 500 | 50 | 15m | Find breaking point |
| Soak Test | 100 | 10 | 60m | Test stability over time |

**Expected Results**:
- **Normal Load**: <10ms p95 latency, >95% success rate
- **Peak Load**: <25ms p95 latency, >90% success rate
- **Stress Test**: <50ms p95 latency, >85% success rate

---

## 📈 Metrics Collection

### metrics_collector.py

**Purpose**: Collect and export PostgreSQL metrics to Prometheus.

**Metrics Exported**:

| Metric | Type | Description |
|--------|------|-------------|
| `vector_search_duration_seconds` | Histogram | Vector search latency |
| `vector_search_results_total` | Counter | Total search results |
| `db_connections_active` | Gauge | Active connections |
| `db_connections_idle` | Gauge | Idle connections |
| `table_size_bytes` | Gauge | Table sizes |
| `table_row_count` | Gauge | Row counts per table |
| `index_size_bytes` | Gauge | Index sizes |
| `replication_lag_seconds` | Gauge | Replication lag |
| `cache_hit_ratio` | Gauge | Cache hit ratio |

**Usage**:
```bash
# Start metrics collector (default port 9090)
python scripts/performance/metrics_collector.py

# Custom port
METRICS_PORT=9091 python scripts/performance/metrics_collector.py

# Run in background
nohup python scripts/performance/metrics_collector.py > /var/log/metrics_collector.log 2>&1 &
```

**Prometheus Configuration**:
```yaml
# /etc/prometheus/prometheus.yml
scrape_configs:
  - job_name: 'postgres_metrics'
    static_configs:
      - targets: ['localhost:9090']
    scrape_interval: 15s
```

---

## 📊 Grafana Dashboards

### grafana_dashboard.json

**Purpose**: Pre-configured Grafana dashboard for distributed PostgreSQL.

**Panels**:
1. **Vector Search Latency** (p95, p99)
2. **Queries Per Second** (by namespace)
3. **Database Connections** (active, idle, total)
4. **Cache Hit Ratio** (with 90% threshold)
5. **Replication Lag** (per replica)
6. **Table Sizes** (bar gauge)
7. **Table Row Counts** (bar gauge)
8. **Error Rate** (by namespace and error type)
9. **Index Sizes** (HNSW indexes)

**Import to Grafana**:
```bash
# Via UI
1. Go to Dashboards > Import
2. Upload: scripts/performance/grafana_dashboard.json
3. Select Prometheus datasource

# Via API
curl -X POST http://localhost:3000/api/dashboards/db \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d @scripts/performance/grafana_dashboard.json
```

**Variables**:
- `$namespace`: Filter by namespace (multi-select)

---

## 🚨 Alert Rules

### prometheus_alerts.yml

**Purpose**: Comprehensive alerting for production monitoring.

**Alert Groups**:

#### 1. Latency Alerts
- **HighVectorSearchLatency**: p95 > 50ms for 5 minutes
- **CriticalVectorSearchLatency**: p95 > 100ms for 2 minutes

#### 2. Replication Alerts
- **HighReplicationLag**: Lag > 10s for 2 minutes
- **ReplicationLagIncreasing**: Lag growing >0.5s/min
- **ReplicationBroken**: Cannot connect to replica

#### 3. Connection Pool Alerts
- **ConnectionPoolExhaustion**: >450 active connections
- **ConnectionPoolCritical**: >480 active connections

#### 4. Cache Alerts
- **LowCacheHitRatio**: <90% for 10 minutes
- **CriticalCacheHitRatio**: <75% for 5 minutes

#### 5. Storage Alerts
- **TableSizeGrowing**: Growing >1GB/hour
- **IndexBloat**: Index size >2x table size

**Setup**:
```bash
# Copy to Prometheus rules directory
sudo cp scripts/performance/prometheus_alerts.yml \
    /etc/prometheus/rules/postgres_alerts.yml

# Update prometheus.yml
rule_files:
  - "/etc/prometheus/rules/*.yml"

# Reload Prometheus
sudo systemctl reload prometheus

# Or send SIGHUP
sudo kill -HUP $(pgrep prometheus)
```

**Alert Notification**:
```yaml
# /etc/alertmanager/alertmanager.yml
route:
  group_by: ['alertname', 'severity']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 12h
  receiver: 'postgres-alerts'

receivers:
  - name: 'postgres-alerts'
    slack_configs:
      - api_url: 'YOUR_SLACK_WEBHOOK'
        channel: '#postgres-alerts'
        title: '{{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
```

---

## 🎯 Performance Targets

| Metric | Target | Critical |
|--------|--------|----------|
| Vector Search (p95) | <10ms | <50ms |
| Vector Search (p99) | <25ms | <100ms |
| Cross-Shard Search (p95) | <25ms | <100ms |
| Insert Throughput | >1000 TPS | >500 TPS |
| Query Throughput | >1000 QPS | >100 QPS |
| Cache Hit Ratio | >90% | >75% |
| Replication Lag | <5s | <10s |
| Connection Pool Usage | <80% | <95% |
| Success Rate | >99% | >95% |

---

## 📁 File Structure

```
scripts/performance/
├── README.md                    # This file
├── benchmark_vector_search.py   # Benchmark suite
├── load_test_locust.py          # Locust load testing
├── metrics_collector.py         # Prometheus exporter
├── grafana_dashboard.json       # Grafana dashboard
├── prometheus_alerts.yml        # Alert rules
└── requirements.txt             # Python dependencies

reports/
├── benchmark_results.json       # Benchmark output
├── load_test.html               # Load test report
├── load_test_stats.csv          # Load test statistics
└── load_test_failures.csv       # Load test failures
```

---

## 🔍 Troubleshooting

### High Latency
1. Check HNSW index parameters (m, ef_construction)
2. Review query plans with EXPLAIN ANALYZE
3. Monitor cache hit ratio
4. Check for table bloat: `VACUUM ANALYZE memory_entries`

### Connection Pool Exhaustion
1. Review slow queries: `SELECT * FROM pg_stat_activity WHERE state = 'active' AND now() - query_start > interval '5 seconds'`
2. Increase pool size in `pool.py`
3. Optimize queries to reduce connection time

### Replication Lag
1. Check replica load: CPU, disk I/O
2. Review network bandwidth
3. Check for long-running transactions on primary
4. Consider increasing `max_wal_senders` and `wal_keep_size`

### Low Throughput
1. Increase connection pool size
2. Optimize HNSW parameters for speed (lower m, ef_search)
3. Add more replicas for read scaling
4. Consider query result caching (Redis)

---

## 📚 Additional Resources

- [Performance Optimization Guide](../../docs/performance/distributed-optimization.md)
- [PostgreSQL Performance Tuning](https://wiki.postgresql.org/wiki/Performance_Optimization)
- [HNSW Index Tuning](https://github.com/pgvector/pgvector#hnsw)
- [Locust Documentation](https://docs.locust.io/)
- [Prometheus Best Practices](https://prometheus.io/docs/practices/)

---

## 🤝 Contributing

To add new benchmarks or metrics:

1. Add benchmark function to `benchmark_vector_search.py`
2. Add corresponding metric to `metrics_collector.py`
3. Update Grafana dashboard with new panel
4. Add alert rule if critical metric
5. Document in this README

---

## 📝 License

MIT License - See project root LICENSE file.
