# Performance Testing Guide

**Quick Reference for Running Performance Tests**

---

## 🚀 Quick Start

### 1. One-Command Test Suite

```bash
# Quick smoke test (5 min)
./scripts/performance/run_all_tests.sh quick

# Full benchmark suite (30 min)
./scripts/performance/run_all_tests.sh full

# Stress test (60 min)
./scripts/performance/run_all_tests.sh stress
```

### 2. Individual Components

```bash
# Benchmarks only
python3 scripts/performance/benchmark_vector_search.py

# Load test only
locust -f scripts/performance/load_test_locust.py \
    --host http://localhost:5432 \
    --users 100 --spawn-rate 10 --run-time 5m --headless

# Metrics collector (background)
python3 scripts/performance/metrics_collector.py &
```

---

## 📊 Performance Targets

### Vector Search Performance

| Operation | p50 | p95 | p99 | Target QPS |
|-----------|-----|-----|-----|-----------|
| Single-shard search | <5ms | <10ms | <25ms | 1000+ |
| Cross-shard search | <15ms | <25ms | <50ms | 500+ |
| Concurrent (100 clients) | <10ms | <30ms | <60ms | 5000+ |

### Write Performance

| Operation | p50 | p95 | p99 | Target TPS |
|-----------|-----|-----|-----|-----------|
| Single insert | <3ms | <8ms | <15ms | 500+ |
| Bulk insert (100 rows) | <50ms | <100ms | <200ms | 1000+ |

### System Health

| Metric | Target | Critical |
|--------|--------|----------|
| Cache hit ratio | >90% | >75% |
| Replication lag | <5s | <10s |
| Connection pool usage | <80% | <95% |
| Success rate | >99% | >95% |

---

## 🎯 Test Scenarios

### 1. Baseline Performance
**Purpose**: Establish baseline metrics

```bash
# Run benchmark suite
python3 scripts/performance/benchmark_vector_search.py

# Expected results:
# - Single-shard p95: <10ms
# - Cross-shard p95: <25ms
# - Bulk insert: >1000 TPS
```

### 2. Normal Load (100 users)
**Purpose**: Simulate typical production load

```bash
locust -f scripts/performance/load_test_locust.py \
    --host http://localhost:5432 \
    --users 100 --spawn-rate 10 --run-time 10m \
    --headless --html reports/normal_load.html

# Expected results:
# - p95 latency: <15ms
# - Success rate: >99%
# - QPS: 1000-2000
```

### 3. Peak Load (300 users)
**Purpose**: Simulate peak traffic hours

```bash
locust -f scripts/performance/load_test_locust.py \
    --host http://localhost:5432 \
    --users 300 --spawn-rate 30 --run-time 10m \
    --headless --html reports/peak_load.html

# Expected results:
# - p95 latency: <25ms
# - Success rate: >95%
# - QPS: 3000-5000
```

### 4. Stress Test (500+ users)
**Purpose**: Find system breaking point

```bash
locust -f scripts/performance/load_test_locust.py \
    --host http://localhost:5432 \
    --users 500 --spawn-rate 50 --run-time 15m \
    --headless --html reports/stress_test.html

# Watch for:
# - Latency degradation
# - Connection pool exhaustion
# - Error rate increase
# - Resource utilization (CPU, memory, disk I/O)
```

### 5. Soak Test (Long Duration)
**Purpose**: Test stability over extended period

```bash
locust -f scripts/performance/load_test_locust.py \
    --host http://localhost:5432 \
    --users 100 --spawn-rate 10 --run-time 60m \
    --headless --html reports/soak_test.html

# Watch for:
# - Memory leaks
# - Connection leaks
# - Performance degradation over time
# - Replication lag accumulation
```

---

## 📈 Monitoring Setup

### 1. Start Metrics Collector

```bash
# Start in background
nohup python3 scripts/performance/metrics_collector.py \
    > /var/log/metrics_collector.log 2>&1 &

# Verify metrics
curl http://localhost:9090/metrics | grep vector_search

# Expected output:
# vector_search_duration_seconds_bucket{...} ...
# vector_search_results_total{...} ...
```

### 2. Configure Prometheus

```yaml
# Add to /etc/prometheus/prometheus.yml
scrape_configs:
  - job_name: 'postgres_metrics'
    static_configs:
      - targets: ['localhost:9090']
    scrape_interval: 15s

  - job_name: 'postgres_exporter'
    static_configs:
      - targets: ['localhost:9187']
```

### 3. Import Grafana Dashboard

```bash
# Copy dashboard
cp scripts/performance/grafana_dashboard.json /tmp/

# Import via UI
1. Go to Grafana → Dashboards → Import
2. Upload: /tmp/grafana_dashboard.json
3. Select Prometheus datasource
4. Click Import

# Or via API
curl -X POST http://localhost:3000/api/dashboards/db \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d @scripts/performance/grafana_dashboard.json
```

### 4. Configure Alerts

