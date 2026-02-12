# Traefik Production Deployment Guide

## Overview

This guide explains how to integrate the Distributed PostgreSQL Cluster with existing Traefik infrastructure in production.

## Architecture

```
                   ┌─────────────┐
                   │   Traefik   │ (Already exists in prod)
                   │   (HA LB)   │
                   └──────┬──────┘
                          │
        ┌─────────────────┼─────────────────┐
        │                 │                 │
    patroni-1         patroni-2         patroni-3
    (Replica)         (Leader)          (Replica)
        │                 │                 │
    Port 5432         Port 5432         Port 5432
    Port 8008         Port 8008         Port 8008
```

## Configuration Options

### Option 1: Static Configuration (Recommended)

**Pros**: Explicit control, predictable behavior
**Cons**: Requires Traefik restart/reload

1. Copy `config/traefik/postgresql-tcp.yml` to Traefik's dynamic config directory:
   ```bash
   cp config/traefik/postgresql-tcp.yml /etc/traefik/dynamic/
   ```

2. Verify Traefik static config has PostgreSQL entryPoints:
   ```yaml
   # /etc/traefik/traefik.yml
   entryPoints:
     postgres:
       address: ":5432"
     postgres-ro:
       address: ":5433"  # Optional: read-only endpoint
   ```

3. Restart Traefik:
   ```bash
   docker restart traefik
   # OR systemctl restart traefik
   ```

### Option 2: Docker Labels (Auto-Discovery)

**Pros**: Automatic service discovery, no Traefik restart
**Cons**: Requires Patroni containers on Traefik network

1. Connect Patroni containers to Traefik network:
   ```bash
   docker network connect traefik-network patroni-1
   docker network connect traefik-network patroni-2
   docker network connect traefik-network patroni-3
   ```

2. Add labels to docker-compose.yml (see `config/traefik/docker-labels.yml`)

3. Restart Patroni containers:
   ```bash
   docker-compose restart
   ```

## Connection Strings

### Primary (Read-Write)
```bash
# Via Traefik
psql "host=traefik-host port=5432 dbname=postgres user=app_user sslmode=require"

# Python
POSTGRES_URL = "postgresql://app_user:password@traefik-host:5432/postgres?sslmode=require"
```

### Read Replicas (Read-Only)
```bash
# Via Traefik read-only endpoint
psql "host=traefik-host port=5433 dbname=postgres user=readonly_user sslmode=require"
```

## Health Checks

Traefik health checks work via:
1. **TCP dial** - Checks if port 5432 is accepting connections
2. **Patroni REST API** (optional) - Check port 8008 for `/health` endpoint

### Patroni Health Check Endpoint
```bash
# Check leader status
curl http://patroni-2:8008/leader
# Returns 200 if this node is the leader

# Check replica status
curl http://patroni-1:8008/replica
# Returns 200 if this node is a healthy replica

# Check overall health
curl http://patroni-2:8008/health
# Returns 200 if node is healthy
```

## SSL/TLS Configuration

### Passthrough Mode (Recommended)
```yaml
tls:
  passthrough: true  # Let PostgreSQL handle SSL/TLS
```

**Pros**:
- End-to-end encryption
- PostgreSQL handles cert verification
- No TLS termination overhead

**Cons**:
- Traefik cannot inspect traffic
- Cannot use Traefik's cert management

### TLS Termination Mode (Alternative)
```yaml
tls:
  certResolver: letsencrypt
  domains:
    - main: postgres.example.com
```

**Pros**:
- Centralized cert management
- Can use Let's Encrypt
- Traffic inspection possible

**Cons**:
- TLS overhead at Traefik
- PostgreSQL connection not encrypted internally

## Monitoring & Metrics

### Traefik Metrics
```bash
# Check backend health
curl http://traefik-host:8080/api/http/services/postgres-cluster

# View active connections
curl http://traefik-host:8080/api/tcp/services/postgres-cluster
```

### PostgreSQL Metrics
- Already exposed via Prometheus postgres-exporter on port 9187
- Grafana dashboards at http://grafana-host:3000

## Failover Behavior

### Automatic Patroni Failover
1. **Leader fails** (e.g., patroni-2 crashes)
2. **etcd detects failure** (~3 seconds)
3. **Patroni elects new leader** (e.g., patroni-1 promoted)
4. **Traefik health check fails** on old leader (~10 seconds)
5. **Traefik routes to new leader** automatically

