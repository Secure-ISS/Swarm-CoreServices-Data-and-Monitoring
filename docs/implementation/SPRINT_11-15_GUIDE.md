# Sprint 11-15 Implementation Guide
## Weeks 13-17: Security Hardening → Testing

---

## Sprint 11: Security Foundation (Week 13)

### S11.1: Security Audit & Baseline
- [ ] Run security baseline audit
  ```bash
  bash scripts/security/security-audit.sh
  ```
- [ ] Review audit report in `logs/security-audit.log`
- [ ] Document findings in security issue tracker
- [ ] Create remediation tickets for critical/high findings

### S11.2: Network Hardening
- [ ] Configure firewall rules (iptables/UFW)
  ```bash
  sudo iptables -A INPUT -p tcp --dport 5432 -s 10.0.0.0/8 -j ACCEPT
  sudo iptables -A INPUT -p tcp --dport 5432 -j DROP
  ```
- [ ] Enable fail2ban for PostgreSQL port
  ```bash
  sudo systemctl enable fail2ban
  sudo systemctl start fail2ban
  ```
- [ ] Verify network segmentation (app tier → db tier only)
- [ ] Test connection limits via `pg_hba.conf`

### S11.3: Host Security
- [ ] Disable unnecessary services
  ```bash
  sudo systemctl disable bluetooth avahi-daemon cups
  ```
- [ ] Enable SELinux/AppArmor for PostgreSQL process
- [ ] Configure file permissions
  ```bash
  sudo chmod 700 /var/lib/postgresql
  sudo chmod 600 /etc/postgresql/postgresql.conf
  ```
- [ ] Install security tools: `aide`, `auditd`, `chkrootkit`

---

## Sprint 12: TLS/SSL Implementation (Week 14)

### S12.1: Certificate Generation
- [ ] Generate self-signed certificates (development)
  ```bash
  ./scripts/generate_ssl_certs.sh
  ```
- [ ] For production, obtain CA-signed certificates from trusted CA
- [ ] Verify certificate files exist:
  - [ ] `certs/ca.crt` - CA certificate
  - [ ] `certs/server.crt` - Server certificate
  - [ ] `certs/server.key` - Server private key
  - [ ] `certs/client.crt` - Client certificate
  - [ ] `certs/client.key` - Client private key

### S12.2: Server Configuration
- [ ] Update `postgresql.conf`:
  ```conf
  ssl = on
  ssl_cert_file = '/etc/postgresql/certs/server.crt'
  ssl_key_file = '/etc/postgresql/certs/server.key'
  ssl_ca_file = '/etc/postgresql/certs/ca.crt'
  ssl_min_protocol_version = 'TLSv1.2'
  ssl_ciphers = 'HIGH:MEDIUM:!aNULL'
  ssl_prefer_server_ciphers = on
  ```
- [ ] Restrict key file permissions: `chmod 600 server.key`
- [ ] Restart PostgreSQL
  ```bash
  docker restart ruvector-db  # or: sudo systemctl restart postgresql
  ```

### S12.3: pg_hba.conf Configuration
- [ ] Backup original: `cp pg_hba.conf pg_hba.conf.bak`
- [ ] Update connection rules (PROD: require SSL)
  ```conf
  # TYPE   DATABASE   USER   ADDRESS   METHOD      OPTIONS
  hostssl  all        all    0.0.0.0/0 scram-sha-256
  hostnossl all       all    0.0.0.0/0 reject
  ```
- [ ] Development: use `prefer` mode (allows non-SSL fallback)
- [ ] Reload configuration: `SELECT pg_reload_conf();`

### S12.4: Client Configuration & Testing
- [ ] Update connection strings
  ```
  postgresql://user:pass@host:5432/db?sslmode=verify-full
  ```
- [ ] Test TLS connection
  ```bash
  psql "sslmode=verify-full sslcert=certs/client.crt sslkey=certs/client.key sslrootcert=certs/ca.crt" -d postgres
  ```
- [ ] Verify TLS in pg_stat_ssl view
  ```sql
  SELECT pid, ssl, version FROM pg_stat_ssl WHERE pid = pg_backend_pid();
  ```
- [ ] Update Python connection in `.env`: `SSLMODE=verify-full`
- [ ] Run SSL connection tests
  ```bash
  pytest tests/test_ssl_connection.py -v
  ```

---

## Sprint 13: RBAC & Authentication (Week 15)

