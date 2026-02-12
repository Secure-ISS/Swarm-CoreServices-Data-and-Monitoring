# Distributed PostgreSQL Cluster - Operators Quick Reference

**Last Updated:** 2026-02-12 | **Version:** 1.0

---

## PORT REFERENCE TABLE

| Service | Port | Type | Purpose |
|---------|------|------|---------|
| **Patroni-1** | 5435 | TCP | Direct connection (HA node 1) |
| **Patroni-2** | 5433 | TCP | Direct connection (HA node 2) |
| **Patroni-3** | 5434 | TCP | Direct connection (HA node 3) |
| **Patroni REST API-1** | 8008 | HTTP | Health checks, status |
| **Patroni REST API-2** | 8009 | HTTP | Health checks, status |
| **Patroni REST API-3** | 8010 | HTTP | Health checks, status |
| **HAProxy Primary** | 5000 | TCP | Write-only load balancer |
| **HAProxy Replicas** | 5001 | TCP | Read-only load balancer |
| **HAProxy All Nodes** | 5002 | TCP | All nodes (health checks) |
| **HAProxy Stats** | 7000 | HTTP | Stats UI (admin/admin) |
| **etcd-1** | 2379 | HTTP | Distributed consensus |
| **etcd-2** | 2379 | HTTP | Distributed consensus |
| **etcd-3** | 2379 | HTTP | Distributed consensus |
| **Redis** | 6379 | TCP | Cache layer |
| **PgAdmin** | 5050 | HTTP | Database admin UI |
| **Prometheus** | 9090 | HTTP | Metrics collection |
| **Grafana** | 3000 | HTTP | Metrics dashboard |
| **AlertManager** | 9093 | HTTP | Alert management |

---

## DOCKER COMMANDS

### Cluster Startup/Shutdown
```bash
# Start entire cluster
docker-compose -f docker/patroni/docker-compose.yml up -d

# Stop entire cluster
docker-compose -f docker/patroni/docker-compose.yml down

# Start development stack
scripts/dev/start-dev-stack.sh

# Stop development stack
scripts/dev/stop-dev-stack.sh

# View logs
docker-compose -f docker/patroni/docker-compose.yml logs -f [service]

# Restart specific service
docker-compose -f docker/patroni/docker-compose.yml restart [service-name]
```

### Service Management
```bash
# List running containers
docker ps

# Check service health
docker healthcheck inspect [container-name]

# View container logs
docker logs -f [container-name]

# Execute command in container
docker exec -it [container-name] bash

# Rebuild image
docker-compose -f docker/patroni/docker-compose.yml build --no-cache [service]
```

---

## PATRONI COMMANDS

### Status & Monitoring
```bash
# Check cluster status
docker exec patroni-1 patronictl -c /etc/patroni/patroni.yml list

# Get primary/replica info
docker exec patroni-1 patronictl -c /etc/patroni/patroni.yml members

# View member details
docker exec patroni-1 patronictl -c /etc/patroni/patroni.yml show-config

# REST API health check
curl http://localhost:8008/health
curl http://localhost:8009/health
curl http://localhost:8010/health
```

### Failover Operations
```bash
# Trigger manual failover (will elect new primary)
docker exec patroni-1 patronictl -c /etc/patroni/patroni.yml failover

# Switchover (graceful failover with re-sync)
docker exec patroni-1 patronictl -c /etc/patroni/patroni.yml switchover

# Restart node
docker exec patroni-1 patronictl -c /etc/patroni/patroni.yml restart patroni-1

# Reinitialize replica
docker exec patroni-2 patronictl -c /etc/patroni/patroni.yml reinit patroni-2
```

### Replication Management
```bash
# Check replication lag
docker exec patroni-1 psql -U postgres -d postgres \
  -c "SELECT slot_name, restart_lsn FROM pg_replication_slots;"

# Monitor streaming replication
docker exec patroni-1 psql -U postgres -d postgres \
  -c "SELECT client_addr, state, sync_state FROM pg_stat_replication;"

# Pause replication
docker exec patroni-1 patronictl -c /etc/patroni/patroni.yml pause

# Resume replication
docker exec patroni-1 patronictl -c /etc/patroni/patroni.yml resume
```

---

## CITUS COMMANDS

### Setup & Initialization
```bash
# Initialize Citus extension
scripts/citus/setup-citus.sh

# Verify Citus installation
docker exec patroni-1 psql -U postgres -d postgres \
  -c "SELECT * FROM citus_version();"

# Create distributed tables
docker exec patroni-1 psql -U postgres -d postgres \
  -f scripts/citus/01-init-citus.sql
```