**Total failover time**: ~13 seconds (Patroni: 3s + Traefik: 10s)

### Traefik Load Balancing
- Traefik doesn't care which node is the leader
- **Patroni handles routing** - all nodes can accept connections
- Non-leader nodes proxy writes to current leader
- Reads can be served from any node

## Production Checklist

- [ ] Traefik has PostgreSQL entryPoints configured (5432, 5433)
- [ ] Patroni containers accessible from Traefik network
- [ ] Health checks configured (interval: 10s, timeout: 3s)
- [ ] SSL passthrough enabled
- [ ] Connection strings updated in application config
- [ ] Monitoring dashboards updated (Grafana)
- [ ] Alert rules configured (Prometheus)
- [ ] Firewall rules allow Traefik → Patroni (5432, 8008)
- [ ] DNS records point to Traefik (postgres.example.com)
- [ ] Connection pooling configured (PgBouncer on 6432)
- [ ] Backup verification (pgBackRest)
- [ ] Disaster recovery plan documented
- [ ] Runbook updated with Traefik troubleshooting

## Troubleshooting

### Cannot Connect via Traefik
```bash
# 1. Check Traefik logs
docker logs traefik | grep postgres

# 2. Check Patroni is accessible
curl http://patroni-2:8008/health

# 3. Test direct connection
psql -h patroni-2 -p 5432 -U postgres

# 4. Check Traefik routing
curl http://traefik-host:8080/api/tcp/routers
```

### Traefik Routes to Wrong Node
```bash
# Check current leader
patronictl -c /etc/patroni/patroni.yml list

# Force health check refresh
# Traefik will auto-detect in ~10 seconds
```

### High Latency
```bash
# Check if Traefik is the bottleneck
# Direct connection:
time psql -h patroni-2 -p 5432 -c "SELECT 1"

# Via Traefik:
time psql -h traefik-host -p 5432 -c "SELECT 1"

# If Traefik adds >5ms, consider direct connections
```

## Migration from HAProxy to Traefik

### Pre-Migration
1. Deploy Traefik configuration (static or labels)
2. Verify health checks working
3. Test connections via Traefik
4. Update monitoring to include Traefik metrics

### Migration Day
1. Update DNS: `postgres.example.com` → Traefik IP
2. Update application connection strings
3. Monitor error rates and latency
4. Keep HAProxy running as fallback for 24h

### Post-Migration
1. Remove HAProxy after 24h of stable operation
2. Archive HAProxy configuration
3. Update documentation and runbooks

## Performance Tuning

### Connection Limits
```yaml
# Increase Traefik's connection limits
serversTransport:
  maxIdleConnsPerHost: 200  # Match PgBouncer max_client_conn
```

### Health Check Tuning
```yaml
healthCheck:
  interval: "10s"    # Default
  timeout: "3s"      # Default
  # Reduce interval for faster failover detection
  # interval: "5s"   # More aggressive
```

### Read Replica Scaling
```yaml
# Add more replicas for read scaling
postgres-replicas:
  loadBalancer:
    servers:
      - address: "patroni-1:5432"
      - address: "patroni-3:5432"
      - address: "patroni-4:5432"  # New replica
      - address: "patroni-5:5432"  # New replica
```

## Security Considerations

- ✅ SSL/TLS passthrough maintains end-to-end encryption
- ✅ Traefik cannot see query contents
- ✅ Client certificates still validated by PostgreSQL
- ✅ pg_hba.conf rules still enforced
- ⚠️ Traefik network must be secured (no untrusted containers)
- ⚠️ Patroni REST API (8008) should be internal only

## References

- [Traefik TCP Documentation](https://doc.traefik.io/traefik/routing/routers/#configuring-tcp-routers)
- [Patroni Documentation](https://patroni.readthedocs.io/)
- [PostgreSQL SSL Documentation](https://www.postgresql.org/docs/current/ssl-tcp.html)

## Support

For issues:
1. Check Traefik logs: `docker logs traefik`
2. Check Patroni cluster status: `patronictl list`
3. Check Prometheus alerts: http://prometheus:9090/alerts
4. Review this document's troubleshooting section