### S13.1: Create Database Roles
- [ ] Create cluster role with strong password
  ```sql
  CREATE ROLE dpg_cluster LOGIN PASSWORD 'secure_password_2026';
  ALTER ROLE dpg_cluster CREATEDB CREATEROLE;
  ```
- [ ] Create application role (read-only)
  ```sql
  CREATE ROLE dpg_app LOGIN PASSWORD 'app_password_2026';
  ```
- [ ] Create monitoring role
  ```sql
  CREATE ROLE dpg_monitor LOGIN PASSWORD 'monitor_password_2026';
  ```
- [ ] Create backup role
  ```sql
  CREATE ROLE dpg_backup LOGIN PASSWORD 'backup_password_2026';
  ```

### S13.2: Grant Role Permissions
- [ ] Grant schema permissions
  ```sql
  GRANT USAGE ON SCHEMA public TO dpg_app;
  GRANT USAGE ON SCHEMA public TO dpg_monitor;
  GRANT USAGE ON SCHEMA claude_flow TO dpg_app;
  ```
- [ ] Grant table SELECT to app role
  ```sql
  GRANT SELECT ON ALL TABLES IN SCHEMA public TO dpg_app;
  GRANT SELECT ON ALL TABLES IN SCHEMA claude_flow TO dpg_app;
  ```
- [ ] Grant monitoring permissions
  ```sql
  GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_catalog TO dpg_monitor;
  GRANT SELECT ON pg_stat_statements TO dpg_monitor;
  ```
- [ ] Deny dangerous operations
  ```sql
  REVOKE ALL ON SCHEMA public FROM public;
  REVOKE ALL ON SCHEMA claude_flow FROM public;
  ```

### S13.3: Audit Logging Configuration
- [ ] Enable pgaudit extension
  ```sql
  CREATE EXTENSION IF NOT EXISTS pgaudit;
  ```
- [ ] Configure audit parameters
  ```conf
  pgaudit.log = 'DML,DDL,ROLE'
  pgaudit.log_level = 'NOTICE'
  pgaudit.log_client = on
  ```
- [ ] Create audit table
  ```sql
  CREATE TABLE IF NOT EXISTS audit_log (
    id SERIAL PRIMARY KEY,
    audit_time TIMESTAMP DEFAULT NOW(),
    username TEXT,
    statement TEXT,
    succeeded BOOLEAN
  );
  ```
- [ ] Test audit logging
  ```sql
  CREATE USER test_user; -- Should appear in audit_log
  DROP USER test_user;
  ```

### S13.4: Password Policies
- [ ] Set password expiration
  ```sql
  ALTER ROLE dpg_app VALID UNTIL '2027-02-12';
  ```
- [ ] Enforce scram-sha-256 authentication
  ```conf
  password_encryption = 'scram-sha-256'
  ```
- [ ] Document password rotation schedule (90 days)
- [ ] Create rotation automation script

---

## Sprint 14: Encryption at Rest (Week 16)

### S14.1: Tablespace Encryption
- [ ] Create encrypted tablespace (if using LUKS)
  ```bash
  # Create and mount LUKS partition
  sudo cryptsetup luksFormat /dev/sdb1
  sudo cryptsetup luksOpen /dev/sdb1 pg_encrypted
  sudo mkfs.ext4 /dev/mapper/pg_encrypted
  sudo mkdir -p /var/lib/postgresql/encrypted
  sudo mount /dev/mapper/pg_encrypted /var/lib/postgresql/encrypted
  ```
- [ ] Create PostgreSQL tablespace
  ```sql
  CREATE TABLESPACE encrypted LOCATION '/var/lib/postgresql/encrypted';
  ```
- [ ] Move sensitive tables to encrypted tablespace
  ```sql
  ALTER TABLE memory_entries SET TABLESPACE encrypted;
  ALTER TABLE embeddings SET TABLESPACE encrypted;
  ```

### S14.2: Backup Encryption
- [ ] Enable encryption in backup script
  ```bash
  pg_dump -Fc <db> | openssl enc -aes-256-cbc > backup.sql.enc
  ```
- [ ] Store encryption keys separately (HSM recommended)
- [ ] Document decryption procedure
- [ ] Test backup restore with encryption

### S14.3: Application-Level Encryption
- [ ] Identify sensitive columns (passwords, tokens, PII)
- [ ] Add `pgcrypto` extension
  ```sql
  CREATE EXTENSION pgcrypto;
  ```
- [ ] Encrypt sensitive data
  ```sql
  UPDATE memory_entries
  SET content = pgp_pub_encrypt(content, keys.pubkey)
  FROM keys WHERE keys.id = 1;
  ```

