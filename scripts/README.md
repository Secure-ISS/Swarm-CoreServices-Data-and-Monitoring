# Scripts Directory

This directory contains operational scripts for managing the Distributed PostgreSQL Cluster.

## Production Readiness

### 🚀 Main Validation Script

**`production-readiness-check.sh`** - Comprehensive production readiness validation

```bash
# Run full validation
./scripts/production-readiness-check.sh

# Review detailed log
cat production-readiness-*.log
```

**Exit codes:**
- `0` = Production ready (all checks passed)
- `1` = Not ready (critical failures)
- `2` = Ready with warnings

**Validates:**
1. Infrastructure (Docker, Swarm, networking, storage, SSL)
2. Database (PostgreSQL, RuVector, configuration, replication)
3. Security (SSL/TLS, secrets, firewall, audit logging)
4. Monitoring (Prometheus, Grafana, alerts, notifications)
5. Performance (benchmarks, connection pools, resources)
6. High Availability (Patroni, failover, backups, DR)

### 📊 Supporting Scripts

**`benchmark/quick_benchmark.py`** - Database performance benchmarks

```bash
python3 scripts/benchmark/quick_benchmark.py
```

Tests:
- Simple query performance (<10ms target)
- Vector search performance (<50ms target)
- Connection pool capacity
- Database size metrics

**`validate_data_integrity.py`** - Data integrity validation

```bash
python3 scripts/validate_data_integrity.py
```

Validates:
- RuVector extension installed
- Required schemas and tables exist
- No NULL or invalid embeddings
- HNSW indexes present
- Referential integrity

## Database Management

### Health & Monitoring

**`db_health_check.py`** - Database health check

```bash
python3 scripts/db_health_check.py
```

Checks:
- Docker container status
- Environment configuration
- Database connections
- Schema existence
- SSL/TLS status

**`health_check_service.py`** - Continuous health monitoring service

```bash
# Start service
python3 scripts/health_check_service.py

# With interval
python3 scripts/health_check_service.py --interval 60
```

**`start_database.sh`** - Start or create database container

```bash
./scripts/start_database.sh
```

### Connection Testing

**`test_pool_capacity.py`** - Connection pool load testing

```bash
python3 scripts/test_pool_capacity.py
```

Tests connection pool with 35+ concurrent agents.

**`test_patroni_connection.py`** - Patroni HA connection testing

```bash
python3 scripts/test_patroni_connection.py
```

### Redis Cache

**`start_redis.sh`** - Start Redis cache container

```bash
./scripts/start_redis.sh
```

**`test_redis_cache.py`** - Test Redis caching

```bash
python3 scripts/test_redis_cache.py
```

**`validate_redis_deployment.py`** - Validate Redis deployment

```bash
python3 scripts/validate_redis_deployment.py
```

## Deployment

### Cluster Management

**`deployment/initialize-cluster.sh`** - Initialize Patroni cluster

```bash
./scripts/deployment/initialize-cluster.sh
```

**`deployment/deploy-production.sh`** - Deploy to production

```bash
./scripts/deployment/deploy-production.sh
```

**`deployment/add-worker.sh`** - Add worker node

```bash
./scripts/deployment/add-worker.sh <worker-ip>
```

**`deployment/remove-worker.sh`** - Remove worker node

```bash
./scripts/deployment/remove-worker.sh <worker-name>
```

### Backup & Restore

**`deployment/backup-distributed.sh`** - Backup distributed cluster

```bash
./scripts/deployment/backup-distributed.sh
```

**`deployment/restore-distributed.sh`** - Restore from backup

```bash
./scripts/deployment/restore-distributed.sh /path/to/backup.sql.gz
```

### Health Monitoring

**`deployment/health-check.sh`** - Deployment health check

```bash
./scripts/deployment/health-check.sh
```

**`deployment/health-monitor.py`** - Continuous health monitoring

```bash
python3 scripts/deployment/health-monitor.py
```

### Secrets Management

**`deployment/create-secrets.sh`** - Create Docker secrets

```bash
./scripts/deployment/create-secrets.sh
```

## Security

**`generate_ssl_certs.sh`** - Generate SSL/TLS certificates

```bash
./scripts/generate_ssl_certs.sh
```

**`security/audit.sh`** - Security audit (if exists)

```bash
./scripts/security/audit.sh
```

## Monitoring

**`start_monitoring.sh`** - Start monitoring stack

```bash
./scripts/start_monitoring.sh
```

Starts:
- Prometheus
- Grafana
- Alertmanager
- Exporters (postgres, redis, node)

## Performance

### Benchmarking

**`benchmark/run-load-tests.sh`** - Comprehensive load testing

```bash
./scripts/benchmark/run-load-tests.sh
```

**`benchmark_redis_realistic.py`** - Redis benchmark

```bash
python3 scripts/benchmark_redis_realistic.py
```

### Performance Testing

**`performance/` directory** - Additional performance scripts

## Development

### Database Setup

**`setup.sh`** - Initial project setup

```bash
./scripts/setup.sh
```

**`migrate_sqlite_to_postgres.py`** - Migrate from SQLite

```bash
python3 scripts/migrate_sqlite_to_postgres.py
```

### Patroni

