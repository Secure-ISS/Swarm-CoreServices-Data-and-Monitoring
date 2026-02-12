# Stack Manager Quick Reference

## Quick Commands

```bash
# Start stacks
./scripts/stack-manager.sh start dev          # Dev stack
./scripts/stack-manager.sh start dev --tools  # Dev + PgAdmin
./scripts/stack-manager.sh start citus        # Citus cluster
./scripts/stack-manager.sh start patroni      # HA cluster
./scripts/stack-manager.sh start monitoring   # Monitoring

# Stop stacks
./scripts/stack-manager.sh stop dev
./scripts/stack-manager.sh stop citus --force

# Restart
./scripts/stack-manager.sh restart dev

# Status & logs
./scripts/stack-manager.sh status
./scripts/stack-manager.sh logs dev
./scripts/stack-manager.sh logs dev --follow

# Clean (removes volumes!)
./scripts/stack-manager.sh clean dev

# Interactive mode
./scripts/stack-manager.sh interactive
```

## Stack Comparison

| Stack | Nodes | Memory | Ports | Use Case |
|-------|-------|--------|-------|----------|
| **dev** | 1 | 4GB | 5432, 6379, 8080 | Local development |
| **citus** | 4 | 15GB | 5432-5435, 6379 | Horizontal scaling |
| **patroni** | 7 | 12GB | 5000-5001, 7000 | High availability |
| **monitoring** | 7 | 1.5GB | 3000, 9090, 9093 | Observability |
| **production** | 10+ | 80GB | 5432, 6432, 9090 | Production use |

## Connection Strings

### Dev Stack
```bash
psql "postgresql://dpg_cluster:dpg_cluster_2026@localhost:5432/distributed_postgres_cluster"
```

### Citus Stack
```bash
# Coordinator
psql "postgresql://dpg_cluster:dpg_cluster_2026@localhost:5432/distributed_postgres_cluster"

# Workers
psql "postgresql://dpg_cluster:dpg_cluster_2026@localhost:5433/distributed_postgres_cluster"
psql "postgresql://dpg_cluster:dpg_cluster_2026@localhost:5434/distributed_postgres_cluster"
psql "postgresql://dpg_cluster:dpg_cluster_2026@localhost:5435/distributed_postgres_cluster"
```

### Patroni Stack
```bash
# Primary (read-write)
psql "postgresql://postgres:postgres@localhost:5000/postgres"

# Replicas (read-only)
psql "postgresql://postgres:postgres@localhost:5001/postgres"
```

### Production Stack
```bash
# Via HAProxy (read-write)
psql "postgresql://postgres:PASSWORD@localhost:5432/distributed_postgres_cluster"

# Via PgBouncer (connection pooling)
psql "postgresql://postgres:PASSWORD@localhost:6432/distributed_postgres_cluster"
```

## URLs

### Dev Stack
- PgAdmin: http://localhost:8080 (with --tools)

### Citus Stack
- PgAdmin: http://localhost:8080 (with --tools)

### Patroni Stack
- HAProxy Stats: http://localhost:7000
- Patroni API Node 1: http://localhost:8008
- Patroni API Node 2: http://localhost:8009
- Patroni API Node 3: http://localhost:8010

### Monitoring Stack
- Grafana: http://localhost:3000 (admin/admin)
- Prometheus: http://localhost:9090
- AlertManager: http://localhost:9093
- Postgres Exporter: http://localhost:9187/metrics
- Redis Exporter: http://localhost:9121/metrics

### Production Stack
- Grafana: http://localhost:3001 (admin/admin)
- Prometheus: http://localhost:9090
- HAProxy Stats: http://localhost:7000

## Port Reference

| Port | Service | Stack |
|------|---------|-------|
| 5432 | PostgreSQL/Coordinator/HAProxy-RW | dev, citus, production |
| 5433 | Citus Worker 1 / HAProxy-RO | citus, production |
| 5434 | Citus Worker 2 | citus |
| 5435 | Citus Worker 3 | citus |
| 5000 | HAProxy Primary (RW) | patroni |
| 5001 | HAProxy Replicas (RO) | patroni |
| 6379 | Redis | dev, citus |
| 6432 | PgBouncer | production |
| 7000 | HAProxy Stats | patroni, production |
| 8008-8010 | Patroni REST APIs | patroni, production |
| 8080 | PgAdmin | dev, citus |
| 3000 | Grafana | monitoring |
| 3001 | Grafana | production |
| 9090 | Prometheus | monitoring, production |
| 9093 | AlertManager | monitoring |
| 9100 | Node Exporter | monitoring |
| 9121 | Redis Exporter | monitoring |
| 9187 | Postgres Exporter | monitoring, production |
| 9999 | App Exporter | monitoring |

## Health Checks

```bash
# Dev stack
docker exec dpg-postgres-dev pg_isready
docker exec dpg-redis-dev redis-cli ping

# Citus stack
docker exec citus-coordinator pg_isready
docker exec citus-worker-1 pg_isready

# Patroni stack
curl http://localhost:8008/health
curl http://localhost:7000/stats

# Monitoring stack
curl http://localhost:9090/-/healthy
curl http://localhost:3000/api/health
```

## Troubleshooting

```bash
# Check running containers
docker ps

# View container logs
docker logs dpg-postgres-dev
docker logs -f citus-coordinator

# Check resource usage
docker stats

# View stack manager logs
tail -f logs/stack-manager.log

# Restart Docker
sudo systemctl restart docker

# Clean all Docker resources
docker system prune -a --volumes

# Check port usage
lsof -i :5432
ss -tulpn | grep :5432
```

## Common Issues

**Port conflict:**
```bash
./scripts/stack-manager.sh stop dev
./scripts/stack-manager.sh start citus
```

