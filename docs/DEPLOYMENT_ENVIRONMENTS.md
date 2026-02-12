# Deployment Environments

## Local Development

**Purpose**: Development and testing  
**Load Balancer**: HAProxy (single instance)  
**Acceptable**: Single point of failure (manual recovery ~30s)  

**Stack**:
- 3x Patroni nodes (HA)
- 3x etcd nodes (HA)
- 1x HAProxy (SPOF - acceptable for dev)
- 1x PgBouncer
- Monitoring: Prometheus, Grafana, AlertManager
- Redis caching

**Connection**:
- Direct: `localhost:5433` (patroni-2)
- Via HAProxy: `localhost:5000`
- Via PgBouncer: `localhost:6432`

---

## Production

**Purpose**: Production workloads  
**Load Balancer**: Traefik (existing, HA)  
**Requirement**: No single point of failure  

**Stack**:
- 3x Patroni nodes (HA) ✅
- 3x etcd nodes (HA) ✅
- Traefik (HA, already exists) ✅
- PgBouncer cluster (3+ instances)
- Full monitoring stack
- Redis cluster
- pgBackRest automated backups

**Connection**:
- Via Traefik: `postgres.example.com:5432`
- Read replicas: `postgres.example.com:5433`

**Documentation**: See `TRAEFIK_PRODUCTION_DEPLOYMENT.md`

---

## Architecture Comparison

| Component | Local Dev | Production |
|-----------|-----------|------------|
| **Database** | 3-node Patroni HA | 3-node Patroni HA |
| **Consensus** | 3-node etcd | 3-node etcd |
| **Load Balancer** | HAProxy (SPOF) | Traefik (HA) ✅ |
| **Connection Pool** | 1x PgBouncer | 3x PgBouncer |
| **Monitoring** | Single instance | HA cluster |
| **Backups** | Local pgBackRest | S3/remote backup |
| **SSL/TLS** | Self-signed certs | Let's Encrypt/CA |
| **Failover Time** | ~3s (Patroni) | ~13s (Patroni + Traefik) |
| **Recovery Time** | ~30s (manual) | Automatic |

---

## Key Differences

### Local Dev Philosophy
- **Fast iteration** over redundancy
- Manual intervention acceptable
- Single HAProxy is fine (database is HA)
- Self-signed certificates
- Local storage for backups

### Production Philosophy
- **Zero tolerance** for single points of failure
- Automatic recovery required
- Traefik provides load balancer HA
- Valid CA certificates
- Remote backup storage
- Full observability

---

## Migration Path

When promoting from dev → production:

1. ✅ Database already HA (Patroni + etcd)
2. ✅ SSL/TLS already configured
3. ✅ Backups already operational
4. ✅ Monitoring already deployed
5. 🔄 **Replace HAProxy with Traefik** (see TRAEFIK_PRODUCTION_DEPLOYMENT.md)
6. 🔄 Scale PgBouncer to 3 instances
7. 🔄 Replace self-signed certs with CA certs
8. 🔄 Configure remote backup storage (S3)

**Result**: Production-ready with minimal changes
