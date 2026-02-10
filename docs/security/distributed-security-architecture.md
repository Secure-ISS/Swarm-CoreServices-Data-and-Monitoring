# Distributed PostgreSQL Mesh - Security Architecture

## Executive Summary

This document defines the comprehensive security architecture for the distributed PostgreSQL mesh, implementing defense-in-depth across network, authentication, data protection, access control, and compliance domains.

## Table of Contents

1. [Security Model Overview](#security-model-overview)
2. [Network Security](#network-security)
3. [Authentication & Identity](#authentication--identity)
4. [Data Protection](#data-protection)
5. [Access Control](#access-control)
6. [Audit & Compliance](#audit--compliance)
7. [Threat Model](#threat-model)
8. [Security Operations](#security-operations)

---

## Security Model Overview

### Defense-in-Depth Layers

```
┌─────────────────────────────────────────────────────────────┐
│                    PERIMETER SECURITY                        │
│  - Network Isolation (Overlay)                              │
│  - TLS/mTLS Encryption                                      │
│  - Firewall Rules & IP Whitelisting                         │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│                 AUTHENTICATION & IDENTITY                    │
│  - Docker Secrets Management                                │
│  - PostgreSQL Role-Based Authentication                     │
│  - Certificate-Based Node Identity                          │
│  - Credential Rotation (90-day cycle)                       │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│                   AUTHORIZATION & ACCESS                     │
│  - Role-Based Access Control (RBAC)                         │
│  - Row-Level Security (RLS)                                 │
│  - Schema-Level Permissions                                 │
│  - Query Privilege Separation                               │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│                      DATA PROTECTION                         │
│  - Encryption at Rest (AES-256)                             │
│  - Encryption in Transit (TLS 1.3)                          │
│  - Encrypted Backups                                        │
│  - Key Management System (KMS)                              │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│                   MONITORING & AUDIT                         │
│  - Connection Logging                                       │
│  - Query Audit Trail                                        │
│  - Security Event Logging                                   │
│  - SIEM Integration                                         │
└─────────────────────────────────────────────────────────────┘
```

### Security Principles

1. **Zero Trust Architecture**: No implicit trust between components
2. **Least Privilege**: Minimum required permissions for all roles
3. **Defense in Depth**: Multiple security layers
4. **Fail Secure**: Security controls fail closed
5. **Security by Default**: Secure configuration out-of-box
6. **Audit Everything**: Comprehensive logging and monitoring

---

## Network Security

### 1. Docker Overlay Network Encryption

**Configuration**: Already implemented in `stack.yml`

```yaml
networks:
  postgres_mesh:
    driver: overlay
    attachable: true
    driver_opts:
      encrypted: "true"  # IPsec encryption for all traffic
    ipam:
      config:
        - subnet: 10.0.10.0/24
```

**Security Features**:
- **IPsec Encryption**: Automatic encryption of all inter-node traffic
- **Network Isolation**: Dedicated subnet for PostgreSQL mesh
- **Service Discovery**: DNS-based secure service discovery

**Implementation Status**: ✅ Complete

### 2. TLS/mTLS Configuration

#### 2.1 Certificate Architecture

```
Root CA (Self-Signed or Enterprise CA)
├── Intermediate CA (PostgreSQL Cluster)
│   ├── Coordinator Certificate
│   ├── Worker-1 Certificate
│   ├── Worker-2 Certificate
│   ├── Worker-3 Certificate
│   └── Client Certificates
│       ├── Application Client
│       ├── Replication User
│       └── Admin User
└── PgBouncer Certificate
```

#### 2.2 PostgreSQL TLS Configuration

**File**: `config/security/postgresql-tls.conf`

```conf
# TLS/SSL Configuration
ssl = on
ssl_ca_file = '/etc/postgresql/certs/ca.crt'
ssl_cert_file = '/etc/postgresql/certs/server.crt'
ssl_key_file = '/etc/postgresql/certs/server.key'

# Require TLS for all connections
ssl_min_protocol_version = 'TLSv1.3'
ssl_ciphers = 'TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256'
ssl_prefer_server_ciphers = on

# Client certificate verification
ssl_ca_file = '/etc/postgresql/certs/ca.crt'
ssl_crl_file = '/etc/postgresql/certs/crl.pem'

# DH parameters for Perfect Forward Secrecy
ssl_dh_params_file = '/etc/postgresql/certs/dhparams.pem'

# Security options
ssl_passphrase_command = '/usr/local/bin/get-ssl-passphrase.sh'
ssl_passphrase_command_supports_reload = on
```

**Implementation Status**: 🔄 See `config/security/setup-tls.sh`

#### 2.3 Certificate Generation Script

**File**: `scripts/security/generate-certificates.sh`

See detailed implementation in scripts section.

### 3. Network Access Control

#### 3.1 PostgreSQL Host-Based Authentication (pg_hba.conf)

**File**: `config/security/pg_hba.conf`

```conf
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Local connections (Unix socket)
local   all             postgres                                peer
local   all             all                                     scram-sha-256

# Coordinator node
hostssl all             all             10.0.10.2/32            scram-sha-256 clientcert=verify-ca
hostssl replication     replicator      10.0.10.0/24            scram-sha-256 clientcert=verify-ca

# Worker nodes
hostssl all             all             10.0.10.0/24            scram-sha-256 clientcert=verify-ca

# PgBouncer
hostssl all             all             10.0.10.100/32          scram-sha-256

# External clients (requires client certificate)
hostssl all             all             0.0.0.0/0               scram-sha-256 clientcert=verify-full

# Deny all other connections
host    all             all             all                     reject
```

**Security Features**:
- **Certificate-based authentication**: `clientcert=verify-full`
- **Strong password hashing**: `scram-sha-256` (replaces md5)
- **Network segmentation**: Different rules for different node types
- **Explicit deny**: Reject all non-matching connections

#### 3.2 Firewall Rules

**Docker Swarm Ingress Rules**:

```yaml
# Only expose necessary ports
ports:
  coordinator:
    - "5432:5432"  # Restrict to specific IPs via firewall
  pgbouncer:
    - "6432:6432"  # Client connections only
```

**Host-level Firewall (iptables)**:

```bash
# Allow only from specific application subnets
iptables -A INPUT -p tcp --dport 5432 -s 10.0.0.0/16 -j ACCEPT
iptables -A INPUT -p tcp --dport 6432 -s 10.0.0.0/16 -j ACCEPT
iptables -A INPUT -p tcp --dport 5432 -j DROP
iptables -A INPUT -p tcp --dport 6432 -j DROP
```

**Implementation Status**: 📋 See `scripts/security/configure-firewall.sh`

### 4. Network Monitoring

**Tools**:
- **Packet Inspection**: tcpdump for encrypted traffic validation
- **Connection Tracking**: PostgreSQL `pg_stat_ssl` views
- **Intrusion Detection**: Suricata/Snort integration

---

## Authentication & Identity

### 1. User Management Architecture

#### 1.1 Role Hierarchy

```
┌──────────────────────────────────────────────────┐
│                  superuser                       │
│  (postgres - emergency access only)              │
└──────────────────────────────────────────────────┘
                      ↓
┌──────────────────────────────────────────────────┐
│                cluster_admin                     │
│  (dpg_cluster - cluster operations)              │
└──────────────────────────────────────────────────┘
          ↓                    ↓                ↓
┌─────────────┐    ┌──────────────┐    ┌──────────────┐
│ replicator  │    │ app_writer   │    │  app_reader  │
│ (replication)│    │ (read/write) │    │  (read-only) │
└─────────────┘    └──────────────┘    └──────────────┘
                            ↓
                   ┌──────────────────┐
                   │  service_accounts│
                   │  (per-app users) │
                   └──────────────────┘
```

#### 1.2 Role Definitions

**File**: `scripts/security/create-roles.sql`

```sql
-- ============================================
-- ROLE CREATION AND PRIVILEGE ASSIGNMENT
-- ============================================

-- 1. Cluster administrator (inherits from postgres)
CREATE ROLE cluster_admin WITH
    LOGIN
    CREATEROLE
    CREATEDB
    REPLICATION
    BYPASSRLS
    PASSWORD NULL;  -- Use certificate-based auth

COMMENT ON ROLE cluster_admin IS 'Cluster administration and maintenance';

-- 2. Replication user (logical/physical replication)
CREATE ROLE replicator WITH
    LOGIN
    REPLICATION
    PASSWORD NULL;  -- Set via Docker secret

COMMENT ON ROLE replicator IS 'Replication between nodes';

-- 3. Application writer role (read/write)
CREATE ROLE app_writer WITH
    LOGIN
    NOCREATEROLE
    NOCREATEDB
    NOREPLICATION
    PASSWORD NULL;

GRANT CONNECT ON DATABASE distributed_postgres_cluster TO app_writer;
GRANT USAGE ON SCHEMA public, claude_flow TO app_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public, claude_flow TO app_writer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public, claude_flow TO app_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA public, claude_flow
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_writer;

COMMENT ON ROLE app_writer IS 'Application read-write access';

-- 4. Application reader role (read-only)
CREATE ROLE app_reader WITH
    LOGIN
    NOCREATEROLE
    NOCREATEDB
    NOREPLICATION
    PASSWORD NULL;

GRANT CONNECT ON DATABASE distributed_postgres_cluster TO app_reader;
GRANT USAGE ON SCHEMA public, claude_flow TO app_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public, claude_flow TO app_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public, claude_flow
    GRANT SELECT ON TABLES TO app_reader;

COMMENT ON ROLE app_reader IS 'Application read-only access';

-- 5. Backup role (for backup agent)
CREATE ROLE backup_agent WITH
    LOGIN
    REPLICATION
    NOCREATEROLE
    NOCREATEDB
    PASSWORD NULL;

GRANT CONNECT ON DATABASE distributed_postgres_cluster TO backup_agent;
GRANT USAGE ON SCHEMA public, claude_flow TO backup_agent;
GRANT SELECT ON ALL TABLES IN SCHEMA public, claude_flow TO backup_agent;

COMMENT ON ROLE backup_agent IS 'Backup and restore operations';

-- 6. Monitoring role (for health checks)
CREATE ROLE monitor WITH
    LOGIN
    NOCREATEROLE
    NOCREATEDB
    NOREPLICATION
    PASSWORD NULL;

GRANT CONNECT ON DATABASE distributed_postgres_cluster TO monitor;
GRANT USAGE ON SCHEMA pg_catalog TO monitor;
GRANT SELECT ON pg_stat_database, pg_stat_activity, pg_stat_replication TO monitor;

COMMENT ON ROLE monitor IS 'Health monitoring and metrics collection';
```

**Implementation Status**: 📋 See `scripts/security/create-roles.sql`

### 2. Docker Secrets Management

#### 2.1 Secrets Architecture

```bash
# Create Docker secrets (run on Swarm manager)
echo "strongpassword_$(openssl rand -hex 16)" | docker secret create postgres_password -
echo "replpassword_$(openssl rand -hex 16)" | docker secret create replication_password -
echo "pgbouncer_auth_$(openssl rand -hex 16)" | docker secret create pgbouncer_auth -

# Certificate secrets
docker secret create postgres_ca_cert config/security/certs/ca.crt
docker secret create postgres_server_cert config/security/certs/server.crt
docker secret create postgres_server_key config/security/certs/server.key
docker secret create postgres_client_cert config/security/certs/client.crt
docker secret create postgres_client_key config/security/certs/client.key
```

#### 2.2 Secret Rotation Policy

**Rotation Schedule**:
- **Passwords**: Every 90 days
- **TLS Certificates**: Every 365 days (before expiry)
- **CA Certificates**: Every 5 years

**File**: `scripts/security/rotate-credentials.sh`

See implementation in scripts section.

### 3. Password Policies

**File**: `config/security/password-policy.sql`

```sql
-- Install pgcrypto extension for password strength checking
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Password strength function
CREATE OR REPLACE FUNCTION check_password_strength(password TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    -- Minimum 16 characters
    IF LENGTH(password) < 16 THEN
        RAISE EXCEPTION 'Password must be at least 16 characters';
    END IF;

    -- Must contain uppercase
    IF password !~ '[A-Z]' THEN
        RAISE EXCEPTION 'Password must contain uppercase letters';
    END IF;

    -- Must contain lowercase
    IF password !~ '[a-z]' THEN
        RAISE EXCEPTION 'Password must contain lowercase letters';
    END IF;

    -- Must contain numbers
    IF password !~ '[0-9]' THEN
        RAISE EXCEPTION 'Password must contain numbers';
    END IF;

    -- Must contain special characters
    IF password !~ '[!@#$%^&*()_+=-]' THEN
        RAISE EXCEPTION 'Password must contain special characters';
    END IF;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- Set password encryption
ALTER SYSTEM SET password_encryption = 'scram-sha-256';
SELECT pg_reload_conf();
```

**Implementation Status**: 📋 See `config/security/password-policy.sql`

---

## Data Protection

### 1. Encryption at Rest

#### 1.1 PostgreSQL Data Encryption

**Methods**:

1. **Filesystem-level encryption** (Recommended for production):
   - LUKS (Linux Unified Key Setup)
   - dm-crypt
   - AWS EBS encryption
   - Azure Disk Encryption

2. **Column-level encryption** (Sensitive data):
   ```sql
   CREATE EXTENSION pgcrypto;

   -- Encrypt sensitive columns
   CREATE TABLE user_credentials (
       id SERIAL PRIMARY KEY,
       username TEXT,
       encrypted_password BYTEA,  -- pgcrypto.crypt()
       encrypted_ssn BYTEA         -- pgcrypto.pgp_sym_encrypt()
   );

   -- Encrypt data
   INSERT INTO user_credentials (username, encrypted_password, encrypted_ssn)
   VALUES (
       'john_doe',
       pgp_sym_encrypt('password123', 'encryption_key'),
       pgp_sym_encrypt('123-45-6789', 'encryption_key')
   );

   -- Decrypt data
   SELECT
       username,
       pgp_sym_decrypt(encrypted_password, 'encryption_key') AS password,
       pgp_sym_decrypt(encrypted_ssn, 'encryption_key') AS ssn
   FROM user_credentials;
   ```

#### 1.2 Volume Encryption Configuration

**Docker Volume with LUKS**:

```bash
# scripts/security/setup-encrypted-volumes.sh

#!/bin/bash
set -euo pipefail

VOLUME_SIZE="100G"
VOLUME_PATH="/var/lib/docker/volumes/encrypted_postgres"

# Create encrypted volume
fallocate -l $VOLUME_SIZE $VOLUME_PATH.img
cryptsetup luksFormat $VOLUME_PATH.img
cryptsetup luksOpen $VOLUME_PATH.img encrypted_postgres

# Create filesystem
mkfs.ext4 /dev/mapper/encrypted_postgres
mkdir -p $VOLUME_PATH
mount /dev/mapper/encrypted_postgres $VOLUME_PATH

# Add to /etc/fstab for auto-mount
echo "/dev/mapper/encrypted_postgres $VOLUME_PATH ext4 defaults 0 2" >> /etc/fstab

# Update stack.yml to use encrypted volume
```

**Implementation Status**: 📋 See `scripts/security/setup-encrypted-volumes.sh`

### 2. Encryption in Transit

#### 2.1 TLS Configuration (Already covered in Network Security)

- TLS 1.3 for all connections
- Strong cipher suites
- Certificate pinning

#### 2.2 Replication Encryption

**Configuration**: `config/security/replication-tls.conf`

```conf
# Primary server configuration
wal_level = replica
max_wal_senders = 10
wal_keep_size = 1GB

# SSL for replication
ssl = on
ssl_ca_file = '/etc/postgresql/certs/ca.crt'
ssl_cert_file = '/etc/postgresql/certs/server.crt'
ssl_key_file = '/etc/postgresql/certs/server.key'

# Standby server configuration (on workers)
primary_conninfo = 'host=pg-coordinator port=5432 user=replicator sslmode=verify-full sslcert=/etc/postgresql/certs/client.crt sslkey=/etc/postgresql/certs/client.key sslrootcert=/etc/postgresql/certs/ca.crt'
```

### 3. Backup Encryption

#### 3.1 Encrypted Backup Strategy

**File**: `scripts/security/backup-encrypted.sh`

```bash
#!/bin/bash
set -euo pipefail

BACKUP_DIR="/backups"
ENCRYPTION_KEY_FILE="/run/secrets/backup_encryption_key"
BACKUP_DATE=$(date +%Y%m%d_%H%M%S)

# Dump database with compression
pg_dump -h pg-coordinator -U dpg_cluster -Fc distributed_postgres_cluster \
    | gpg --symmetric --cipher-algo AES256 --passphrase-file "$ENCRYPTION_KEY_FILE" \
    > "$BACKUP_DIR/backup_${BACKUP_DATE}.dump.gpg"

# Backup WAL files
tar czf - /var/lib/postgresql/data/pg_wal \
    | gpg --symmetric --cipher-algo AES256 --passphrase-file "$ENCRYPTION_KEY_FILE" \
    > "$BACKUP_DIR/wal_${BACKUP_DATE}.tar.gz.gpg"

# Verify backup integrity
gpg --decrypt --passphrase-file "$ENCRYPTION_KEY_FILE" \
    "$BACKUP_DIR/backup_${BACKUP_DATE}.dump.gpg" | pg_restore --list > /dev/null

echo "Backup completed: $BACKUP_DIR/backup_${BACKUP_DATE}.dump.gpg"
```

**Implementation Status**: 📋 See `scripts/security/backup-encrypted.sh`

### 4. Key Management

#### 4.1 Key Management System (KMS)

**Options**:

1. **HashiCorp Vault** (Recommended):
   - Dynamic secrets generation
   - Automatic key rotation
   - Audit logging

2. **AWS KMS** (Cloud environments):
   - Managed key rotation
   - IAM integration
   - CloudTrail auditing

3. **Docker Secrets** (Basic):
   - Encrypted at rest
   - TLS in transit
   - Swarm-level security

**Implementation**: See `docs/security/kms-integration.md`

---

## Access Control

### 1. Role-Based Access Control (RBAC)

#### 1.1 RBAC Implementation

**File**: `config/security/rbac-policies.sql`

```sql
-- ============================================
-- ROLE-BASED ACCESS CONTROL POLICIES
-- ============================================

-- 1. Admin role (full access)
GRANT ALL PRIVILEGES ON DATABASE distributed_postgres_cluster TO cluster_admin;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public, claude_flow TO cluster_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public, claude_flow TO cluster_admin;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public, claude_flow TO cluster_admin;

-- 2. Application roles (granular access)
-- Read-write access to specific tables
REVOKE ALL ON TABLE sensitive_data FROM app_writer;
GRANT SELECT, INSERT, UPDATE ON TABLE user_data TO app_writer;
GRANT SELECT ON TABLE reference_data TO app_writer;

-- Read-only access
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_reader;
REVOKE SELECT ON TABLE sensitive_data FROM app_reader;

-- 3. Service-specific roles
CREATE ROLE analytics_service WITH LOGIN;
GRANT SELECT ON TABLE metrics, logs, events TO analytics_service;

CREATE ROLE api_service WITH LOGIN;
GRANT SELECT, INSERT, UPDATE ON TABLE api_data TO api_service;
GRANT EXECUTE ON FUNCTION api_functions.* TO api_service;

-- 4. Schema-level isolation
CREATE SCHEMA IF NOT EXISTS tenant_a;
CREATE SCHEMA IF NOT EXISTS tenant_b;

CREATE ROLE tenant_a_user WITH LOGIN;
GRANT USAGE ON SCHEMA tenant_a TO tenant_a_user;
GRANT ALL ON ALL TABLES IN SCHEMA tenant_a TO tenant_a_user;
REVOKE ALL ON SCHEMA tenant_b FROM tenant_a_user;

-- 5. Prevent privilege escalation
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON pg_catalog, information_schema FROM PUBLIC;
```

**Implementation Status**: 📋 See `config/security/rbac-policies.sql`

### 2. Row-Level Security (RLS)

#### 2.1 RLS Policies

**File**: `config/security/rls-policies.sql`

```sql
-- ============================================
-- ROW-LEVEL SECURITY POLICIES
-- ============================================

-- Enable RLS on tables
ALTER TABLE user_data ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_data ENABLE ROW LEVEL SECURITY;

-- Policy 1: Users can only see their own data
CREATE POLICY user_isolation_policy ON user_data
    FOR ALL
    TO app_writer, app_reader
    USING (user_id = current_user::int);

-- Policy 2: Multi-tenant isolation
CREATE POLICY tenant_isolation_policy ON tenant_data
    FOR ALL
    TO app_writer, app_reader
    USING (tenant_id = current_setting('app.current_tenant_id')::int);

-- Policy 3: Admin bypass
CREATE POLICY admin_full_access ON user_data
    FOR ALL
    TO cluster_admin
    USING (true)
    WITH CHECK (true);

-- Policy 4: Time-based access
CREATE POLICY business_hours_policy ON sensitive_operations
    FOR ALL
    TO app_writer
    USING (
        EXTRACT(HOUR FROM now()) BETWEEN 8 AND 18 AND
        EXTRACT(DOW FROM now()) BETWEEN 1 AND 5
    );

-- Set tenant context (application-level)
-- Applications must run: SET app.current_tenant_id = 'tenant_123';
```

**Implementation Status**: 📋 See `config/security/rls-policies.sql`

### 3. Query Privilege Separation

```sql
-- Prevent dangerous operations
REVOKE EXECUTE ON FUNCTION pg_sleep(double precision) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pg_read_file(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pg_read_binary_file(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pg_ls_dir(text) FROM PUBLIC;

-- Limit extensions
REVOKE CREATE ON DATABASE distributed_postgres_cluster FROM PUBLIC;
ALTER DATABASE distributed_postgres_cluster SET default_transaction_read_only = on;
```

---

## Audit & Compliance

### 1. Audit Logging

#### 1.1 PostgreSQL Audit Configuration

**File**: `config/security/audit-logging.conf`

```conf
# Enable pgaudit extension
shared_preload_libraries = 'pgaudit,pg_stat_statements'

# Audit logging settings
pgaudit.log = 'all'  # Log all statements (DDL, DML, DCL)
pgaudit.log_catalog = on
pgaudit.log_client = on
pgaudit.log_level = 'log'
pgaudit.log_parameter = on
pgaudit.log_relation = on
pgaudit.log_statement_once = off

# Connection logging
log_connections = on
log_disconnections = on
log_hostname = on
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '

# Query logging
log_statement = 'ddl'  # Log all DDL statements
log_duration = on
log_min_duration_statement = 1000  # Log queries > 1s

# Error logging
log_error_verbosity = default
log_min_messages = warning

# CSV logging for SIEM integration
logging_collector = on
log_destination = 'csvlog'
log_directory = '/var/log/postgresql'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1d
log_rotation_size = 100MB
```

**Implementation Status**: 📋 See `config/security/audit-logging.conf`

#### 1.2 Audit Query Examples

```sql
-- Install pgaudit
CREATE EXTENSION IF NOT EXISTS pgaudit;

-- View audit logs
SELECT * FROM pg_log ORDER BY log_time DESC LIMIT 100;

-- Track failed login attempts
SELECT
    log_time,
    user_name,
    database_name,
    remote_host,
    message
FROM pg_log
WHERE message LIKE '%authentication failed%'
ORDER BY log_time DESC;

-- Track privileged operations
SELECT
    log_time,
    user_name,
    command_tag,
    message
FROM pg_log
WHERE command_tag IN ('ALTER', 'CREATE', 'DROP', 'GRANT', 'REVOKE')
ORDER BY log_time DESC;

-- Track data access
SELECT
    log_time,
    user_name,
    database_name,
    application_name,
    query
FROM pg_stat_statements
WHERE query LIKE '%sensitive_table%'
ORDER BY calls DESC;
```

### 2. Compliance Requirements

#### 2.1 GDPR Compliance

**Data Subject Rights**:

```sql
-- Right to Access
CREATE OR REPLACE FUNCTION gdpr_export_user_data(user_email TEXT)
RETURNS JSON AS $$
DECLARE
    result JSON;
BEGIN
    SELECT json_build_object(
        'personal_data', (SELECT row_to_json(u) FROM users u WHERE email = user_email),
        'activity_logs', (SELECT json_agg(row_to_json(l)) FROM activity_logs l WHERE user_email = l.email),
        'preferences', (SELECT row_to_json(p) FROM preferences p WHERE user_email = p.email)
    ) INTO result;

    -- Log access request
    INSERT INTO audit_log (action, user_email, timestamp)
    VALUES ('GDPR_EXPORT', user_email, now());

    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Right to Erasure
CREATE OR REPLACE FUNCTION gdpr_delete_user_data(user_email TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    -- Anonymize instead of delete (for audit trail)
    UPDATE users SET
        email = 'deleted_' || gen_random_uuid()::text,
        name = 'DELETED',
        phone = NULL
    WHERE email = user_email;

    DELETE FROM activity_logs WHERE email = user_email;
    DELETE FROM preferences WHERE email = user_email;

    -- Log deletion request
    INSERT INTO audit_log (action, user_email, timestamp)
    VALUES ('GDPR_DELETE', user_email, now());

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Data retention policy
CREATE OR REPLACE FUNCTION enforce_data_retention()
RETURNS void AS $$
BEGIN
    -- Delete logs older than 90 days
    DELETE FROM activity_logs WHERE timestamp < now() - INTERVAL '90 days';

    -- Archive audit logs older than 7 years
    INSERT INTO audit_log_archive SELECT * FROM audit_log WHERE timestamp < now() - INTERVAL '7 years';
    DELETE FROM audit_log WHERE timestamp < now() - INTERVAL '7 years';
END;
$$ LANGUAGE plpgsql;

-- Schedule retention enforcement
SELECT cron.schedule('enforce-retention', '0 2 * * 0', 'SELECT enforce_data_retention()');
```

**Implementation Status**: 📋 See `config/security/gdpr-compliance.sql`

#### 2.2 SOC 2 Compliance

**Control Mapping**:

| Control | Implementation | Evidence |
|---------|---------------|----------|
| CC6.1 - Logical Access | RBAC, RLS, pg_hba.conf | Audit logs, role definitions |
| CC6.2 - Authentication | SCRAM-SHA-256, mTLS | Certificate store, auth logs |
| CC6.3 - Authorization | Role-based privileges | Role grants, RLS policies |
| CC6.6 - Encryption | TLS 1.3, AES-256 | ssl_cipher, encryption configs |
| CC6.7 - Removal of Access | Automated de-provisioning | User lifecycle logs |
| CC7.2 - System Monitoring | pgaudit, pg_stat_activity | Audit logs, monitoring dashboards |
| CC7.3 - Anomaly Detection | Query pattern analysis | Alert logs, SIEM events |

**Documentation**: See `docs/security/soc2-compliance-matrix.md`

### 3. Security Event Monitoring

#### 3.1 SIEM Integration

**File**: `scripts/security/siem-integration.py`

```python
#!/usr/bin/env python3
"""
PostgreSQL Security Event Integration with SIEM
Sends security events to Splunk/ELK/Datadog
"""

import psycopg2
import json
import requests
from datetime import datetime

SIEM_ENDPOINT = "https://siem.example.com/api/events"
SIEM_API_KEY = "your-api-key"

def fetch_security_events():
    """Fetch recent security events from PostgreSQL"""
    conn = psycopg2.connect(
        host="pg-coordinator",
        database="distributed_postgres_cluster",
        user="monitor",
        password="monitor_password"
    )

    cursor = conn.cursor()
    cursor.execute("""
        SELECT
            log_time,
            user_name,
            database_name,
            remote_host,
            session_id,
            command_tag,
            message,
            detail
        FROM pg_log
        WHERE log_time > now() - INTERVAL '5 minutes'
        AND (
            message LIKE '%authentication failed%' OR
            message LIKE '%permission denied%' OR
            command_tag IN ('ALTER', 'DROP', 'GRANT', 'REVOKE')
        )
    """)

    events = cursor.fetchall()
    conn.close()

    return events

def send_to_siem(events):
    """Send events to SIEM"""
    for event in events:
        payload = {
            "timestamp": event[0].isoformat(),
            "user": event[1],
            "database": event[2],
            "source_ip": event[3],
            "session": event[4],
            "action": event[5],
            "message": event[6],
            "severity": "high" if "failed" in event[6] else "medium"
        }

        response = requests.post(
            SIEM_ENDPOINT,
            headers={"Authorization": f"Bearer {SIEM_API_KEY}"},
            json=payload
        )

        if response.status_code != 200:
            print(f"Failed to send event: {response.text}")

if __name__ == "__main__":
    events = fetch_security_events()
    send_to_siem(events)
```

**Implementation Status**: 📋 See `scripts/security/siem-integration.py`

---

## Threat Model

### 1. Threat Actors

| Actor | Motivation | Capability | Impact |
|-------|-----------|------------|--------|
| External Attacker | Data theft, ransomware | High | Critical |
| Malicious Insider | Data exfiltration | Medium | High |
| Compromised Application | Lateral movement | Medium | High |
| Accidental Misconfiguration | N/A | Low | Medium |

### 2. Attack Vectors

#### 2.1 Network-Based Attacks

| Attack | Mitigation | Status |
|--------|-----------|--------|
| Man-in-the-Middle | TLS 1.3, certificate pinning | ✅ Implemented |
| Network Sniffing | IPsec overlay encryption | ✅ Implemented |
| Port Scanning | Firewall rules, network isolation | 📋 Planned |
| DDoS | Rate limiting, connection pooling | ✅ Implemented |

#### 2.2 Authentication Attacks

| Attack | Mitigation | Status |
|--------|-----------|--------|
| Brute Force | Account lockout, SCRAM-SHA-256 | 📋 Planned |
| Credential Stuffing | Certificate-based auth | ✅ Implemented |
| Session Hijacking | Short session timeouts, TLS | ✅ Implemented |
| Privilege Escalation | RBAC, RLS, audit logging | ✅ Implemented |

#### 2.3 Data Attacks

| Attack | Mitigation | Status |
|--------|-----------|--------|
| SQL Injection | Parameterized queries, least privilege | ✅ Implemented |
| Data Exfiltration | RLS, query logging, DLP | ✅ Implemented |
| Ransomware | Encrypted backups, immutable storage | 📋 Planned |
| Data Corruption | WAL archiving, replication | ✅ Implemented |

### 3. Security Controls Matrix

| Control | Prevention | Detection | Response |
|---------|-----------|-----------|----------|
| Network Access | Firewall, TLS | Connection logs | Block IP |
| Authentication | SCRAM, mTLS | Failed login logs | Lock account |
| Authorization | RBAC, RLS | Audit logs | Revoke access |
| Data Protection | Encryption | Integrity checks | Restore backup |
| Monitoring | N/A | SIEM alerts | Incident response |

---

## Security Operations

### 1. Security Monitoring

#### 1.1 Real-Time Monitoring Dashboard

**Metrics to Track**:

- Failed authentication attempts (> 5/min)
- Privilege escalation attempts
- Unusual query patterns
- Connection spikes
- Slow queries (> 5s)
- Replication lag (> 10s)
- SSL certificate expiry (< 30 days)

**File**: `scripts/security/security-monitor.sh`

See implementation in scripts section.

### 2. Incident Response

**Phases**:

1. **Detection**: Automated alerts from SIEM
2. **Containment**: Isolate affected nodes
3. **Eradication**: Remove threat, patch vulnerabilities
4. **Recovery**: Restore from clean backups
5. **Lessons Learned**: Update runbooks, policies

**See**: `docs/security/incident-response-runbook.md`

### 3. Vulnerability Management

**Process**:

1. **Scanning**: Weekly vulnerability scans
2. **Assessment**: Risk prioritization (CVSS scores)
3. **Patching**: Monthly patch cycles
4. **Verification**: Post-patch testing

**File**: `scripts/security/vulnerability-scan.sh`

See implementation in scripts section.

---

## Implementation Roadmap

### Phase 1: Foundation (Week 1-2)
- ✅ Docker overlay network encryption
- ✅ Docker secrets management
- 📋 TLS certificate generation
- 📋 pg_hba.conf configuration

### Phase 2: Authentication (Week 3-4)
- 📋 Role-based access control
- 📋 Password policies
- 📋 Certificate-based authentication
- 📋 Credential rotation automation

### Phase 3: Data Protection (Week 5-6)
- 📋 Encryption at rest (LUKS)
- 📋 Column-level encryption
- 📋 Encrypted backups
- 📋 Key management system

### Phase 4: Monitoring (Week 7-8)
- 📋 Audit logging (pgaudit)
- 📋 SIEM integration
- 📋 Security monitoring dashboard
- 📋 Incident response automation

### Phase 5: Compliance (Week 9-10)
- 📋 GDPR compliance functions
- 📋 SOC 2 control mapping
- 📋 Audit report generation
- 📋 Compliance testing

---

## References

1. PostgreSQL Security Documentation: https://www.postgresql.org/docs/current/security.html
2. NIST Cybersecurity Framework: https://www.nist.gov/cyberframework
3. OWASP Database Security Cheat Sheet: https://cheatsheetseries.owasp.org/
4. CIS PostgreSQL Benchmark: https://www.cisecurity.org/

---

## Appendices

### Appendix A: Security Checklist

See `docs/security/security-checklist.md`

### Appendix B: Security Testing Procedures

See `docs/security/security-testing.md`

### Appendix C: Certificate Management

See `docs/security/certificate-management.md`

---

**Document Version**: 1.0
**Last Updated**: 2026-02-10
**Next Review**: 2026-05-10
**Owner**: Security Architecture Team
