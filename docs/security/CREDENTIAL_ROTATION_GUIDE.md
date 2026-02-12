# Credential Rotation Guide

## Overview

This guide provides procedures for rotating database credentials in the Distributed PostgreSQL Cluster system. Regular credential rotation is a critical security practice that reduces the risk of unauthorized access.

## Rotation Schedule

**Recommended Rotation Intervals:**
- **Production**: Every 90 days
- **Staging**: Every 180 days
- **Development**: Every 365 days or as needed
- **Compromised Credentials**: Immediately

## Prerequisites

Before rotating credentials, ensure you have:
- [ ] Administrator access to all database instances
- [ ] Access to environment configuration files
- [ ] Ability to restart application services
- [ ] Backup of current configuration
- [ ] Scheduled maintenance window

## Rotation Procedures

### 1. Generate New Strong Passwords

```bash
# Generate a 32-character password
openssl rand -base64 32

# Or use Python
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

### 2. Update Database User Passwords

#### For Project Database (RuVector)

```sql
-- Connect as superuser
psql -h localhost -U postgres

-- Rotate password for dpg_cluster user
ALTER USER dpg_cluster WITH PASSWORD 'NEW_STRONG_PASSWORD';

-- Verify the change
\du dpg_cluster
```

#### For Shared Knowledge Database

```sql
-- Connect as superuser
psql -h localhost -U postgres

-- Rotate password for shared_user
ALTER USER shared_user WITH PASSWORD 'NEW_STRONG_PASSWORD';

-- Verify the change
\du shared_user
```

#### For Coordinator/Worker Nodes

```sql
-- On each coordinator node
ALTER USER dpg_cluster WITH PASSWORD 'NEW_COORDINATOR_PASSWORD';

-- On each worker node (if different user)
ALTER USER worker_user WITH PASSWORD 'NEW_WORKER_PASSWORD';
```

### 3. Update Environment Configuration

#### Update .env File

```bash
# Backup current .env
cp .env .env.backup.$(date +%Y%m%d)

# Edit .env with new passwords
nano .env
```

Update these variables:
```bash
# RuVector Database
RUVECTOR_PASSWORD=NEW_STRONG_PASSWORD

# Shared Knowledge Database
SHARED_KNOWLEDGE_PASSWORD=NEW_STRONG_PASSWORD

# Distributed Cluster
COORDINATOR_PASSWORD=NEW_COORDINATOR_PASSWORD
WORKER_PASSWORDS=NEW_WORKER_PASS_1,NEW_WORKER_PASS_2
REPLICA_PASSWORDS=NEW_REPLICA_PASS_1,NEW_REPLICA_PASS_2

# Docker Container
POSTGRES_PASSWORD=NEW_POSTGRES_PASSWORD
```

### 4. Update Docker Secrets (Production)

For production deployments using Docker Swarm/Kubernetes:

```bash
# Remove old secret
docker secret rm postgres_password

# Create new secret
echo "NEW_STRONG_PASSWORD" | docker secret create postgres_password -

# Update service to use new secret
docker service update --secret-rm postgres_password \
  --secret-add postgres_password \
  distributed-postgres-service
```

### 5. Restart Services

```bash
# Stop application services
docker-compose down

# Or stop Python application
pkill -f "python.*your_app.py"

# Restart with new credentials
docker-compose up -d

# Or restart Python application
python your_app.py
```

### 6. Verify Connectivity

```bash
# Run health check
python scripts/db_health_check.py

# Test vector operations
python src/test_vector_ops.py

# Check connection pools
python -c "from src.db.pool import DualDatabasePools; pools = DualDatabasePools()"
```

### 7. Update CI/CD Secrets

If using CI/CD pipelines, update secrets in:

#### GitHub Actions
```bash
# Via GitHub UI: Settings > Secrets and variables > Actions
# Or via CLI:
gh secret set RUVECTOR_PASSWORD --body "NEW_PASSWORD"
gh secret set SHARED_KNOWLEDGE_PASSWORD --body "NEW_PASSWORD"
gh secret set COORDINATOR_PASSWORD --body "NEW_PASSWORD"
```

#### GitLab CI/CD
```bash
# Via GitLab UI: Settings > CI/CD > Variables
# Or via CLI:
gitlab-ci-variables set RUVECTOR_PASSWORD "NEW_PASSWORD"
```

## Emergency Rotation (Compromised Credentials)

If credentials are compromised, follow these steps immediately:

### 1. Assess the Breach
- Identify which credentials were exposed
- Check access logs for unauthorized activity
- Document the incident

### 2. Immediate Actions
```sql
-- Terminate all active connections
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE usename = 'compromised_user'
  AND pid <> pg_backend_pid();

-- Change password immediately
ALTER USER compromised_user WITH PASSWORD 'EMERGENCY_NEW_PASSWORD';

-- Optionally disable user temporarily
ALTER USER compromised_user WITH NOLOGIN;
```

### 3. Audit Access
```sql
-- Check recent login attempts
SELECT *
FROM pg_stat_activity
WHERE usename = 'compromised_user'
ORDER BY backend_start DESC;

