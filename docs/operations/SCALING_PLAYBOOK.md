# PostgreSQL Cluster Scaling Playbook

## Table of Contents
1. [Scaling Overview](#scaling-overview)
2. [Horizontal Scaling Procedures](#horizontal-scaling-procedures)
3. [Vertical Scaling Procedures](#vertical-scaling-procedures)
4. [Load Testing](#load-testing)
5. [Performance Tuning](#performance-tuning)
6. [Capacity Planning](#capacity-planning)
7. [Scaling Decision Matrix](#scaling-decision-matrix)

---

## Scaling Overview

### Scaling Principles
- **Scale horizontally first** (add read replicas, connection poolers)
- **Scale vertically when needed** (increase CPU/RAM/IOPS)
- **Monitor before and after** scaling operations
- **Test in staging** before production changes
- **Document all changes** and results

### Current Capacity

```
Production Cluster (baseline):
- 3 Patroni nodes: 8 vCPU, 32 GB RAM each
- 2 HAProxy nodes: 2 vCPU, 2 GB RAM each
- 2 PgBouncer nodes: 2 vCPU, 2 GB RAM each
- 1 Redis master: 2 vCPU, 6 GB RAM

Capacity:
- Theoretical TPS: ~15,000 (read-heavy workload)
- Max connections: 5,000 (via PgBouncer)
- Storage: 2 TB per node
- Replication lag: <100ms (synchronous)
```

---

## Horizontal Scaling Procedures

### 1. Adding Read Replicas

**When to add:**
- Read load > 80% of capacity
- Replication lag > 5 seconds
- Read query latency > 100ms (p95)
- Need for geographic distribution

**Procedure:**

```bash
# Step 1: Provision new node
# - Add new worker to Docker Swarm
docker swarm join-token worker
# On new node:
docker swarm join --token <token> manager-1:2377

# Step 2: Label new node
docker node update --label-add postgres.role=patroni node-8
docker node update --label-add postgres.patroni-id=4 node-8

# Step 3: Create storage directory on new node
ssh node-8
mkdir -p /mnt/postgres-cluster/patroni-4
chown -R 999:999 /mnt/postgres-cluster/patroni-4
chmod 700 /mnt/postgres-cluster/patroni-4

# Step 4: Update docker-compose.yml to add patroni-4 service
# Copy patroni-3 configuration and update:
#   - hostname: patroni-4
#   - PATRONI_NAME: patroni-4
#   - PATRONI_POSTGRESQL_CONNECT_ADDRESS: patroni-4:5432
#   - placement constraint: postgres.patroni-id == 4

# Step 5: Deploy updated stack
docker stack deploy -c docker-compose.yml postgres-prod

# Step 6: Wait for replica to sync
watch 'docker exec postgres-prod_patroni-4.1.$(docker ps -q -f name=patroni-4) \
  curl -s http://localhost:8008/patroni | jq ".replication_state"'

# Step 7: Verify replication
docker exec postgres-prod_patroni-1.1.$(docker ps -q -f name=patroni-1) \
  psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# Step 8: Update HAProxy to include new replica
# Edit config/haproxy/haproxy.cfg and add:
#   server patroni-4 patroni-4:5432 check inter 5000
docker config create haproxy_config_v2 config/haproxy/haproxy.cfg
docker service update --config-rm haproxy_config \
  --config-add source=haproxy_config_v2,target=/usr/local/etc/haproxy/haproxy.cfg \
  postgres-prod_haproxy

# Step 9: Monitor performance
# Check query distribution, replication lag, and system resources
```

**Validation:**
```bash
# Verify new replica is receiving queries
psql -h haproxy -U postgres -c "SELECT client_addr, state, query FROM pg_stat_activity WHERE backend_type = 'client backend';"

# Check replication lag
psql -h haproxy -U postgres -c "SELECT application_name, state, sent_lsn, replay_lsn, replay_lag FROM pg_stat_replication;"

# Monitor system resources
docker stats postgres-prod_patroni-4
```

**Rollback:**
```bash
# Remove from HAProxy
docker service update --config-rm haproxy_config_v2 \
  --config-add source=haproxy_config,target=/usr/local/etc/haproxy/haproxy.cfg \
  postgres-prod_haproxy

# Scale down service
docker service scale postgres-prod_patroni=3

# Remove node from swarm
docker node update --availability drain node-8
docker node rm node-8
```

### 2. Adding Connection Poolers (PgBouncer)

**When to add:**
- Connection saturation > 80%
- Client connection failures
- Need for connection multiplexing

**Procedure:**

```bash
# Scale PgBouncer service
docker service scale postgres-prod_pgbouncer=4

# Verify scaling
docker service ps postgres-prod_pgbouncer

# Update DNS or load balancer to include new instances
# For round-robin DNS:
for i in {1..4}; do
  IP=$(docker inspect -f '{{.NetworkSettings.Networks.postgres-prod_app-net.IPAddress}}' \
    postgres-prod_pgbouncer.$i.$(docker ps -q -f name=pgbouncer))
  echo "pgbouncer-$i.postgres-prod  A  $IP"
done

# Monitor connection distribution
for i in {1..4}; do
  docker exec postgres-prod_pgbouncer.$i.$(docker ps -q -f name=pgbouncer) \
    psql -U postgres -p 6432 -d pgbouncer -c "SHOW POOLS;"
done
```

**Validation:**
```bash
# Test connections
for i in {1..100}; do
  psql -h pgbouncer -p 6432 -U postgres -c "SELECT 1;" &
done
wait

# Check pool utilization
docker exec postgres-prod_pgbouncer.1.$(docker ps -q -f name=pgbouncer) \
  psql -U postgres -p 6432 -d pgbouncer -c "SHOW STATS;"
```

### 3. Adding Load Balancers (HAProxy)

**When to add:**
- HAProxy CPU > 70%
- Connection queuing detected
- Geographic distribution needed

**Procedure:**

```bash
# Scale HAProxy service
docker service scale postgres-prod_haproxy=3

# Update external load balancer to include new instances
# AWS NLB example:
aws elbv2 register-targets \
  --target-group-arn arn:aws:elasticloadbalancing:region:account:targetgroup/postgres-prod/xxx \
  --targets Id=i-newinstance

# Verify health checks
aws elbv2 describe-target-health \
  --target-group-arn arn:aws:elasticloadbalancing:region:account:targetgroup/postgres-prod/xxx
```

---

## Vertical Scaling Procedures

### 1. CPU Scaling

**When to scale:**
- CPU utilization > 70% sustained
- Query performance degradation
- Checkpoint spikes causing CPU saturation

**Procedure:**

```bash
# Step 1: Update service CPU limits
docker service update \
  --limit-cpu 16 \
  --reserve-cpu 8 \
  postgres-prod_patroni-1

# Step 2: Verify resource allocation
docker service inspect postgres-prod_patroni-1 \
  --format='{{.Spec.TaskTemplate.Resources}}'

# Step 3: Monitor performance improvement
docker stats postgres-prod_patroni-1

# Step 4: Update PostgreSQL parameters for increased CPU
docker exec postgres-prod_patroni-1.1.$(docker ps -q -f name=patroni-1) \
  patronictl edit-config postgres-cluster-main

# Update these parameters:
#   max_worker_processes: 16 (was 8)
#   max_parallel_workers: 16 (was 8)
#   max_parallel_workers_per_gather: 8 (was 4)

# Step 5: Reload configuration
docker exec postgres-prod_patroni-1.1.$(docker ps -q -f name=patroni-1) \
  patronictl reload postgres-cluster-main
```

**Cloud-specific CPU scaling:**

```bash
# AWS: Modify instance type
aws ec2 stop-instances --instance-ids i-xxx
aws ec2 modify-instance-attribute --instance-id i-xxx --instance-type r6i.4xlarge
aws ec2 start-instances --instance-ids i-xxx

# GCP: Change machine type
gcloud compute instances stop postgres-worker-1
gcloud compute instances set-machine-type postgres-worker-1 --machine-type n2-highmem-16
gcloud compute instances start postgres-worker-1

# Azure: Resize VM
az vm deallocate --resource-group rg-postgres --name postgres-worker-1
az vm resize --resource-group rg-postgres --name postgres-worker-1 --size Standard_E16s_v5
az vm start --resource-group rg-postgres --name postgres-worker-1
```

### 2. Memory Scaling

**When to scale:**
- Memory utilization > 85%
- OOM killer events
- High cache miss rate
- Excessive swapping

**Procedure:**

```bash
# Step 1: Update service memory limits
docker service update \
  --limit-memory 64G \
  --reserve-memory 32G \
  postgres-prod_patroni-1

# Step 2: Update PostgreSQL memory parameters
docker exec postgres-prod_patroni-1.1.$(docker ps -q -f name=patroni-1) \
  patronictl edit-config postgres-cluster-main

# Update these parameters:
#   shared_buffers: 16GB (was 8GB) - 25% of total RAM
#   effective_cache_size: 48GB (was 24GB) - 75% of total RAM
#   work_mem: 256MB (was 128MB)
#   maintenance_work_mem: 4GB (was 2GB)

# Step 3: Restart PostgreSQL to apply memory changes
docker exec postgres-prod_patroni-1.1.$(docker ps -q -f name=patroni-1) \
  patronictl restart postgres-cluster-main patroni-1 --force

# Step 4: Verify memory usage
docker exec postgres-prod_patroni-1.1.$(docker ps -q -f name=patroni-1) \
  psql -U postgres -c "SHOW shared_buffers; SHOW effective_cache_size;"
```

**Memory scaling formula:**
```
shared_buffers = total_ram * 0.25
effective_cache_size = total_ram * 0.75
work_mem = (total_ram - shared_buffers) / max_connections / 2
maintenance_work_mem = total_ram * 0.05 (max 8GB)
```

### 3. Storage Scaling

**When to scale:**
- Disk usage > 85%
- IOPS saturation > 80%
- Slow query performance due to I/O
- WAL write bottlenecks

**Procedure - Expand Volume:**

```bash
# AWS EBS Volume Expansion
# Step 1: Modify volume size
aws ec2 modify-volume --volume-id vol-xxx --size 4096

# Step 2: Wait for modification to complete
aws ec2 describe-volumes-modifications --volume-id vol-xxx

# Step 3: Expand filesystem (on the node)
sudo resize2fs /dev/sdf

# Step 4: Verify new size
df -h /mnt/postgres-cluster/patroni-1
```

**Procedure - Increase IOPS:**

```bash
# AWS EBS: Increase IOPS
aws ec2 modify-volume --volume-id vol-xxx --iops 32000 --throughput 1000

# GCP: Change disk type
gcloud compute disks update patroni-1-data --type=pd-ssd --size=4096

# Azure: Increase disk tier
az disk update --resource-group rg-postgres --name patroni-1-data --sku Premium_LRS
```

**Procedure - Add Tablespace:**

```bash
# Step 1: Create new volume and attach
mkdir -p /mnt/postgres-cluster/tablespace-fast
chown -R 999:999 /mnt/postgres-cluster/tablespace-fast

# Step 2: Create tablespace in PostgreSQL
psql -h haproxy -U postgres <<EOF
CREATE TABLESPACE fast_ssd LOCATION '/mnt/postgres-cluster/tablespace-fast';
EOF

# Step 3: Move hot tables to new tablespace
psql -h haproxy -U postgres <<EOF
ALTER TABLE hot_table SET TABLESPACE fast_ssd;
EOF
```

---

## Load Testing

### 1. Benchmarking Tools

#### pgbench (Built-in)

```bash
# Initialize test database
pgbench -h haproxy -U postgres -i -s 100 distributed_postgres_cluster

# Run TPS test (10 clients, 1000 transactions each)
pgbench -h haproxy -U postgres -c 10 -t 1000 distributed_postgres_cluster

# Run duration-based test (10 clients, 60 seconds)
pgbench -h haproxy -U postgres -c 10 -T 60 distributed_postgres_cluster

# Run with multiple connections (simulate production load)
pgbench -h haproxy -U postgres -c 100 -j 10 -T 300 distributed_postgres_cluster

# Custom query test
pgbench -h haproxy -U postgres -c 50 -T 60 -f custom-queries.sql distributed_postgres_cluster
```

**custom-queries.sql:**
```sql
-- Read-heavy workload
\set id random(1, 100000)
SELECT * FROM pgbench_accounts WHERE aid = :id;

-- Write-heavy workload
\set id random(1, 100000)
\set delta random(-5000, 5000)
BEGIN;
UPDATE pgbench_accounts SET abalance = abalance + :delta WHERE aid = :id;
INSERT INTO pgbench_history (aid, tid, bid, delta, mtime) VALUES (:id, 1, 1, :delta, CURRENT_TIMESTAMP);
END;
```

#### Apache JMeter

```xml
<!-- JMeter JDBC Test Plan -->
<jmeterTestPlan>
  <hashTree>
    <TestPlan guiclass="TestPlanGui" testclass="TestPlan" testname="PostgreSQL Load Test">
      <stringProp name="TestPlan.comments">Production load simulation</stringProp>
      <boolProp name="TestPlan.functional_mode">false</boolProp>
      <boolProp name="TestPlan.serialize_threadgroups">false</boolProp>
      <elementProp name="TestPlan.user_defined_variables" elementType="Arguments">
        <collectionProp name="Arguments.arguments"/>
      </elementProp>
      <stringProp name="TestPlan.user_define_classpath"></stringProp>
    </TestPlan>
    <hashTree>
      <ThreadGroup guiclass="ThreadGroupGui" testclass="ThreadGroup" testname="Database Users">
        <stringProp name="ThreadGroup.num_threads">100</stringProp>
        <stringProp name="ThreadGroup.ramp_time">60</stringProp>
        <longProp name="ThreadGroup.duration">600</longProp>
        <stringProp name="ThreadGroup.delay"></stringProp>
      </ThreadGroup>
      <hashTree>
        <JDBCSampler guiclass="TestBeanGUI" testclass="JDBCSampler" testname="Select Query">
          <stringProp name="dataSource">postgres</stringProp>
          <stringProp name="queryType">Select Statement</stringProp>
          <stringProp name="query">SELECT * FROM users WHERE id = ${__Random(1,100000)}</stringProp>
        </JDBCSampler>
      </hashTree>
    </hashTree>
  </hashTree>
</jmeterTestPlan>
```

### 2. Load Test Scenarios

#### Scenario 1: Normal Operation
```
Objective: Validate baseline performance
Duration: 30 minutes
Clients: 100
TPS Target: 5,000
Read/Write Ratio: 70/30

Expected Results:
- Average latency: <10ms (p50)
- p95 latency: <50ms
- p99 latency: <100ms
- CPU utilization: <50%
- Memory utilization: <60%
- Replication lag: <100ms
```

#### Scenario 2: Peak Load
```
Objective: Test maximum capacity
Duration: 15 minutes
Clients: 500
TPS Target: 15,000
Read/Write Ratio: 80/20

Expected Results:
- Average latency: <20ms (p50)
- p95 latency: <100ms
- p99 latency: <200ms
- CPU utilization: <80%
- Memory utilization: <80%
- Replication lag: <500ms
```

#### Scenario 3: Sustained High Load
```
Objective: Endurance testing
Duration: 4 hours
Clients: 300
TPS Target: 10,000
Read/Write Ratio: 75/25

Expected Results:
- No memory leaks
- No connection pool exhaustion
- No replication drift
- Stable query performance
```

#### Scenario 4: Failover Testing
```
Objective: Test HA failover under load
Duration: 30 minutes with failover at 15min mark
Clients: 200
TPS Target: 8,000
Read/Write Ratio: 70/30

Expected Results:
- Failover time: <30 seconds
- Zero data loss
- Auto-recovery of failed node
- Client reconnection successful
```

### 3. Load Test Execution

```bash
#!/bin/bash
# run-load-test.sh

# Configuration
TEST_DURATION=600
NUM_CLIENTS=100
SCALE_FACTOR=100

# Initialize test database
echo "Initializing test database..."
pgbench -h haproxy -U postgres -i -s $SCALE_FACTOR distributed_postgres_cluster

# Start monitoring
echo "Starting metrics collection..."
docker service logs -f postgres-prod_prometheus > prometheus.log 2>&1 &
PROMETHEUS_PID=$!

# Run load test
echo "Starting load test..."
pgbench -h haproxy -U postgres \
  -c $NUM_CLIENTS \
  -j $(nproc) \
  -T $TEST_DURATION \
  -P 10 \
  --log \
  --log-prefix=loadtest \
  distributed_postgres_cluster

# Generate report
echo "Generating report..."
python3 <<EOF
import json
import statistics

# Parse pgbench log
latencies = []
with open('loadtest.log', 'r') as f:
    for line in f:
        parts = line.split()
        if len(parts) >= 3:
            latencies.append(float(parts[2]))

# Calculate statistics
print(f"Total transactions: {len(latencies)}")
print(f"Average latency: {statistics.mean(latencies):.2f}ms")
print(f"Median latency (p50): {statistics.median(latencies):.2f}ms")
print(f"p95 latency: {statistics.quantiles(latencies, n=20)[18]:.2f}ms")
print(f"p99 latency: {statistics.quantiles(latencies, n=100)[98]:.2f}ms")
print(f"Max latency: {max(latencies):.2f}ms")
EOF

# Stop monitoring
kill $PROMETHEUS_PID

echo "Load test complete. Results saved to loadtest.log"
```

---

## Performance Tuning

### 1. PostgreSQL Configuration Optimization

```sql
-- Analyze query performance
SELECT query, calls, total_time, mean_time, max_time
FROM pg_stat_statements
ORDER BY total_time DESC
LIMIT 20;

-- Find missing indexes
SELECT schemaname, tablename, attname, n_distinct, correlation
FROM pg_stats
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
  AND n_distinct > 100
  AND correlation < 0.5
ORDER BY n_distinct DESC;

-- Identify bloated tables
SELECT
  schemaname,
  tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - pg_relation_size(schemaname||'.'||tablename)) AS external_size
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 20;
```

### 2. Index Optimization

```sql
-- Find unused indexes
SELECT
  schemaname,
  tablename,
  indexname,
  idx_scan,
  pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_relation_size(indexrelid) DESC;

-- Create missing indexes
CREATE INDEX CONCURRENTLY idx_users_email ON users(email);
CREATE INDEX CONCURRENTLY idx_orders_created_at ON orders(created_at);

-- Rebuild bloated indexes
REINDEX INDEX CONCURRENTLY idx_users_email;
```

### 3. Vacuum and Analyze

```sql
-- Manual vacuum
VACUUM ANALYZE users;

-- Configure autovacuum
ALTER TABLE users SET (
  autovacuum_vacuum_threshold = 50,
  autovacuum_analyze_threshold = 50,
  autovacuum_vacuum_scale_factor = 0.1,
  autovacuum_analyze_scale_factor = 0.05
);
```

### 4. Connection Pooling Optimization

```ini
# pgbouncer.ini tuning

[databases]
distributed_postgres_cluster = host=haproxy port=5432 pool_size=50

[pgbouncer]
pool_mode = transaction
max_client_conn = 5000
default_pool_size = 50
min_pool_size = 20
reserve_pool_size = 10
max_db_connections = 100
max_user_connections = 100
server_idle_timeout = 600
server_lifetime = 3600
```

---

## Capacity Planning

### 1. Growth Forecasting

```python
# capacity_forecast.py
import pandas as pd
import numpy as np
from sklearn.linear_model import LinearRegression

# Load historical metrics
df = pd.read_csv('metrics.csv')
df['timestamp'] = pd.to_datetime(df['timestamp'])

# Calculate growth rate
model = LinearRegression()
X = np.array(range(len(df))).reshape(-1, 1)
y = df['tps'].values

model.fit(X, y)
growth_rate = model.coef_[0]

# Forecast next 6 months
future_months = 180  # days
future_X = np.array(range(len(df), len(df) + future_months)).reshape(-1, 1)
forecast_tps = model.predict(future_X)

# Determine scaling needs
current_capacity = 15000  # TPS
if forecast_tps[-1] > current_capacity * 0.8:
    print(f"WARNING: Capacity planning required")
    print(f"Current capacity: {current_capacity} TPS")
    print(f"Forecasted demand: {forecast_tps[-1]:.0f} TPS")
    print(f"Recommended action: Add {int((forecast_tps[-1] - current_capacity) / 5000) + 1} read replicas")
```

### 2. Resource Utilization Formulas

```
CPU Utilization:
  Required vCPUs = (Target TPS / TPS per vCPU) * Safety Factor
  TPS per vCPU ≈ 500 (OLTP workload)
  Safety Factor = 1.5

Memory Utilization:
  Required RAM = (Working Set + Shared Buffers + Connection Overhead) * Safety Factor
  Working Set = Active Data Size * 0.5
  Shared Buffers = Total RAM * 0.25
  Connection Overhead = Max Connections * 10MB
  Safety Factor = 1.3

Storage IOPS:
  Required IOPS = (Write TPS * WAL IOPS) + (Read TPS * Read IOPS)
  WAL IOPS per TPS ≈ 5-10
  Read IOPS per TPS ≈ 2-5 (with good caching)

Connection Capacity:
  Max Connections = Backend Connections + Pooler Multiplier
  Backend Connections = (vCPUs * 50)
  Pooler Multiplier = 10x (via PgBouncer)
```

### 3. Capacity Planning Matrix

| Metric | Current | 3 Months | 6 Months | 12 Months | Action Required |
|--------|---------|----------|----------|-----------|-----------------|
| TPS | 5,000 | 7,000 | 10,000 | 15,000 | Add 1 replica at 6mo |
| Connections | 500 | 700 | 1,000 | 1,500 | Add PgBouncer at 9mo |
| Data Size | 500GB | 750GB | 1TB | 2TB | Expand storage at 6mo |
| RAM Usage | 60% | 70% | 80% | 90% | Vertical scale at 9mo |
| CPU Usage | 40% | 50% | 60% | 70% | OK until 12mo |

---

## Scaling Decision Matrix

### When to Scale Horizontally (Add Nodes)

| Metric | Threshold | Action | Priority |
|--------|-----------|--------|----------|
| Read TPS | > 10,000 | Add read replica | High |
| Write TPS | > 5,000 | Consider sharding | Medium |
| Replication Lag | > 5 seconds | Add replica | High |
| Connection Pool | > 4,000 active | Add PgBouncer | High |
| Geographic Latency | > 100ms | Add regional replica | Medium |

### When to Scale Vertically (Upgrade Resources)

| Metric | Threshold | Action | Priority |
|--------|-----------|--------|----------|
| CPU Utilization | > 70% sustained | Add vCPUs | High |
| Memory Usage | > 85% | Add RAM | Critical |
| Disk IOPS | > 80% saturation | Upgrade storage tier | High |
| Cache Hit Ratio | < 95% | Increase shared_buffers | Medium |
| Checkpoint Frequency | < 5 minutes | Increase max_wal_size | Medium |

### Cost vs Performance Trade-offs

| Scaling Option | Cost Impact | Performance Gain | Complexity | Recommendation |
|----------------|-------------|------------------|------------|----------------|
| Add read replica | Medium | High (read-heavy) | Low | First choice for reads |
| Add PgBouncer | Low | High (connections) | Low | Always beneficial |
| Vertical scale CPU | High | Medium | Low | When CPU-bound |
| Vertical scale RAM | Medium | High (caching) | Low | When cache miss rate high |
| Add sharding | Low (compute) | Very High | Very High | Last resort |
| Upgrade storage | Medium | High (I/O bound) | Low | When IOPS saturated |

---

## Conclusion

### Scaling Best Practices

1. **Monitor continuously** - Use Prometheus/Grafana dashboards
2. **Test before production** - Always test scaling in staging
3. **Document changes** - Record all scaling operations
4. **Automate when possible** - Use scripts for repeatable tasks
5. **Plan ahead** - Don't wait for crisis to scale

### Recommended Review Schedule

- **Weekly:** Review key metrics dashboards
- **Monthly:** Capacity planning review
- **Quarterly:** Load testing and performance tuning
- **Annually:** Architecture review and optimization

### Escalation Path

1. **Warning (70% capacity):** Schedule scaling review
2. **Critical (85% capacity):** Execute scaling plan
3. **Emergency (95% capacity):** Immediate action required

For questions or assistance with scaling operations, contact the database operations team or refer to the production deployment documentation.