---

## Sprint 15: Testing & Validation (Week 17)

### S15.1: Security Testing
- [ ] Run security tests
  ```bash
  pytest tests/security/ -v --tb=short
  pytest tests/domains/security/test_authentication.py -v
  pytest tests/domains/security/test_cve_remediation.py -v
  ```
- [ ] Execute vulnerability scanning
  ```bash
  bandit -r src/ -ll
  ```
- [ ] Test SQL injection prevention
  ```bash
  pytest tests/demo_security_issues.py -v
  ```
- [ ] Verify credential handling
  ```bash
  pytest tests/security/test_credentials.py -v
  ```

### S15.2: Integration Testing
- [ ] Run integration tests with TLS
  ```bash
  pytest tests/integration/test_distributed_cluster.py -v
  ```
- [ ] Test RBAC enforcement
  ```bash
  pytest tests/integration/test_ha_failover.py -v
  ```
- [ ] Verify encryption at rest
  ```bash
  pytest tests/integration/test_cache_coherence.py -v
  ```
- [ ] Run end-to-end tests
  ```bash
  bash tests/e2e/run_e2e_tests.sh
  ```

### S15.3: Performance & Compliance Testing
- [ ] Benchmark TLS overhead
  ```bash
  pytest tests/benchmark_performance.py::test_ssl_connection_overhead -v
  ```
- [ ] Validate audit logging
  ```sql
  SELECT COUNT(*) FROM audit_log WHERE audit_time > NOW() - INTERVAL '1 hour';
  ```
- [ ] Test failover with security enabled
  ```bash
  bash scripts/patroni/chaos-test.sh
  ```

### S15.4: Compliance Validation
- [ ] CIS Benchmark check
  ```bash
  bash scripts/security/harden-cluster.sh --check
  ```
- [ ] Document compliance status (PCI-DSS, HIPAA, SOC 2, GDPR)
- [ ] Create compliance report
- [ ] Sign-off from security team

### S15.5: Production Readiness
- [ ] Run production readiness check
  ```bash
  bash scripts/production-readiness-check.sh
  ```
- [ ] Verify all security controls active
- [ ] Load test with security enabled
  ```bash
  python scripts/performance/load_test_locust.py --users 100
  ```
- [ ] Schedule post-deployment security audit

---

## Test Execution Plan

### Command Reference
```bash
# Unit tests
pytest tests/unit/ -v

# Security tests
pytest tests/security/ -v

# Integration tests
pytest tests/integration/ -v

# HA tests
pytest tests/ha/ -v

# E2E tests
bash tests/e2e/run_e2e_tests.sh

# All tests with coverage
pytest tests/ --cov=src --cov-report=html

# Specific test
pytest tests/test_ssl_connection.py::test_verify_full_mode -v
```

### Required Passing Tests
- [ ] All unit tests: `tests/unit/`
- [ ] All security tests: `tests/security/`
- [ ] TLS connection tests: `tests/test_ssl_connection.py`
- [ ] RBAC tests: `tests/domains/security/`
- [ ] Integration tests: `tests/integration/`

### Coverage Target: 80% minimum

---

## Rollback Plan (if needed)

### TLS Rollback
```bash
# Restore pg_hba.conf
cp pg_hba.conf.bak pg_hba.conf

# Disable SSL in postgresql.conf
sed -i 's/ssl = on/ssl = off/' postgresql.conf

# Restart PostgreSQL
docker restart ruvector-db
```

### RBAC Rollback
```sql
-- Drop new roles
DROP ROLE IF EXISTS dpg_app;
DROP ROLE IF EXISTS dpg_monitor;
DROP ROLE IF EXISTS dpg_backup;

-- Restore default roles (if backup exists)
```

### Encryption Rollback
```sql
-- Move tables back to default tablespace
ALTER TABLE memory_entries SET TABLESPACE pg_default;
ALTER TABLE embeddings SET TABLESPACE pg_default;

-- Drop encrypted tablespace
DROP TABLESPACE encrypted;
```

---

## Key Files
- `docs/SECURITY_HARDENING.md` - Comprehensive security guide
- `docs/SSL_TLS_SETUP.md` - TLS configuration details
- `scripts/security/harden-cluster.sh` - Automation script
- `scripts/generate_ssl_certs.sh` - Certificate generation
- `tests/test_ssl_connection.py` - SSL connection tests
- `tests/security/` - Security test suite

---

**Status**: Ready for Sprint 11-15 execution
**Last Updated**: 2026-02-12
**Owner**: Security & QA Teams