-- Check for suspicious queries (if logging enabled)
SELECT *
FROM pg_stat_statements
WHERE userid = (SELECT oid FROM pg_roles WHERE rolname = 'compromised_user')
ORDER BY calls DESC;
```

### 4. Follow Normal Rotation Procedure
Complete steps 1-7 from the standard rotation procedure.

### 5. Post-Incident
- Review security logs
- Update incident response documentation
- Consider additional security measures (IP whitelisting, MFA)

## Automation Scripts

### Automated Rotation Script

Create `/home/matt/projects/Distributed-Postgress-Cluster/scripts/security/rotate_credentials.sh`:

```bash
#!/bin/bash
# Automated credential rotation script

set -e

# Generate new passwords
NEW_RUVECTOR_PASS=$(openssl rand -base64 32)
NEW_SHARED_PASS=$(openssl rand -base64 32)
NEW_COORDINATOR_PASS=$(openssl rand -base64 32)

# Update PostgreSQL
psql -h localhost -U postgres -c "ALTER USER dpg_cluster WITH PASSWORD '$NEW_RUVECTOR_PASS';"
psql -h localhost -U postgres -c "ALTER USER shared_user WITH PASSWORD '$NEW_SHARED_PASS';"

# Backup current .env
cp .env .env.backup.$(date +%Y%m%d_%H%M%S)

# Update .env file
sed -i "s/^RUVECTOR_PASSWORD=.*/RUVECTOR_PASSWORD=$NEW_RUVECTOR_PASS/" .env
sed -i "s/^SHARED_KNOWLEDGE_PASSWORD=.*/SHARED_KNOWLEDGE_PASSWORD=$NEW_SHARED_PASS/" .env
sed -i "s/^COORDINATOR_PASSWORD=.*/COORDINATOR_PASSWORD=$NEW_COORDINATOR_PASS/" .env

# Restart services
docker-compose restart

# Verify
python scripts/db_health_check.py

echo "✓ Credential rotation complete"
```

### Rotation Reminder Cron Job

```bash
# Add to crontab to check rotation schedule
# Run weekly check on Mondays at 9am
0 9 * * 1 /path/to/check_rotation_schedule.sh
```

## Rollback Procedure

If rotation causes issues:

```bash
# Restore previous .env
cp .env.backup.YYYYMMDD .env

# Restart services
docker-compose restart

# Or restore database passwords manually
psql -h localhost -U postgres -c "ALTER USER dpg_cluster WITH PASSWORD 'OLD_PASSWORD';"
```

## Security Best Practices

1. **Never commit passwords to version control**
   - Always use `.env` files (git-ignored)
   - Use Docker secrets or Kubernetes secrets in production

2. **Use strong password generation**
   - Minimum 32 characters
   - Use cryptographically secure random generators
   - Avoid predictable patterns

3. **Secure password storage**
   - Encrypt `.env` files at rest
   - Use hardware security modules (HSM) for production
   - Implement access controls on credential files

4. **Audit and logging**
   - Enable PostgreSQL audit logging
   - Monitor failed authentication attempts
   - Set up alerts for suspicious activity

5. **Testing**
   - Always test credential rotation in staging first
   - Verify all services can connect after rotation
   - Have rollback plan ready

## Compliance Requirements

### SOC 2 / ISO 27001
- Document all credential rotations
- Maintain audit trail
- Follow 90-day rotation schedule

### PCI DSS
- Rotate credentials quarterly
- Use strong passwords (12+ characters)
- Implement multi-factor authentication

### HIPAA
- Rotate credentials every 90 days
- Implement password complexity requirements
- Log all credential access

## Troubleshooting

### Connection Failures After Rotation

```python
# Test connection manually
import psycopg2
import os

try:
    conn = psycopg2.connect(
        host=os.getenv("RUVECTOR_HOST"),
        port=int(os.getenv("RUVECTOR_PORT")),
        database=os.getenv("RUVECTOR_DB"),
        user=os.getenv("RUVECTOR_USER"),
        password=os.getenv("RUVECTOR_PASSWORD")
    )
    print("✓ Connection successful")
except Exception as e:
    print(f"✗ Connection failed: {e}")
```

### Password Not Updated

```sql
-- Check when password was last changed
SELECT rolname, rolvaliduntil
FROM pg_authid
WHERE rolname IN ('dpg_cluster', 'shared_user');
```

### Services Not Recognizing New Password

```bash
# Clear connection pool cache
docker-compose restart

# Or reload application
systemctl reload your-app.service
```

## Contact and Support

For issues or questions about credential rotation:
- Internal Security Team: security@yourorg.com
- DevOps On-Call: devops-oncall@yourorg.com
- Emergency Hotline: +1-XXX-XXX-XXXX

## Related Documentation

- [Security Audit Report](/home/matt/projects/Distributed-Postgress-Cluster/docs/security/SECURITY-AUDIT-REPORT.md)
- [Error Handling Guide](/home/matt/projects/Distributed-Postgress-Cluster/docs/ERROR_HANDLING.md)
- [Database Health Check](/home/matt/projects/Distributed-Postgress-Cluster/scripts/db_health_check.py)
