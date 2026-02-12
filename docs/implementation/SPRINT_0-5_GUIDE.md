# Sprint 0-5 Implementation Guide (Weeks 1-6)
## Infrastructure → High Availability Deployment

---

## SPRINT 0: Week 1 - Foundation & Prerequisites

### Tasks
1. **Environment Setup**
   ```bash
   # Clone and initialize
   git clone <repo> && cd Distributed-Postgress-Cluster
   cp .env.example .env

   # Install dependencies
   python -m venv .venv && source .venv/bin/activate
   pip install -r requirements.txt

   # Start base PostgreSQL
   docker run -d --name postgres-base \
     -e POSTGRES_PASSWORD=postgres \
     -p 5432:5432 postgres:15-bullseye
   ```

2. **RuVector Extension Installation**
   ```bash
   # Build RuVector extension
   docker build -t ruvector-pg:2.0 docker/
   docker run -d --name ruvector-db \
     -e POSTGRES_PASSWORD=ruvector_2026 \
     -p 5432:5432 ruvector-pg:2.0

   # Verify extension
   psql -h localhost -U postgres -c "SELECT * FROM pg_extension WHERE extname='ruvector';"
   ```

3. **Database Initialization**
   ```bash
   # Initialize public schema
   psql -h localhost -f scripts/sql/init-ruvector.sql

   # Initialize claude_flow schema
   psql -h localhost -f scripts/sql/init-claude-flow-schema.sql

   # Create indexes
   python scripts/db_health_check.py
   ```

4. **Dual Database Setup**
   ```bash
   # Project database
   createdb -h localhost distributed_postgres_cluster

   # Shared database
   createdb -h localhost claude_flow_shared

   # Initialize both schemas
   python src/db/__init__.py
   ```

### Success Criteria
- PostgreSQL 15+ running on :5432
- RuVector 2.0 extension installed and verified
- Both project and shared databases created
- All HNSW indexes created
- `scripts/db_health_check.py` returns all PASS

### Verification
```bash
# Health check
python scripts/db_health_check.py

# Vector test
python -c "from src.db.vector_ops import store_embedding; print('OK')"

# Connection pool test
python scripts/test_pool_capacity.py --agents 5
```

---

## SPRINT 1: Week 2 - Connection Pooling & Monitoring

### Tasks
1. **PgBouncer Configuration**
   ```bash
   # Install PgBouncer
   sudo apt-get install pgbouncer

   # Configure pooling
   cp config/pgbouncer/pgbouncer.ini /etc/pgbouncer/

   # Set credentials
   cat > /etc/pgbouncer/userlist.txt <<EOF
   "dpg_cluster" "md5<hash>"
   "shared_user" "md5<hash>"
   EOF

   # Start service
   sudo systemctl start pgbouncer
   sudo systemctl enable pgbouncer
   ```

2. **Connection Pool Tuning**
   ```bash
   # Edit pgbouncer.ini
   # - pool_mode = transaction
   # - max_client_conn = 10000
   # - default_pool_size = 25
   # - reserve_pool_size = 5
   # - reserve_pool_timeout = 3

   # Test capacity
   python scripts/test_pool_capacity.py --agents 40 --duration 300
   ```

3. **Prometheus Monitoring Setup**
   ```bash
   # Install Prometheus
   wget https://github.com/prometheus/prometheus/releases/download/v2.40.0/prometheus-2.40.0.linux-amd64.tar.gz
   tar xvfz prometheus-2.40.0.linux-amd64.tar.gz

   # Configure scrape targets
   cp config/prometheus/prometheus.yml /etc/prometheus/

   # Start Prometheus
   ./prometheus --config.file=config/prometheus/prometheus.yml
   ```

4. **Grafana Dashboards**
   ```bash
   # Install Grafana
   sudo apt-get install grafana-server

   # Deploy dashboards
   cp config/grafana/dashboards/*.json \
     /var/lib/grafana/dashboards/

   # Configure datasources
   sudo systemctl restart grafana-server
   # Access: http://localhost:3000
   ```

### Success Criteria
- PgBouncer listening on :6432
- 40+ concurrent connections sustained
- Prometheus scraping metrics every 15s
- Grafana dashboard showing connection pool status
- Zero connection timeouts in 5-minute load test

