# Citus Distributed PostgreSQL Cluster

Complete Citus setup with RuVector extension support for horizontal sharding and distributed vector operations.

## Architecture

- **1 Coordinator Node**: Query routing, metadata management, result aggregation
- **3 Worker Nodes**: Shard storage and distributed query execution
- **Redis Cache**: Query result caching
- **PgAdmin**: Web-based management interface (optional)

## Quick Start

### 1. Start Cluster

```bash
# From project root
docker compose -f docker/citus/docker-compose.yml up -d

# Or with PgAdmin
docker compose -f docker/citus/docker-compose.yml --profile tools up -d
```

### 2. Initialize Citus

```bash
# Run setup script (creates extensions, registers workers, creates demo tables)
./scripts/citus/setup-citus.sh
```

### 3. Connect

```bash
# Using psql
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster

# Using Docker
docker exec -it citus-coordinator psql -U dpg_cluster -d distributed_postgres_cluster
```

### 4. Verify

```sql
-- Check worker nodes
SELECT * FROM citus_get_active_worker_nodes();

-- Check distributed tables
SELECT * FROM citus_tables;

-- Check shard distribution
SELECT nodename, COUNT(*) as shards, pg_size_pretty(SUM(shard_size)) as size
FROM citus_shards
GROUP BY nodename;
```

## Connection Details

| Service | Host | Port | Purpose |
|---------|------|------|---------|
| Coordinator | localhost | 5432 | Main connection point |
| Worker 1 | localhost | 5433 | Direct worker access (optional) |
| Worker 2 | localhost | 5434 | Direct worker access (optional) |
| Worker 3 | localhost | 5435 | Direct worker access (optional) |
| Redis | localhost | 6379 | Query cache |
| PgAdmin | localhost | 8080 | Web UI (with --profile tools) |

**Credentials:**
- User: `dpg_cluster`
- Password: `dpg_cluster_2026` (change in production!)
- Database: `distributed_postgres_cluster`

## Distributed Table Examples

### Hash Distribution (Default)

```sql
-- Create table
CREATE TABLE users (
    user_id BIGSERIAL PRIMARY KEY,
    username VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL
);

-- Distribute by user_id (32 shards across 3 workers)
SELECT create_distributed_table('users', 'user_id');

-- Insert data
INSERT INTO users (username, email)
SELECT 'user_' || i, 'user' || i || '@example.com'
FROM generate_series(1, 10000) i;

-- Query (automatically routed to correct shard)
SELECT * FROM users WHERE user_id = 123;
```

### Co-located Tables

```sql
-- Related tables should share distribution column
CREATE TABLE orders (
    order_id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL,
    total DECIMAL(10,2)
);

-- Co-locate with users for efficient joins
SELECT create_distributed_table('orders', 'user_id', colocate_with => 'users');

-- Efficient join (happens locally on each shard)
SELECT u.username, COUNT(o.order_id)
FROM users u
JOIN orders o ON u.user_id = o.user_id
GROUP BY u.username;
```

### Reference Tables

```sql
-- Small lookup tables (replicated to all workers)
CREATE TABLE countries (
    country_code CHAR(2) PRIMARY KEY,
    country_name VARCHAR(100)
);

SELECT create_reference_table('countries');

-- Can join with any distributed table efficiently
SELECT u.username, c.country_name
FROM users u
JOIN countries c ON u.country_code = c.country_code;
```

### Vector Embeddings

```sql
-- Distributed vector table with RuVector
CREATE TABLE user_embeddings (
    embedding_id BIGSERIAL,
    user_id BIGINT NOT NULL,
    content TEXT,
    embedding ruvector(1536),
    PRIMARY KEY (embedding_id, user_id)
);

-- Distribute by user_id
SELECT create_distributed_table('user_embeddings', 'user_id', colocate_with => 'users');

-- Create HNSW index on each shard
CREATE INDEX idx_embeddings_hnsw
ON user_embeddings
USING hnsw (embedding ruvector_cosine_ops)
WITH (m = 16, ef_construction = 100);

-- Vector similarity search (distributed)
SELECT embedding_id, content
FROM user_embeddings
WHERE user_id = 123
ORDER BY embedding <=> '[0.1, 0.2, ...]'::ruvector
LIMIT 10;
```

## Management Scripts

### Monitoring

```bash
# Real-time dashboard
./scripts/citus/monitor-citus.sh watch

# Single snapshot
./scripts/citus/monitor-citus.sh snapshot

# Export metrics to JSON
./scripts/citus/monitor-citus.sh export metrics.json
```

### Shard Rebalancing

```bash
# Check distribution balance
./scripts/citus/rebalance-shards.sh status

# Get rebalancing recommendations
./scripts/citus/rebalance-shards.sh analyze

# Rebalance all tables
./scripts/citus/rebalance-shards.sh rebalance

# Rebalance specific table
./scripts/citus/rebalance-shards.sh rebalance distributed.users
```

### Adding/Removing Workers

```bash
# Add new worker
./scripts/citus/rebalance-shards.sh add citus-worker-4 5432

# Drain worker (move shards away)
./scripts/citus/rebalance-shards.sh drain citus-worker-3 5432

# Remove worker
./scripts/citus/rebalance-shards.sh remove citus-worker-3 5432
```

## Migration from Single-Node

