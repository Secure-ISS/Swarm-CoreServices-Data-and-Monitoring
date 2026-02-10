# Incident Response Runbook
# PostgreSQL Distributed Mesh Security

## Quick Reference

| Incident Type | Severity | Response Time | Page |
|---------------|----------|---------------|------|
| Unauthorized Access | Critical | Immediate | [Link](#unauthorized-access) |
| Data Breach | Critical | Immediate | [Link](#data-breach) |
| Ransomware | Critical | Immediate | [Link](#ransomware-attack) |
| Privilege Escalation | High | < 15 min | [Link](#privilege-escalation) |
| SQL Injection | High | < 30 min | [Link](#sql-injection-attack) |
| DDoS Attack | High | < 30 min | [Link](#ddos-attack) |
| Performance Degradation | Medium | < 1 hour | [Link](#performance-degradation) |
| Certificate Expiry | Medium | < 1 hour | [Link](#certificate-expiry) |

---

## Table of Contents

1. [General Response Framework](#general-response-framework)
2. [Critical Incidents](#critical-incidents)
3. [High Priority Incidents](#high-priority-incidents)
4. [Medium Priority Incidents](#medium-priority-incidents)
5. [Post-Incident Procedures](#post-incident-procedures)
6. [Contact Information](#contact-information)

---

## General Response Framework

### Incident Response Phases

```
┌──────────────┐
│ 1. DETECT    │ → Automated alerts, monitoring, user reports
└──────────────┘
       ↓
┌──────────────┐
│ 2. TRIAGE    │ → Severity assessment, team notification
└──────────────┘
       ↓
┌──────────────┐
│ 3. CONTAIN   │ → Isolate affected systems, stop the bleeding
└──────────────┘
       ↓
┌──────────────┐
│ 4. ERADICATE │ → Remove threat, patch vulnerabilities
└──────────────┘
       ↓
┌──────────────┐
│ 5. RECOVER   │ → Restore services, verify integrity
└──────────────┘
       ↓
┌──────────────┐
│ 6. LEARN     │ → Post-mortem, update procedures
└──────────────┘
```

### Initial Response Checklist

- [ ] Verify incident is real (not false positive)
- [ ] Assess severity (Critical / High / Medium / Low)
- [ ] Notify security team / on-call engineer
- [ ] Start incident log (timestamp all actions)
- [ ] Preserve evidence (logs, snapshots)
- [ ] Follow runbook for specific incident type

---

## Critical Incidents

### Unauthorized Access

**Detection Indicators**:
- Failed authentication attempts from unknown IPs
- Successful login from unusual location/time
- Access to restricted tables/schemas
- Privilege escalation attempts

**Immediate Actions** (0-5 minutes):

```bash
# 1. Identify compromised user
PGPASSWORD=$ADMIN_PASSWORD psql -h pg-coordinator -U cluster_admin -d distributed_postgres_cluster <<EOF
SELECT
    usename,
    client_addr,
    query,
    state,
    query_start
FROM pg_stat_activity
WHERE usename NOT IN ('postgres', 'cluster_admin', 'monitor')
ORDER BY query_start DESC;
EOF

# 2. Terminate suspicious connections
PGPASSWORD=$ADMIN_PASSWORD psql -h pg-coordinator -U cluster_admin -d distributed_postgres_cluster <<EOF
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE usename = 'suspicious_user' AND client_addr = '192.168.1.100';
EOF

# 3. Lock compromised account
PGPASSWORD=$ADMIN_PASSWORD psql -h pg-coordinator -U cluster_admin -d distributed_postgres_cluster <<EOF
ALTER USER suspicious_user WITH NOLOGIN;
REVOKE ALL PRIVILEGES ON DATABASE distributed_postgres_cluster FROM suspicious_user;
EOF

# 4. Block source IP at firewall
iptables -A INPUT -s 192.168.1.100 -j DROP
iptables-save > /etc/iptables/rules.v4
```

**Investigation** (5-30 minutes):

```bash
# 1. Check authentication logs
grep "authentication failed" /var/log/postgresql/postgresql-*.log | tail -100

# 2. Audit recent queries from compromised user
PGPASSWORD=$ADMIN_PASSWORD psql -h pg-coordinator -U cluster_admin -d distributed_postgres_cluster <<EOF
SELECT
    log_time,
    user_name,
    database_name,
    remote_host,
    command_tag,
    query
FROM pg_log
WHERE user_name = 'suspicious_user'
ORDER BY log_time DESC
LIMIT 100;
EOF

# 3. Check for data exfiltration
SELECT
    schemaname,
    tablename,
    n_tup_upd,
    n_tup_del,
    last_vacuum,
    last_analyze
FROM pg_stat_user_tables
ORDER BY n_tup_upd DESC;

# 4. Review granted privileges
SELECT
    grantee,
    table_schema,
    table_name,
    privilege_type
FROM information_schema.role_table_grants
WHERE grantee = 'suspicious_user';
```

**Recovery** (30+ minutes):

```bash
# 1. Rotate all credentials
./scripts/security/rotate-credentials.sh

# 2. Review and update pg_hba.conf
# Remove any unauthorized entries

# 3. Force re-authentication for all users
SELECT pg_reload_conf();

# 4. Notify affected parties
# Send security incident notification
```

**Lessons Learned**:
- Update firewall rules to block attacker network
- Review authentication logs for patterns
- Implement MFA if not already enabled
- Update intrusion detection rules

---

### Data Breach

**Detection Indicators**:
- Large data export detected
- Unauthorized access to sensitive tables
- Data sent to external IP addresses
- Compliance alert triggered

**Immediate Actions** (0-5 minutes):

```bash
# 1. Identify affected data
PGPASSWORD=$ADMIN_PASSWORD psql -h pg-coordinator -U cluster_admin -d distributed_postgres_cluster <<EOF
-- Check recent SELECT queries on sensitive tables
SELECT
    log_time,
    user_name,
    remote_host,
    query
FROM pg_log
WHERE query ILIKE '%sensitive_table%'
AND command_tag = 'SELECT'
AND log_time > now() - INTERVAL '1 hour'
ORDER BY log_time DESC;
EOF

# 2. Stop all external connections
iptables -A INPUT -p tcp --dport 5432 -j DROP
iptables -A INPUT -p tcp --dport 6432 -j DROP

# 3. Isolate affected nodes
docker service scale postgres-worker-1=0

# 4. Capture network traffic
tcpdump -i eth0 -w /tmp/breach-capture.pcap port 5432
```

**Legal Compliance** (5-30 minutes):

```bash
# 1. Document breach scope
# - Number of records affected
# - Type of data (PII, PHI, financial, etc.)
# - Time window of exposure
# - Affected users/customers

# 2. Notify legal team (GDPR requires notification within 72 hours)

# 3. Preserve evidence
# - Database snapshots
# - Network logs
# - Authentication logs
# - Query logs

# 4. Create forensic backup
pg_dump -h pg-coordinator -U cluster_admin -Fc distributed_postgres_cluster \
    > /secure/forensics/breach-$(date +%Y%m%d-%H%M%S).dump
```

**Data Containment**:

```sql
-- Encrypt affected columns if not already encrypted
ALTER TABLE sensitive_data
    ALTER COLUMN ssn TYPE bytea USING pgp_sym_encrypt(ssn::text, 'encryption_key');

-- Enable RLS on affected tables
ALTER TABLE sensitive_data ENABLE ROW LEVEL SECURITY;

-- Revoke excessive permissions
REVOKE ALL ON TABLE sensitive_data FROM PUBLIC;
REVOKE ALL ON TABLE sensitive_data FROM app_writer;
GRANT SELECT ON TABLE sensitive_data TO app_writer WHERE user_id = current_user;
```

**Notification Requirements**:

| Regulation | Notification Timeline | Authority |
|------------|----------------------|-----------|
| GDPR | 72 hours | Data Protection Authority |
| HIPAA | 60 days | HHS Office for Civil Rights |
| CCPA | Without unreasonable delay | California AG |
| SOC 2 | Per contract | Auditor + Customers |

---

### Ransomware Attack

**Detection Indicators**:
- Encrypted files in database directories
- Unusual CPU/disk activity
- Ransom note files
- Inaccessible database

**Immediate Actions** (0-5 minutes):

```bash
# 1. ISOLATE IMMEDIATELY - Do not attempt recovery without isolation
# Disconnect from network
ifconfig eth0 down

# 2. Stop PostgreSQL services
docker service scale postgres-coordinator=0
docker service scale postgres-worker-1=0
docker service scale postgres-worker-2=0
docker service scale postgres-worker-3=0

# 3. Preserve evidence
dd if=/dev/sda of=/mnt/forensics/disk-image.img bs=4M

# 4. Notify security team (DO NOT pay ransom)
```

**DO NOT**:
- ❌ Pay the ransom
- ❌ Restart services
- ❌ Delete or modify files
- ❌ Connect to network

**Recovery Procedure**:

```bash
# 1. Verify backups are clean (scan for malware)
clamscan -r /backups/latest-backup.dump.gpg

# 2. Restore from clean backup
# Use backup from BEFORE infection (check timestamps)
gpg --decrypt --passphrase-file /run/secrets/backup_encryption_key \
    /backups/backup_20260208_020000.dump.gpg | \
    pg_restore -h pg-coordinator-new -U cluster_admin -d distributed_postgres_cluster

# 3. Build new infrastructure from scratch
# DO NOT restore to infected infrastructure

# 4. Update all credentials
./scripts/security/rotate-credentials.sh

# 5. Harden security
# - Update firewall rules
# - Enable disk encryption
# - Implement immutable backups
```

**Prevention**:
- Implement immutable backups (AWS S3 Object Lock, Azure Immutable Blob Storage)
- Enable disk encryption (LUKS)
- Regular vulnerability scanning
- Network segmentation
- Principle of least privilege

---

## High Priority Incidents

### Privilege Escalation

**Detection**:
- User attempting to escalate privileges
- Suspicious GRANT/REVOKE operations
- Access to pg_authid table

**Response**:

```sql
-- 1. Identify escalation attempt
SELECT
    log_time,
    user_name,
    command_tag,
    query
FROM pg_log
WHERE command_tag IN ('GRANT', 'REVOKE', 'ALTER ROLE')
ORDER BY log_time DESC;

-- 2. Revoke unauthorized privileges
REVOKE ALL PRIVILEGES ON DATABASE distributed_postgres_cluster FROM suspicious_user;
REVOKE ALL ON SCHEMA public FROM suspicious_user;

-- 3. Reset user to baseline
ALTER USER suspicious_user NOCREATEROLE NOCREATEDB NOREPLICATION NOBYPASSRLS;

-- 4. Audit all roles
SELECT
    rolname,
    rolsuper,
    rolcreaterole,
    rolcreatedb,
    rolcanlogin,
    rolbypassrls
FROM pg_roles
WHERE rolname NOT IN ('postgres')
ORDER BY rolsuper DESC, rolcreaterole DESC;
```

---

### SQL Injection Attack

**Detection**:
- Unusual SQL syntax in query logs
- Error messages in application logs
- Increased query volume

**Response**:

```bash
# 1. Identify injection attempts
grep -E "(UNION SELECT|' OR '1'='1|; DROP TABLE)" /var/log/postgresql/postgresql-*.log

# 2. Block malicious queries
# Add to postgresql.conf:
# statement_timeout = 5000  # 5 seconds
# idle_in_transaction_session_timeout = 10000  # 10 seconds

# 3. Terminate suspicious sessions
PGPASSWORD=$ADMIN_PASSWORD psql -h pg-coordinator -U cluster_admin -d distributed_postgres_cluster <<EOF
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE query LIKE '%UNION SELECT%' OR query LIKE '%OR 1=1%';
EOF

# 4. Review application code
# - Use parameterized queries
# - Implement input validation
# - Escape special characters
```

**Prevention**:
```python
# Bad (vulnerable to SQL injection)
cursor.execute(f"SELECT * FROM users WHERE username = '{username}'")

# Good (parameterized query)
cursor.execute("SELECT * FROM users WHERE username = %s", (username,))
```

---

### DDoS Attack

**Detection**:
- Sudden spike in connections
- High CPU/memory usage
- Connection pool exhaustion

**Response**:

```bash
# 1. Identify attacking IPs
netstat -ntu | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -nr | head -20

# 2. Block attacking IPs
for ip in $(netstat -ntu | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -nr | head -20 | awk '{print $2}'); do
    iptables -A INPUT -s $ip -j DROP
done

# 3. Enable connection rate limiting
# Add to postgresql.conf:
# max_connections = 200
# superuser_reserved_connections = 10

# 4. Scale PgBouncer instances
docker service scale postgres-pgbouncer=5

# 5. Implement geo-blocking (if appropriate)
# Use CloudFlare, AWS WAF, or nginx geo module
```

**Long-term Solutions**:
- Implement rate limiting (nginx, HAProxy)
- Use connection pooling (PgBouncer)
- Enable DDoS protection (CloudFlare, AWS Shield)
- Geographic distribution (multi-region deployment)

---

## Medium Priority Incidents

### Certificate Expiry

**Detection**:
```bash
# Check certificate expiry
./config/security/certs/check-cert-expiry.sh
```

**Response**:

```bash
# 1. Generate new certificates
./scripts/security/generate-certificates.sh --renew

# 2. Update Docker secrets
docker secret rm postgres_server_cert
docker secret create postgres_server_cert config/security/certs/coordinator.crt

# 3. Rolling restart services
docker service update --force postgres-coordinator

# 4. Verify new certificate
openssl s_client -connect pg-coordinator:5432 -starttls postgres | \
    openssl x509 -noout -dates
```

**Prevention**:
- Set up automated monitoring (30 days before expiry)
- Use Let's Encrypt for auto-renewal (if applicable)
- Calendar reminder for manual certificates

---

### Performance Degradation

**Detection**:
- Slow query logs
- High CPU/memory usage
- Connection timeouts

**Response**:

```sql
-- 1. Identify slow queries
SELECT
    query,
    calls,
    total_time,
    mean_time,
    max_time
FROM pg_stat_statements
ORDER BY mean_time DESC
LIMIT 20;

-- 2. Check blocking queries
SELECT
    blocked.pid,
    blocked.usename,
    blocked.query AS blocked_query,
    blocking.pid AS blocking_pid,
    blocking.query AS blocking_query
FROM pg_stat_activity AS blocked
JOIN pg_stat_activity AS blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.wait_event_type = 'Lock';

-- 3. Terminate long-running queries
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'active' AND query_start < now() - INTERVAL '10 minutes';

-- 4. Analyze and vacuum
VACUUM ANALYZE;
```

---

## Post-Incident Procedures

### Incident Documentation

**Required Information**:
- Incident timeline (detection → resolution)
- Affected systems and data
- Actions taken
- Root cause analysis
- Preventive measures

**Template**: See `incident-report-template.md`

### Post-Mortem Meeting

**Agenda**:
1. What happened?
2. What was the impact?
3. What went well?
4. What could be improved?
5. Action items

**Output**: Post-mortem document with action items assigned

### System Hardening

**Follow-up Actions**:
- Update runbooks based on lessons learned
- Patch identified vulnerabilities
- Implement additional monitoring
- Update security policies
- Conduct security training

---

## Contact Information

### Emergency Contacts

| Role | Contact | Phone | Email |
|------|---------|-------|-------|
| Security Lead | John Doe | +1-555-0100 | security@example.com |
| Database Admin | Jane Smith | +1-555-0101 | dba@example.com |
| Network Engineer | Bob Wilson | +1-555-0102 | neteng@example.com |
| Legal Counsel | Sarah Jones | +1-555-0103 | legal@example.com |

### Escalation Matrix

| Severity | First Contact | Escalation (15 min) | Executive (30 min) |
|----------|--------------|---------------------|-------------------|
| Critical | On-call Security | Security Lead | CTO / CISO |
| High | On-call DBA | Database Manager | VP Engineering |
| Medium | Team Lead | Department Manager | N/A |

### External Resources

- **PostgreSQL Security**: security@postgresql.org
- **CERT Coordination**: https://www.kb.cert.org/vuls/report/
- **GDPR Violations**: [Your DPA Contact]
- **Law Enforcement**: [Local Cybercrime Unit]

---

## Runbook Maintenance

**Review Schedule**: Quarterly
**Last Updated**: 2026-02-10
**Next Review**: 2026-05-10
**Owner**: Security Team

**Version History**:
- v1.0 (2026-02-10): Initial version
