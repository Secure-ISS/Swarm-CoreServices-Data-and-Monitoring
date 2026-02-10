# Security Quick Reference Card
# Distributed PostgreSQL Cluster

## Emergency Response

### 🚨 Breach Detected
```bash
# 1. Isolate immediately
iptables -A INPUT -p tcp --dport 5432 -j DROP
docker service scale postgres-coordinator=0

# 2. Preserve evidence
pg_dump -Fc > /forensics/breach-$(date +%Y%m%d-%H%M%S).dump

# 3. Notify
# - Security team: security@example.com
# - Legal (GDPR 72h): legal@example.com
```

### 🔐 Unauthorized Access
```bash
# 1. Terminate suspicious connections
psql -U cluster_admin -d distributed_postgres_cluster <<EOF
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE usename = 'suspicious_user';
EOF

# 2. Lock account
psql -U cluster_admin -c "ALTER USER suspicious_user WITH NOLOGIN;"

# 3. Block IP
iptables -A INPUT -s 192.168.1.100 -j DROP
```

### 🦠 Ransomware
```bash
# 1. ISOLATE (do not pay ransom)
ifconfig eth0 down

# 2. Stop all services
docker service scale postgres-coordinator=0

# 3. Restore from clean backup (pre-infection)
gpg --decrypt /backups/backup_YYYYMMDD.dump.gpg | pg_restore
```

---

## Daily Operations

### Security Audit
```bash
# Run comprehensive audit (50+ checks)
./scripts/security/audit-security.sh

# Target score: 90/100+
```

### Check Certificate Expiry
```bash
# Check all certificates
./config/security/certs/check-cert-expiry.sh

# Renew if < 30 days
./scripts/security/generate-certificates.sh --renew
```

### Review Audit Logs
```bash
# Failed logins
grep "authentication failed" /var/log/postgresql/postgresql-*.log | tail -50

# Privilege escalation attempts
psql -U cluster_admin -d distributed_postgres_cluster <<EOF
SELECT log_time, user_name, query
FROM pg_log
WHERE command_tag IN ('GRANT', 'REVOKE', 'ALTER ROLE')
ORDER BY log_time DESC LIMIT 20;
EOF
```

### Monitor Active Connections
```bash
# View all connections
psql -U monitor -d distributed_postgres_cluster <<EOF
SELECT
    usename,
    application_name,
    client_addr,
    state,
    query_start,
    query
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY query_start;
EOF
```

---

## Common Tasks

### Add New User
```bash
# 1. Create role
psql -U cluster_admin -d distributed_postgres_cluster <<EOF
CREATE ROLE new_user WITH LOGIN PASSWORD 'strong_password_16+chars';
GRANT app_writer TO new_user;
EOF

# 2. Update pg_hba.conf (add IP)
echo "hostssl distributed_postgres_cluster new_user 10.0.1.100/32 scram-sha-256 clientcert=verify-full" \
    >> config/security/pg_hba.conf

# 3. Reload config
psql -U postgres -c "SELECT pg_reload_conf();"
```

### Rotate Credentials
```bash
# Automated 90-day rotation
export ADMIN_PASSWORD="your_admin_password"
./scripts/security/rotate-credentials.sh

# Manual rotation for specific user
psql -U cluster_admin -d distributed_postgres_cluster <<EOF
ALTER USER app_writer WITH PASSWORD '$(openssl rand -base64 32)';
EOF
```

### Grant Table Access
```bash
# Read-only
psql -U cluster_admin -d distributed_postgres_cluster <<EOF
GRANT SELECT ON TABLE sensitive_data TO app_reader;
EOF

# Read-write
psql -U cluster_admin -d distributed_postgres_cluster <<EOF
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE user_data TO app_writer;
EOF
```

### Enable RLS on Table
```bash
psql -U cluster_admin -d distributed_postgres_cluster <<EOF
-- Enable RLS
ALTER TABLE tenant_data ENABLE ROW LEVEL SECURITY;

-- Create isolation policy
CREATE POLICY tenant_isolation ON tenant_data
    FOR ALL
    TO app_writer, app_reader
    USING (tenant_id = current_setting('app.current_tenant_id')::int);
EOF
```

---

## Troubleshooting

### Connection Refused
```bash
# Check PostgreSQL is running
docker ps | grep postgres

# Check listen_addresses
psql -U postgres -c "SHOW listen_addresses;"

# Check firewall
iptables -L -n | grep 5432
```

### Authentication Failed
```bash
# Check pg_hba.conf
docker exec $(docker ps -qf name=coordinator) \
    cat /var/lib/postgresql/data/pg_hba.conf

# Check password encryption
psql -U postgres -c "SHOW password_encryption;"

# Check user exists
psql -U postgres -c "SELECT usename, valuntil FROM pg_user;"
```

### Permission Denied
```bash
# Check role privileges
psql -U postgres -d distributed_postgres_cluster -c "\du+ app_writer"

# Check table permissions
psql -U postgres -d distributed_postgres_cluster -c "\dp table_name"

# Check RLS policies
psql -U postgres -d distributed_postgres_cluster <<EOF
SELECT * FROM pg_policies WHERE tablename = 'table_name';
EOF
```

### SSL/TLS Issues
```bash
# Check SSL is enabled
psql -U postgres -c "SHOW ssl;"

# Test SSL connection
psql "host=pg-coordinator port=5432 dbname=distributed_postgres_cluster \
      user=app_writer sslmode=verify-full \
      sslcert=/path/to/client.crt sslkey=/path/to/client.key \
      sslrootcert=/path/to/ca.crt"

# Check certificate
openssl verify -CAfile ca.crt server.crt
openssl x509 -enddate -noout -in server.crt
```

