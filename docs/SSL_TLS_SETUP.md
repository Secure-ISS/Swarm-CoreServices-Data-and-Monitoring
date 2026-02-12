# SSL/TLS Setup Guide for Distributed PostgreSQL Cluster

## Security Advisory: SEC-002

**Issue**: Database connections transmit passwords in plaintext
**Severity**: HIGH (CVSS 7.4)
**Resolution**: Enable SSL/TLS encryption for all database connections

## Overview

This guide covers SSL/TLS configuration for the Distributed PostgreSQL Cluster to encrypt all database connections and prevent man-in-the-middle attacks.

## SSL/TLS Modes

PostgreSQL supports several SSL modes, ordered by increasing security:

| Mode | Security Level | Description | Certificate Required |
|------|---------------|-------------|---------------------|
| `disable` | None | No SSL (NOT RECOMMENDED) | No |
| `allow` | Low | Try non-SSL first, then SSL | No |
| `prefer` | Medium | Try SSL first, fall back to non-SSL (DEFAULT) | No |
| `require` | High | Require SSL, no certificate verification | No |
| `verify-ca` | Very High | Require SSL, verify server certificate | Yes (CA cert) |
| `verify-full` | Maximum | Require SSL, verify certificate + hostname | Yes (CA cert) |

### Recommended Configuration

- **Development**: `prefer` (allows both SSL and non-SSL)
- **Staging**: `require` (enforces SSL)
- **Production**: `verify-full` (maximum security)

## Quick Start

### 1. Generate SSL Certificates

For development and testing, generate self-signed certificates:

```bash
# Run the certificate generation script
./scripts/generate_ssl_certs.sh
```

This creates:
- `certs/ca.crt` - Certificate Authority certificate
- `certs/server.crt` - Server certificate
- `certs/server.key` - Server private key
- `certs/client.crt` - Client certificate
- `certs/client.key` - Client private key

### 2. Configure PostgreSQL Server

Update `postgresql.conf`:

```conf
# SSL Configuration
ssl = on
ssl_cert_file = '/path/to/certs/server.crt'
ssl_key_file = '/path/to/certs/server.key'
ssl_ca_file = '/path/to/certs/ca.crt'

# Cipher configuration (optional but recommended)
ssl_ciphers = 'HIGH:MEDIUM:+3DES:!aNULL'
ssl_prefer_server_ciphers = on
ssl_min_protocol_version = 'TLSv1.2'
```

Update `pg_hba.conf` to require SSL:

```conf
# TYPE  DATABASE        USER            ADDRESS                 METHOD  OPTIONS
hostssl all             all             0.0.0.0/0               md5
hostnossl all           all             0.0.0.0/0               reject
```

Restart PostgreSQL:

```bash
docker restart ruvector-db
# OR for system PostgreSQL:
sudo systemctl restart postgresql
```

### 3. Configure Client Connections

Update `.env` file:

```bash
# Project Database SSL Configuration
RUVECTOR_SSLMODE=require
RUVECTOR_SSLROOTCERT=/path/to/certs/ca.crt
RUVECTOR_SSLCERT=/path/to/certs/client.crt
RUVECTOR_SSLKEY=/path/to/certs/client.key

# Shared Database SSL Configuration
SHARED_KNOWLEDGE_SSLMODE=require
SHARED_KNOWLEDGE_SSLROOTCERT=/path/to/certs/ca.crt
SHARED_KNOWLEDGE_SSLCERT=/path/to/certs/client.crt
SHARED_KNOWLEDGE_SSLKEY=/path/to/certs/client.key

# Distributed Cluster SSL Configuration
DISTRIBUTED_SSLMODE=require
DISTRIBUTED_SSLROOTCERT=/path/to/certs/ca.crt
DISTRIBUTED_SSLCERT=/path/to/certs/client.crt
DISTRIBUTED_SSLKEY=/path/to/certs/client.key
```

### 4. Verify SSL/TLS Connection