```bash
# Copy alert rules
sudo cp scripts/performance/prometheus_alerts.yml \
    /etc/prometheus/rules/postgres_alerts.yml

# Update prometheus.yml
sudo tee -a /etc/prometheus/prometheus.yml <<EOF
rule_files:
  - "/etc/prometheus/rules/*.yml"
EOF

# Reload Prometheus
sudo systemctl reload prometheus

# Verify alerts
curl http://localhost:9090/api/v1/rules | jq '.data.groups[].rules[].name'
```

---

## 🔍 Analyzing Results

### 1. Benchmark Results

```bash
# View JSON results
cat reports/benchmark_results.json | jq '.results[]'

# Extract key metrics
cat reports/benchmark_results.json | jq '.results[] | {
  operation: .operation,
  p95_ms: .p95_ms,
  qps: .qps
}'
```

### 2. Load Test Results

```bash
# Open HTML report
open reports/load_test_results.html

# View CSV statistics
cat reports/load_test_stats.csv

# Analyze failures
cat reports/load_test_failures.csv
```

### 3. Performance Trends

```python
# scripts/performance/analyze_trends.py
import pandas as pd
import matplotlib.pyplot as plt

# Load multiple benchmark results
results = []
for file in ['benchmark_1.json', 'benchmark_2.json']:
    df = pd.read_json(file)
    results.append(df)

# Plot latency trend
plt.figure(figsize=(12, 6))
for i, df in enumerate(results):
    plt.plot(df['timestamp'], df['p95_ms'], label=f'Test {i+1}')

plt.xlabel('Time')
plt.ylabel('p95 Latency (ms)')
plt.title('Vector Search Latency Trend')
plt.legend()
plt.savefig('reports/latency_trend.png')
```

---

## 🐛 Troubleshooting

### High Latency

**Symptom**: p95 latency > 50ms

**Diagnosis**:
```sql
-- Check slow queries
SELECT pid, now() - query_start as duration, state, query
FROM pg_stat_activity
WHERE state = 'active'
  AND now() - query_start > interval '100 milliseconds'
ORDER BY duration DESC;

-- Check index usage
SELECT schemaname, tablename, indexname, idx_scan, idx_tup_read, idx_tup_fetch
FROM pg_stat_user_indexes
WHERE schemaname IN ('public', 'claude_flow')
ORDER BY idx_scan DESC;
```

**Solutions**:
1. Tune HNSW parameters: Reduce `ef_search` for speed
2. Increase cache size: `shared_buffers`, `effective_cache_size`
3. Vacuum analyze tables: `VACUUM ANALYZE memory_entries`
4. Add more indexes on frequently filtered columns

### Connection Pool Exhaustion

**Symptom**: "Too many connections" errors

**Diagnosis**:
```sql
-- Check active connections
SELECT state, count(*) FROM pg_stat_activity GROUP BY state;

-- Check long-running queries
SELECT pid, state, query_start, query
FROM pg_stat_activity
WHERE state != 'idle'
  AND now() - query_start > interval '30 seconds';
```

**Solutions**:
1. Increase pool size in `pool.py`
2. Kill stuck queries: `SELECT pg_terminate_backend(pid)`
3. Implement connection timeouts
4. Add connection pooler (PgBouncer)

### Replication Lag

**Symptom**: Replication lag > 10s

**Diagnosis**:
```sql
-- Check replication status
SELECT application_name, client_addr,
       write_lag, flush_lag, replay_lag, sync_state
FROM pg_stat_replication;

-- Check replication slots
SELECT slot_name, active, restart_lsn, confirmed_flush_lsn
FROM pg_replication_slots;
```

**Solutions**:
1. Reduce load on replica (add more replicas)
2. Increase `wal_sender_timeout`
3. Check network bandwidth
4. Ensure replica has sufficient resources (CPU, disk I/O)

---

## 📚 Additional Resources

- [Full Performance Optimization Guide](./distributed-optimization.md)
- [Database Health Check](../../scripts/db_health_check.py)
- [Error Handling Guide](../ERROR_HANDLING.md)
- [PostgreSQL Performance Wiki](https://wiki.postgresql.org/wiki/Performance_Optimization)

---

## 🤝 Best Practices

### Before Testing

1. **Baseline metrics**: Record current performance
2. **Environment**: Use production-like setup
3. **Data volume**: Test with realistic data size
4. **Monitoring**: Ensure metrics collector is running

### During Testing

1. **Progressive load**: Gradually increase users
2. **Monitor system**: Watch CPU, memory, disk I/O
3. **Watch alerts**: Check for triggered alerts
4. **Log errors**: Capture and analyze failures

### After Testing

1. **Compare results**: Against baseline and targets
2. **Identify bottlenecks**: Review slow queries, high latency
3. **Document findings**: Record issues and solutions
4. **Plan improvements**: Prioritize optimizations

---

## 📝 Test Checklist

- [ ] Database is running and healthy
- [ ] Test data loaded (sufficient volume)
- [ ] Metrics collector started
- [ ] Prometheus scraping metrics
- [ ] Grafana dashboard configured
- [ ] Alert rules loaded
- [ ] Baseline performance recorded
- [ ] Run benchmark suite
- [ ] Run load tests (normal, peak, stress)
- [ ] Analyze results
- [ ] Document findings
- [ ] Plan optimizations

---

**Last Updated**: 2026-02-10