### Shard Management
```bash
# View shard distribution
docker exec patroni-1 psql -U postgres -d postgres \
  -c "SELECT * FROM citus_shards;"

# Rebalance shards
scripts/citus/rebalance-shards.sh

# Monitor shard health
scripts/citus/monitor-citus.sh

# Test distribution
scripts/citus/test-distribution.sh
```

---

## HAPROXY COMMANDS

### Statistics & Health
```bash
# View HAProxy stats page
# Open: http://localhost:7000
# Credentials: admin / admin

# Check HAProxy status
curl http://localhost:7000/

# Verify primary routing
curl -v postgres://postgres:postgres@localhost:5000/postgres

# Verify replica routing
curl -v postgres://postgres:postgres@localhost:5001/postgres
```

### Connection Testing
```bash
# Test primary connection
docker exec -it patroni-1 psql -h haproxy -p 5000 -U postgres

# Test replica connection
docker exec -it patroni-1 psql -h haproxy -p 5001 -U postgres -c \
  "SELECT pg_is_in_recovery();"

# Test all nodes connection
docker exec -it patroni-1 psql -h haproxy -p 5002 -U postgres -c "SELECT version();"
```

---

## HEALTH CHECK COMMANDS

### Cluster Health
```bash
# Run comprehensive health check
python scripts/db_health_check.py

# Check etcd cluster health
docker exec etcd-1 etcdctl --endpoints=http://localhost:2379 endpoint health

# Check all Patroni nodes
for i in 1 2 3; do
  echo "=== Patroni-$i ==="
  curl -s http://localhost:$((8007+$i))/health | jq .
done

# Check PostgreSQL replication status
docker exec patroni-1 psql -U postgres -d postgres \
  -c "SELECT datname, slot_type, restart_lsn FROM pg_replication_slots;"
```

### Component Health
```bash
# PostgreSQL availability
pg_isready -h localhost -p 5000

# HAProxy status
nc -zv localhost 5000 && echo "Primary OK" || echo "Primary DOWN"
nc -zv localhost 5001 && echo "Replicas OK" || echo "Replicas DOWN"

# Redis health
redis-cli -h localhost ping

# etcd health
docker exec etcd-1 etcdctl endpoint health
```

---

## EMERGENCY PROCEDURES

### Node Failure - Complete Node Down
```bash
# 1. Identify failed node
docker ps | grep patroni

# 2. Check if cluster can elect primary (need 2/3 quorum)
docker exec patroni-1 patronictl list

# 3. If PRIMARY failed, failover is automatic (should complete in <30s)
# If REPLICA failed, it will be excluded automatically

# 4. Restart failed node
docker-compose -f docker/patroni/docker-compose.yml up -d patroni-[number]

# 5. Verify rejoined cluster
docker exec patroni-1 patronictl list

# 6. If node won't sync, reinitialize
docker exec patroni-[number] patronictl reinit patroni-[number]
```

### Consensus Loss - etcd Quorum Lost
```bash
# 1. Check etcd status
docker exec etcd-1 etcdctl member list

# 2. If lost quorum, restart all etcd nodes
docker-compose -f docker/patroni/docker-compose.yml restart etcd-1 etcd-2 etcd-3

# 3. Wait 30s for consensus recovery
sleep 30

# 4. Verify cluster state
docker exec patroni-1 patronictl list

# 5. If Patroni stuck, force reconnect
docker exec patroni-1 patronictl -c /etc/patroni/patroni.yml reload
```

### All Nodes Down - Total Cluster Failure
```bash
# 1. Start services in order
docker-compose -f docker/patroni/docker-compose.yml up -d etcd-1 etcd-2 etcd-3
sleep 10

# 2. Start Patroni nodes
docker-compose -f docker/patroni/docker-compose.yml up -d patroni-1 patroni-2 patroni-3
sleep 30

# 3. Verify recovery
docker exec patroni-1 patronictl list

# 4. Check replication status
docker exec patroni-1 psql -U postgres -d postgres \
  -c "SELECT client_addr, state FROM pg_stat_replication;"

# 5. Validate data integrity
scripts/validate_data_integrity.py
```

### Connection Pool Exhaustion
```bash
# 1. Check current connections
docker exec patroni-1 psql -U postgres -d postgres \
  -c "SELECT count(*) FROM pg_stat_activity;"

# 2. Check max connections
docker exec patroni-1 psql -U postgres -d postgres \
  -c "SHOW max_connections;"

# 3. Increase if needed (requires restart)
# Edit docker/postgresql.conf and restart container

# 4. Kill idle connections
docker exec patroni-1 psql -U postgres -d postgres \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity \
      WHERE state = 'idle' AND state_change < now() - interval '30 min';"

# 5. Monitor pool usage
python scripts/test_pool_capacity.py
```

