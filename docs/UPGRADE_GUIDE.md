# PostgreSQL Distributed Cluster Upgrade Guide

## Version Compatibility Matrix

### PostgreSQL Versions

| Version | Patroni | Citus | RuVector | Release Date | End of Life |
|---------|---------|-------|----------|--------------|-------------|
| 18.x    | 3.2+    | 12.1+ | 2.0+     | 2025-09      | 2030-09     |
| 17.x    | 3.1+    | 12.0+ | 2.0+     | 2024-09      | 2029-09     |
| 16.x    | 3.0+    | 11.0+ | 0.1+     | 2023-09      | 2028-09     |
| 15.x    | 2.1+    | 10.0+ | 0.1+     | 2022-09      | 2027-09     |

### Component Versions

| Component | Current | Target | Breaking Changes |
|-----------|---------|--------|------------------|
| Patroni   | 3.1.0   | 3.2.0  | None             |
| Citus     | 12.0    | 12.1   | Minor API changes |
| RuVector  | 0.1.0   | 2.0.0  | Index parameters |
| PostgreSQL| 17.2    | 18.0   | Major upgrade    |

## Upgrade Paths

### Direct Upgrades (Supported)

```
PostgreSQL 17.x → 18.x ✓
PostgreSQL 16.x → 17.x ✓
PostgreSQL 15.x → 16.x ✓

Patroni 3.1.x → 3.2.x ✓
Patroni 3.0.x → 3.2.x ✓

Citus 12.0.x → 12.1.x ✓
Citus 11.x → 12.x ✓

RuVector 0.1.x → 2.0.x ✓
```

### Step Upgrades (Required)

```
PostgreSQL 15.x → 18.x requires:
  15.x → 16.x → 17.x → 18.x

PostgreSQL 14.x → 17.x requires:
  14.x → 15.x → 16.x → 17.x

Patroni 2.x → 3.2.x requires:
  2.x → 3.0.x → 3.2.x

Citus 10.x → 12.x requires:
  10.x → 11.x → 12.x
```

## Pre-Upgrade Checklist

### 1. System Requirements

- [ ] PostgreSQL target version installed
- [ ] Sufficient disk space (2x current data size + 20%)
- [ ] Backup storage available (3x data size minimum)
- [ ] Network bandwidth adequate for replication
- [ ] Memory: 25% more than current usage
- [ ] CPU: Same or better than current nodes

### 2. Backup Verification

- [ ] Full pg_dumpall backup completed
- [ ] PITR WAL archives up to date
- [ ] Backup tested and validated
- [ ] Backup retention policy reviewed
- [ ] Offsite backup copy confirmed
- [ ] Backup restoration procedure documented

### 3. Compatibility Checks

- [ ] Application compatibility tested
- [ ] Extension versions compatible
- [ ] Client library versions checked
- [ ] SQL syntax compatibility verified
- [ ] Breaking changes documented
- [ ] Deprecated features identified

### 4. Cluster Health

- [ ] All nodes running and healthy
- [ ] Replication lag < 10MB on all replicas
- [ ] No long-running transactions (> 1 hour)
- [ ] No prepared transactions pending
- [ ] Autovacuum up to date (no bloat)
- [ ] Index health verified
- [ ] Table statistics current

### 5. Maintenance Window

- [ ] Maintenance window scheduled
- [ ] Stakeholders notified
- [ ] Rollback plan documented
- [ ] On-call team assigned
- [ ] Monitoring alerts configured
- [ ] Communication plan ready

## Upgrade Procedures

### PostgreSQL Major Version Upgrade

#### Estimated Downtime

| Database Size | Downtime (pg_upgrade) | Downtime (rolling) |
|---------------|------------------------|---------------------|
| < 10 GB       | 5-15 minutes          | 0 minutes           |
| 10-100 GB     | 15-60 minutes         | 0 minutes           |
| 100-500 GB    | 1-3 hours             | 0 minutes           |
| > 500 GB      | 3-8 hours             | 0 minutes           |

Rolling upgrade requires Patroni HA cluster.

#### Step 1: Pre-Upgrade Preparation

```bash
# 1. Check current version
psql -U postgres -c "SELECT version()"

# 2. Check for prepared transactions
psql -U postgres -c "SELECT * FROM pg_prepared_xacts"

# 3. Check for replication slots
psql -U postgres -c "SELECT * FROM pg_replication_slots"

# 4. List all extensions
psql -U postgres -c "SELECT extname, extversion FROM pg_extension"

# 5. Check disk space
df -h /var/lib/postgresql

# 6. Create backup
./scripts/backup/backup_cluster.sh --full --compress
```

#### Step 2: Perform Upgrade

##### Option A: Single-Node Upgrade (Downtime Required)

```bash
# Run automated upgrade script
sudo -u postgres ./scripts/upgrade/upgrade-postgresql.sh 17 18

# Monitor progress
tail -f /var/lib/postgresql/backups/upgrade_17_to_18_*/upgrade.log
```

##### Option B: Rolling Upgrade (Zero Downtime)