### Verification
```bash
# Connection pool status
psql -h localhost -p 6432 -c "SHOW STATS"

# Prometheus health
curl http://localhost:9090/-/healthy

# Grafana dashboard
curl http://localhost:3000/api/datasources
```

---

## SPRINT 2: Week 3 - etcd Cluster & Consensus

### Tasks
1. **etcd Installation (3 nodes)**
   ```bash
   # Node 1 (Manager)
   ETCD_VER=v3.5.6
   wget -q --show-progress https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz
   tar xzf etcd-${ETCD_VER}-linux-amd64.tar.gz
   sudo mv etcd-${ETCD_VER}-linux-amd64/etcd* /usr/local/bin/

   # Start etcd cluster
   etcd --name etcd1 \
     --listen-client-urls http://0.0.0.0:2379 \
     --advertise-client-urls http://etcd1:2379 \
     --listen-peer-urls http://0.0.0.0:2380 \
     --initial-advertise-peer-urls http://etcd1:2380 \
     --initial-cluster etcd1=http://etcd1:2380,etcd2=http://etcd2:2380,etcd3=http://etcd3:2380 \
     --initial-cluster-state new &
   ```

2. **Cluster Verification**
   ```bash
   # Verify cluster health
   etcdctl --endpoints=http://localhost:2379 endpoint health

   # List members
   etcdctl --endpoints=http://localhost:2379 member list

   # Test write/read
   etcdctl --endpoints=http://localhost:2379 put test-key test-value
   etcdctl --endpoints=http://localhost:2379 get test-key
   ```

3. **Patroni Configuration**
   ```bash
   # Install Patroni
   pip install patroni[etcd]

   # Configure Patroni
   cp docker/patroni/patroni.yml /etc/patroni/

   # Edit for local setup:
   # - DCS: etcd
   # - etcd_host: localhost:2379
   # - postgresql.data_dir: /var/lib/postgresql/15/main
   ```

4. **HAProxy Load Balancer**
   ```bash
   # Install HAProxy
   sudo apt-get install haproxy

   # Configure for Patroni
   cp docker/patroni/haproxy.cfg /etc/haproxy/

   # Start service
   sudo systemctl restart haproxy
   sudo systemctl enable haproxy
   ```

### Success Criteria
- 3-node etcd cluster passing health checks
- etcdctl can read/write to cluster
- Patroni nodes registered in etcd
- HAProxy routing to primary PostgreSQL
- Leader election working (kill primary, verify failover)

### Verification
```bash
# etcd cluster health
etcdctl --endpoints=http://localhost:2379 endpoint health

# Patroni cluster status
patronictl -c /etc/patroni/patroni.yml list

# HAProxy stats
curl http://localhost:8404/stats | grep postgres

# Test failover
# Kill primary, verify secondary promoted
```

---

## SPRINT 3: Week 4 - Patroni HA Cluster Setup

### Tasks
1. **Initialize Patroni Nodes (3 total)**
   ```bash
   # Node 1 (Primary)
   sudo systemctl start postgresql@15-main
   patroni /etc/patroni/patroni.yml > /var/log/patroni.log 2>&1 &

   # Nodes 2-3 (Standby) - same commands
   # Patroni will auto-detect via etcd and join as replicas
   ```

2. **Replication Configuration**
   ```bash
   # Verify replication slots
   psql -h localhost -U postgres -c \
     "SELECT * FROM pg_replication_slots;"

   # Check streaming replication
   psql -h localhost -U postgres -c \
     "SELECT client_addr, state, write_lag FROM pg_stat_replication;"
   ```

3. **RuVector Extension on All Nodes**
   ```bash
   # Install on primary (replicates to standbys)
   psql -h localhost -U postgres -c \
     "CREATE EXTENSION ruvector;"

   # Verify on standbys
   psql -h standby1 -U postgres -c \
     "SELECT * FROM pg_extension WHERE extname='ruvector';"
   ```

4. **Synchronous Replication Setup**
   ```bash
   # Configure in patroni.yml:
   # synchronous_mode: true
   # synchronous_mode_strict: false
   # synchronous_commit: remote_apply

   # Reload Patroni
   patronictl -c /etc/patroni/patroni.yml reload cluster-name
   ```