**Out of memory:**
```bash
./scripts/stack-manager.sh status  # Check usage
./scripts/stack-manager.sh stop <unused-stack>
docker system prune -a --volumes
```

**Services not healthy:**
```bash
./scripts/stack-manager.sh logs dev --follow
docker exec dpg-postgres-dev pg_isready
docker restart dpg-postgres-dev
```

**Clean start:**
```bash
./scripts/stack-manager.sh clean dev
./scripts/stack-manager.sh start dev
```

## Aliases (Add to ~/.bashrc)

```bash
# Stack manager aliases
alias sm='./scripts/stack-manager.sh'
alias sm-start='./scripts/stack-manager.sh start'
alias sm-stop='./scripts/stack-manager.sh stop'
alias sm-status='./scripts/stack-manager.sh status'
alias sm-logs='./scripts/stack-manager.sh logs'
alias sm-interactive='./scripts/stack-manager.sh interactive'

# Quick stack access
alias sm-dev='./scripts/stack-manager.sh start dev --tools'
alias sm-citus='./scripts/stack-manager.sh start citus'
alias sm-patroni='./scripts/stack-manager.sh start patroni'
alias sm-mon='./scripts/stack-manager.sh start monitoring'

# Database connections
alias psql-dev='psql "postgresql://dpg_cluster:dpg_cluster_2026@localhost:5432/distributed_postgres_cluster"'
alias psql-citus='psql "postgresql://dpg_cluster:dpg_cluster_2026@localhost:5432/distributed_postgres_cluster"'
alias psql-patroni='psql "postgresql://postgres:postgres@localhost:5000/postgres"'

# Monitoring
alias open-grafana='open http://localhost:3000'
alias open-prometheus='open http://localhost:9090'
alias open-pgadmin='open http://localhost:8080'
```

## Environment Variables

Create `.env` file in project root:

```bash
# PostgreSQL
POSTGRES_USER=dpg_cluster
POSTGRES_PASSWORD=dpg_cluster_2026
POSTGRES_DB=distributed_postgres_cluster

# PgAdmin
PGADMIN_EMAIL=admin@dpg.local
PGADMIN_PASSWORD=admin

# Grafana
GRAFANA_USER=admin
GRAFANA_PASSWORD=admin

# Patroni (for HA stack)
PATRONI_SCOPE=patroni-cluster
REPLICATION_USER=replicator
REPLICATION_PASSWORD=replicator_pass
```

## Docker Commands

```bash
# View all containers
docker ps -a

# View logs
docker-compose -f docker-compose.dev.yml logs -f

# Execute command in container
docker exec -it dpg-postgres-dev bash
docker exec -it dpg-postgres-dev psql -U dpg_cluster

# Stop all containers
docker stop $(docker ps -q)

# Remove all containers
docker rm $(docker ps -aq)

# Remove all volumes
docker volume rm $(docker volume ls -q)

# Clean system
docker system prune -a --volumes -f

# View resource usage
docker stats
docker system df
```

## Backup & Restore

```bash
# Backup database
docker exec dpg-postgres-dev pg_dump -U dpg_cluster distributed_postgres_cluster > backup.sql

# Restore database
docker exec -i dpg-postgres-dev psql -U dpg_cluster distributed_postgres_cluster < backup.sql

# Backup volume
docker run --rm -v dpg-postgres-dev-data:/data -v $(pwd):/backup alpine tar czf /backup/postgres-data.tar.gz /data

# Restore volume
docker run --rm -v dpg-postgres-dev-data:/data -v $(pwd):/backup alpine tar xzf /backup/postgres-data.tar.gz -C /
```

## Performance Tuning

```bash
# Check active connections
docker exec dpg-postgres-dev psql -U dpg_cluster -c "SELECT count(*) FROM pg_stat_activity;"

# View slow queries
docker exec dpg-postgres-dev psql -U dpg_cluster -c "SELECT query, calls, total_time, mean_time FROM pg_stat_statements ORDER BY mean_time DESC LIMIT 10;"

# Cache hit ratio
docker exec dpg-postgres-dev psql -U dpg_cluster -c "SELECT sum(heap_blks_read) as heap_read, sum(heap_blks_hit) as heap_hit, sum(heap_blks_hit) / (sum(heap_blks_hit) + sum(heap_blks_read)) as ratio FROM pg_statio_user_tables;"

# Redis info
docker exec dpg-redis-dev redis-cli info stats
docker exec dpg-redis-dev redis-cli info memory
```

## Monitoring Queries

```bash
# Database size
SELECT pg_size_pretty(pg_database_size('distributed_postgres_cluster'));

# Table sizes
SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_tables
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 10;

# Active connections
SELECT count(*) FROM pg_stat_activity WHERE state = 'active';

# Long running queries
SELECT pid, now() - query_start as duration, query
FROM pg_stat_activity
WHERE state = 'active' AND now() - query_start > interval '5 minutes'
ORDER BY duration DESC;

# Replication lag (Patroni)
SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
```

## Quick Setup Script

```bash
#!/bin/bash
# quick-setup.sh

# Clone and setup
cd /path/to/project
chmod +x scripts/stack-manager.sh

# Source bash completion
source scripts/stack-manager-completion.bash

# Add aliases
cat >> ~/.bashrc << 'EOF'
alias sm='./scripts/stack-manager.sh'
alias sm-dev='./scripts/stack-manager.sh start dev --tools'
EOF

source ~/.bashrc

# Start dev stack
sm-dev
```

## Support

- **Documentation:** `scripts/STACK_MANAGER_README.md`
- **Logs:** `logs/stack-manager.log`
- **Issues:** Check Docker logs and container status