---

## Key Files

### Documentation
- `docs/security/distributed-security-architecture.md` - Complete architecture
- `docs/security/incident-response-runbook.md` - Emergency procedures
- `docs/security/implementation-guide.md` - Step-by-step setup
- `docs/security/SECURITY_SUMMARY.md` - Executive summary

### Configuration
- `config/security/pg_hba.conf` - Access control rules
- `config/security/postgresql-tls.conf` - TLS configuration
- `config/security/create-roles.sql` - Role definitions
- `config/security/rbac-policies.sql` - Access policies

### Scripts
- `scripts/security/generate-certificates.sh` - Certificate generation
- `scripts/security/rotate-credentials.sh` - Password rotation
- `scripts/security/audit-security.sh` - Security audit

---

## Security Checklist

### Pre-Production
- [ ] Generate TLS certificates
- [ ] Deploy pg_hba.conf with IP restrictions
- [ ] Create all roles (8 roles)
- [ ] Apply RBAC policies
- [ ] Set strong passwords (16+ chars)
- [ ] Enable audit logging
- [ ] Test certificate-based authentication
- [ ] Run security audit (score 90+)

### Post-Deployment
- [ ] Monitor audit logs daily
- [ ] Check certificate expiry weekly
- [ ] Rotate credentials quarterly
- [ ] Run security audit weekly
- [ ] Review firewall rules monthly
- [ ] Test incident response procedures

### Ongoing
- [ ] Patch PostgreSQL monthly
- [ ] Update security docs quarterly
- [ ] External audit annually
- [ ] Disaster recovery drill annually

---

## Connection Examples

### Client Certificate Authentication
```bash
# psql
psql "host=pg-coordinator port=5432 dbname=distributed_postgres_cluster \
      user=app_writer sslmode=verify-full \
      sslcert=/path/to/client.crt sslkey=/path/to/client.key \
      sslrootcert=/path/to/ca.crt"

# Python (psycopg2)
import psycopg2
conn = psycopg2.connect(
    host="pg-coordinator",
    port=5432,
    database="distributed_postgres_cluster",
    user="app_writer",
    sslmode="verify-full",
    sslcert="/path/to/client.crt",
    sslkey="/path/to/client.key",
    sslrootcert="/path/to/ca.crt"
)

# JDBC
jdbc:postgresql://pg-coordinator:5432/distributed_postgres_cluster?\
    user=app_writer&ssl=true&sslmode=verify-full&\
    sslcert=/path/to/client.crt&sslkey=/path/to/client.key&\
    sslrootcert=/path/to/ca.crt
```

### Password Authentication (with TLS)
```bash
PGPASSWORD='password' psql -h pg-coordinator -U app_writer \
    -d distributed_postgres_cluster \
    "sslmode=verify-full sslrootcert=/path/to/ca.crt"
```

---

## Security Contacts

| Role | Contact | Phone | Email |
|------|---------|-------|-------|
| Security Lead | [Name] | [Phone] | security@example.com |
| DBA | [Name] | [Phone] | dba@example.com |
| Network Eng | [Name] | [Phone] | neteng@example.com |
| Legal | [Name] | [Phone] | legal@example.com |

### Escalation
- **Critical**: Security Lead → CTO/CISO (immediate)
- **High**: On-call DBA → Database Manager (15 min)
- **Medium**: Team Lead → Department Manager (1 hour)

---

## Quick Metrics

### Target Security Posture
- Security Score: **90/100+**
- TLS Version: **TLS 1.3**
- Password Encryption: **SCRAM-SHA-256**
- Audit Coverage: **100% DDL/DCL**
- RLS Coverage: **100% multi-tenant tables**
- Failed Auth Rate: **< 1%**
- Certificate Expiry: **> 30 days**

### Current Implementation Status
- Network Security: **95%** ✅
- Authentication: **100%** designed, ready for deployment
- Data Protection: **90%** ✅
- Access Control: **95%** ✅
- Audit & Compliance: **85%** ✅

---

## Commands by Role

### As cluster_admin
```bash
# Create user
CREATE ROLE new_user WITH LOGIN PASSWORD 'password';

# Grant privileges
GRANT app_writer TO new_user;

# Rotate password
ALTER USER app_writer WITH PASSWORD 'new_password';

# View audit logs
SELECT * FROM audit_log ORDER BY timestamp DESC LIMIT 100;
```

### As app_writer
```bash
# Query data (with RLS)
SET app.current_tenant_id = 1;
SELECT * FROM tenant_data;

# Insert data
INSERT INTO users (username, email) VALUES ('john', 'john@example.com');

# Cannot escalate privileges (will fail)
ALTER USER app_writer WITH SUPERUSER;  -- ERROR
```

### As app_reader
```bash
# Read-only queries
SELECT * FROM users WHERE active = true;

# Cannot modify data (will fail)
INSERT INTO users (username) VALUES ('hacker');  -- ERROR
DELETE FROM users;  -- ERROR
```

### As monitor
```bash
# View connections
SELECT * FROM pg_stat_activity;

# View replication status
SELECT * FROM pg_stat_replication;

# View SSL connections
SELECT * FROM pg_stat_ssl;
```

---

**Keep this card accessible for quick reference!**

**Version**: 1.0
**Last Updated**: 2026-02-10
**Review**: Quarterly