### Success Criteria
- 3 Patroni nodes running (1 primary, 2 standby)
- Streaming replication lag < 1 second
- Synchronous replication mode active
- RuVector extension on all nodes
- Automatic failover tested and working (<30s RTO)

### Verification
```bash
# Cluster status
patronictl -c /etc/patroni/patroni.yml list

# Replication lag
psql -c "SELECT slot_name, restart_lsn FROM pg_replication_slots;"

# Extension check
psql -c "SELECT extname FROM pg_extension WHERE extname='ruvector';"

# Test failover
# Kill primary, measure time to new primary elected
```

---

## SPRINT 4: Week 5 - Backup & Disaster Recovery

### Tasks
1. **pgBackRest Installation**
   ```bash
   # Install pgBackRest
   sudo apt-get install pgbackrest

   # Configure
   sudo cp config/pgbackrest/pgbackrest.conf /etc/pgbackrest/

   # Initialize
   sudo -u postgres pgbackrest --stanza=cluster --log-level-console=info \
     stanza-create --force
   ```

2. **Backup Strategy**
   ```bash
   # Full backup
   sudo -u postgres pgbackrest --stanza=cluster backup

   # Incremental backup (daily)
   sudo -u postgres pgbackrest --stanza=cluster backup \
     --type=incr

   # Schedule via cron
   echo "0 2 * * * postgres pgbackrest --stanza=cluster backup" | \
     sudo tee -a /etc/cron.d/pgbackrest
   ```

3. **Point-in-Time Recovery Testing**
   ```bash
   # List backups
   sudo -u postgres pgbackrest --stanza=cluster info

   # Simulate recovery
   sudo -u postgres pgbackrest --stanza=cluster restore \
     --type=time --target-timeline=latest

   # Restore to specific point
   sudo -u postgres pgbackrest --stanza=cluster restore \
     --type=time --target="2024-02-12 14:30:00"
   ```

4. **Backup Monitoring**
   ```bash
   # Monitor backup success
   python scripts/monitoring/backup_monitor.py

   # Alert on backup failures
   # Configure in: config/prometheus/alerts/database-alerts.yml
   ```

### Success Criteria
- Full backup succeeds and is reproducible
- Incremental backups scheduled daily
- Point-in-time recovery tested and verified
- Backup repository accessible
- Backup monitoring alerts configured

### Verification
```bash
# List backups
pgbackrest --stanza=cluster info

# Backup age
# Ensure full backup < 7 days old

# Test restore on isolated instance
# Measure RTO for various backup points

# Monitor backup size
du -h /var/lib/pgbackrest/
```

---

## SPRINT 5: Week 6 - Security Hardening & Production Readiness

### Tasks
1. **SSL/TLS Configuration**
   ```bash
   # Generate certificates
   sudo bash scripts/generate_ssl_certs.sh

   # PostgreSQL SSL setup
   sudo cp server.crt server.key /var/lib/postgresql/15/main/
   sudo chown postgres:postgres /var/lib/postgresql/15/main/server.*

   # Update postgresql.conf
   echo "ssl = on" | sudo tee -a /etc/postgresql/15/main/postgresql.conf
   echo "ssl_cert_file = 'server.crt'" | \
     sudo tee -a /etc/postgresql/15/main/postgresql.conf
   echo "ssl_key_file = 'server.key'" | \
     sudo tee -a /etc/postgresql/15/main/postgresql.conf

   # Restart PostgreSQL
   sudo systemctl restart postgresql@15-main
   ```

2. **Network Security**
   ```bash
   # Configure pg_hba.conf
   sudo cp docker/pg_hba.conf.ssl /etc/postgresql/15/main/pg_hba.conf

   # Firewall rules
   sudo ufw allow from 10.0.1.0/24 to any port 5432 proto tcp
   sudo ufw allow from 10.0.2.0/24 to any port 5432 proto tcp
   sudo ufw allow from 10.0.3.0/24 to any port 5432 proto tcp

   # HAProxy SSL
   sudo cp docker/pg_hba.conf.ssl /etc/haproxy/certs/
   ```

3. **User & Credential Management**
   ```bash
   # Create restricted users
   psql -h localhost -U postgres <<EOF
   CREATE USER app_user WITH PASSWORD 'secure_password_123';
   CREATE USER readonly_user WITH PASSWORD 'readonly_pass_456';
   GRANT CONNECT ON DATABASE distributed_postgres_cluster TO app_user;
   GRANT USAGE ON SCHEMA public TO readonly_user;
   GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_user;
   EOF

   # Rotate passwords
   python scripts/security/rotate_credentials.sh
   ```

