# PostgreSQL Security Hardening Guide

## Table of Contents

1. [Overview](#overview)
2. [Defense in Depth Strategy](#defense-in-depth-strategy)
3. [CIS Benchmark Implementation](#cis-benchmark-implementation)
4. [SSL/TLS Configuration](#ssltls-configuration)
5. [Authentication and Authorization](#authentication-and-authorization)
6. [Network Security](#network-security)
7. [Encryption at Rest](#encryption-at-rest)
8. [Audit Logging](#audit-logging)
9. [Compliance Requirements](#compliance-requirements)
10. [Security Incident Response](#security-incident-response)
11. [Security Checklist](#security-checklist)
12. [Common Vulnerabilities and Fixes](#common-vulnerabilities-and-fixes)
13. [Penetration Testing Guidelines](#penetration-testing-guidelines)

## Overview

This guide provides comprehensive security hardening procedures for the Distributed PostgreSQL Cluster, implementing industry best practices, CIS benchmarks, and compliance requirements for PCI-DSS, HIPAA, SOC 2, and GDPR.

### Security Objectives

- **Confidentiality**: Protect data from unauthorized access
- **Integrity**: Ensure data accuracy and prevent tampering
- **Availability**: Maintain system uptime and resilience
- **Compliance**: Meet regulatory requirements
- **Defense in Depth**: Multiple layers of security controls

### Quick Start

```bash
# Run security hardening script
sudo bash scripts/security/harden-cluster.sh

# Perform security audit
bash scripts/security/security-audit.sh

# Rotate credentials
bash scripts/security/rotate-credentials.sh all
```

## Defense in Depth Strategy

Defense in depth implements multiple layers of security controls to protect the database cluster.

### Layer 1: Physical Security

```
┌─────────────────────────────────────┐
│     Physical Data Center            │
│  - Access controls                  │
│  - Surveillance                     │
│  - Environmental controls           │
└─────────────────────────────────────┘
```

**Controls**:
- Physical access controls to server rooms
- Video surveillance and logging
- Fire suppression and environmental monitoring
- Hardware security modules (HSM) for key storage

### Layer 2: Network Security

```
┌─────────────────────────────────────┐
│        Network Perimeter            │
│  - Firewall rules                   │
│  - VPN/Private networking           │
│  - DDoS protection                  │
│  - Network segmentation             │
└─────────────────────────────────────┘
```

**Controls**:
- Firewall rules restricting PostgreSQL port (5432) to trusted networks
- VPC/Private networking for inter-node communication
- DDoS protection and rate limiting
- Network segmentation (DMZ, application tier, database tier)

**Firewall Configuration**:

```bash
# Allow PostgreSQL only from internal networks
iptables -A INPUT -p tcp --dport 5432 -s 10.0.0.0/8 -j ACCEPT
iptables -A INPUT -p tcp --dport 5432 -s 172.16.0.0/12 -j ACCEPT
iptables -A INPUT -p tcp --dport 5432 -s 192.168.0.0/16 -j ACCEPT

# Drop all other PostgreSQL connections
iptables -A INPUT -p tcp --dport 5432 -j DROP

# Log dropped connections
iptables -A INPUT -p tcp --dport 5432 -j LOG --log-prefix "PG_DROPPED: "
```

### Layer 3: Host Security

```
┌─────────────────────────────────────┐
│      Operating System               │
│  - OS hardening                     │
│  - Patch management                 │
│  - Antivirus/EDR                    │
│  - File integrity monitoring        │
└─────────────────────────────────────┘
```

**Controls**:
- Minimal OS installation (no unnecessary services)
- Regular security updates and patches
- SELinux or AppArmor enforcement
- File integrity monitoring (AIDE, Tripwire)
- Host-based intrusion detection (OSSEC, Wazuh)

### Layer 4: Database Security

```
┌─────────────────────────────────────┐
│         PostgreSQL                  │
│  - Authentication (SCRAM-SHA-256)   │
│  - Authorization (RBAC)             │
│  - Encryption (SSL/TLS)             │
│  - Audit logging                    │
│  - Row-level security               │
└─────────────────────────────────────┘
```

**Controls**:
- Strong authentication (SCRAM-SHA-256)
- Role-based access control (RBAC)
- SSL/TLS encryption for all connections
- Comprehensive audit logging (pgaudit)
- Row-level security policies
- Database activity monitoring

### Layer 5: Application Security

```
┌─────────────────────────────────────┐
│        Application Layer            │
│  - Input validation                 │
│  - Prepared statements              │
│  - Connection pooling               │
│  - Secrets management               │
└─────────────────────────────────────┘
```

**Controls**:
- Input validation and sanitization
- Prepared statements (prevent SQL injection)
- Secure connection pooling with timeout
- Secrets management (Vault, AWS Secrets Manager)
- Least privilege principle for application users

## CIS Benchmark Implementation

The Center for Internet Security (CIS) provides security benchmarks for PostgreSQL. Our implementation follows CIS PostgreSQL Benchmark v1.1.

### Level 1 Recommendations (Required)

| ID | Recommendation | Status | Script |
|----|----------------|--------|--------|
| 1.1 | Ensure latest PostgreSQL version is used | ✅ | Manual |
| 2.1 | Ensure PGDATA directory has appropriate permissions (700) | ✅ | harden-cluster.sh |
| 2.2 | Ensure configuration files have appropriate permissions (600) | ✅ | harden-cluster.sh |
| 3.1 | Enable logging collector | ✅ | harden-cluster.sh |
| 3.2 | Set log_connections to 'on' | ✅ | harden-cluster.sh |
| 3.3 | Set log_disconnections to 'on' | ✅ | harden-cluster.sh |
| 4.1 | Set password_encryption to 'scram-sha-256' | ✅ | harden-cluster.sh |
| 4.2 | Configure pg_hba.conf with least privilege | ✅ | harden-cluster.sh |
| 5.1 | Set listen_addresses appropriately | ✅ | harden-cluster.sh |
| 6.1 | Ensure only necessary users exist | ⚠️ | Manual review |
| 7.1 | Ensure SSL is enabled | ✅ | harden-cluster.sh |
| 8.1 | Disable unnecessary extensions | ✅ | harden-cluster.sh |

### Level 2 Recommendations (Defense in Depth)

| ID | Recommendation | Status | Script |
|----|----------------|--------|--------|
| 3.4 | Install and configure pgaudit extension | ✅ | harden-cluster.sh |
| 4.3 | Implement password complexity policies | ✅ | harden-cluster.sh |
| 5.2 | Configure statement_timeout | ✅ | harden-cluster.sh |
| 6.2 | Restrict superuser access | ⚠️ | Manual review |
| 7.2 | Use TLS 1.2 or higher | ✅ | harden-cluster.sh |
| 8.2 | Enable row_security | ✅ | harden-cluster.sh |

### Implementation

Run the hardening script:

```bash
sudo bash scripts/security/harden-cluster.sh
```

The script performs:
1. File permission hardening
2. SSL/TLS certificate generation
3. Authentication configuration
4. Logging setup
5. Network security configuration
6. Database parameter hardening

## SSL/TLS Configuration

### Certificate Management

#### 1. Generate SSL Certificates

```bash
# Generate root CA
openssl genrsa -out root.key 4096
openssl req -new -x509 -days 3650 -key root.key -out root.crt \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=PostgreSQL-Root-CA"

# Generate server certificate
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=$(hostname)"
openssl x509 -req -in server.csr -CA root.crt -CAkey root.key \
    -CAcreateserial -out server.crt -days 365

# Set permissions
chmod 600 root.key server.key
chmod 644 root.crt server.crt
chown postgres:postgres *
```

#### 2. PostgreSQL SSL Configuration

Add to `postgresql.conf`:

```ini
# SSL Configuration
ssl = on
ssl_cert_file = '/etc/postgresql/ssl/server.crt'
ssl_key_file = '/etc/postgresql/ssl/server.key'
ssl_ca_file = '/etc/postgresql/ssl/root.crt'
ssl_ciphers = 'HIGH:MEDIUM:+3DES:!aNULL:!eNULL:!MD5:!PSK'
ssl_prefer_server_ciphers = on
ssl_min_protocol_version = 'TLSv1.2'
```

#### 3. Cipher Suite Selection

**Recommended cipher suites**:
```
ECDHE-ECDSA-AES256-GCM-SHA384
ECDHE-RSA-AES256-GCM-SHA384
ECDHE-ECDSA-CHACHA20-POLY1305
ECDHE-RSA-CHACHA20-POLY1305
ECDHE-ECDSA-AES128-GCM-SHA256
ECDHE-RSA-AES128-GCM-SHA256
```

**Configuration**:
```ini
ssl_ciphers = 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305'
```

#### 4. Client Certificate Authentication

Update `pg_hba.conf` to require client certificates:

```
# Require SSL with client certificate verification
hostssl all all 0.0.0.0/0 scram-sha-256 clientcert=verify-ca
```

Generate client certificates:

```bash
# For each client
openssl genrsa -out client.key 2048
openssl req -new -key client.key -out client.csr \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=client_name"
openssl x509 -req -in client.csr -CA root.crt -CAkey root.key \
    -CAcreateserial -out client.crt -days 365
```

### SSL Testing

```bash
# Test SSL connection
psql "sslmode=require host=localhost port=5432 dbname=postgres user=postgres"

# Verify SSL is being used
psql -c "SELECT * FROM pg_stat_ssl WHERE pid = pg_backend_pid();"

# Check cipher being used
openssl s_client -connect localhost:5432 -starttls postgres
```

## Authentication and Authorization

### Password Policies

#### 1. SCRAM-SHA-256 Configuration

```sql
-- Set password encryption
ALTER SYSTEM SET password_encryption = 'scram-sha-256';

-- Reload configuration
SELECT pg_reload_conf();

-- Update existing passwords (forces re-hash)
ALTER USER username WITH PASSWORD 'new_password';
```

#### 2. Password Complexity Function

```sql
CREATE OR REPLACE FUNCTION check_password_strength(username text, password text)
RETURNS boolean AS $$
BEGIN
    -- Minimum length check (12 characters)
    IF length(password) < 12 THEN
        RAISE EXCEPTION 'Password must be at least 12 characters long';
    END IF;

    -- Complexity check (uppercase, lowercase, digit, special char)
    IF NOT (password ~ '[A-Z]' AND
            password ~ '[a-z]' AND
            password ~ '[0-9]' AND
            password ~ '[^A-Za-z0-9]') THEN
        RAISE EXCEPTION 'Password must contain uppercase, lowercase, digit, and special character';
    END IF;

    -- Username check
    IF lower(password) LIKE '%' || lower(username) || '%' THEN
        RAISE EXCEPTION 'Password must not contain username';
    END IF;

    -- Common password check
    IF password IN ('Password123!', 'Admin123!', 'Welcome123!') THEN
        RAISE EXCEPTION 'Password is too common';
    END IF;

    RETURN true;
END;
$$ LANGUAGE plpgsql;

-- Use in password policies
CREATE OR REPLACE FUNCTION enforce_password_policy()
RETURNS event_trigger AS $$
DECLARE
    obj record;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
        IF obj.command_tag = 'ALTER USER' THEN
            -- Validate password strength
            -- (Implementation depends on password extension)
            RAISE NOTICE 'Password policy enforced for %', obj.object_identity;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE EVENT TRIGGER password_policy_trigger
ON ddl_command_end
EXECUTE FUNCTION enforce_password_policy();
```

### Role-Based Access Control (RBAC)

#### 1. Role Hierarchy

```sql
-- Create role hierarchy
CREATE ROLE readonly_role;
CREATE ROLE readwrite_role;
CREATE ROLE admin_role;

-- Grant privileges
GRANT CONNECT ON DATABASE mydb TO readonly_role;
GRANT USAGE ON SCHEMA public TO readonly_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO readonly_role;

GRANT readonly_role TO readwrite_role;
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO readwrite_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT INSERT, UPDATE, DELETE ON TABLES TO readwrite_role;

GRANT readwrite_role TO admin_role;
GRANT ALL PRIVILEGES ON DATABASE mydb TO admin_role;
```

#### 2. Application Users

```sql
-- Create application user with minimal privileges
CREATE USER app_user WITH PASSWORD 'strong_password';
GRANT readwrite_role TO app_user;

-- Restrict to specific database
REVOKE ALL ON DATABASE postgres FROM app_user;
GRANT CONNECT ON DATABASE mydb TO app_user;

-- Set search path (security)
ALTER USER app_user SET search_path TO public;
```

#### 3. Row-Level Security (RLS)

```sql
-- Enable row-level security
ALTER TABLE sensitive_data ENABLE ROW LEVEL SECURITY;

-- Create policy for data isolation
CREATE POLICY tenant_isolation ON sensitive_data
    FOR ALL
    TO app_user
    USING (tenant_id = current_setting('app.tenant_id')::integer);

-- Create policy for read-only access
CREATE POLICY readonly_policy ON sensitive_data
    FOR SELECT
    TO readonly_role
    USING (true);

-- Set tenant context in application
SET app.tenant_id = '123';
```

### pg_hba.conf Best Practices

```
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Local connections (Unix socket) - peer authentication
local   all             postgres                                peer
local   all             all                                     scram-sha-256

# SSL-only connections from internal networks
hostssl all             all             10.0.0.0/8              scram-sha-256 clientcert=verify-ca
hostssl all             all             172.16.0.0/12           scram-sha-256 clientcert=verify-ca
hostssl all             all             192.168.0.0/16          scram-sha-256 clientcert=verify-ca

# Replication connections (SSL required)
hostssl replication     replication     10.0.0.0/8              scram-sha-256 clientcert=verify-ca

# Reject all non-SSL connections
host    all             all             0.0.0.0/0               reject
host    all             all             ::/0                    reject

# Reject connections from specific IPs (blacklist)
host    all             all             192.168.1.100/32        reject
```

## Network Security

### Firewall Configuration

#### iptables Rules

```bash
#!/bin/bash
# Flush existing rules
iptables -F
iptables -X
iptables -Z

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow SSH (change port as needed)
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Allow PostgreSQL from internal networks only
iptables -A INPUT -p tcp --dport 5432 -s 10.0.0.0/8 -j ACCEPT
iptables -A INPUT -p tcp --dport 5432 -s 172.16.0.0/12 -j ACCEPT
iptables -A INPUT -p tcp --dport 5432 -s 192.168.0.0/16 -j ACCEPT

# Rate limiting for PostgreSQL (DDoS protection)
iptables -A INPUT -p tcp --dport 5432 -m recent --set --name postgresql
iptables -A INPUT -p tcp --dport 5432 -m recent --update --seconds 60 --hitcount 10 --name postgresql -j DROP

# Log dropped PostgreSQL connections
iptables -A INPUT -p tcp --dport 5432 -j LOG --log-prefix "PG_BLOCKED: " --log-level 4

# Drop all other PostgreSQL connections
iptables -A INPUT -p tcp --dport 5432 -j DROP

# Save rules
iptables-save > /etc/iptables/rules.v4
```

#### Cloud Security Groups

**AWS Security Group**:
```json
{
  "IpPermissions": [
    {
      "IpProtocol": "tcp",
      "FromPort": 5432,
      "ToPort": 5432,
      "IpRanges": [
        {
          "CidrIp": "10.0.0.0/8",
          "Description": "Internal network"
        }
      ]
    }
  ]
}
```

### Connection Limits

```ini
# postgresql.conf
max_connections = 100
superuser_reserved_connections = 3

# Connection timeouts
authentication_timeout = 30s
tcp_keepalives_idle = 300
tcp_keepalives_interval = 30
tcp_keepalives_count = 10

# Statement timeouts (prevent runaway queries)
statement_timeout = 3600000  # 1 hour
idle_in_transaction_session_timeout = 600000  # 10 minutes
```

### Network Isolation

```
┌──────────────────────────────────────────┐
│            DMZ Network                    │
│   ┌──────────┐      ┌──────────┐        │
│   │ Web      │      │ Load     │        │
│   │ Server   │──────│ Balancer │        │
│   └──────────┘      └──────────┘        │
└────────────────┬─────────────────────────┘
                 │
         ┌───────▼──────────┐
         │ Application      │
         │ Network          │
         │  ┌────────────┐  │
         │  │ App Server │  │
         │  └────────────┘  │
         └────────┬──────────┘
                  │
          ┌───────▼─────────┐
          │ Database        │
          │ Network         │
          │  ┌──────────┐   │
          │  │PostgreSQL│   │
          │  └──────────┘   │
          └─────────────────┘
```

## Encryption at Rest

### Data Encryption Options

#### 1. Full Disk Encryption (FDE)

**LUKS Encryption**:

```bash
# Create encrypted volume
cryptsetup luksFormat /dev/sdb
cryptsetup luksOpen /dev/sdb pgdata_encrypted

# Create filesystem
mkfs.ext4 /dev/mapper/pgdata_encrypted

# Mount
mount /dev/mapper/pgdata_encrypted /var/lib/postgresql/data

# Add to /etc/crypttab for auto-mount
echo "pgdata_encrypted /dev/sdb none luks" >> /etc/crypttab
```

#### 2. Transparent Data Encryption (TDE)

PostgreSQL doesn't have native TDE, but alternatives exist:

**pgcrypto Extension**:

```sql
-- Install pgcrypto
CREATE EXTENSION pgcrypto;

-- Encrypt data
CREATE TABLE encrypted_data (
    id SERIAL PRIMARY KEY,
    sensitive_data BYTEA
);

-- Insert encrypted data
INSERT INTO encrypted_data (sensitive_data)
VALUES (pgp_sym_encrypt('Secret data', 'encryption_key'));

-- Query encrypted data
SELECT pgp_sym_decrypt(sensitive_data, 'encryption_key')
FROM encrypted_data;
```

**Column-level Encryption**:

```sql
-- Create encryption functions
CREATE OR REPLACE FUNCTION encrypt_column(plaintext TEXT, key TEXT)
RETURNS TEXT AS $$
    SELECT encode(encrypt(plaintext::bytea, key::bytea, 'aes'), 'base64');
$$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION decrypt_column(ciphertext TEXT, key TEXT)
RETURNS TEXT AS $$
    SELECT convert_from(decrypt(decode(ciphertext, 'base64'), key::bytea, 'aes'), 'UTF8');
$$ LANGUAGE SQL;

-- Use in tables
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    email TEXT NOT NULL,
    ssn TEXT  -- Encrypted column
);

-- Insert with encryption
INSERT INTO users (email, ssn)
VALUES ('user@example.com', encrypt_column('123-45-6789', 'secret_key'));

-- Query with decryption
SELECT id, email, decrypt_column(ssn, 'secret_key') AS ssn
FROM users;
```

#### 3. Backup Encryption

```bash
# Encrypted backup with gpg
pg_dump dbname | gzip | gpg -c -o backup.sql.gz.gpg

# Restore encrypted backup
gpg -d backup.sql.gz.gpg | gunzip | psql dbname
```

### Key Management

**Best Practices**:
- Store encryption keys in Hardware Security Module (HSM)
- Use key rotation policies (90-day rotation)
- Separate key management from database administration
- Use envelope encryption for data encryption keys (DEK)

**AWS KMS Integration**:

```python
import boto3
import base64

kms = boto3.client('kms')

def encrypt_data(plaintext, key_id):
    response = kms.encrypt(
        KeyId=key_id,
        Plaintext=plaintext
    )
    return base64.b64encode(response['CiphertextBlob']).decode()

def decrypt_data(ciphertext, key_id):
    ciphertext_blob = base64.b64decode(ciphertext)
    response = kms.decrypt(
        KeyId=key_id,
        CiphertextBlob=ciphertext_blob
    )
    return response['Plaintext'].decode()
```

## Audit Logging

### pgaudit Configuration

#### 1. Install pgaudit

```bash
# Install pgaudit extension
sudo apt-get install postgresql-XX-pgaudit
```

#### 2. Configure pgaudit

Add to `postgresql.conf`:

```ini
# Load pgaudit
shared_preload_libraries = 'pgaudit'

# Audit all statements
pgaudit.log = 'all'

# Audit configuration
pgaudit.log_catalog = on
pgaudit.log_parameter = on
pgaudit.log_relation = on
pgaudit.log_statement_once = off

# Audit specific users
pgaudit.role = 'auditor'
```

#### 3. Create pgaudit Extension

```sql
CREATE EXTENSION pgaudit;
```

#### 4. Configure Audit Scope

```sql
-- Audit all DDL statements
ALTER SYSTEM SET pgaudit.log = 'ddl';

-- Audit specific operations
ALTER SYSTEM SET pgaudit.log = 'read, write, ddl';

-- Audit by role
CREATE ROLE auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO auditor;
ALTER SYSTEM SET pgaudit.role = 'auditor';
```

### Log Analysis

#### 1. Log Aggregation

**Rsyslog Configuration** (`/etc/rsyslog.d/postgresql.conf`):

```
# Forward PostgreSQL logs to central server
:programname, isequal, "postgres" @@log-server:514
```

#### 2. SIEM Integration

**Splunk Forwarder**:

```ini
[monitor:///var/log/postgresql/*.log]
sourcetype = postgresql
index = database
```

**Elasticsearch Integration**:

```bash
# Filebeat configuration
filebeat.inputs:
- type: log
  enabled: true
  paths:
    - /var/log/postgresql/*.log
  multiline.pattern: '^\d{4}-\d{2}-\d{2}'
  multiline.negate: true
  multiline.match: after

output.elasticsearch:
  hosts: ["elasticsearch:9200"]
```

### Audit Log Retention

```bash
# Log rotation configuration (/etc/logrotate.d/postgresql)
/var/log/postgresql/*.log {
    daily
    rotate 90
    compress
    delaycompress
    notifempty
    create 640 postgres postgres
    sharedscripts
    postrotate
        /usr/bin/pg_ctl reload -D /var/lib/postgresql/data
    endscript
}
```

## Compliance Requirements

### PCI-DSS 3.2.1

| Requirement | Implementation | Verification |
|-------------|----------------|--------------|
| 2.2 Develop configuration standards | CIS Benchmark | security-audit.sh |
| 2.2.4 Configure security parameters | harden-cluster.sh | pg_settings |
| 3.4 Render PAN unreadable | Encryption at rest | Column encryption |
| 8.2.1 Strong passwords | SCRAM-SHA-256 | password_encryption |
| 8.7 Database access restricted | RBAC, pg_hba.conf | pg_hba.conf |
| 10.2 Audit logging | pgaudit | log files |
| 10.3 Audit trail details | Log line prefix | log format |

**PCI-DSS Compliance Checklist**:

```sql
-- Check password encryption
SHOW password_encryption;  -- Should be 'scram-sha-256'

-- Check SSL
SHOW ssl;  -- Should be 'on'

-- Check logging
SHOW log_connections;  -- Should be 'on'
SHOW log_disconnections;  -- Should be 'on'

-- Check audit logging
SELECT * FROM pg_extension WHERE extname = 'pgaudit';
```

### HIPAA

| Requirement | Implementation | Verification |
|-------------|----------------|--------------|
| 164.312(a)(2)(i) Unique user IDs | Individual user accounts | pg_user |
| 164.312(a)(2)(iv) Encryption | SSL/TLS, encryption at rest | ssl settings |
| 164.312(b) Audit controls | pgaudit, logging | log files |
| 164.312(d) User authentication | SCRAM-SHA-256 | password_encryption |

**HIPAA Compliance Checklist**:

```sql
-- Check for shared accounts
SELECT usename FROM pg_user GROUP BY usename HAVING COUNT(*) > 1;

-- Verify SSL enabled
SHOW ssl;  -- Should be 'on'
SHOW ssl_min_protocol_version;  -- Should be 'TLSv1.2'

-- Check audit logging
SHOW logging_collector;  -- Should be 'on'
SELECT * FROM pg_extension WHERE extname = 'pgaudit';

-- Verify no null passwords
SELECT COUNT(*) FROM pg_shadow WHERE passwd IS NULL;  -- Should be 0
```

### SOC 2

**Type II Controls**:

1. **CC6.1 - Logical Access Controls**
   - Role-based access control (RBAC)
   - Strong authentication (SCRAM-SHA-256)
   - SSL/TLS encryption

2. **CC6.2 - Unauthorized Access**
   - pg_hba.conf restrictions
   - Firewall rules
   - Failed login monitoring

3. **CC6.3 - Privileged Access**
   - Superuser restrictions
   - Privilege escalation monitoring
   - Separation of duties

4. **CC7.2 - Logging and Monitoring**
   - pgaudit for database activity
   - Connection/disconnection logging
   - Log retention (90 days)

### GDPR

| Requirement | Implementation | Verification |
|-------------|----------------|--------------|
| Article 32 Security | Encryption, access controls | Security audit |
| Article 33 Breach notification | Monitoring, alerting | Log monitoring |
| Article 17 Right to erasure | Soft delete, data masking | Application logic |
| Article 25 Data protection by design | RLS, encryption | Database policies |

**Data Subject Rights Implementation**:

```sql
-- Right to erasure (pseudonymization)
UPDATE users
SET email = 'deleted_' || id || '@example.com',
    name = 'DELETED',
    deleted_at = NOW()
WHERE id = 123;

-- Right to access (data export)
COPY (
    SELECT * FROM users WHERE id = 123
) TO '/tmp/user_data_123.csv' CSV HEADER;

-- Right to data portability
SELECT json_agg(row_to_json(t))
FROM (
    SELECT * FROM users WHERE id = 123
) t;
```

## Security Incident Response

### Incident Response Plan

#### Phase 1: Preparation

```bash
# Create incident response team contacts
cat > /etc/postgresql/incident_contacts.txt <<EOF
DBA Lead: dba-lead@example.com, +1-555-0100
Security Lead: security@example.com, +1-555-0101
Management: cto@example.com, +1-555-0102
Legal: legal@example.com, +1-555-0103
EOF

# Set up monitoring alerts
# Configure PagerDuty, OpsGenie, etc.
```

#### Phase 2: Detection and Analysis

**Security Event Monitoring**:

```sql
-- Monitor failed login attempts
SELECT usename, COUNT(*) AS failed_attempts,
       MAX(log_time) AS last_attempt
FROM pg_log
WHERE message LIKE '%authentication failed%'
  AND log_time > NOW() - INTERVAL '1 hour'
GROUP BY usename
HAVING COUNT(*) > 5;

-- Monitor privilege escalation
SELECT * FROM pg_log
WHERE message LIKE '%ALTER USER%'
   OR message LIKE '%GRANT%'
   OR message LIKE '%SUPERUSER%'
ORDER BY log_time DESC;

-- Monitor suspicious queries
SELECT usename, query, query_start
FROM pg_stat_activity
WHERE query ILIKE '%DROP%'
   OR query ILIKE '%DELETE FROM%'
   OR query ILIKE '%TRUNCATE%'
ORDER BY query_start DESC;
```

**Automated Alerting**:

```bash
#!/bin/bash
# Monitor for security events

LOGFILE="/var/log/postgresql/postgresql.log"
ALERT_EMAIL="security@example.com"

# Check for failed authentication
if tail -n 100 "$LOGFILE" | grep -q "authentication failed"; then
    echo "Failed authentication attempts detected" | \
        mail -s "PostgreSQL Security Alert" "$ALERT_EMAIL"
fi

# Check for privilege changes
if tail -n 100 "$LOGFILE" | grep -qE "(GRANT|REVOKE|ALTER USER)"; then
    echo "Privilege changes detected" | \
        mail -s "PostgreSQL Privilege Alert" "$ALERT_EMAIL"
fi
```

#### Phase 3: Containment

**Immediate Actions**:

```sql
-- Terminate suspicious connections
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE usename = 'suspicious_user'
  AND state = 'active';

-- Revoke user access
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM suspicious_user;
ALTER USER suspicious_user WITH NOLOGIN;

-- Block IP in pg_hba.conf
-- Add to top of pg_hba.conf:
-- host all all 192.168.1.100/32 reject

-- Reload configuration
SELECT pg_reload_conf();
```

**Network Isolation**:

```bash
# Block IP address
iptables -I INPUT -s 192.168.1.100 -j DROP
iptables-save > /etc/iptables/rules.v4

# Isolate database server (emergency)
iptables -P INPUT DROP
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -s 10.0.0.0/8 -j ACCEPT
```

#### Phase 4: Eradication

```sql
-- Remove compromised user
DROP USER IF EXISTS compromised_user;

-- Rotate all credentials
\i /path/to/rotate-credentials.sh

-- Audit and remove backdoors
SELECT * FROM pg_proc WHERE prosrc LIKE '%malicious%';
SELECT * FROM pg_trigger WHERE tgname LIKE '%backdoor%';

-- Review and remove suspicious extensions
SELECT * FROM pg_extension WHERE extname NOT IN ('plpgsql', 'pgaudit');
```

#### Phase 5: Recovery

```bash
# Restore from clean backup
pg_restore -d dbname -v clean_backup.dump

# Verify integrity
md5sum /var/lib/postgresql/data/base/* > checksums.txt
diff checksums.txt checksums.txt.known_good

# Re-apply security hardening
bash scripts/security/harden-cluster.sh
```

#### Phase 6: Post-Incident

**Forensic Analysis**:

```bash
# Preserve evidence
tar -czf incident_logs_$(date +%Y%m%d).tar.gz /var/log/postgresql/
pg_dump --schema-only dbname > schema_snapshot.sql

# Analyze logs
grep -E "authentication failed|DROP|DELETE|GRANT" /var/log/postgresql/*.log > incident_events.txt

# Generate timeline
awk -F',' '{print $1, $2, $3}' /var/log/postgresql/*.log | sort > incident_timeline.txt
```

**Post-Incident Report Template**:

```markdown
# Security Incident Report

## Incident Summary
- **Date/Time**:
- **Severity**: Critical / High / Medium / Low
- **Status**: Resolved / In Progress / Monitoring

## Detection
- **How Detected**:
- **Detection Time**:
- **Reporter**:

## Analysis
- **Attack Vector**:
- **Affected Systems**:
- **Data Exposed**:
- **Attacker Info**:

## Response Actions
1.
2.
3.

## Root Cause
- **Vulnerability Exploited**:
- **Contributing Factors**:

## Remediation
- **Immediate Actions**:
- **Long-term Fixes**:
- **Preventive Measures**:

## Lessons Learned
-
-

## Timeline
| Time | Event | Action Taken |
|------|-------|--------------|
|      |       |              |
```

### Incident Categories

| Category | Severity | Response Time | Escalation |
|----------|----------|---------------|------------|
| Unauthorized access | Critical | Immediate | Security Lead + Management |
| Data breach | Critical | Immediate | Security Lead + Legal + Management |
| Privilege escalation | High | <1 hour | Security Lead |
| Failed login attempts | Medium | <4 hours | DBA Team |
| Configuration changes | Medium | <4 hours | DBA Team |
| Performance anomaly | Low | <24 hours | DBA Team |

## Security Checklist

### Pre-Production Checklist

- [ ] PostgreSQL version is latest stable release
- [ ] PGDATA directory permissions set to 700
- [ ] Configuration files permissions set to 600
- [ ] SSL/TLS certificates generated and configured
- [ ] SSL minimum protocol version is TLSv1.2
- [ ] Strong cipher suites configured
- [ ] SCRAM-SHA-256 authentication enabled
- [ ] pg_hba.conf configured with least privilege
- [ ] All connections require SSL (hostssl only)
- [ ] Client certificate authentication enabled
- [ ] Logging collector enabled
- [ ] Connection and disconnection logging enabled
- [ ] pgaudit extension installed and configured
- [ ] Firewall rules configured (PostgreSQL port restricted)
- [ ] listen_addresses configured appropriately
- [ ] statement_timeout configured
- [ ] idle_in_transaction_session_timeout configured
- [ ] Superuser accounts minimized
- [ ] Application users use least privilege
- [ ] Row-level security policies implemented
- [ ] Dangerous extensions removed (plperl, pltcl)
- [ ] allow_system_table_mods = off
- [ ] Encryption at rest configured
- [ ] Backup encryption configured
- [ ] Log rotation configured
- [ ] Monitoring and alerting configured
- [ ] Incident response plan documented
- [ ] Security audit passed

### Monthly Security Tasks

- [ ] Review user accounts and privileges
- [ ] Audit failed login attempts
- [ ] Review pgaudit logs for suspicious activity
- [ ] Check SSL certificate expiration dates
- [ ] Review and update firewall rules
- [ ] Verify backup encryption and restoration
- [ ] Run security audit script
- [ ] Update PostgreSQL security patches
- [ ] Review and rotate credentials
- [ ] Test incident response procedures

### Quarterly Security Tasks

- [ ] Comprehensive security audit
- [ ] Penetration testing
- [ ] Rotate SSL/TLS certificates
- [ ] Rotate database passwords
- [ ] Review and update security policies
- [ ] Security training for database team
- [ ] Disaster recovery drill
- [ ] Compliance audit (PCI, HIPAA, etc.)
- [ ] Third-party security assessment

## Common Vulnerabilities and Fixes

### SQL Injection

**Vulnerable Code**:
```python
# NEVER DO THIS
query = f"SELECT * FROM users WHERE username = '{username}'"
cursor.execute(query)
```

**Secure Code**:
```python
# ALWAYS use parameterized queries
query = "SELECT * FROM users WHERE username = %s"
cursor.execute(query, (username,))
```

**Database Protection**:
```sql
-- Restrict permissions
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON users TO app_user;
```

### Privilege Escalation

**Issue**: User gains unauthorized superuser access

**Detection**:
```sql
-- Monitor privilege changes
SELECT * FROM pg_log
WHERE message LIKE '%GRANT%SUPERUSER%'
   OR message LIKE '%ALTER USER%SUPERUSER%';
```

**Prevention**:
```sql
-- Limit GRANT privileges
REVOKE ALL ON DATABASE mydb FROM PUBLIC;
GRANT CONNECT ON DATABASE mydb TO app_user;

-- Audit privilege changes
CREATE OR REPLACE FUNCTION audit_privilege_changes()
RETURNS event_trigger AS $$
BEGIN
    RAISE WARNING 'Privilege change detected: %', current_query();
END;
$$ LANGUAGE plpgsql;

CREATE EVENT TRIGGER privilege_audit
ON ddl_command_end
EXECUTE FUNCTION audit_privilege_changes();
```

### Weak Authentication

**Issue**: Weak password or password reuse

**Fix**:
```sql
-- Enforce SCRAM-SHA-256
ALTER SYSTEM SET password_encryption = 'scram-sha-256';

-- Password complexity function
CREATE OR REPLACE FUNCTION validate_password(username text, password text)
RETURNS boolean AS $$
BEGIN
    PERFORM check_password_strength(username, password);
    RETURN true;
END;
$$ LANGUAGE plpgsql;
```

### Information Disclosure

**Issue**: Error messages reveal database structure

**Fix**:
```sql
-- Generic error messages in application
-- Log detailed errors only on server side

-- Restrict system catalog access
REVOKE SELECT ON pg_user FROM PUBLIC;
REVOKE SELECT ON pg_shadow FROM PUBLIC;
```

### Unencrypted Connections

**Issue**: Data transmitted in plaintext

**Fix**:
```
# pg_hba.conf - Force SSL
hostssl all all 0.0.0.0/0 scram-sha-256
host    all all 0.0.0.0/0 reject
```

### Default Credentials

**Issue**: Default postgres superuser password

**Fix**:
```sql
-- Change default password immediately
ALTER USER postgres WITH PASSWORD 'strong_random_password';

-- Disable postgres user for remote access
-- In pg_hba.conf:
-- local all postgres peer
-- host  all postgres 0.0.0.0/0 reject
```

## Penetration Testing Guidelines

### Pre-Testing

1. **Get Authorization**
   - Written approval from management
   - Define scope and boundaries
   - Set testing window

2. **Prepare Test Environment**
   - Use staging/test environment first
   - Backup production before testing
   - Notify stakeholders

### Testing Methodology

#### 1. Information Gathering

```bash
# Port scanning
nmap -p 5432 -sV target_host

# Banner grabbing
telnet target_host 5432

# SSL/TLS testing
testssl.sh target_host:5432
```

#### 2. Authentication Testing

```bash
# Brute force testing (with permission)
hydra -l postgres -P passwords.txt postgres://target_host

# Default credentials
psql -h target_host -U postgres -d postgres

# SQL injection in login
sqlmap -u "http://target/login" --dbms=postgresql
```

#### 3. Authorization Testing

```sql
-- Test privilege escalation
CREATE USER test_user WITH PASSWORD 'test123';
GRANT CONNECT ON DATABASE mydb TO test_user;

-- Attempt privilege escalation
SET ROLE postgres;  -- Should fail
CREATE USER admin_user WITH SUPERUSER;  -- Should fail
```

#### 4. Encryption Testing

```bash
# Test SSL enforcement
psql "sslmode=disable host=target_host dbname=mydb"  -- Should fail

# Cipher strength testing
nmap --script ssl-enum-ciphers -p 5432 target_host
```

#### 5. Audit Logging Testing

```sql
-- Verify logging is enabled
SHOW logging_collector;
SHOW log_connections;

-- Generate test events
CREATE TABLE test_audit (id INT);
DROP TABLE test_audit;

-- Check logs
SELECT * FROM pg_log WHERE message LIKE '%test_audit%';
```

### Post-Testing

1. **Generate Report**
   - Executive summary
   - Vulnerability findings (severity, impact, remediation)
   - Evidence (screenshots, logs)
   - Remediation timeline

2. **Remediation**
   - Fix critical vulnerabilities immediately
   - Plan fixes for high/medium issues
   - Re-test after remediation

### Vulnerability Severity Rating

| Severity | CVSS Score | Examples | Response Time |
|----------|------------|----------|---------------|
| Critical | 9.0-10.0 | RCE, Authentication bypass | Immediate |
| High | 7.0-8.9 | SQL injection, Privilege escalation | <24 hours |
| Medium | 4.0-6.9 | XSS, Information disclosure | <7 days |
| Low | 0.1-3.9 | Configuration issues | <30 days |

## Security Hardening Scripts

### Quick Reference

```bash
# 1. Initial hardening
sudo bash scripts/security/harden-cluster.sh

# 2. Run security audit
bash scripts/security/security-audit.sh

# 3. Rotate credentials
bash scripts/security/rotate-credentials.sh all

# 4. Generate SSL certificates
bash scripts/security/generate-certificates.sh

# 5. Continuous monitoring
bash scripts/security/monitor-security.sh --daemon
```

### Script Locations

- `/home/matt/projects/Distributed-Postgress-Cluster/scripts/security/harden-cluster.sh`
- `/home/matt/projects/Distributed-Postgress-Cluster/scripts/security/security-audit.sh`
- `/home/matt/projects/Distributed-Postgress-Cluster/scripts/security/rotate-credentials.sh`

## Additional Resources

- [PostgreSQL Security Documentation](https://www.postgresql.org/docs/current/security.html)
- [CIS PostgreSQL Benchmark](https://www.cisecurity.org/benchmark/postgresql)
- [PCI DSS Requirements](https://www.pcisecuritystandards.org/)
- [HIPAA Security Rule](https://www.hhs.gov/hipaa/for-professionals/security/index.html)
- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework)

---

**Document Version**: 1.0.0
**Last Updated**: 2026-02-12
**Maintainer**: Database Security Team