```bash
# 1. Prepare migration
./scripts/citus/migrate-to-citus.sh all

# 2. Review analysis
cat backups/migration-*/table-analysis.txt

# 3. Start Citus cluster
docker compose -f docker/citus/docker-compose.yml up -d
./scripts/citus/setup-citus.sh

# 4. Apply migration
psql -h localhost -p 5432 -U dpg_cluster -d distributed_postgres_cluster \
  < backups/migration-*/migration-script.sql

# 5. Verify
./scripts/citus/migrate-to-citus.sh verify
```

See [MIGRATION_GUIDE.md](../../docs/MIGRATION_GUIDE.md) for detailed instructions.

## Performance Tuning

### Coordinator Settings

```
shared_buffers = 512MB
effective_cache_size = 1536MB
work_mem = 32MB
max_connections = 100
```

### Worker Settings

```
shared_buffers = 1GB
effective_cache_size = 3GB
work_mem = 64MB
max_connections = 200
```

### Shard Count

- Default: 32 shards
- Large clusters (6+ workers): 64-128 shards
- Rule: 2-4x total CPU cores

### Query Optimization

```sql
-- Use EXPLAIN (DIST) to see query distribution
EXPLAIN (ANALYZE, DIST) SELECT ...;

-- Always include distribution column in WHERE
SELECT * FROM users WHERE user_id = 123;  -- Good: single shard
SELECT * FROM users WHERE email = 'x';     -- Bad: all shards

-- Use co-location for joins
SELECT * FROM users u
JOIN orders o ON u.user_id = o.user_id;  -- Local join per shard
```

## Troubleshooting

### Workers Not Showing

```sql
-- Check worker registration
SELECT * FROM pg_dist_node;

-- Re-register if needed
SELECT citus_add_node('citus-worker-1', 5432);
```

### Uneven Shard Distribution

```bash
# Check balance
./scripts/citus/rebalance-shards.sh status

# Rebalance
./scripts/citus/rebalance-shards.sh rebalance
```

### Connection Issues

```bash
# Check container status
docker compose -f docker/citus/docker-compose.yml ps

# Check logs
docker logs citus-coordinator
docker logs citus-worker-1

# Test connectivity
docker exec citus-coordinator pg_isready -h citus-worker-1
```

## Useful SQL Queries

```sql
-- List distributed tables
SELECT * FROM citus_tables;

-- Shard distribution
SELECT
    table_name::text,
    nodename,
    COUNT(*) as shard_count,
    pg_size_pretty(SUM(shard_size)) as size
FROM citus_shards
GROUP BY table_name, nodename
ORDER BY table_name, nodename;

-- Active distributed queries
SELECT * FROM citus_dist_stat_activity WHERE state != 'idle';

-- Worker node health
SELECT nodename, nodeport, isactive, shouldhaveshards
FROM pg_dist_node;

-- Query statistics
SELECT query, calls, mean_exec_time
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat%'
ORDER BY mean_exec_time DESC
LIMIT 10;

-- Rebalance table
SELECT rebalance_table_shards('table_name');

-- Check cluster health
SELECT * FROM citus_check_cluster_node_health();
```

## Docker Commands

```bash
# Start cluster
docker compose -f docker/citus/docker-compose.yml up -d

# Stop cluster
docker compose -f docker/citus/docker-compose.yml down

# View logs
docker compose -f docker/citus/docker-compose.yml logs -f

# Clean all data (DESTRUCTIVE!)
docker compose -f docker/citus/docker-compose.yml down -v

# Restart single service
docker compose -f docker/citus/docker-compose.yml restart citus-coordinator

# Scale workers (experimental)
docker compose -f docker/citus/docker-compose.yml up -d --scale citus-worker=5
```

## Resource Usage

| Component | CPU | Memory | Disk |
|-----------|-----|--------|------|
| Coordinator | 1-2 cores | 1-2GB | 50GB |
| Worker | 2-4 cores | 2-4GB | 200GB each |
| Redis | 0.5 cores | 256MB | 10GB |
| PgAdmin | 0.5 cores | 256MB | 5GB |
| **Total** | **8-14 cores** | **7-14GB** | **700GB** |

## Security Considerations

### Production Checklist

- [ ] Change default passwords
- [ ] Enable SSL/TLS
- [ ] Restrict network access (firewall)
- [ ] Use secrets management (not environment variables)
- [ ] Enable audit logging
- [ ] Set up regular backups
- [ ] Configure pg_hba.conf
- [ ] Use connection pooling (PgBouncer)

### SSL Configuration

See [config/security/postgresql-tls.conf](../../config/security/postgresql-tls.conf)

## Backup and Recovery

```bash
# Backup coordinator metadata
pg_dump -h localhost -p 5432 -U dpg_cluster \
  -d distributed_postgres_cluster \
  --schema=pg_dist \
  > coordinator-metadata.sql

# Backup distributed table
pg_dump -h localhost -p 5432 -U dpg_cluster \
  -d distributed_postgres_cluster \
  -t distributed.users \
  > users-table.sql

# For full cluster backup, use Citus backup tools
# https://docs.citusdata.com/en/stable/admin_guide/backup_restore.html
```

## Documentation

- [Citus Setup Guide](../../docs/CITUS_SETUP.md) - Complete setup documentation
- [Migration Guide](../../docs/MIGRATION_GUIDE.md) - Single-node to Citus migration
- [Citus Documentation](https://docs.citusdata.com/) - Official docs
- [RuVector Integration](https://github.com/ruvnet/ruvector) - Vector operations

## License

MIT License - see LICENSE file

## Support

- GitHub Issues: https://github.com/your-repo/issues
- Citus Community: https://www.citusdata.com/community
- PostgreSQL Help: https://www.postgresql.org/support/