**`patroni/` directory** - Patroni-specific scripts

**`start_pgbouncer.sh`** - Start PgBouncer connection pooler

```bash
./scripts/start_pgbouncer.sh
```

## Citus (Distributed PostgreSQL)

**`citus/` directory** - Citus-specific scripts for horizontal scaling

## Systemd Services

**`systemd/` directory** - Systemd service files for production deployment

**`install-health-service.sh`** - Install health check service

```bash
sudo ./scripts/install-health-service.sh
```

**`install-hooks.sh`** - Install git hooks

```bash
./scripts/install-hooks.sh
```

## SQL Scripts

**`sql/` directory** - SQL initialization scripts

- `init-ruvector.sql` - Initialize RuVector extension and schemas

## Common Workflows

### Initial Setup

```bash
# 1. Run setup
./scripts/setup.sh

# 2. Start database
./scripts/start_database.sh

# 3. Verify health
python3 scripts/db_health_check.py

# 4. Start monitoring
./scripts/start_monitoring.sh
```

### Pre-Production Validation

```bash
# 1. Run production readiness check
./scripts/production-readiness-check.sh

# 2. Review results
cat production-readiness-*.log

# 3. Run benchmarks
python3 scripts/benchmark/quick_benchmark.py

# 4. Test connection pool
python3 scripts/test_pool_capacity.py

# 5. Validate data integrity
python3 scripts/validate_data_integrity.py
```

### Production Deployment

```bash
# 1. Generate SSL certificates
./scripts/generate_ssl_certs.sh

# 2. Create secrets
./scripts/deployment/create-secrets.sh

# 3. Initialize cluster
./scripts/deployment/initialize-cluster.sh

# 4. Deploy to production
./scripts/deployment/deploy-production.sh

# 5. Verify deployment
./scripts/deployment/health-check.sh

# 6. Start monitoring
./scripts/start_monitoring.sh
```

### Daily Operations

```bash
# Morning health check
python3 scripts/db_health_check.py

# Check monitoring stack
docker ps | grep -E "prometheus|grafana|alertmanager"

# Review alerts
curl -s http://localhost:9093/api/v2/alerts | jq

# Backup database
./scripts/deployment/backup-distributed.sh
```

### Troubleshooting

```bash
# Database health
python3 scripts/db_health_check.py

# Connection pool status
python3 scripts/test_pool_capacity.py

# Data integrity
python3 scripts/validate_data_integrity.py

# Patroni cluster status (if enabled)
patronictl -c /etc/patroni/patroni.yml list

# Docker logs
docker logs dpg-postgres-dev
```

## Script Organization

```
scripts/
├── README.md (this file)
├── production-readiness-check.sh    # Main validation script
├── validate_data_integrity.py       # Data integrity checks
├── db_health_check.py               # Database health
├── test_pool_capacity.py            # Pool load testing
├── start_database.sh                # Database startup
├── start_monitoring.sh              # Monitoring stack
├── generate_ssl_certs.sh            # SSL certificate generation
├── setup.sh                         # Project setup
│
├── benchmark/                       # Performance benchmarks
│   ├── quick_benchmark.py
│   └── run-load-tests.sh
│
├── deployment/                      # Production deployment
│   ├── deploy-production.sh
│   ├── initialize-cluster.sh
│   ├── backup-distributed.sh
│   ├── restore-distributed.sh
│   ├── create-secrets.sh
│   ├── health-check.sh
│   └── health-monitor.py
│
├── security/                        # Security tools
├── performance/                     # Performance tools
├── patroni/                         # Patroni scripts
├── citus/                          # Citus scripts
├── systemd/                        # Systemd services
└── sql/                            # SQL scripts
```

## Environment Variables

Most scripts require environment variables from `.env`:

```bash
# Project database
RUVECTOR_DB=distributed_postgres_cluster
RUVECTOR_USER=dpg_cluster
RUVECTOR_PASSWORD=<password>
RUVECTOR_HOST=localhost
RUVECTOR_PORT=5432
RUVECTOR_SSLMODE=prefer

# Shared database
SHARED_KNOWLEDGE_DB=claude_flow_shared
SHARED_KNOWLEDGE_USER=shared_user
SHARED_KNOWLEDGE_PASSWORD=<password>
SHARED_KNOWLEDGE_HOST=localhost
SHARED_KNOWLEDGE_PORT=5432

# Patroni (optional)
ENABLE_PATRONI=false
```

## Documentation

- **Production Readiness**: [../docs/PRODUCTION_READINESS.md](../docs/PRODUCTION_READINESS.md)
- **Quick Reference**: [../docs/PRODUCTION_READINESS_SUMMARY.md](../docs/PRODUCTION_READINESS_SUMMARY.md)
- **Deployment Guide**: [../deployment/DEPLOYMENT_GUIDE.md](../deployment/DEPLOYMENT_GUIDE.md)
- **Patroni HA**: [../docs/architecture/PATRONI_HA_DESIGN.md](../docs/architecture/PATRONI_HA_DESIGN.md)

## Support

For issues with scripts:
1. Check script comments for usage
2. Review documentation in `docs/`
3. Check script logs and output
4. Verify environment variables

---

**Last Updated**: 2026-02-12
**Maintainer**: Operations Team
