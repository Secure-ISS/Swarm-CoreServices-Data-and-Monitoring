# Production Readiness Quick Reference

## Quick Validation

```bash
# Run full production readiness check
./scripts/production-readiness-check.sh

# Expected: Exit code 0 (ready) or 2 (ready with warnings)
# Review: production-readiness-YYYYMMDD-HHMMSS.log
```

## Readiness Score Interpretation

| Score | Status | Action |
|-------|--------|--------|
| ≥90% + No blockers | 🟢 **PRODUCTION READY** | Deploy |
| 75-89% + No blockers | 🟡 **READY WITH WARNINGS** | Address warnings, then deploy |
| <75% or Has blockers | 🔴 **NOT READY** | Fix blockers before deployment |

## Critical Checklist (Must Pass)

### Infrastructure ✅
- [ ] Docker 20.10+ and Docker Compose 2.0+ installed
- [ ] ≥20GB available storage (50GB+ recommended)
- [ ] Valid SSL certificates (≥30 days until expiry)
- [ ] Docker Swarm active with ≥3 nodes (for HA)

### Database ✅
- [ ] PostgreSQL 15.0+ with RuVector 2.0+ installed
- [ ] max_connections ≥100
- [ ] Replication lag <5 seconds (if using Patroni)
- [ ] Connection pool: 100% success at 35+ agents
- [ ] Automated backups configured

### Security ✅
- [ ] Strong, unique passwords (no defaults)
- [ ] SSL/TLS enforced (sslmode=require or verify-full)
- [ ] Firewall configured
- [ ] Non-superuser application accounts
- [ ] Audit logging enabled (log_statement=ddl)

### Monitoring ✅
- [ ] Prometheus scraping all targets
- [ ] Grafana dashboards loaded
- [ ] Critical alerts configured
- [ ] At least one notification channel tested

### Performance ✅
- [ ] Simple queries: <10ms average
- [ ] Vector search: <50ms p95
- [ ] Connection pool: 100% success under load
- [ ] Resource usage: <80% CPU/memory

### High Availability ✅
- [ ] Patroni cluster healthy (if enabled)
- [ ] Automatic failover tested (<30s)
- [ ] Recent backups verified (<24 hours)
- [ ] Disaster recovery procedures documented

## Warning Items (Recommended)

### Infrastructure 🟡
- Docker Swarm mode for HA
- Load balancer configured
- Shared storage for backups

### Database 🟡
- Point-in-time recovery (PITR) enabled
- Backup encryption
- Offsite backup storage

### Security 🟡
- Network segmentation
- Intrusion detection (fail2ban)
- Security scanning (Trivy/Grype)
- Two-factor authentication

### Monitoring 🟡
- Log aggregation (ELK/Loki)
- Distributed tracing (Jaeger)
- Alert escalation (PagerDuty)

### Performance 🟡
- PgBouncer for connection pooling
- Redis caching layer
- Query optimization for slow queries

## Quick Commands

### Health Checks
```bash
# Database health
python3 scripts/db_health_check.py

# Pool capacity
python3 scripts/test_pool_capacity.py

# Benchmark
python3 scripts/benchmark/quick_benchmark.py

# Monitoring stack
./scripts/start_monitoring.sh
docker ps | grep -E "prometheus|grafana|alertmanager"
```

### Cluster Status
```bash
# Docker Swarm
docker node ls

# Patroni (if enabled)
patronictl -c /etc/patroni/patroni.yml list

# Replication
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT * FROM pg_stat_replication;"
```

### Security Validation
```bash
# SSL connections
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT pid, usename, ssl, cipher FROM pg_stat_ssl JOIN pg_stat_activity USING (pid);"

# User privileges
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT usename, usecreatedb, usesuper FROM pg_user;"

# Firewall status
sudo ufw status verbose
```

### Monitoring
```bash
# Prometheus targets
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, state: .health}'

# Active alerts
curl -s http://localhost:9093/api/v2/alerts | jq '.[] | {alertname: .labels.alertname, state: .status.state}'

# Grafana health
curl -s http://localhost:3000/api/health | jq
```

### Performance
```bash
# Query statistics
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "
SELECT query, calls, mean_exec_time, max_exec_time
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;"

# Resource usage
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"

# Index usage
docker exec dpg-postgres-dev psql -U dpg_cluster -d distributed_postgres_cluster -c "
SELECT schemaname, tablename, indexname, idx_scan
FROM pg_stat_user_indexes
WHERE indexname LIKE '%hnsw%'
ORDER BY idx_scan DESC;"
```

## Common Issues & Solutions

### Issue: Production readiness check fails
**Solution**: Review log file, address all blockers, rerun check

### Issue: SSL/TLS not enforced
**Solution**: Set `RUVECTOR_SSLMODE=require` in .env, restart containers

### Issue: Backup not found
**Solution**: Run `./scripts/deployment/backup-distributed.sh`, verify cron job

### Issue: Monitoring stack not running
**Solution**: Run `./scripts/start_monitoring.sh`, check Docker logs

### Issue: Connection pool exhaustion
**Solution**: Increase maxconn in `src/db/pool.py`, restart application

### Issue: Replication lag high
**Solution**: Check network, long-running transactions, checkpoint settings

## Pre-Launch Timeline

### 1 Week Before
- Run full production readiness check
- Test disaster recovery
- Load test with 2x traffic
- Security audit

### 3 Days Before
- Freeze code
- Final readiness check
- Test all alerts
- Schedule deployment

### Day of Launch
- Final health check
- Deploy to production
- Smoke test
- Monitor dashboards (4 hours)

### Post-Launch
- Continuous monitoring
- Review metrics
- Check error rates
- Document lessons learned

## Emergency Contacts

- **Operations Team**: ops-team@example.com
- **On-Call**: [Insert on-call rotation]
- **Escalation**: [Insert escalation path]

## Documentation

- **Full Guide**: [docs/PRODUCTION_READINESS.md](PRODUCTION_READINESS.md)
- **Deployment**: [deployment/DEPLOYMENT_GUIDE.md](../deployment/DEPLOYMENT_GUIDE.md)
- **Patroni HA**: [docs/architecture/PATRONI_HA_DESIGN.md](architecture/PATRONI_HA_DESIGN.md)
- **Failover**: [docs/operations/FAILOVER_RUNBOOK.md](operations/FAILOVER_RUNBOOK.md)

## Exit Codes

| Code | Meaning | Action |
|------|---------|--------|
| 0 | Production ready | Deploy to production |
| 1 | Not ready (blockers) | Fix blockers, rerun check |
| 2 | Ready with warnings | Review warnings, consider deploying |

---

**Last Updated**: 2026-02-12
**Version**: 1.0
**Review Cycle**: After each deployment