4. **Monitoring & Alerting**
   ```bash
   # Deploy security monitoring
   cp config/prometheus/alerts/security-alerts.yml \
     /etc/prometheus/rules/

   # Configure audit logging
   echo "log_connections = on" | \
     sudo tee -a /etc/postgresql/15/main/postgresql.conf
   echo "log_disconnections = on" | \
     sudo tee -a /etc/postgresql/15/main/postgresql.conf
   echo "log_statement = 'all'" | \
     sudo tee -a /etc/postgresql/15/main/postgresql.conf

   # Reload config
   sudo systemctl reload postgresql@15-main
   ```

5. **Production Readiness Checklist**
   ```bash
   # Run full validation
   bash scripts/production-readiness-check.sh

   # Expected output: All checks PASS
   # - SSL/TLS enabled
   # - HA configured and tested
   # - Backups verified
   # - Monitoring active
   # - Security hardened
   ```

### Success Criteria
- SSL/TLS certificates installed and verified
- All connections encrypted (verify with: psql sslmode=require)
- User roles and permissions configured
- Audit logging enabled
- Security monitoring rules deployed
- Production readiness check 100% PASS

### Verification
```bash
# SSL verification
psql -h localhost sslmode=require -c "SELECT version();"

# Audit log
tail -100 /var/log/postgresql/postgresql-15-main.log | grep "audit"

# Security rules
curl http://localhost:9090/api/v1/rules | grep security

# Full readiness
bash scripts/production-readiness-check.sh
```

---

## Quick Command Reference

### Health Checks
```bash
# Overall health
python scripts/db_health_check.py

# Cluster status
patronictl -c /etc/patroni/patroni.yml list

# etcd cluster
etcdctl --endpoints=http://localhost:2379 endpoint health

# Connection pool
psql -h localhost -p 6432 -c "SHOW STATS"

# RuVector extension
psql -c "SELECT * FROM pg_extension WHERE extname='ruvector';"
```

### Monitoring & Logs
```bash
# PostgreSQL logs
tail -f /var/log/postgresql/postgresql-15-main.log

# Patroni logs
tail -f /var/log/patroni.log

# HAProxy stats
curl http://localhost:8404/stats

# Prometheus metrics
curl http://localhost:9090/api/v1/query?query=pg_up
```

### Troubleshooting
```bash
# Failover test
patronictl -c /etc/patroni/patroni.yml restart cluster-name primary

# Force resync replicas
psql -c "SELECT pg_wal_replay_resume();"

# Check replication slots
psql -c "SELECT * FROM pg_replication_slots;"

# Force failover
patronictl -c /etc/patroni/patroni.yml failover --master=node1 --candidate=node2
```

---

## Dependencies & Timelines

| Sprint | Duration | Key Deliverable | Blocker Removal |
|--------|----------|-----------------|-----------------|
| 0 | Week 1 | Base DB + RuVector | None |
| 1 | Week 2 | Pooling + Monitoring | Sprint 0 complete |
| 2 | Week 3 | etcd + Patroni Config | Sprint 1 healthy |
| 3 | Week 4 | HA Cluster Active | Sprint 2 etcd ready |
| 4 | Week 5 | Backup Strategy | Sprint 3 replication works |
| 5 | Week 6 | Security Hardened | Sprint 4 verified |

**Total Duration:** 6 weeks (42 days)
**Parallel Activities:** Sprints 1-2 can overlap by week
**GO-LIVE:** End of Sprint 5

---

## Success Metrics

### Infrastructure (Sprint 0-1)
- 40+ concurrent connections sustained
- <5ms vector search latency
- Zero connection pool exhaustion

### High Availability (Sprint 2-4)
- <30s automatic failover RTO
- <1s replication lag (synchronous mode)
- 99.95% uptime SLA achievable
- Full backup + recovery tested

### Security (Sprint 5)
- 100% TLS/SSL encryption
- Role-based access control
- Audit logging complete
- Production readiness: 100% PASS

---

**Last Updated:** 2026-02-12
**Status:** Ready for Implementation
**Owner:** DevOps Team
