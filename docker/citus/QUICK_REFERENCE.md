# Citus Quick Reference Card

## One-Command Start

```bash
# Start cluster + initialize
docker compose -f docker/citus/docker-compose.yml up -d && \
sleep 30 && \
./scripts/citus/setup-citus.sh
```

## Essential Commands

### Cluster Management

```bash
# Start
docker compose -f docker/citus/docker-compose.yml up -d

# Stop
docker compose -f docker/citus/docker-compose.yml down

# Restart
docker compose -f docker/citus/docker-compose.yml restart

# Clean (DESTRUCTIVE!)
docker compose -f docker/citus/docker-compose.yml down -v

# Logs
docker compose -f docker/citus/docker-compose.yml logs -f citus-coordinator
```

### Connect

```bash
# Coordinator (main)
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster

# Workers (direct)
psql -h localhost -p 5433 -U dpg_cluster -d distributed_postgres_cluster  # Worker 1
psql -h localhost -p 5434 -U dpg_cluster -d distributed_postgres_cluster  # Worker 2
psql -h localhost -p 5435 -U dpg_cluster -d distributed_postgres_cluster  # Worker 3
```

### Monitoring

```bash
./scripts/citus/monitor-citus.sh watch      # Dashboard
./scripts/citus/monitor-citus.sh snapshot   # One-time
./scripts/citus/monitor-citus.sh alerts     # Alerts only
./scripts/citus/monitor-citus.sh export     # Export JSON
```

### Shard Management

```bash
./scripts/citus/rebalance-shards.sh status                    # Show distribution
./scripts/citus/rebalance-shards.sh analyze                   # Recommendations
./scripts/citus/rebalance-shards.sh rebalance                 # Rebalance all
./scripts/citus/rebalance-shards.sh rebalance distributed.users  # One table
./scripts/citus/rebalance-shards.sh add worker-4 5432         # Add worker
./scripts/citus/rebalance-shards.sh remove worker-3 5432      # Remove worker
```

## SQL Quick Reference

### Check Cluster Status

```sql
-- Worker nodes
SELECT * FROM citus_get_active_worker_nodes();

-- Distributed tables
SELECT * FROM citus_tables;

-- Shard distribution
SELECT nodename, COUNT(*), pg_size_pretty(SUM(shard_size))
FROM citus_shards GROUP BY nodename;

-- Active queries
SELECT * FROM citus_dist_stat_activity WHERE state != 'idle';
```

### Create Distributed Table

```sql
-- Hash distribution
CREATE TABLE users (user_id BIGSERIAL PRIMARY KEY, username TEXT);
SELECT create_distributed_table('users', 'user_id');

-- Co-located table
CREATE TABLE orders (order_id BIGSERIAL, user_id BIGINT, PRIMARY KEY (order_id, user_id));
SELECT create_distributed_table('orders', 'user_id', colocate_with => 'users');

-- Reference table
CREATE TABLE countries (code CHAR(2) PRIMARY KEY, name TEXT);
SELECT create_reference_table('countries');

-- Vector table
CREATE TABLE embeddings (id BIGSERIAL, user_id BIGINT, vec ruvector(1536), PRIMARY KEY (id, user_id));
SELECT create_distributed_table('embeddings', 'user_id', colocate_with => 'users');
CREATE INDEX ON embeddings USING hnsw (vec ruvector_cosine_ops);
```

### Query Optimization

```sql
-- GOOD: Includes distribution column (single shard)
SELECT * FROM users WHERE user_id = 123;

-- BAD: No distribution column (all shards)
SELECT * FROM users WHERE email = 'test@example.com';

-- FIX: Use subquery
SELECT * FROM users WHERE user_id IN (
    SELECT user_id FROM users WHERE email = 'test@example.com'
);

-- Check query plan
EXPLAIN (ANALYZE, DIST) SELECT ...;
```

### Shard Operations

```sql
-- Rebalance table
SELECT rebalance_table_shards('users');

-- Move shard
SELECT citus_move_shard_placement(123, 'old-worker', 5432, 'new-worker', 5432);

-- Get shard for key
SELECT get_shard_id_for_distribution_column('users', 123);
```

## Troubleshooting

### Workers Not Showing

```sql
-- Check registration
SELECT * FROM pg_dist_node;

-- Re-register
SELECT citus_add_node('citus-worker-1', 5432);
SELECT citus_activate_node('citus-worker-1', 5432);
```

### Connection Refused

```bash
# Check containers
docker ps | grep citus

# Check logs
docker logs citus-coordinator
docker logs citus-worker-1

# Test connectivity
docker exec citus-coordinator pg_isready -h citus-worker-1
```

### Slow Queries

```sql
-- Top slow queries
SELECT query, mean_exec_time, calls
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat%'
ORDER BY mean_exec_time DESC LIMIT 10;

-- Reset stats
SELECT pg_stat_statements_reset();
```

### Uneven Distribution

```bash
# Check balance
./scripts/citus/rebalance-shards.sh status

# Rebalance
./scripts/citus/rebalance-shards.sh rebalance
```

## Performance Tips