```bash
# Requires Patroni HA cluster with 3+ nodes

# 1. Upgrade replicas first
for replica in replica1 replica2; do
    ssh $replica "sudo -u postgres ./scripts/upgrade/upgrade-postgresql.sh 17 18"
done

# 2. Perform switchover
patronictl -c /etc/patroni.yml switchover --candidate replica1

# 3. Upgrade old primary
ssh primary "sudo -u postgres ./scripts/upgrade/upgrade-postgresql.sh 17 18"

# 4. Verify cluster
patronictl -c /etc/patroni.yml list
```

#### Step 3: Post-Upgrade Validation

```bash
# 1. Check new version
psql -U postgres -c "SELECT version()"

# 2. Run ANALYZE
vacuumdb -U postgres --all --analyze-only -j$(nproc)

# 3. Check extensions
psql -U postgres -c "SELECT extname, extversion FROM pg_extension"

# 4. Test queries
psql -U postgres -f tests/sql/smoke_tests.sql

# 5. Check replication
psql -U postgres -c "SELECT * FROM pg_stat_replication"

# 6. Monitor performance
pgbench -U postgres -c 10 -t 1000 postgres
```

### Patroni Upgrade

#### Estimated Downtime: 0 minutes (rolling upgrade)

```bash
# Upgrade Patroni on all nodes
./scripts/upgrade/upgrade-cluster.sh patroni 3.2.0

# Verification
for node in node1 node2 node3; do
    ssh $node "patronictl version"
done
```

### Citus Upgrade

#### Estimated Downtime: 10-30 minutes (shard rebalancing)

```bash
# Upgrade Citus extension
./scripts/upgrade/upgrade-cluster.sh citus 12.1

# Verification
psql -U postgres -c "SELECT * FROM citus_version()"
psql -U postgres -c "SELECT * FROM citus_get_active_worker_nodes()"
```

### RuVector Upgrade

#### Estimated Downtime: 5-15 minutes per database (index rebuild)

```bash
# Upgrade RuVector extension
./scripts/upgrade/upgrade-ruvector.sh 0.1.0 2.0.0

# Verification
psql -U postgres -c "SELECT extversion FROM pg_extension WHERE extname = 'ruvector'"

# Performance test
psql -U postgres -c "
    EXPLAIN ANALYZE
    SELECT id FROM embeddings
    ORDER BY embedding <=> '[0.1,0.2,0.3]'::ruvector
    LIMIT 10
"
```

## Downtime Estimates

### Single-Node Cluster

| Upgrade Type        | 10 GB    | 100 GB   | 500 GB   | 1 TB     |
|---------------------|----------|----------|----------|----------|
| PostgreSQL (major)  | 15 min   | 45 min   | 3 hours  | 6 hours  |
| PostgreSQL (minor)  | 5 min    | 5 min    | 5 min    | 5 min    |
| Patroni             | 2 min    | 2 min    | 2 min    | 2 min    |
| Citus               | 10 min   | 20 min   | 30 min   | 45 min   |
| RuVector            | 5 min    | 10 min   | 15 min   | 20 min   |

### HA Cluster (3+ Nodes)

| Upgrade Type        | 10 GB    | 100 GB   | 500 GB   | 1 TB     |
|---------------------|----------|----------|----------|----------|
| PostgreSQL (major)  | 0 min    | 0 min    | 0 min    | 0 min    |
| PostgreSQL (minor)  | 0 min    | 0 min    | 0 min    | 0 min    |
| Patroni             | 0 min    | 0 min    | 0 min    | 0 min    |
| Citus               | 10 min   | 20 min   | 30 min   | 45 min   |
| RuVector            | 5 min    | 10 min   | 15 min   | 20 min   |

## Risk Assessment

### Low Risk (Green)

- PostgreSQL minor version upgrades (17.1 → 17.2)
- Patroni upgrades within same major version
- RuVector upgrades within same major version
- Configuration changes

### Medium Risk (Yellow)

- PostgreSQL major version upgrades (17.x → 18.x)
- Citus major version upgrades
- Extension upgrades with breaking changes
- Cluster topology changes

### High Risk (Red)

- Multi-version PostgreSQL upgrades (15.x → 18.x)
- Downgrade operations (always avoid)
- Cluster migration to different hardware
- Major configuration changes (shared_buffers, max_connections)

## Testing Procedures

### Pre-Production Testing

```bash
# 1. Create test cluster with production data
./scripts/testing/create_test_cluster.sh --clone-from-production

# 2. Run upgrade on test cluster
./scripts/upgrade/upgrade-postgresql.sh 17 18

# 3. Run test suite
./tests/run_integration_tests.sh

# 4. Performance benchmark
pgbench -i -s 100 test_db
pgbench -c 10 -t 1000 test_db

# 5. Application smoke tests
./tests/app_smoke_tests.sh
```

### Production Testing (After Upgrade)

```bash
# 1. Smoke tests
./tests/smoke_tests.sh

# 2. Performance validation
./tests/performance_tests.sh

# 3. Replication validation
./tests/replication_tests.sh

# 4. Application integration tests
./tests/app_integration_tests.sh

# 5. Monitoring validation
./tests/monitoring_tests.sh
```