Run the health check:

```bash
python scripts/db_health_check.py
```

Expected output:
```
✓ SSL/TLS: Enabled (cipher: ECDHE-RSA-AES256-GCM-SHA384)
```

## Docker Configuration

### Using Self-Signed Certificates with Docker

Mount certificates into the container:

```bash
docker run -d --name ruvector-db \
  -e POSTGRES_PASSWORD=your_password \
  -p 5432:5432 \
  -v $(pwd)/certs:/etc/postgresql/certs:ro \
  -v $(pwd)/docker/postgresql.conf:/etc/postgresql/postgresql.conf \
  ruvnet/ruvector-postgres \
  -c config_file=/etc/postgresql/postgresql.conf
```

Create `docker/postgresql.conf`:

```conf
ssl = on
ssl_cert_file = '/etc/postgresql/certs/server.crt'
ssl_key_file = '/etc/postgresql/certs/server.key'
ssl_ca_file = '/etc/postgresql/certs/ca.crt'
```

### Using Let's Encrypt Certificates

For production with public domains:

```bash
# Install certbot
sudo apt-get install certbot

# Generate certificates (requires domain and HTTP server)
sudo certbot certonly --standalone -d your-database-domain.com

# Link to PostgreSQL directory
sudo ln -s /etc/letsencrypt/live/your-database-domain.com/fullchain.pem /path/to/server.crt
sudo ln -s /etc/letsencrypt/live/your-database-domain.com/privkey.pem /path/to/server.key
```

## Certificate Management

### Certificate Expiration

Check certificate expiration:

```bash
openssl x509 -in certs/server.crt -noout -enddate
```

### Automatic Renewal

Add to cron for Let's Encrypt renewal:

```bash
# Renew certificates monthly
0 0 1 * * certbot renew --quiet && systemctl reload postgresql
```

### Certificate Rotation

1. Generate new certificates
2. Update PostgreSQL configuration
3. Reload PostgreSQL (no restart needed):
   ```bash
   docker exec ruvector-db pg_ctl reload
   ```
4. Update client `.env` files
5. Restart applications

## Security Best Practices

### 1. Use Strong Ciphers

Configure PostgreSQL to use only strong cipher suites:

```conf
ssl_ciphers = 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256'
ssl_prefer_server_ciphers = on
ssl_min_protocol_version = 'TLSv1.2'
```

### 2. Disable Non-SSL Connections

Update `pg_hba.conf`:

```conf
# Reject non-SSL connections
hostnossl all all 0.0.0.0/0 reject

# Allow only SSL connections
hostssl all all 0.0.0.0/0 scram-sha-256
```

### 3. Use Client Certificates (Mutual TLS)

For maximum security, require client certificates:

```conf
# pg_hba.conf
hostssl all all 0.0.0.0/0 cert clientcert=verify-full
```

Update `.env`:

```bash
RUVECTOR_SSLMODE=verify-full
RUVECTOR_SSLCERT=/path/to/client.crt
RUVECTOR_SSLKEY=/path/to/client.key
```

### 4. Protect Private Keys

Set strict permissions:

```bash
chmod 600 certs/*.key
chown postgres:postgres certs/server.key
chmod 644 certs/*.crt
```

### 5. Certificate Pinning (Advanced)

For high-security environments, implement certificate pinning in application code to prevent certificate substitution attacks.

## Troubleshooting

### Connection Fails with "SSL required"

**Error**: `connection requires a valid client certificate`

**Solution**: Set correct SSL mode in `.env`:
```bash
RUVECTOR_SSLMODE=require
```

### Certificate Verification Failed

**Error**: `certificate verify failed`

**Solutions**:
1. Check CA certificate path is correct
2. Verify certificate hasn't expired
3. Ensure hostname matches certificate CN/SAN
4. Use `verify-ca` instead of `verify-full` if hostname doesn't match

### Permission Denied on Private Key

**Error**: `private key file has group or world access`