1. **Always include distribution column in WHERE clause**
2. **Co-locate related tables** (same distribution column)
3. **Use reference tables** for small lookups (<100MB)
4. **Create indexes** on each shard separately
5. **Monitor cache hit ratio** (target: >90%)
6. **Rebalance after adding/removing workers**
7. **Use EXPLAIN (DIST)** to verify query routing

## File Locations

| File | Purpose |
|------|---------|
| `docker/citus/docker-compose.yml` | Cluster definition |
| `scripts/citus/setup-citus.sh` | Initialization |
| `scripts/citus/monitor-citus.sh` | Monitoring |
| `scripts/citus/rebalance-shards.sh` | Shard management |
| `scripts/citus/migrate-to-citus.sh` | Migration tools |
| `scripts/citus/test-distribution.sh` | Test suite |
| `config/citus/citus.conf` | Configuration |
| `docs/CITUS_SETUP.md` | Full guide |
| `docs/MIGRATION_GUIDE.md` | Migration steps |

## Environment Variables

```bash
# Connection
export CITUS_COORDINATOR_HOST=localhost
export CITUS_COORDINATOR_PORT=5432
export POSTGRES_USER=dpg_cluster
export POSTGRES_PASSWORD=dpg_cluster_2026
export POSTGRES_DB=distributed_postgres_cluster

# Workers
export CITUS_WORKER_1_HOST=citus-worker-1
export CITUS_WORKER_2_HOST=citus-worker-2
export CITUS_WORKER_3_HOST=citus-worker-3
```

## Common Patterns

### User Sharding

```sql
-- Base user table
CREATE TABLE users (user_id BIGSERIAL PRIMARY KEY, ...);
SELECT create_distributed_table('users', 'user_id');

-- User-related tables (co-located)
CREATE TABLE user_profiles (profile_id BIGSERIAL, user_id BIGINT, ...);
SELECT create_distributed_table('user_profiles', 'user_id', colocate_with => 'users');

CREATE TABLE user_sessions (session_id UUID, user_id BIGINT, ...);
SELECT create_distributed_table('user_sessions', 'user_id', colocate_with => 'users');
```

### Time-Series Sharding

```sql
-- Events table (range by time)
CREATE TABLE events (
    event_id BIGSERIAL,
    event_time TIMESTAMP NOT NULL,
    data JSONB,
    PRIMARY KEY (event_time, event_id)
);
SELECT create_distributed_table('events', 'event_time', 'range');
```

### Multi-Tenant Sharding

```sql
-- Tenant table
CREATE TABLE tenants (tenant_id BIGSERIAL PRIMARY KEY, ...);
SELECT create_distributed_table('tenants', 'tenant_id');

-- Tenant data (co-located)
CREATE TABLE tenant_data (id BIGSERIAL, tenant_id BIGINT, ...);
SELECT create_distributed_table('tenant_data', 'tenant_id', colocate_with => 'tenants');

-- Ensure tenant_id in all queries
SELECT * FROM tenant_data WHERE tenant_id = ? AND ...;
```

## Useful Aliases

```bash
# Add to ~/.bashrc or ~/.zshrc
alias citus-up='docker compose -f docker/citus/docker-compose.yml up -d'
alias citus-down='docker compose -f docker/citus/docker-compose.yml down'
alias citus-logs='docker compose -f docker/citus/docker-compose.yml logs -f'
alias citus-psql='psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster'
alias citus-monitor='./scripts/citus/monitor-citus.sh watch'
alias citus-status='./scripts/citus/rebalance-shards.sh status'
```

## Emergency Procedures

### Coordinator Down

```bash
# Check status
docker ps | grep citus-coordinator

# Restart
docker compose -f docker/citus/docker-compose.yml restart citus-coordinator

# If data corruption, restore from backup
```

### Worker Down

```bash
# Identify failed worker
docker ps | grep citus-worker

# Restart worker
docker compose -f docker/citus/docker-compose.yml restart citus-worker-1

# If unrecoverable, remove and add new worker
./scripts/citus/rebalance-shards.sh remove citus-worker-1 5432
# Fix worker or create new one
./scripts/citus/rebalance-shards.sh add citus-worker-1 5432
./scripts/citus/rebalance-shards.sh rebalance
```

### Out of Disk Space

```sql
-- Find largest tables
SELECT table_name, pg_size_pretty(SUM(shard_size))
FROM citus_shards
GROUP BY table_name
ORDER BY SUM(shard_size) DESC;

-- Vacuum to reclaim space
VACUUM FULL ANALYZE large_table;

-- Or drop old data
DELETE FROM events WHERE event_time < NOW() - INTERVAL '90 days';
```

### Cluster Locked Up

```sql
-- Check locks
SELECT * FROM pg_locks WHERE NOT granted;

-- Kill long-running queries
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'active' AND query_start < NOW() - INTERVAL '5 minutes';

-- Check for distributed deadlocks
SELECT * FROM citus_lock_waits;
```

## Resources

- Full Documentation: `docs/CITUS_SETUP.md`
- Migration Guide: `docs/MIGRATION_GUIDE.md`
- Citus Docs: https://docs.citusdata.com/
- PostgreSQL Docs: https://www.postgresql.org/docs/

---

**Quick Help:** Run `./scripts/citus/setup-citus.sh` for guided setup
**Support:** Check logs first: `docker logs citus-coordinator`
