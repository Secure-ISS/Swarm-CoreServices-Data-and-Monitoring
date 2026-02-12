# Monitoring Runbooks

## Overview

This document contains runbooks for common monitoring alerts in the Distributed PostgreSQL Cluster. Each runbook provides diagnosis steps, resolution procedures, and prevention strategies.

## Table of Contents

- [Database Alerts](#database-alerts)
- [RuVector Alerts](#ruvector-alerts)
- [Redis Alerts](#redis-alerts)
- [System Alerts](#system-alerts)
- [Application Alerts](#application-alerts)

## Database Alerts

### PostgreSQLDown

**Severity**: Critical

**Description**: PostgreSQL instance is not responding

**Diagnosis**:
```bash
# Check container status
docker ps -a | grep postgres

# Check logs
docker logs dpg-postgres-dev --tail 100

# Check network
docker network inspect dpg-dev-network

# Test connection
psql -h localhost -U dpg_cluster -d distributed_postgres_cluster -c "SELECT 1"
```

**Resolution**:
```bash
# Restart PostgreSQL
docker restart dpg-postgres-dev

# If container is stopped
docker start dpg-postgres-dev

# If container won't start, check logs and fix issues
docker logs dpg-postgres-dev

# Verify recovery
docker exec dpg-postgres-dev pg_isready
```

**Prevention**:
- Monitor disk space (auto-shutdown if full)
- Set up connection pooling
- Configure proper resource limits
- Regular backups

### PostgreSQLConnectionPoolExhausted

**Severity**: Critical

**Description**: No available database connections

**Diagnosis**:
```bash
# Check active connections
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT count(*), state FROM pg_stat_activity GROUP BY state"

# Find long-running queries
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT pid, now() - query_start as duration, state, query FROM pg_stat_activity WHERE state != 'idle' ORDER BY duration DESC LIMIT 10"
```

**Resolution**:
```bash
# Kill idle connections
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state = 'idle' AND now() - state_change > interval '10 minutes'"

# Kill specific long-running query (replace PID)
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT pg_terminate_backend(12345)"

# Restart application to reset connection pool
docker restart <app-container>
```

**Prevention**:
- Increase max_connections in PostgreSQL config
- Implement connection pooling (PgBouncer)
- Set connection timeout in application
- Monitor connection usage trends

### PostgreSQLReplicationLag

**Severity**: Warning/Critical

**Description**: Replication is falling behind

**Diagnosis**:
```bash
# Check replication status on primary
docker exec dpg-postgres-dev psql -U dpg_cluster -c \
  "SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication"

# Check replication lag on replica
docker exec dpg-postgres-replica psql -U dpg_cluster -c \
  "SELECT now() - pg_last_xact_replay_timestamp() AS lag"

# Check WAL sender on primary
docker exec dpg-postgres-dev psql -U dpg_cluster -c \
  "SELECT * FROM pg_stat_replication"
```

**Resolution**:
```bash
# Check network connectivity
docker exec dpg-postgres-dev ping dpg-postgres-replica

# Check replica load
docker exec dpg-postgres-replica top -bn1

# If lag is severe, consider:
# 1. Reduce load on replica (stop analytics queries)
# 2. Increase replica resources
# 3. Check for long-running transactions on replica

# Monitor recovery
watch -n 5 'docker exec dpg-postgres-replica psql -U dpg_cluster -c "SELECT now() - pg_last_xact_replay_timestamp() AS lag"'
```

**Prevention**:
- Monitor replica resource usage
- Use connection pooling for read queries
- Separate analytics workload
- Configure appropriate replication settings

### PostgreSQLDeadTuplesHigh

**Severity**: Warning

**Description**: Table has high percentage of dead tuples

**Diagnosis**:
```bash
# Check dead tuples per table
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT schemaname, tablename, n_live_tup, n_dead_tup,
   CASE WHEN n_live_tup + n_dead_tup > 0
   THEN (n_dead_tup::float / (n_live_tup + n_dead_tup)) * 100
   ELSE 0 END as dead_ratio
   FROM pg_stat_user_tables
   WHERE n_dead_tup > 1000
   ORDER BY dead_ratio DESC"

# Check autovacuum status
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT schemaname, tablename, last_vacuum, last_autovacuum, last_analyze
   FROM pg_stat_user_tables
   ORDER BY last_autovacuum NULLS FIRST"
```

**Resolution**:
```bash
# Manual vacuum on specific table
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "VACUUM VERBOSE ANALYZE public.tablename"

# Vacuum all tables in schema
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "VACUUM ANALYZE"

# For severe bloat, use VACUUM FULL (requires table lock)
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "VACUUM FULL VERBOSE ANALYZE public.tablename"
```

**Prevention**:
- Tune autovacuum settings
- Schedule regular maintenance windows
- Monitor table growth patterns
- Use partitioning for large tables

## RuVector Alerts

### RuVectorSearchLatencyHigh

**Severity**: Warning/Critical

**Description**: Vector search operations are slow

**Diagnosis**:
```bash
# Check HNSW index sizes
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT schemaname, tablename, indexname,
   pg_size_pretty(pg_relation_size(indexrelid)) as index_size
   FROM pg_stat_user_indexes
   WHERE indexname LIKE '%hnsw%'"

# Check index scan statistics
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT schemaname, tablename, indexname, idx_scan, idx_tup_read, idx_tup_fetch
   FROM pg_stat_user_indexes
   WHERE indexname LIKE '%hnsw%'"

# Test search performance
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "EXPLAIN ANALYZE SELECT * FROM embeddings
   ORDER BY embedding <-> '[0.1, 0.2, ...]'::ruvector
   LIMIT 10"
```

**Resolution**:
```bash
# Rebuild HNSW index with better parameters
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "REINDEX INDEX CONCURRENTLY embedding_hnsw_idx"

# Increase HNSW ef_search parameter
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SET ruvector.hnsw_ef_search = 200"

# Analyze table for better statistics
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "ANALYZE embeddings"
```

**Prevention**:
- Regularly analyze tables
- Monitor index growth
- Tune HNSW parameters (m, ef_construction)
- Consider partitioning for very large datasets

### RuVectorOperationErrors

**Severity**: Critical

**Description**: Vector operations are failing

**Diagnosis**:
```bash
# Check PostgreSQL logs
docker logs dpg-postgres-dev --tail 100 | grep -i error

# Check RuVector extension status
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT extname, extversion FROM pg_extension WHERE extname = 'ruvector'"

# Test vector operations
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT '[0.1, 0.2, 0.3]'::ruvector"
```

**Resolution**:
```bash
# If extension is missing, reinstall
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "CREATE EXTENSION IF NOT EXISTS ruvector"

# If index is corrupted, rebuild
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "REINDEX INDEX CONCURRENTLY embedding_hnsw_idx"

# Check and fix data types
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT column_name, data_type FROM information_schema.columns
   WHERE table_name = 'embeddings' AND column_name = 'embedding'"
```

**Prevention**:
- Validate vector dimensions before insert
- Use transactions for batch operations
- Monitor extension version updates
- Regular backups

## Redis Alerts

### RedisMemoryUsageHigh

**Severity**: Warning/Critical

**Description**: Redis is using too much memory

**Diagnosis**:
```bash
# Check memory usage
docker exec dpg-redis-dev redis-cli INFO memory

# Check key count and sizes
docker exec dpg-redis-dev redis-cli --bigkeys

# Sample key TTLs
docker exec dpg-redis-dev redis-cli --scan | head -100 | xargs -I {} docker exec dpg-redis-dev redis-cli TTL {}
```

**Resolution**:
```bash
# Flush expired keys
docker exec dpg-redis-dev redis-cli FLUSHDB ASYNC

# Set TTL on keys without expiration
docker exec dpg-redis-dev redis-cli KEYS "*" | while read key; do
  docker exec dpg-redis-dev redis-cli EXPIRE "$key" 3600
done

# Increase maxmemory (temporary)
docker exec dpg-redis-dev redis-cli CONFIG SET maxmemory 1gb

# Restart with new maxmemory
# Edit docker-compose.dev.yml maxmemory value
docker restart dpg-redis-dev
```

**Prevention**:
- Set TTL on all cached data
- Implement eviction policy
- Monitor key patterns
- Regular cleanup of stale keys

### RedisHitRateLow

**Severity**: Warning

**Description**: Cache is not effective

**Diagnosis**:
```bash
# Check hit/miss statistics
docker exec dpg-redis-dev redis-cli INFO stats | grep -E 'keyspace_hits|keyspace_misses'

# Check key patterns
docker exec dpg-redis-dev redis-cli --scan --pattern "*" | head -100

# Check key distribution
docker exec dpg-redis-dev redis-cli INFO keyspace
```

**Resolution**:
```bash
# Review and adjust caching strategy in application
# - Cache frequently accessed data
# - Set appropriate TTLs
# - Pre-warm cache for common queries

# Monitor improvement
watch -n 5 'docker exec dpg-redis-dev redis-cli INFO stats | grep -E "keyspace_hits|keyspace_misses"'
```

**Prevention**:
- Analyze access patterns
- Implement cache warming
- Use appropriate cache keys
- Monitor cache effectiveness metrics

## System Alerts

### HighCPUUsage / CriticalCPUUsage

**Severity**: Warning/Critical

**Description**: System CPU usage is high

**Diagnosis**:
```bash
# Check container CPU usage
docker stats --no-stream

# Check processes in container
docker exec dpg-postgres-dev top -bn1

# Check PostgreSQL query activity
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT pid, query, state, query_start FROM pg_stat_activity WHERE state = 'active'"
```

**Resolution**:
```bash
# Kill expensive queries
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query_start < now() - interval '5 minutes' AND state = 'active'"

# Increase CPU limits (temporary)
# Edit docker-compose.dev.yml CPU limits
docker compose -f docker-compose.dev.yml up -d

# Scale horizontally if possible
# Add read replicas for query load
```

**Prevention**:
- Optimize queries
- Implement query timeout
- Use connection pooling
- Monitor query patterns

### DiskSpaceLow / DiskSpaceCritical

**Severity**: Warning/Critical

**Description**: Disk space is running low

**Diagnosis**:
```bash
# Check disk usage
df -h

# Check Docker volume usage
docker system df -v

# Check PostgreSQL data directory
docker exec dpg-postgres-dev du -sh /var/lib/postgresql/data

# Find large files
docker exec dpg-postgres-dev find /var/lib/postgresql/data -type f -size +100M -exec ls -lh {} \\;
```

**Resolution**:
```bash
# Clean up old WAL files
docker exec dpg-postgres-dev psql -U dpg_cluster -c "CHECKPOINT"

# Vacuum full on large tables
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "VACUUM FULL"

# Remove old Docker images and volumes
docker system prune -a --volumes

# Extend volume size (if possible)
# Or migrate to larger disk
```

**Prevention**:
- Set up log rotation
- Configure WAL archiving
- Monitor growth trends
- Regular cleanup of old data

## Application Alerts

### HighErrorRate

**Severity**: Critical

**Description**: Application is returning many errors

**Diagnosis**:
```bash
# Check application logs
docker logs <app-container> --tail 100 | grep -i error

# Check database errors
docker logs dpg-postgres-dev --tail 100 | grep -i error

# Check error patterns in Prometheus
# http://localhost:9090/graph
# Query: rate(http_requests_total{status=~"5.."}[5m])

# Test endpoints
curl -v http://localhost:8000/health
```

**Resolution**:
```bash
# Restart application
docker restart <app-container>

# Check database connectivity
docker exec <app-container> nc -zv dpg-postgres-dev 5432

# Roll back recent changes if applicable
git revert <commit-hash>
docker compose up -d --build

# Scale up if traffic-related
docker compose up -d --scale app=3
```

**Prevention**:
- Implement circuit breakers
- Add retry logic with backoff
- Comprehensive error logging
- Regular load testing

### SlowResponseTime

**Severity**: Warning/Critical

**Description**: API responses are slow

**Diagnosis**:
```bash
# Check slow queries
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "SELECT query, calls, mean_exec_time, max_exec_time
   FROM pg_stat_statements
   ORDER BY mean_exec_time DESC LIMIT 10"

# Check application performance
docker logs <app-container> | grep -i "slow\|timeout"

# Test endpoint performance
time curl http://localhost:8000/api/search?q=test
```

**Resolution**:
```bash
# Add missing indexes
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c \
  "CREATE INDEX CONCURRENTLY idx_name ON table_name (column_name)"

# Optimize slow queries
# - Add WHERE clauses
# - Limit result sets
# - Use appropriate indexes

# Increase cache hit ratio
# - Pre-warm cache
# - Increase cache TTL for stable data

# Scale horizontally
docker compose up -d --scale app=3
```

**Prevention**:
- Regular query optimization
- Implement caching strategy
- Monitor query plans
- Load testing before deployment

---

## General Troubleshooting Steps

### 1. Check All Services
```bash
docker ps -a
docker compose -f docker-compose.dev.yml ps
docker compose -f docker/monitoring/docker-compose.yml ps
```

### 2. View Logs
```bash
docker logs <container-name> --tail 100 -f
```

### 3. Check Resource Usage
```bash
docker stats
```

### 4. Test Connectivity
```bash
docker exec <container> ping <target>
docker exec <container> nc -zv <host> <port>
```

### 5. Restart Services
```bash
docker restart <container>
docker compose restart
```

### 6. Check Metrics
- Prometheus: http://localhost:9090
- Grafana: http://localhost:3000

## Contact

For escalation or additional support:
- DevOps Team: devops@dpg-cluster.local
- On-call: oncall@dpg-cluster.local
- PagerDuty: Integration configured in AlertManager