**Solution**: Fix permissions:
```bash
chmod 600 /path/to/server.key
chown postgres:postgres /path/to/server.key
```

### SSL Not Available

**Error**: `SSL is not supported by this build`

**Solution**: Ensure PostgreSQL was compiled with SSL support:
```bash
postgres -V  # Check for SSL support
```

Use official PostgreSQL Docker image which includes SSL support.

## Monitoring SSL/TLS Connections

### Check Current Connections

```sql
SELECT
    datname,
    usename,
    client_addr,
    ssl,
    version AS ssl_version,
    cipher
FROM pg_stat_ssl
JOIN pg_stat_activity ON pg_stat_ssl.pid = pg_stat_activity.pid;
```

### Verify All Connections Use SSL

```sql
SELECT COUNT(*) as total_connections,
       SUM(CASE WHEN ssl THEN 1 ELSE 0 END) as ssl_connections,
       SUM(CASE WHEN NOT ssl THEN 1 ELSE 0 END) as non_ssl_connections
FROM pg_stat_ssl
JOIN pg_stat_activity ON pg_stat_ssl.pid = pg_stat_activity.pid
WHERE backend_type = 'client backend';
```

### Alert on Non-SSL Connections

Create a monitoring query:

```sql
-- Alert if any non-SSL connections exist
SELECT
    current_timestamp,
    usename,
    client_addr,
    'SECURITY ALERT: Non-SSL connection detected'
FROM pg_stat_ssl
JOIN pg_stat_activity ON pg_stat_ssl.pid = pg_stat_activity.pid
WHERE NOT ssl
  AND backend_type = 'client backend';
```

## Production Deployment Checklist

- [ ] Generate production certificates (Let's Encrypt or commercial CA)
- [ ] Configure PostgreSQL with `ssl = on`
- [ ] Set `ssl_min_protocol_version = 'TLSv1.2'` or higher
- [ ] Configure strong cipher suites
- [ ] Update `pg_hba.conf` to require SSL
- [ ] Restart PostgreSQL server
- [ ] Update all client `.env` files with SSL settings
- [ ] Set `SSLMODE=verify-full` for production
- [ ] Verify SSL connections with health check
- [ ] Set up certificate renewal automation
- [ ] Configure monitoring for non-SSL connections
- [ ] Update firewall rules if needed
- [ ] Document certificate locations and renewal procedures
- [ ] Test connection failure scenarios
- [ ] Implement certificate rotation procedure

## Performance Impact

SSL/TLS encryption has minimal performance impact on modern systems:

- **CPU overhead**: ~2-5% (negligible with AES-NI hardware acceleration)
- **Latency increase**: <1ms per connection
- **Throughput**: No significant impact for typical workloads

Benefits far outweigh the minimal overhead:
- Prevents password interception
- Protects data in transit
- Compliance with security standards (PCI-DSS, HIPAA, SOC 2)

## Compliance

SSL/TLS encryption is required for:

- **PCI-DSS**: All credit card data transmission must be encrypted
- **HIPAA**: Protected Health Information (PHI) must be encrypted in transit
- **GDPR**: Personal data must be protected with appropriate security measures
- **SOC 2**: Requires encryption of sensitive data in transit

## References

- [PostgreSQL SSL Support Documentation](https://www.postgresql.org/docs/current/ssl-tcp.html)
- [psycopg2 SSL Parameters](https://www.psycopg.org/docs/module.html#psycopg2.connect)
- [OpenSSL Certificate Generation](https://www.openssl.org/docs/man1.1.1/man1/openssl-req.html)
- [Let's Encrypt Documentation](https://letsencrypt.org/docs/)
- [Mozilla SSL Configuration Generator](https://ssl-config.mozilla.org/)

## Support

For issues or questions:
1. Check troubleshooting section above
2. Run `python scripts/db_health_check.py` for diagnostics
3. Review PostgreSQL logs: `docker logs ruvector-db`
4. Open an issue in the project repository
