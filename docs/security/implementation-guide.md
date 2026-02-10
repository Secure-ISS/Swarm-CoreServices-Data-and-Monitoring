# Security Implementation Guide
# Distributed PostgreSQL Cluster

## Quick Start

This guide provides step-by-step instructions for implementing the security architecture for the distributed PostgreSQL mesh.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Phase 1: Network Security](#phase-1-network-security)
3. [Phase 2: TLS/Certificate Setup](#phase-2-tlscertificate-setup)
4. [Phase 3: Authentication & Authorization](#phase-3-authentication--authorization)
5. [Phase 4: Data Protection](#phase-4-data-protection)
6. [Phase 5: Audit & Monitoring](#phase-5-audit--monitoring)
7. [Verification & Testing](#verification--testing)
8. [Maintenance](#maintenance)

---

## Prerequisites

### Required Software

- Docker 20.10+ with Swarm mode enabled
- PostgreSQL 15+ (via ruvnet/ruvector-postgres image)
- OpenSSL 1.1.1+
- Bash 4.0+

### Required Knowledge

- Docker Swarm orchestration
- PostgreSQL administration
- TLS/SSL certificate management
- Network security concepts

### Access Requirements

- Root/sudo access to Docker hosts
- PostgreSQL superuser credentials
- Docker Swarm manager access

---

## Phase 1: Network Security

### 1.1 Enable Docker Overlay Encryption

**Status**: ✅ Already implemented in `deployment/docker-swarm/stack.yml`

Verify encryption is enabled:

```bash
docker network inspect postgres_mesh | grep -A2 "driver_opts"
```

Expected output:
```json
"driver_opts": {
    "encrypted": "true"
}
```

### 1.2 Configure Firewall Rules

Create firewall rules to restrict access:

```bash
# Allow PostgreSQL only from application subnets
sudo iptables -A INPUT -p tcp --dport 5432 -s 10.0.0.0/16 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 5432 -j DROP

# Allow PgBouncer only from application subnets
sudo iptables -A INPUT -p tcp --dport 6432 -s 10.0.0.0/16 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 6432 -j DROP

# Save rules
sudo iptables-save | sudo tee /etc/iptables/rules.v4
```

**Verification**:
```bash
sudo iptables -L -n | grep 5432
```

### 1.3 Network Segmentation

Isolate PostgreSQL network from other services:

```bash
# Create dedicated network for PostgreSQL (already done in stack.yml)
docker network create \
  --driver overlay \
  --attachable \
  --opt encrypted=true \
  --subnet 10.0.10.0/24 \
  postgres_mesh
```

**Timeline**: 1 hour

---

## Phase 2: TLS/Certificate Setup

### 2.1 Generate Certificates

Run the certificate generation script:

```bash
cd /home/matt/projects/Distributed-Postgress-Cluster
./scripts/security/generate-certificates.sh
```

This will create:
- CA certificate (`ca.crt`)
- Server certificates (coordinator, workers)
- Client certificates (replication, application, admin)
- DH parameters (`dhparams.pem`)

**Output location**: `/home/matt/projects/Distributed-Postgress-Cluster/config/security/certs/`

### 2.2 Deploy Certificates to Docker Swarm

```bash
cd config/security/certs

# Create Docker secrets for certificates
docker secret create postgres_ca_cert ca.crt
docker secret create postgres_coordinator_cert coordinator.crt
docker secret create postgres_coordinator_key coordinator.key

# Worker certificates
for i in 1 2 3; do
    docker secret create postgres_worker_${i}_cert worker-${i}.crt
    docker secret create postgres_worker_${i}_key worker-${i}.key
done

# Client certificates
docker secret create postgres_replicator_cert replicator.crt
docker secret create postgres_replicator_key replicator.key
docker secret create postgres_admin_cert admin_client.crt
docker secret create postgres_admin_key admin_client.key
```

### 2.3 Update Docker Stack Configuration

Edit `deployment/docker-swarm/stack.yml` to mount certificates:

```yaml
services:
  coordinator:
    secrets:
      - source: postgres_ca_cert
        target: /run/secrets/postgres_ca_cert
      - source: postgres_coordinator_cert
        target: /run/secrets/postgres_server_cert
      - source: postgres_coordinator_key
        target: /run/secrets/postgres_server_key
    configs:
      - source: postgresql_tls_config
        target: /etc/postgresql/conf.d/tls.conf
```

### 2.4 Apply TLS Configuration

```bash
# Copy TLS configuration to Docker config
docker config create postgresql_tls_config config/security/postgresql-tls.conf

# Deploy/update stack
docker stack deploy -c deployment/docker-swarm/stack.yml postgres-cluster
```

### 2.5 Verify TLS Configuration

```bash
# Check SSL is enabled
docker exec $(docker ps -qf name=coordinator) \
    psql -U postgres -c "SHOW ssl;"

# Check TLS version
docker exec $(docker ps -qf name=coordinator) \
    psql -U postgres -c "SELECT version, cipher FROM pg_stat_ssl;"

# Test connection with client certificate
psql "host=localhost port=5432 dbname=distributed_postgres_cluster user=cluster_admin \
      sslmode=verify-full \
      sslcert=config/security/certs/admin_client.crt \
      sslkey=config/security/certs/admin_client.key \
      sslrootcert=config/security/certs/ca.crt"
```

**Timeline**: 2-3 hours

---

## Phase 3: Authentication & Authorization

### 3.1 Configure pg_hba.conf

```bash
# Copy secure pg_hba.conf to container
docker cp config/security/pg_hba.conf \
    $(docker ps -qf name=coordinator):/var/lib/postgresql/data/pg_hba.conf

# Reload configuration
docker exec $(docker ps -qf name=coordinator) \
    psql -U postgres -c "SELECT pg_reload_conf();"
```

### 3.2 Create Roles and Users

```bash
# Run role creation script
docker exec -i $(docker ps -qf name=coordinator) \
    psql -U postgres -d distributed_postgres_cluster < config/security/create-roles.sql
```

### 3.3 Apply RBAC Policies

```bash
# Apply role-based access control
docker exec -i $(docker ps -qf name=coordinator) \
    psql -U postgres -d distributed_postgres_cluster < config/security/rbac-policies.sql
```

### 3.4 Set User Passwords

```bash
# Generate strong passwords
REPLICATOR_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-24)
APP_WRITER_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-24)
APP_READER_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-24)

# Store in Docker secrets
echo "$REPLICATOR_PASSWORD" | docker secret create replication_password -
echo "$APP_WRITER_PASSWORD" | docker secret create app_writer_password -
echo "$APP_READER_PASSWORD" | docker secret create app_reader_password -

# Update PostgreSQL roles
docker exec $(docker ps -qf name=coordinator) \
    psql -U postgres -d distributed_postgres_cluster <<EOF
ALTER USER replicator WITH PASSWORD '$REPLICATOR_PASSWORD';
ALTER USER app_writer WITH PASSWORD '$APP_WRITER_PASSWORD';
ALTER USER app_reader WITH PASSWORD '$APP_READER_PASSWORD';
EOF

# Save passwords to secure vault (example with 1Password CLI)
# op create item --category=password --title="PostgreSQL app_writer" password="$APP_WRITER_PASSWORD"
```

### 3.5 Verify Authentication

```bash
# Test app_writer authentication
PGPASSWORD="$APP_WRITER_PASSWORD" psql -h localhost -U app_writer \
    -d distributed_postgres_cluster -c "SELECT current_user, current_database();"

# Test app_reader authentication
PGPASSWORD="$APP_READER_PASSWORD" psql -h localhost -U app_reader \
    -d distributed_postgres_cluster -c "SELECT current_user, current_database();"
```

**Timeline**: 2-3 hours

---

## Phase 4: Data Protection

### 4.1 Enable Column-Level Encryption

```bash
# Install pgcrypto extension
docker exec $(docker ps -qf name=coordinator) \
    psql -U postgres -d distributed_postgres_cluster -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

# Example: Encrypt sensitive column
docker exec $(docker ps -qf name=coordinator) \
    psql -U postgres -d distributed_postgres_cluster <<EOF
-- Add encrypted column
ALTER TABLE users ADD COLUMN ssn_encrypted BYTEA;

-- Encrypt existing data
UPDATE users SET ssn_encrypted = pgp_sym_encrypt(ssn, 'encryption_key_from_vault');

-- Drop plaintext column
ALTER TABLE users DROP COLUMN ssn;

-- Rename encrypted column
ALTER TABLE users RENAME COLUMN ssn_encrypted TO ssn;
EOF
```

### 4.2 Setup Encrypted Backups

```bash
# Create backup encryption key
BACKUP_ENCRYPTION_KEY=$(openssl rand -base64 32)
echo "$BACKUP_ENCRYPTION_KEY" | docker secret create backup_encryption_key -

# Deploy backup script
docker cp scripts/security/backup-encrypted.sh \
    $(docker ps -qf name=backup-agent):/usr/local/bin/

# Schedule encrypted backups (via cron)
docker exec $(docker ps -qf name=backup-agent) \
    bash -c 'echo "0 2 * * * /usr/local/bin/backup-encrypted.sh" | crontab -'
```

### 4.3 Enable Row-Level Security

```bash
# Apply RLS policies (already in rbac-policies.sql)
docker exec $(docker ps -qf name=coordinator) \
    psql -U postgres -d distributed_postgres_cluster <<EOF
-- Enable RLS on tenant_data table
ALTER TABLE tenant_data ENABLE ROW LEVEL SECURITY;

-- Create isolation policy
CREATE POLICY tenant_isolation ON tenant_data
    FOR ALL
    TO app_writer, app_reader
    USING (tenant_id = current_setting('app.current_tenant_id')::int);
EOF
```

### 4.4 Verify Encryption

```bash
# Test column encryption
docker exec $(docker ps -qf name=coordinator) \
    psql -U postgres -d distributed_postgres_cluster <<EOF
-- Encrypt test data
SELECT pgp_sym_encrypt('sensitive_data', 'test_key');

-- Decrypt test data
SELECT pgp_sym_decrypt(pgp_sym_encrypt('sensitive_data', 'test_key'), 'test_key');
EOF

# Test RLS
docker exec $(docker ps -qf name=coordinator) \
    psql -U app_writer -d distributed_postgres_cluster <<EOF
-- Set tenant context
SET app.current_tenant_id = 1;

-- Query should only return tenant 1 data
SELECT * FROM tenant_data;
EOF
```

**Timeline**: 2-3 hours

---

## Phase 5: Audit & Monitoring

### 5.1 Enable Audit Logging

```bash
# Install pgaudit extension
docker exec $(docker ps -qf name=coordinator) \
    psql -U postgres -d distributed_postgres_cluster -c "CREATE EXTENSION IF NOT EXISTS pgaudit;"

# Apply audit configuration
docker config create postgresql_audit_config config/security/audit-logging.conf

# Update stack with audit config
# Add to coordinator service in stack.yml:
#   configs:
#     - source: postgresql_audit_config
#       target: /etc/postgresql/conf.d/audit.conf
```

### 5.2 Setup Log Aggregation

```bash
# Create log directory on host
sudo mkdir -p /var/log/postgresql-cluster
sudo chmod 755 /var/log/postgresql-cluster

# Mount log directory in stack.yml
#   volumes:
#     - /var/log/postgresql-cluster:/var/log/postgresql
```

### 5.3 Deploy Security Monitoring

```bash
# Run security audit script
./scripts/security/audit-security.sh

# Schedule regular audits (cron)
echo "0 6 * * * /path/to/scripts/security/audit-security.sh" | sudo crontab -
```

### 5.4 Setup SIEM Integration (Optional)

```bash
# Install SIEM integration script dependencies
pip3 install psycopg2-binary requests

# Configure SIEM endpoint in script
# Edit scripts/security/siem-integration.py

# Schedule SIEM forwarding (every 5 minutes)
echo "*/5 * * * * /usr/bin/python3 /path/to/scripts/security/siem-integration.py" | sudo crontab -
```

### 5.5 Verify Audit Logging

```bash
# Check audit logs
docker exec $(docker ps -qf name=coordinator) \
    tail -f /var/log/postgresql/postgresql-*.log

# Query audit log table
docker exec $(docker ps -qf name=coordinator) \
    psql -U postgres -d distributed_postgres_cluster -c \
    "SELECT * FROM audit_log ORDER BY timestamp DESC LIMIT 10;"
```

**Timeline**: 2-3 hours

---

## Verification & Testing

### Security Audit Checklist

Run comprehensive security audit:

```bash
./scripts/security/audit-security.sh --output security-report.txt
```

Expected score: **90/100+**

### Penetration Testing

```bash
# Test SQL injection (should fail)
psql -h localhost -U app_writer -d distributed_postgres_cluster \
    -c "SELECT * FROM users WHERE username = 'admin' OR '1'='1';"

# Test privilege escalation (should fail)
psql -h localhost -U app_writer -d distributed_postgres_cluster \
    -c "ALTER USER app_writer WITH SUPERUSER;"

# Test unauthorized table access (should fail)
psql -h localhost -U app_reader -d distributed_postgres_cluster \
    -c "INSERT INTO users (username) VALUES ('hacker');"
```

### Performance Testing

```bash
# Test TLS overhead
time psql -h localhost -U app_writer -d distributed_postgres_cluster \
    -c "SELECT COUNT(*) FROM large_table;"

# Compare with unencrypted connection (for baseline)
# Expected overhead: < 5%
```

### Compliance Testing

```bash
# GDPR: Test data export
psql -h localhost -U cluster_admin -d distributed_postgres_cluster \
    -c "SELECT gdpr_export_user_data('user@example.com');"

# GDPR: Test data erasure
psql -h localhost -U cluster_admin -d distributed_postgres_cluster \
    -c "SELECT gdpr_delete_user_data('user@example.com');"
```

---

## Maintenance

### Daily Tasks

- [ ] Review audit logs for suspicious activity
- [ ] Monitor failed authentication attempts
- [ ] Check system resource usage

### Weekly Tasks

- [ ] Run security audit script
- [ ] Review certificate expiry dates
- [ ] Check backup integrity
- [ ] Update security dashboard

### Monthly Tasks

- [ ] Rotate non-critical credentials
- [ ] Review and update firewall rules
- [ ] Patch PostgreSQL (if updates available)
- [ ] Conduct security training

### Quarterly Tasks

- [ ] Rotate all credentials (90-day cycle)
- [ ] Review and update RBAC policies
- [ ] Conduct penetration testing
- [ ] Review incident response runbook
- [ ] Update security documentation

### Annual Tasks

- [ ] Renew TLS certificates
- [ ] Full security audit by external auditor
- [ ] Review and update security policies
- [ ] Disaster recovery drill

---

## Troubleshooting

### Common Issues

**1. Certificate verification failed**

```bash
# Check certificate validity
openssl verify -CAfile config/security/certs/ca.crt \
    config/security/certs/coordinator.crt

# Check certificate expiry
openssl x509 -enddate -noout -in config/security/certs/coordinator.crt
```

**2. Authentication failed**

```bash
# Check pg_hba.conf
docker exec $(docker ps -qf name=coordinator) \
    cat /var/lib/postgresql/data/pg_hba.conf

# Check password encryption
docker exec $(docker ps -qf name=coordinator) \
    psql -U postgres -c "SHOW password_encryption;"
```

**3. Permission denied**

```bash
# Check role privileges
docker exec $(docker ps -qf name=coordinator) \
    psql -U postgres -d distributed_postgres_cluster -c "\du+ app_writer"

# Check RLS policies
docker exec $(docker ps -qf name=coordinator) \
    psql -U postgres -d distributed_postgres_cluster -c \
    "SELECT * FROM pg_policies WHERE tablename = 'user_data';"
```

---

## Next Steps

After completing this guide:

1. **Document** all credentials in secure vault (HashiCorp Vault, 1Password, etc.)
2. **Test** disaster recovery procedures
3. **Train** team on security policies and incident response
4. **Schedule** regular security reviews
5. **Monitor** security metrics and alerts

---

## References

- [PostgreSQL Security Best Practices](https://www.postgresql.org/docs/current/security.html)
- [Docker Security](https://docs.docker.com/engine/security/)
- [OWASP Database Security](https://owasp.org/www-community/vulnerabilities/Insecure_Database_Access)
- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework)

---

**Document Version**: 1.0
**Last Updated**: 2026-02-10
**Estimated Total Implementation Time**: 10-15 hours
**Difficulty**: Intermediate to Advanced