## Emergency Rollback

### Rollback Decision Tree

```
Is data corrupted? → YES → Use pg_dumpall backup
                  → NO  ↓

Is performance degraded? → YES → Restore from backup
                         → NO  ↓

Are there errors? → YES → Check error severity
                  → NO  → Continue monitoring
```

### Rollback Procedures

#### Quick Rollback (< 30 minutes since upgrade)

```bash
# 1. Stop new PostgreSQL
sudo systemctl stop postgresql@18-main

# 2. Restore old data directory
cd /var/lib/postgresql/backups/upgrade_17_to_18_*
./rollback.sh

# 3. Start old PostgreSQL
sudo systemctl start postgresql@17-main

# 4. Verify
psql -U postgres -c "SELECT version()"
```

#### Full Rollback (> 30 minutes since upgrade)

```bash
# 1. Restore from pg_dumpall backup
cd /var/lib/postgresql/backups
latest_backup=$(ls -t pg_dumpall_*.sql.gz | head -1)

# 2. Stop PostgreSQL
sudo systemctl stop postgresql@18-main

# 3. Reinitialize old cluster
sudo -u postgres /usr/lib/postgresql/17/bin/initdb \
    -D /var/lib/postgresql/17/main

# 4. Start old cluster
sudo systemctl start postgresql@17-main

# 5. Restore data
gunzip -c $latest_backup | psql -U postgres

# 6. Verify
psql -U postgres -c "SELECT count(*) FROM important_table"
```

## Known Issues and Workarounds

### PostgreSQL 17 → 18

**Issue**: Change in replication protocol
**Workaround**: Upgrade all nodes to 18.0.1+ to avoid replication issues

**Issue**: New GUC parameter defaults
**Workaround**: Review postgresql.conf and adjust:
- `max_parallel_workers` increased from 8 to 16
- `maintenance_work_mem` calculation changed

### Citus 12.0 → 12.1

**Issue**: Shard rebalancer may cause high I/O
**Workaround**: Schedule during low-traffic hours

**Issue**: New index types require manual rebuild
**Workaround**: Run `REINDEX CONCURRENTLY` on affected indexes

### RuVector 0.1 → 2.0

**Issue**: HNSW index parameters changed
**Workaround**: Indexes automatically rebuilt during upgrade

**Issue**: Distance function signatures changed
**Workaround**: Update queries to use new function names:
- `ruvector_cosine_distance()` → `cosine_distance()`
- `ruvector_l2_distance()` → `l2_distance()`

## Post-Upgrade Monitoring

### First 24 Hours

Monitor these metrics closely:

- **Performance**: Query response time, throughput
- **Replication**: Lag, slot usage, WAL generation rate
- **Resources**: CPU, memory, disk I/O, disk space
- **Errors**: PostgreSQL logs, application errors
- **Connections**: Active connections, connection pool usage

### Alerting Thresholds

```yaml
alerts:
  # Performance
  - name: slow_queries
    threshold: "queries > 1000ms for 5 minutes"

  # Replication
  - name: replication_lag
    threshold: "lag > 50MB for 5 minutes"

  # Resources
  - name: high_cpu
    threshold: "cpu > 80% for 10 minutes"

  - name: disk_space
    threshold: "free_space < 20%"

  # Errors
  - name: error_rate
    threshold: "errors > 10/minute for 5 minutes"
```

## Support and Troubleshooting

### Common Issues

1. **Upgrade fails with "prepared transactions" error**
   - Commit or rollback all prepared transactions before upgrading
   - `SELECT gid, prepared, owner, database FROM pg_prepared_xacts`

2. **Replication breaks after upgrade**
   - Rebuild replication slots
   - Check client library compatibility

3. **Performance degradation after upgrade**
   - Run `ANALYZE` on all tables
   - Review query plans for regressions
   - Check for missing indexes

### Getting Help

- Documentation: `/docs/`
- Logs: `/var/lib/postgresql/backups/*/upgrade.log`
- Community: [PostgreSQL mailing lists](https://www.postgresql.org/list/)
- Support: [Patroni GitHub](https://github.com/patroni/patroni)

## Appendix

### Useful Commands

```bash
# Check PostgreSQL version
psql -U postgres -c "SELECT version()"

# Check cluster status
patronictl -c /etc/patroni.yml list

# Check replication lag
psql -U postgres -c "SELECT * FROM pg_stat_replication"

# Check extension versions
psql -U postgres -c "SELECT extname, extversion FROM pg_extension"

# Check Citus cluster
psql -U postgres -c "SELECT * FROM citus_get_active_worker_nodes()"

# Performance test
pgbench -i -s 100 postgres
pgbench -c 10 -t 1000 postgres
```

### Additional Resources

- [PostgreSQL Upgrade Guide](https://www.postgresql.org/docs/current/upgrading.html)
- [pg_upgrade Documentation](https://www.postgresql.org/docs/current/pgupgrade.html)
- [Patroni Documentation](https://patroni.readthedocs.io/)
- [Citus Upgrade Guide](https://docs.citusdata.com/en/stable/admin_guide/upgrading_citus.html)