### Data Corruption/Recovery
```bash
# 1. Stop all writes (Patroni pause)
docker exec patroni-1 patronictl pause

# 2. Take immediate backup
scripts/patroni/backup-cluster.sh

# 3. Check PGDATA integrity
docker exec patroni-1 pg_controldata /var/lib/postgresql/data

# 4. If corruption detected, restore from backup
scripts/patroni/restore-cluster.sh --backup-id [BACKUP_ID]

# 5. Resume replication
docker exec patroni-1 patronictl resume
```

---

## BACKUP & RESTORE

### Backup Operations
```bash
# Backup entire cluster
scripts/patroni/backup-cluster.sh

# Backup with compression
docker exec patroni-1 pg_basebackup -D /tmp/backup -F tar -z

# List backups
ls -lh /path/to/backups/

# Verify backup integrity
docker exec patroni-1 pg_controldata /tmp/backup/base
```

### Restore Operations
```bash
# Restore from backup
scripts/patroni/restore-cluster.sh --backup-id [BACKUP_ID]

# Point-in-time recovery
docker exec patroni-1 pg_basebackup -D /var/lib/postgresql/recovery \
  -F tar -z && patronictl restart patroni-1

# Verify restored data
docker exec patroni-1 psql -U postgres -d postgres \
  -c "SELECT * FROM pg_database;"
```

---

## MONITORING COMMANDS

### Real-time Monitoring
```bash
# Watch cluster status
watch -n 5 "docker exec patroni-1 patronictl list"

# Monitor replication lag
watch -n 5 "docker exec patroni-1 psql -U postgres -c \
  'SELECT client_addr, state, sync_state, write_lag FROM pg_stat_replication;'"

# Monitor connections
watch -n 2 "docker exec patroni-1 psql -U postgres -c \
  'SELECT datname, count(*) FROM pg_stat_activity GROUP BY datname;'"

# Monitor slow queries
docker exec patroni-1 tail -f /var/log/postgresql/postgresql.log
```

### Performance Analysis
```bash
# Analyze slow queries
scripts/performance/analyze-slow-queries.sh

# Run load test
scripts/performance/load_test_locust.py --workers 4 --duration 300

# Benchmark vector search
scripts/performance/benchmark_vector_search.py

# Collect metrics
python scripts/performance/metrics_collector.py
```

---

## COMMONLY NEEDED ENDPOINTS

| Component | URL | Auth |
|-----------|-----|------|
| Patroni-1 API | http://localhost:8008 | None |
| Patroni-2 API | http://localhost:8009 | None |
| Patroni-3 API | http://localhost:8010 | None |
| HAProxy Stats | http://localhost:7000 | admin:admin |
| Prometheus | http://localhost:9090 | None |
| Grafana | http://localhost:3000 | admin:admin |
| PgAdmin | http://localhost:5050 | pgadmin@pgadmin.org:admin |
| PostgreSQL Primary | localhost:5000 | postgres:postgres |
| PostgreSQL Replicas | localhost:5001 | postgres:postgres |

---

## TROUBLESHOOTING QUICK TIPS

| Problem | Quick Check |
|---------|-------------|
| Failover slow | Check etcd health: `etcdctl endpoint health` |
| Connections rejected | Check pool capacity: `SELECT count(*) FROM pg_stat_activity;` |
| Replication lag | Check network: `ping patroni-2 patroni-3` |
| Data inconsistency | Compare LSN: `SELECT pg_current_wal_lsn();` on all nodes |
| HAProxy routing wrong | Verify patroni status: `curl http://localhost:8008/primary` |
| Citus distribution issues | Check shard count: `SELECT * FROM citus_shards;` |

---

## KEY FILES LOCATION

- **Config**: `docker/patroni/patroni.yml` | `config/postgresql/postgresql.conf`
- **HAProxy**: `docker/patroni/haproxy.cfg`
- **Patroni Nodes**: `/var/lib/postgresql/data/`
- **Logs**: `/var/log/postgresql/` (inside containers)
- **Scripts**: `scripts/patroni/` | `scripts/citus/` | `scripts/performance/`
- **Monitoring**: `config/prometheus/` | `config/grafana/`

---

## RESPONSE TIMES (SLA)

- **Failover Detection**: <10s (etcd lease timeout)
- **Failover Completion**: <30s (cluster election)
- **Health Check Interval**: 5-10s
- **Vector Search**: <50ms (HNSW index)
- **Connection Pool Response**: <100ms

---

**For detailed documentation, see:**
- `docs/OPERATIONS_GUIDE.md` - Full operations guide
- `docs/RUNBOOKS.md` - Detailed runbooks for complex procedures
- `docs/MONITORING.md` - Comprehensive monitoring setup
- `docs/TROUBLESHOOTING_DEVELOPER.md` - Troubleshooting guide
