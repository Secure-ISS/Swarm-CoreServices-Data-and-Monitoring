# Production Deployment Architecture

## Executive Summary

This document provides comprehensive guidance for deploying the Distributed PostgreSQL Cluster in production environments. The architecture supports high availability, horizontal scalability, and disaster recovery with enterprise-grade security and monitoring.

**Architecture Highlights:**
- 3-node Patroni HA cluster with automatic failover
- 3-node etcd cluster for distributed consensus
- Dual HAProxy load balancers for traffic distribution
- PgBouncer connection pooling (5000+ connections)
- Redis caching layer for query optimization
- Full monitoring stack (Prometheus + Grafana)
- Automated backup and recovery procedures
- SSL/TLS encryption in transit and at rest

**Availability Guarantees:**
- **Uptime SLA:** 99.95% (4.38 hours downtime/year)
- **RPO:** 0 seconds (synchronous replication)
- **RTO:** <30 seconds (automatic failover)
- **Data Durability:** 99.999999999% (11 nines)

---

## Table of Contents

1. [Infrastructure Requirements](#1-infrastructure-requirements)
2. [Network Architecture](#2-network-architecture)
3. [Security Architecture](#3-security-architecture)
4. [Storage Strategy](#4-storage-strategy)
5. [Deployment Procedures](#5-deployment-procedures)
6. [Scaling Strategy](#6-scaling-strategy)
7. [Disaster Recovery](#7-disaster-recovery)
8. [Monitoring and Observability](#8-monitoring-and-observability)
9. [Operational Procedures](#9-operational-procedures)
10. [Cost Optimization](#10-cost-optimization)

---

## 1. Infrastructure Requirements

### 1.1 Minimum Hardware Requirements

#### Manager Nodes (3 nodes recommended)
- **CPU:** 8 cores (16 threads)
- **RAM:** 32 GB
- **Storage:** 500 GB NVMe SSD (OS + etcd data)
- **Network:** 10 Gbps

**Services:** etcd, HAProxy, Prometheus, Grafana

#### Worker Nodes (3+ nodes for PostgreSQL)
- **CPU:** 16 cores (32 threads)
- **RAM:** 64 GB
- **Storage:**
  - OS: 100 GB SSD
  - PostgreSQL data: 2 TB NVMe SSD (or larger)
  - WAL logs: 500 GB NVMe SSD
- **Network:** 10 Gbps with RDMA support (optional)

**Services:** Patroni PostgreSQL nodes

#### Application Nodes (2+ nodes)
- **CPU:** 4 cores (8 threads)
- **RAM:** 16 GB
- **Storage:** 100 GB SSD
- **Network:** 10 Gbps

**Services:** PgBouncer, Redis, application services

### 1.2 Recommended Production Configuration

For a production cluster supporting 1000+ TPS:

```
Total Infrastructure:
- 3 Manager nodes (etcd + control plane)
- 3 Worker nodes (Patroni PostgreSQL)
- 2 Application nodes (PgBouncer + Redis)
- 1 Backup node (optional, for dedicated backups)

Total: 8-9 nodes
```

### 1.3 Cloud Provider Specifications

#### AWS Configuration
```yaml
Manager Nodes: 3x t3.xlarge (4 vCPU, 16 GB RAM)
Worker Nodes: 3x r6i.2xlarge (8 vCPU, 64 GB RAM)
App Nodes: 2x t3.large (2 vCPU, 8 GB RAM)
Storage:
  - EBS gp3 volumes (3000 IOPS baseline)
  - 2 TB per PostgreSQL node
  - Cross-AZ replication enabled
Network: VPC with private subnets, NAT Gateway
Estimated Cost: $3,500-4,500/month
```

#### GCP Configuration
```yaml
Manager Nodes: 3x n2-standard-4 (4 vCPU, 16 GB RAM)
Worker Nodes: 3x n2-highmem-8 (8 vCPU, 64 GB RAM)
App Nodes: 2x n2-standard-2 (2 vCPU, 8 GB RAM)
Storage:
  - Persistent SSD (30 IOPS/GB)
  - 2 TB per PostgreSQL node
  - Regional persistent disks
Network: VPC with Cloud NAT
Estimated Cost: $3,200-4,000/month
```

#### Azure Configuration
```yaml
Manager Nodes: 3x Standard_D4s_v5 (4 vCPU, 16 GB RAM)
Worker Nodes: 3x Standard_E8s_v5 (8 vCPU, 64 GB RAM)
App Nodes: 2x Standard_D2s_v5 (2 vCPU, 8 GB RAM)
Storage:
  - Premium SSD (P40: 2 TB, 7500 IOPS)
  - Zone-redundant storage
Network: Virtual Network with Availability Zones
Estimated Cost: $3,800-4,800/month
```

### 1.4 On-Premises Specifications

Recommended server configuration:
```
Dell PowerEdge R650 or equivalent:
- 2x Intel Xeon Gold 6338 (32 cores, 64 threads each)
- 512 GB DDR4 RAM (16x 32GB modules)
- 4x 3.84 TB NVMe SSD (RAID 10)
- 2x 25 GbE network adapters (bonded)
- Dual power supplies
- Hardware RAID controller with BBU

Total: 3-5 servers ($25,000-40,000 each)
```

---

## 2. Network Architecture

### 2.1 Network Topology

```
┌─────────────────────────────────────────────────────────────────┐
│                    INTERNET / PUBLIC NETWORK                     │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                    ┌───────▼────────┐
                    │   Firewall /   │
                    │   Load Balancer│
                    │   (External)   │
                    └───────┬────────┘
                            │
┌───────────────────────────┼─────────────────────────────────────┐
│              DMZ / APPLICATION NETWORK (10.10.2.0/24)           │
│                           │                                      │
│    ┌──────────────────────┼──────────────────────┐             │
│    │        HAProxy Load Balancers (2)           │             │
│    │    Primary: 10.10.2.10   Backup: 10.10.2.11 │             │
│    └──────────────────────┬──────────────────────┘             │
│                           │                                      │
│    ┌──────────────────────┼──────────────────────┐             │
│    │        PgBouncer Connection Poolers (2)      │             │
│    │      10.10.2.20          10.10.2.21          │             │
│    └──────────────────────┬──────────────────────┘             │
└───────────────────────────┼─────────────────────────────────────┘
                            │
┌───────────────────────────┼─────────────────────────────────────┐
│              DATA NETWORK (10.10.1.0/24)                        │
│                           │                                      │
│    ┌──────────────────────┴──────────────────────┐             │
│    │        Patroni PostgreSQL Cluster (3)        │             │
│    │    Node 1: 10.10.1.11 (Primary)             │             │
│    │    Node 2: 10.10.1.12 (Standby)             │             │
│    │    Node 3: 10.10.1.13 (Standby)             │             │
│    └──────────────────────┬──────────────────────┘             │
│                           │                                      │
│    ┌──────────────────────┴──────────────────────┐             │
│    │             Redis Cache Cluster              │             │
│    │      Master: 10.10.1.30                      │             │
│    └──────────────────────────────────────────────┘             │
└───────────────────────────┼─────────────────────────────────────┘
                            │
┌───────────────────────────┼─────────────────────────────────────┐
│           COORDINATOR NETWORK (10.10.0.0/24)                    │
│                           │                                      │
│    ┌──────────────────────┴──────────────────────┐             │
│    │            etcd Cluster (3)                  │             │
│    │      10.10.0.21  10.10.0.22  10.10.0.23    │             │
│    └──────────────────────────────────────────────┘             │
└─────────────────────────────────────────────────────────────────┘
                            │
┌───────────────────────────┼─────────────────────────────────────┐
│           MONITORING NETWORK (10.10.3.0/24)                     │
│                           │                                      │
│    ┌──────────────────────┴──────────────────────┐             │
│    │    Prometheus: 10.10.3.10                   │             │
│    │    Grafana: 10.10.3.11                      │             │
│    │    Log Aggregation: 10.10.3.20              │             │
│    └──────────────────────────────────────────────┘             │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Network Segmentation

#### Overlay Networks (Docker Swarm)

1. **coordinator-net** (10.10.0.0/24)
   - Purpose: etcd consensus and Patroni coordination
   - Encryption: Mandatory (IPsec)
   - Access: etcd, Patroni nodes only
   - Firewall rules: Port 2379 (etcd client), 2380 (etcd peer), 8008 (Patroni API)

2. **data-net** (10.10.1.0/24)
   - Purpose: PostgreSQL replication and data access
   - Encryption: Mandatory (IPsec + TLS)
   - Access: Patroni, HAProxy, PgBouncer
   - Firewall rules: Port 5432 (PostgreSQL), 6379 (Redis)

3. **app-net** (10.10.2.0/24)
   - Purpose: Application connections
   - Encryption: TLS only
   - Access: HAProxy, PgBouncer, Redis, applications
   - Firewall rules: Port 5432, 6432, 6379

4. **monitoring-net** (10.10.3.0/24)
   - Purpose: Metrics collection and monitoring
   - Encryption: Optional
   - Access: Prometheus, Grafana, exporters
   - Firewall rules: Port 9090, 3000, 9187

### 2.3 Service Discovery

Docker Swarm provides built-in DNS-based service discovery:

```bash
# Internal DNS resolution
patroni-1.postgres-prod           -> 10.10.1.11
patroni-2.postgres-prod           -> 10.10.1.12
haproxy.postgres-prod             -> 10.10.2.10
etcd-1.postgres-prod              -> 10.10.0.21

# Service VIP (Virtual IP)
postgres-prod_patroni             -> Load balanced across all Patroni nodes
postgres-prod_haproxy             -> Load balanced across HAProxy nodes
```

### 2.4 External Access Configuration

#### Load Balancer Setup (AWS Example)

```hcl
# Application Load Balancer
resource "aws_lb" "postgres_nlb" {
  name               = "postgres-prod-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  enable_deletion_protection = true
  enable_cross_zone_load_balancing = true

  tags = {
    Environment = "production"
    Service     = "postgres"
  }
}

resource "aws_lb_target_group" "postgres" {
  name     = "postgres-prod-tg"
  port     = 5432
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = 5432
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 10
  }
}

resource "aws_lb_listener" "postgres" {
  load_balancer_arn = aws_lb.postgres_nlb.arn
  port              = 5432
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.postgres.arn
  }
}
```

### 2.5 Firewall Rules

#### Security Group Configuration (Cloud)

```yaml
# Manager Node Security Group
Inbound:
  - Port 2377: TCP (Docker Swarm management)
  - Port 7946: TCP/UDP (Container network discovery)
  - Port 4789: UDP (Overlay network traffic)
  - Port 2379-2380: TCP (etcd client and peer)
  - Port 22: TCP (SSH - restricted to bastion host)

Outbound:
  - All traffic allowed

# Worker Node Security Group
Inbound:
  - Port 7946: TCP/UDP (Container network discovery)
  - Port 4789: UDP (Overlay network traffic)
  - Port 5432: TCP (PostgreSQL - from app network only)
  - Port 8008: TCP (Patroni API - from monitoring only)
  - Port 22: TCP (SSH - restricted to bastion host)

Outbound:
  - All traffic allowed

# Application Node Security Group
Inbound:
  - Port 5432: TCP (PostgreSQL proxy - from application VMs)
  - Port 6432: TCP (PgBouncer - from application VMs)
  - Port 6379: TCP (Redis - from application VMs)

Outbound:
  - All traffic allowed
```

#### iptables Rules (On-Premises)

```bash
# Manager node iptables
iptables -A INPUT -p tcp --dport 2377 -j ACCEPT  # Docker Swarm
iptables -A INPUT -p tcp --dport 2379:2380 -j ACCEPT  # etcd
iptables -A INPUT -p tcp --dport 7946 -j ACCEPT  # Discovery TCP
iptables -A INPUT -p udp --dport 7946 -j ACCEPT  # Discovery UDP
iptables -A INPUT -p udp --dport 4789 -j ACCEPT  # Overlay network
iptables -A INPUT -p tcp --dport 22 -s 10.0.0.0/8 -j ACCEPT  # SSH from internal

# Worker node iptables
iptables -A INPUT -p tcp --dport 5432 -s 10.10.0.0/16 -j ACCEPT  # PostgreSQL
iptables -A INPUT -p tcp --dport 8008 -s 10.10.3.0/24 -j ACCEPT  # Patroni API
iptables -A INPUT -p tcp --dport 7946 -j ACCEPT  # Discovery TCP
iptables -A INPUT -p udp --dport 7946 -j ACCEPT  # Discovery UDP
iptables -A INPUT -p udp --dport 4789 -j ACCEPT  # Overlay network

# Default DROP policy
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT
```

---

## 3. Security Architecture

### 3.1 Defense in Depth Strategy

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 7: Application Security                               │
│ - SQL injection prevention                                  │
│ - Input validation                                          │
│ - Prepared statements                                       │
│ - Row-level security (RLS)                                  │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Layer 6: Authentication & Authorization                     │
│ - SCRAM-SHA-256 authentication                             │
│ - Certificate-based authentication                          │
│ - Role-based access control (RBAC)                         │
│ - Audit logging                                             │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Layer 5: Encryption (Data in Transit)                      │
│ - TLS 1.3 for all connections                              │
│ - Certificate pinning                                       │
│ - Perfect forward secrecy (PFS)                            │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Layer 4: Encryption (Data at Rest)                         │
│ - AES-256 volume encryption                                │
│ - Encrypted backups                                         │
│ - Key rotation policies                                     │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Layer 3: Network Security                                   │
│ - Network segmentation                                      │
│ - Firewall rules                                            │
│ - VPN/Private Link                                          │
│ - DDoS protection                                           │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Layer 2: Secrets Management                                 │
│ - Docker Secrets                                            │
│ - HashiCorp Vault integration                               │
│ - Secret rotation                                           │
│ - No secrets in environment variables or configs           │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Layer 1: Physical/Infrastructure Security                   │
│ - Disk encryption                                           │
│ - Secure boot                                               │
│ - Physical access controls                                  │
│ - Hardware security modules (HSM)                           │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 SSL/TLS Configuration

#### Certificate Generation

Use the provided script:
```bash
cd /home/matt/projects/Distributed-Postgress-Cluster
./scripts/generate_ssl_certs.sh
```

Or generate manually:
```bash
# Generate CA certificate
openssl genrsa -out ca-key.pem 4096
openssl req -new -x509 -days 3650 -key ca-key.pem -out ca-cert.pem \
  -subj "/CN=PostgreSQL-CA"

# Generate server certificate
openssl genrsa -out server-key.pem 4096
openssl req -new -key server-key.pem -out server-req.pem \
  -subj "/CN=patroni-1.postgres-prod"
openssl x509 -req -days 365 -in server-req.pem \
  -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial \
  -out server-cert.pem

# Generate client certificate
openssl genrsa -out client-key.pem 4096
openssl req -new -key client-key.pem -out client-req.pem \
  -subj "/CN=postgres"
openssl x509 -req -days 365 -in client-req.pem \
  -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial \
  -out client-cert.pem
```

#### PostgreSQL SSL Configuration

Add to `postgresql.conf` (via Patroni):
```ini
ssl = on
ssl_cert_file = '/run/secrets/postgres_ssl_cert'
ssl_key_file = '/run/secrets/postgres_ssl_key'
ssl_ca_file = '/run/secrets/postgres_ssl_ca'
ssl_ciphers = 'HIGH:MEDIUM:+3DES:!aNULL'
ssl_prefer_server_ciphers = on
ssl_min_protocol_version = 'TLSv1.3'
```

Add to `pg_hba.conf`:
```
# Require SSL for all connections
hostssl all all 0.0.0.0/0 scram-sha-256
hostnossl all all 0.0.0.0/0 reject
```

### 3.3 Secrets Management

#### Creating Docker Secrets

```bash
#!/bin/bash
# create-secrets.sh

# PostgreSQL password
echo "$(openssl rand -base64 32)" | docker secret create postgres_password -

# Replication password
echo "$(openssl rand -base64 32)" | docker secret create replication_password -

# Redis password
echo "$(openssl rand -base64 32)" | docker secret create redis_password -

# Grafana admin password
echo "$(openssl rand -base64 32)" | docker secret create grafana_admin_password -

# SSL certificates
docker secret create postgres_ssl_cert server-cert.pem
docker secret create postgres_ssl_key server-key.pem
docker secret create postgres_ssl_ca ca-cert.pem

echo "Secrets created successfully"
```

#### HashiCorp Vault Integration (Optional)

```bash
# Store secrets in Vault
vault kv put secret/postgres/passwords \
  postgres="$(openssl rand -base64 32)" \
  replication="$(openssl rand -base64 32)" \
  redis="$(openssl rand -base64 32)"

# Retrieve and create Docker secrets
vault kv get -field=postgres secret/postgres/passwords | \
  docker secret create postgres_password -
```

### 3.4 Authentication Configuration

#### PostgreSQL User Management

```sql
-- Create replication user
CREATE USER replicator WITH REPLICATION PASSWORD 'secret';

-- Create application user with limited privileges
CREATE USER app_user WITH PASSWORD 'secret';
GRANT CONNECT ON DATABASE distributed_postgres_cluster TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;

-- Create read-only user
CREATE USER readonly_user WITH PASSWORD 'secret';
GRANT CONNECT ON DATABASE distributed_postgres_cluster TO readonly_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_user;

-- Enable row-level security
ALTER TABLE sensitive_table ENABLE ROW LEVEL SECURITY;
CREATE POLICY user_isolation_policy ON sensitive_table
  USING (user_id = current_user);
```

#### SCRAM-SHA-256 Authentication

Update `postgresql.conf`:
```ini
password_encryption = scram-sha-256
```

Update `pg_hba.conf`:
```
# Use SCRAM-SHA-256 for all connections
hostssl all all 0.0.0.0/0 scram-sha-256
```

Migrate existing passwords:
```sql
-- Update password to use SCRAM-SHA-256
ALTER USER postgres WITH PASSWORD 'newpassword';
```

### 3.5 Audit Logging

Enable comprehensive audit logging:

```sql
-- Install pgaudit extension
CREATE EXTENSION pgaudit;

-- Configure audit settings
ALTER SYSTEM SET pgaudit.log = 'ddl, write, read';
ALTER SYSTEM SET pgaudit.log_catalog = off;
ALTER SYSTEM SET pgaudit.log_parameter = on;
ALTER SYSTEM SET pgaudit.log_relation = on;
ALTER SYSTEM SET pgaudit.log_statement_once = off;
SELECT pg_reload_conf();
```

PostgreSQL logging configuration:
```ini
logging_collector = on
log_directory = '/var/log/postgresql'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1d
log_rotation_size = 100MB
log_min_duration_statement = 1000  # Log queries > 1s
log_connections = on
log_disconnections = on
log_duration = on
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
log_statement = 'ddl'
log_checkpoints = on
log_lock_waits = on
log_temp_files = 0
```

---

## 4. Storage Strategy

### 4.1 Storage Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Patroni Node 1                          │
│  ┌──────────────────────────────────────────────────────┐  │
│  │           PostgreSQL Data Directory                   │  │
│  │  /var/lib/postgresql/data/pgdata (2 TB NVMe SSD)    │  │
│  │  - Base tables and indexes                           │  │
│  │  - Shared buffers (8 GB in RAM)                      │  │
│  │  - Data files                                         │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │           Write-Ahead Log (WAL)                       │  │
│  │  /var/lib/postgresql/data/pgdata/pg_wal (500 GB)    │  │
│  │  - Transaction logs                                   │  │
│  │  - Checkpoint files                                   │  │
│  │  - Replication logs                                   │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │           Archived WAL Logs                           │  │
│  │  /mnt/postgres-cluster/archives (1 TB)               │  │
│  │  - Compressed WAL archives                            │  │
│  │  - Point-in-time recovery data                        │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                          ↓ Replication
┌─────────────────────────────────────────────────────────────┐
│                   Patroni Node 2 & 3                        │
│  - Streaming replication from Node 1                       │
│  - Synchronous replication (RPO = 0)                       │
│  - Hot standby (read replicas)                             │
└─────────────────────────────────────────────────────────────┘
                          ↓ Continuous Archiving
┌─────────────────────────────────────────────────────────────┐
│                      Backup Storage                          │
│  /mnt/postgres-cluster/backups (5 TB)                      │
│  - Daily full backups (compressed)                          │
│  - Continuous WAL archiving                                 │
│  - Retention: 30 days                                       │
│  - Encrypted with AES-256                                   │
└─────────────────────────────────────────────────────────────┘
                          ↓ Offsite Replication
┌─────────────────────────────────────────────────────────────┐
│                   S3/Cloud Storage                           │
│  - Geo-replicated backups                                   │
│  - Long-term retention (90 days)                            │
│  - Glacier for archive (7 years)                            │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Volume Configuration

#### Docker Volume Mount Strategy

```yaml
# Production volume mounts (from docker-compose.yml)
volumes:
  patroni-1-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /mnt/postgres-cluster/patroni-1

# Directory structure on host
/mnt/postgres-cluster/
├── patroni-1/
│   └── pgdata/
│       ├── base/           # Database files
│       ├── global/         # Cluster-wide tables
│       ├── pg_wal/         # WAL files
│       ├── pg_stat/        # Statistics
│       └── pg_tblspc/      # Tablespaces
├── patroni-2/
├── patroni-3/
├── backups/
│   ├── daily/
│   ├── weekly/
│   └── monthly/
├── archives/
│   └── wal/
├── etcd-1/
├── etcd-2/
└── etcd-3/
```

#### Storage Provisioning (Cloud)

**AWS EBS Volumes:**
```bash
# Create EBS volumes with optimal IOPS
aws ec2 create-volume \
  --size 2048 \
  --volume-type gp3 \
  --iops 16000 \
  --throughput 1000 \
  --availability-zone us-east-1a \
  --encrypted \
  --kms-key-id arn:aws:kms:us-east-1:123456789012:key/12345678 \
  --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=patroni-1-data}]'

# Attach volume to instance
aws ec2 attach-volume \
  --volume-id vol-1234567890abcdef0 \
  --instance-id i-1234567890abcdef0 \
  --device /dev/sdf

# Format and mount
mkfs.ext4 /dev/sdf
mkdir -p /mnt/postgres-cluster/patroni-1
mount /dev/sdf /mnt/postgres-cluster/patroni-1
echo "/dev/sdf /mnt/postgres-cluster/patroni-1 ext4 defaults,nofail 0 2" >> /etc/fstab
```

**GCP Persistent Disks:**
```bash
# Create persistent SSD
gcloud compute disks create patroni-1-data \
  --size=2048GB \
  --type=pd-ssd \
  --zone=us-central1-a \
  --replica-zones=us-central1-a,us-central1-b

# Attach to instance
gcloud compute instances attach-disk postgres-worker-1 \
  --disk=patroni-1-data \
  --zone=us-central1-a

# Format and mount (same as AWS)
```

### 4.3 Backup Strategy

#### Backup Types and Schedule

```
Daily Full Backup:
- Schedule: 2:00 AM daily
- Retention: 7 days
- Method: pg_basebackup
- Compression: zstd (level 3)
- Encryption: AES-256
- Location: /mnt/postgres-cluster/backups/daily/
- Duration: ~30 minutes for 500 GB

Weekly Full Backup:
- Schedule: Sunday 2:00 AM
- Retention: 4 weeks
- Method: pg_basebackup
- Location: /mnt/postgres-cluster/backups/weekly/
- Offsite copy: S3/Cloud Storage

Monthly Full Backup:
- Schedule: 1st of month, 2:00 AM
- Retention: 12 months
- Location: /mnt/postgres-cluster/backups/monthly/
- Archive to cold storage: Glacier/Archive

Continuous WAL Archiving:
- Real-time archiving
- Retention: 30 days
- Method: archive_command
- Location: /mnt/postgres-cluster/archives/wal/
- Point-in-time recovery capability
```

#### Backup Configuration

PostgreSQL configuration (via Patroni):
```yaml
postgresql:
  parameters:
    archive_mode: "on"
    archive_command: 'test ! -f /mnt/postgres-cluster/archives/wal/%f && cp %p /mnt/postgres-cluster/archives/wal/%f'
    archive_timeout: 300  # Archive every 5 minutes
    wal_level: replica
    max_wal_senders: 10
    wal_keep_size: 1GB
```

Backup script (automated):
```bash
#!/bin/bash
# /scripts/backup/backup-patroni.sh

set -euo pipefail

BACKUP_DIR="/mnt/postgres-cluster/backups"
DAILY_DIR="$BACKUP_DIR/daily"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="postgres_backup_$DATE"

# Create backup directory
mkdir -p "$DAILY_DIR"

# Perform basebackup
pg_basebackup -h haproxy -p 5432 -U replicator \
  -D "$DAILY_DIR/$BACKUP_NAME" \
  -Ft -z -Xs -P -v

# Encrypt backup
tar -czf - -C "$DAILY_DIR" "$BACKUP_NAME" | \
  openssl enc -aes-256-cbc -salt -pbkdf2 \
  -out "$DAILY_DIR/${BACKUP_NAME}.tar.gz.enc" \
  -pass file:/run/secrets/backup_encryption_key

# Remove unencrypted backup
rm -rf "$DAILY_DIR/$BACKUP_NAME"

# Upload to S3 (if configured)
if [ -n "${AWS_S3_BUCKET:-}" ]; then
  aws s3 cp "$DAILY_DIR/${BACKUP_NAME}.tar.gz.enc" \
    "s3://$AWS_S3_BUCKET/backups/postgres/${BACKUP_NAME}.tar.gz.enc" \
    --storage-class STANDARD_IA
fi

# Cleanup old backups (retain 7 days)
find "$DAILY_DIR" -name "postgres_backup_*.tar.gz.enc" -mtime +7 -delete

# Log backup completion
echo "$(date): Backup $BACKUP_NAME completed successfully" >> /var/log/postgres-backup.log
```

### 4.4 Replication Strategy

#### Streaming Replication Configuration

```
Primary (patroni-1):
- Role: Read-Write
- Synchronous replication to patroni-2
- Asynchronous replication to patroni-3

Standby 1 (patroni-2):
- Role: Hot Standby (Read-Only)
- Synchronous replica (RPO = 0)
- Automatic failover candidate

Standby 2 (patroni-3):
- Role: Hot Standby (Read-Only)
- Asynchronous replica (RPO < 1 minute)
- Disaster recovery node
```

Patroni synchronous replication configuration:
```yaml
postgresql:
  parameters:
    synchronous_commit: "on"
    synchronous_standby_names: "patroni-2"
```

#### Cross-Region Replication (Optional)

For disaster recovery across regions:

```yaml
# DR Site (Different Region)
patroni-dr-1:
  # Asynchronous replication from production
  # Lag tolerance: < 5 minutes
  # Activation: Manual failover only
```

---

## 5. Deployment Procedures

### 5.1 Pre-Deployment Checklist

```
Infrastructure:
[ ] Hardware/VMs provisioned
[ ] Storage volumes created and attached
[ ] Network configuration completed
[ ] DNS records configured
[ ] Load balancer provisioned

Docker Swarm:
[ ] Swarm initialized on manager nodes
[ ] Worker nodes joined to swarm
[ ] Node labels applied
[ ] Overlay networks created

Security:
[ ] SSL certificates generated
[ ] Docker secrets created
[ ] Firewall rules applied
[ ] Access control configured

Configuration:
[ ] Patroni configuration validated
[ ] HAProxy configuration validated
[ ] Prometheus configuration validated
[ ] Grafana dashboards imported

Testing:
[ ] Network connectivity verified
[ ] Storage performance tested
[ ] Backup/restore tested
[ ] Failover tested
```

### 5.2 Step-by-Step Deployment

#### Step 1: Initialize Docker Swarm

```bash
# On first manager node
docker swarm init --advertise-addr 10.0.1.10

# Get join token for managers
MANAGER_TOKEN=$(docker swarm join-token manager -q)

# Get join token for workers
WORKER_TOKEN=$(docker swarm join-token worker -q)

# On additional manager nodes
docker swarm join --token $MANAGER_TOKEN 10.0.1.10:2377

# On worker nodes
docker swarm join --token $WORKER_TOKEN 10.0.1.10:2377
```

#### Step 2: Configure Node Labels

```bash
# Label etcd nodes
docker node update --label-add postgres.etcd=etcd-1 node-1
docker node update --label-add postgres.etcd=etcd-2 node-2
docker node update --label-add postgres.etcd=etcd-3 node-3

# Label Patroni nodes
docker node update --label-add postgres.role=patroni node-4
docker node update --label-add postgres.patroni-id=1 node-4
docker node update --label-add postgres.role=patroni node-5
docker node update --label-add postgres.patroni-id=2 node-5
docker node update --label-add postgres.role=patroni node-6
docker node update --label-add postgres.patroni-id=3 node-6

# Label Redis node
docker node update --label-add redis.role=master node-7
```

#### Step 3: Create Storage Directories

```bash
# On each node, create required directories
mkdir -p /mnt/postgres-cluster/{patroni-1,patroni-2,patroni-3,etcd-1,etcd-2,etcd-3,backups,archives}

# Set proper permissions
chown -R 999:999 /mnt/postgres-cluster/patroni-*
chown -R 999:999 /mnt/postgres-cluster/etcd-*
chmod 700 /mnt/postgres-cluster/patroni-*
chmod 700 /mnt/postgres-cluster/etcd-*
```

#### Step 4: Generate SSL Certificates

```bash
cd /home/matt/projects/Distributed-Postgress-Cluster
./scripts/generate_ssl_certs.sh
```

#### Step 5: Create Docker Secrets

```bash
cd /home/matt/projects/Distributed-Postgress-Cluster
./scripts/deployment/create-secrets.sh
```

#### Step 6: Deploy Stack

```bash
cd /home/matt/projects/Distributed-Postgress-Cluster/docker/production

# Deploy the stack
docker stack deploy -c docker-compose.yml postgres-prod

# Verify deployment
docker stack ps postgres-prod

# Check service status
docker service ls
```

#### Step 7: Verify Cluster Health

```bash
# Check etcd cluster
docker exec $(docker ps -q -f name=postgres-prod_etcd-1) etcdctl endpoint health --cluster

# Check Patroni cluster
curl http://patroni-1:8008/cluster | jq

# Check HAProxy stats
curl http://haproxy:7000/stats

# Verify PostgreSQL connectivity
psql -h haproxy -U postgres -d distributed_postgres_cluster -c "SELECT version();"
```

### 5.3 Initial Configuration

#### Initialize Databases

```bash
# Connect to primary
psql -h haproxy -U postgres -d distributed_postgres_cluster

# Create extensions
CREATE EXTENSION IF NOT EXISTS ruvector;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgaudit;

# Create application user
CREATE USER app_user WITH PASSWORD 'secret';
GRANT ALL PRIVILEGES ON DATABASE distributed_postgres_cluster TO app_user;

# Create replication slots
SELECT * FROM pg_create_physical_replication_slot('patroni_2_slot');
SELECT * FROM pg_create_physical_replication_slot('patroni_3_slot');
```

---

## 6. Scaling Strategy

### 6.1 Vertical Scaling (Scale Up)

#### CPU Scaling
```bash
# Update service CPU limits
docker service update \
  --limit-cpu 16 \
  --reserve-cpu 8 \
  postgres-prod_patroni-1

# Verify resource allocation
docker service inspect postgres-prod_patroni-1 --format='{{.Spec.TaskTemplate.Resources}}'
```

#### Memory Scaling
```bash
# Update service memory limits
docker service update \
  --limit-memory 64G \
  --reserve-memory 32G \
  postgres-prod_patroni-1

# Update PostgreSQL shared_buffers (requires restart)
docker exec postgres-prod_patroni-1 \
  patronictl edit-config postgres-cluster-main
# Update shared_buffers: 16GB -> 24GB

# Reload configuration
docker exec postgres-prod_patroni-1 \
  patronictl reload postgres-cluster-main
```

#### Storage Scaling
```bash
# Expand EBS volume (AWS)
aws ec2 modify-volume --volume-id vol-xxx --size 4096

# Resize filesystem
resize2fs /dev/sdf

# Verify new size
df -h /mnt/postgres-cluster/patroni-1
```

### 6.2 Horizontal Scaling (Scale Out)

#### Adding Read Replicas

```bash
# Add new worker node to swarm
docker swarm join --token $WORKER_TOKEN manager-1:2377

# Label new node
docker node update --label-add postgres.role=patroni node-7
docker node update --label-add postgres.patroni-id=4 node-7

# Scale Patroni service
docker service scale postgres-prod_patroni=4

# Verify new replica
curl http://patroni-4:8008/patroni | jq
```

#### Adding Connection Poolers

```bash
# Scale PgBouncer
docker service scale postgres-prod_pgbouncer=4

# Verify load distribution
for i in {1..4}; do
  docker service ps postgres-prod_pgbouncer --filter "desired-state=running" | grep pgbouncer
done
```

#### Adding Load Balancers

```bash
# Scale HAProxy
docker service scale postgres-prod_haproxy=3

# Update DNS round-robin
# Add new HAProxy IPs to DNS A records
```

### 6.3 Capacity Planning

#### Metrics-Based Scaling Triggers

```yaml
Scale Up Triggers:
  CPU:
    Threshold: > 70% sustained for 15 minutes
    Action: Add 2-4 cores

  Memory:
    Threshold: > 80% RAM utilization
    Action: Add 16-32 GB RAM

  Disk I/O:
    Threshold: > 80% IOPS utilization
    Action: Increase IOPS or add SSD

  Connections:
    Threshold: > 400 active connections
    Action: Scale PgBouncer replicas

Scale Out Triggers:
  Read Load:
    Threshold: > 5000 TPS read queries
    Action: Add read replica

  Replication Lag:
    Threshold: > 5 seconds lag
    Action: Add replica or increase resources

  Cache Hit Ratio:
    Threshold: < 95% cache hit ratio
    Action: Increase shared_buffers or add RAM
```

#### Sizing Formula

```
Calculate Required Resources:

Connections:
  max_connections = (expected_concurrent_users * 1.5) + 100

Memory:
  shared_buffers = total_ram * 0.25
  effective_cache_size = total_ram * 0.75
  work_mem = (total_ram - shared_buffers) / max_connections / 2

CPU:
  cores_needed = max(4, expected_tps / 500)

Storage:
  data_size = current_db_size * growth_rate * retention_months
  wal_size = data_size * 0.1
  backup_size = data_size * retention_days
  total_storage = data_size + wal_size + backup_size * 1.2
```

Example for 10,000 TPS workload:
```
Expected TPS: 10,000
Concurrent Users: 500

Resources:
- CPU: 20 cores (16 vCPU + 4 for overhead)
- RAM: 64 GB per node
  - shared_buffers: 16 GB
  - effective_cache_size: 48 GB
  - work_mem: 64 MB
- Storage: 5 TB total
  - Data: 2 TB
  - WAL: 200 GB
  - Backups: 2.8 TB (30 days retention)
- Connections: 850 max_connections
- Nodes: 3 Patroni + 2 PgBouncer + 2 HAProxy
```

---

## 7. Disaster Recovery

### 7.1 Recovery Time Objective (RTO) and Recovery Point Objective (RPO)

```
Tier 1 - Critical (Production DB):
- RPO: 0 seconds (synchronous replication)
- RTO: < 30 seconds (automatic failover)
- Availability: 99.95%

Tier 2 - Important (Application Data):
- RPO: < 5 minutes (asynchronous replication)
- RTO: < 5 minutes (manual failover)
- Availability: 99.9%

Tier 3 - Standard (Analytics):
- RPO: < 1 hour (backup-based recovery)
- RTO: < 4 hours (restore from backup)
- Availability: 99.5%
```

### 7.2 Disaster Scenarios and Recovery Procedures

#### Scenario 1: Primary Node Failure

**Detection:** Patroni automatically detects primary failure via health checks.

**Automatic Failover Process:**
```
1. Patroni detects primary unavailable (< 30 seconds)
2. etcd coordinates leader election
3. Standby node (patroni-2) promoted to primary
4. HAProxy redirects traffic to new primary
5. Clients reconnect automatically
```

**Manual Verification:**
```bash
# Check cluster status
curl http://patroni-1:8008/cluster | jq

# Verify new primary
psql -h haproxy -U postgres -c "SELECT pg_is_in_recovery();"

# Check replication lag
psql -h haproxy -U postgres -c "SELECT * FROM pg_stat_replication;"
```

**Recovery:**
```bash
# Investigate failure on patroni-1
docker service logs postgres-prod_patroni-1

# Reinstate failed node
docker exec postgres-prod_patroni-1 patronictl reinit postgres-cluster-main patroni-1

# Verify rejoin
curl http://patroni-1:8008/patroni | jq
```

#### Scenario 2: etcd Cluster Failure

**Detection:** etcd health checks fail, Patroni cannot access DCS.

**Recovery:**
```bash
# Check etcd cluster health
docker exec postgres-prod_etcd-1 etcdctl endpoint health --cluster

# Scenario A: Single etcd node failure
# Cluster continues operating (quorum maintained)
# Restart failed node
docker service update --force postgres-prod_etcd-1

# Scenario B: Quorum lost (2+ nodes failed)
# Emergency recovery: Restore from backup
docker exec postgres-prod_etcd-1 etcdctl snapshot restore /backups/etcd-snapshot.db
```

#### Scenario 3: Complete Cluster Failure

**Recovery from Backup:**
```bash
# 1. Restore infrastructure
# Provision new nodes and configure Docker Swarm

# 2. Restore etcd cluster
docker stack deploy -c docker-compose.yml postgres-prod
# Wait for etcd cluster to stabilize

# 3. Restore PostgreSQL from backup
LATEST_BACKUP=$(ls -t /mnt/postgres-cluster/backups/daily/*.tar.gz.enc | head -1)

# Decrypt backup
openssl enc -aes-256-cbc -d -pbkdf2 \
  -in "$LATEST_BACKUP" \
  -out /tmp/backup.tar.gz \
  -pass file:/run/secrets/backup_encryption_key

# Extract backup
tar -xzf /tmp/backup.tar.gz -C /mnt/postgres-cluster/patroni-1/

# 4. Restore WAL archives for point-in-time recovery
# Copy WAL files from archives
cp /mnt/postgres-cluster/archives/wal/* /mnt/postgres-cluster/patroni-1/pgdata/pg_wal/

# 5. Start Patroni cluster
docker service scale postgres-prod_patroni=3

# 6. Verify data integrity
psql -h haproxy -U postgres -c "SELECT COUNT(*) FROM critical_table;"
```

#### Scenario 4: Network Partition (Split-Brain)

**Prevention:** etcd quorum prevents split-brain.

**Detection:**
```bash
# Check cluster state
curl http://patroni-1:8008/cluster | jq '.members[] | {name, role, state}'
```

**Recovery:**
```bash
# If split-brain detected (rare with etcd):
# 1. Identify primary with latest data
psql -h patroni-1 -U postgres -c "SELECT pg_last_wal_replay_lsn();"
psql -h patroni-2 -U postgres -c "SELECT pg_last_wal_replay_lsn();"

# 2. Force reinit on stale nodes
docker exec postgres-prod_patroni-2 patronictl reinit postgres-cluster-main patroni-2 --force

# 3. Verify cluster consistency
curl http://patroni-1:8008/cluster | jq
```

### 7.3 Backup and Restore Procedures

#### Point-in-Time Recovery (PITR)

```bash
# Restore to specific timestamp
TARGET_TIME="2024-02-12 14:30:00"

# 1. Stop PostgreSQL
docker service scale postgres-prod_patroni=0

# 2. Restore base backup
tar -xzf /mnt/postgres-cluster/backups/daily/postgres_backup_20240212_020000.tar.gz \
  -C /mnt/postgres-cluster/patroni-1/

# 3. Create recovery configuration
cat > /mnt/postgres-cluster/patroni-1/pgdata/recovery.signal <<EOF
restore_command = 'cp /mnt/postgres-cluster/archives/wal/%f %p'
recovery_target_time = '$TARGET_TIME'
recovery_target_action = 'promote'
EOF

# 4. Start PostgreSQL
docker service scale postgres-prod_patroni=1

# 5. Verify recovery
tail -f /var/log/postgresql/postgresql-*.log | grep "recovery"

# 6. Once promoted, rebuild replicas
docker service scale postgres-prod_patroni=3
```

#### Testing Backup Integrity

```bash
# Monthly backup validation
#!/bin/bash
TEST_RESTORE_DIR="/mnt/postgres-cluster/test-restore"
LATEST_BACKUP=$(ls -t /mnt/postgres-cluster/backups/daily/*.tar.gz.enc | head -1)

# Decrypt and extract
openssl enc -aes-256-cbc -d -pbkdf2 \
  -in "$LATEST_BACKUP" \
  -out /tmp/test-backup.tar.gz \
  -pass file:/run/secrets/backup_encryption_key

mkdir -p "$TEST_RESTORE_DIR"
tar -xzf /tmp/test-backup.tar.gz -C "$TEST_RESTORE_DIR"

# Start test instance
docker run -d --name postgres-test \
  -v "$TEST_RESTORE_DIR:/var/lib/postgresql/data" \
  -p 5433:5432 \
  ruvnet/ruvector-postgres:latest

# Verify data
sleep 30
psql -h localhost -p 5433 -U postgres -c "SELECT COUNT(*) FROM pg_tables;"

# Cleanup
docker stop postgres-test && docker rm postgres-test
rm -rf "$TEST_RESTORE_DIR" /tmp/test-backup.tar.gz

echo "Backup validation completed: $(date)" >> /var/log/backup-validation.log
```

### 7.4 Disaster Recovery Drills

**Quarterly DR Drill Schedule:**

```
Q1: Primary Node Failure
- Simulate primary node crash
- Verify automatic failover
- Measure RTO/RPO
- Document lessons learned

Q2: Complete Cluster Rebuild
- Restore from backup
- Verify data integrity
- Test PITR
- Update runbooks

Q3: Network Partition Simulation
- Isolate network segments
- Verify split-brain prevention
- Test reconnection
- Validate replication

Q4: Multi-Region Failover (if applicable)
- Failover to DR region
- Verify application connectivity
- Measure recovery time
- Test failback procedures
```

**DR Drill Checklist:**
```
Pre-Drill:
[ ] Schedule drill with stakeholders
[ ] Notify teams
[ ] Prepare monitoring dashboards
[ ] Backup current state

During Drill:
[ ] Document start time
[ ] Execute failure scenario
[ ] Monitor system behavior
[ ] Track recovery metrics
[ ] Test application connectivity

Post-Drill:
[ ] Document end time
[ ] Calculate RTO/RPO
[ ] Identify issues
[ ] Update procedures
[ ] Share results with team
```

---

## 8. Monitoring and Observability

### 8.1 Key Metrics

#### PostgreSQL Metrics
```
Performance:
- TPS (Transactions Per Second)
- Query latency (p50, p95, p99)
- Cache hit ratio
- Active connections
- Idle connections
- Connection wait time

Replication:
- Replication lag (bytes and seconds)
- WAL generation rate
- Replication slots status
- Streaming replication state

Resources:
- CPU utilization
- Memory utilization
- Disk I/O (read/write IOPS)
- Disk space usage
- Network throughput

Health:
- Database availability
- Checkpoint frequency
- Vacuum operations
- Bloat percentage
- Lock waits
```

#### System Metrics
```
Docker Swarm:
- Service replica status
- Node availability
- Task failures
- Container restart count

etcd:
- Leader status
- Quorum health
- Database size
- Key-value operations/sec

HAProxy:
- Frontend connections
- Backend status
- Request rate
- Error rate (4xx, 5xx)
- Response time

Redis:
- Cache hit ratio
- Eviction rate
- Memory usage
- Connected clients
```

### 8.2 Prometheus Configuration

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: 'postgres-prod'
    datacenter: 'dc1'

# Alerting configuration
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

# Load alert rules
rule_files:
  - '/etc/prometheus/alerts.yml'

# Scrape configurations
scrape_configs:
  # PostgreSQL metrics
  - job_name: 'postgres'
    static_configs:
      - targets:
          - 'postgres-exporter:9187'
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        regex: '([^:]+).*'

  # Patroni metrics
  - job_name: 'patroni'
    static_configs:
      - targets:
          - 'patroni-1:8008'
          - 'patroni-2:8008'
          - 'patroni-3:8008'
    metrics_path: '/metrics'

  # etcd metrics
  - job_name: 'etcd'
    static_configs:
      - targets:
          - 'etcd-1:2379'
          - 'etcd-2:2379'
          - 'etcd-3:2379'

  # HAProxy metrics
  - job_name: 'haproxy'
    static_configs:
      - targets:
          - 'haproxy:9101'

  # Redis metrics
  - job_name: 'redis'
    static_configs:
      - targets:
          - 'redis-exporter:9121'

  # Node exporter (system metrics)
  - job_name: 'node'
    static_configs:
      - targets:
          - 'node-exporter:9100'

  # Docker metrics
  - job_name: 'docker'
    static_configs:
      - targets:
          - 'cadvisor:8080'
```

### 8.3 Alert Rules

```yaml
# prometheus_alerts.yml
groups:
  - name: postgres
    interval: 30s
    rules:
      # Database down
      - alert: PostgreSQLDown
        expr: pg_up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "PostgreSQL is down"
          description: "PostgreSQL instance {{ $labels.instance }} is down"

      # High connection usage
      - alert: PostgreSQLHighConnections
        expr: (pg_stat_database_numbackends / pg_settings_max_connections) > 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High connection usage"
          description: "Connection usage is {{ $value | humanizePercentage }}"

      # Replication lag
      - alert: PostgreSQLReplicationLag
        expr: pg_replication_lag > 30
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High replication lag"
          description: "Replication lag is {{ $value }} seconds"

      # Disk space
      - alert: PostgreSQLDiskSpaceLow
        expr: (pg_database_size_bytes / pg_filesystem_size_bytes) > 0.85
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Low disk space"
          description: "Disk usage is {{ $value | humanizePercentage }}"

      # Cache hit ratio
      - alert: PostgreSQLLowCacheHitRatio
        expr: pg_stat_database_blks_hit / (pg_stat_database_blks_hit + pg_stat_database_blks_read) < 0.95
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Low cache hit ratio"
          description: "Cache hit ratio is {{ $value | humanizePercentage }}"

  - name: patroni
    interval: 30s
    rules:
      # No primary
      - alert: PatroniNoPrimary
        expr: count(patroni_postgres_running{role="master"}) == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "No Patroni primary"
          description: "No Patroni primary node detected"

      # Multiple primaries (split-brain)
      - alert: PatroniMultiplePrimaries
        expr: count(patroni_postgres_running{role="master"}) > 1
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Multiple Patroni primaries detected"
          description: "Split-brain scenario - multiple primaries"

  - name: etcd
    interval: 30s
    rules:
      # etcd down
      - alert: EtcdDown
        expr: up{job="etcd"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "etcd node down"
          description: "etcd node {{ $labels.instance }} is down"

      # No leader
      - alert: EtcdNoLeader
        expr: etcd_server_has_leader == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "etcd has no leader"
          description: "etcd cluster has no leader"

  - name: haproxy
    interval: 30s
    rules:
      # Backend down
      - alert: HAProxyBackendDown
        expr: haproxy_backend_up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "HAProxy backend down"
          description: "HAProxy backend {{ $labels.backend }} is down"
```

### 8.4 Grafana Dashboards

Key dashboards to create:

1. **Cluster Overview Dashboard**
   - Cluster health status
   - Primary/standby node status
   - Replication lag
   - Active connections
   - TPS and query latency

2. **Performance Dashboard**
   - Query performance (p50, p95, p99)
   - Cache hit ratios
   - Buffer usage
   - Vacuum operations
   - Table bloat

3. **Resource Utilization Dashboard**
   - CPU usage per node
   - Memory usage per node
   - Disk I/O per node
   - Network throughput
   - Disk space utilization

4. **Replication Dashboard**
   - Replication lag per node
   - WAL generation rate
   - Streaming replication status
   - Replication slots

5. **Application Dashboard**
   - Connection pool status
   - Cache hit ratio (Redis)
   - HAProxy request rate
   - Error rates
   - Response times

---

## 9. Operational Procedures

### 9.1 Rolling Updates

```bash
# Update PostgreSQL image version
docker service update \
  --image ruvnet/ruvector-postgres:new-version \
  --update-parallelism 1 \
  --update-delay 60s \
  --update-failure-action rollback \
  postgres-prod_patroni

# Monitor update progress
watch -n 1 'docker service ps postgres-prod_patroni'

# Verify cluster health after update
curl http://patroni-1:8008/cluster | jq
```

### 9.2 Configuration Changes

```bash
# Update Patroni configuration
docker exec postgres-prod_patroni-1 \
  patronictl edit-config postgres-cluster-main

# Reload configuration without restart
docker exec postgres-prod_patroni-1 \
  patronictl reload postgres-cluster-main --force

# Restart if required
docker exec postgres-prod_patroni-1 \
  patronictl restart postgres-cluster-main patroni-1 --force
```

### 9.3 Manual Failover

```bash
# Planned maintenance: Switchover to standby
docker exec postgres-prod_patroni-1 \
  patronictl switchover postgres-cluster-main \
  --master patroni-1 \
  --candidate patroni-2 \
  --force

# Emergency failover
docker exec postgres-prod_patroni-2 \
  patronictl failover postgres-cluster-main \
  --candidate patroni-2 \
  --force
```

### 9.4 Node Maintenance

```bash
# Drain node before maintenance
docker node update --availability drain node-4

# Move services to other nodes
docker service update --force postgres-prod_patroni

# Perform maintenance (OS updates, hardware replacement, etc.)

# Reactivate node
docker node update --availability active node-4
```

---

## 10. Cost Optimization

### 10.1 Right-Sizing Resources

```
Optimization Opportunities:

1. Use Reserved/Committed Instances (30-70% savings)
   - AWS Reserved Instances
   - GCP Committed Use Discounts
   - Azure Reserved VM Instances

2. Implement Auto-Scaling for Non-Critical Components
   - Scale down HAProxy during low traffic
   - Scale down read replicas during off-hours
   - Use spot instances for dev/test

3. Optimize Storage
   - Use lifecycle policies for backups
   - Compress and deduplicate backups
   - Move old backups to cold storage (Glacier/Archive)

4. Network Optimization
   - Use VPC endpoints to avoid NAT Gateway costs
   - Enable compression for replication
   - Colocate nodes in same AZ when possible

5. Monitoring Optimization
   - Reduce Prometheus retention (30d -> 15d)
   - Lower scrape intervals for non-critical metrics
   - Archive old metrics to object storage
```

### 10.2 Cost Breakdown

Estimated monthly costs for production deployment:

```
AWS Cost Estimate (us-east-1):

Compute:
- 3x r6i.2xlarge (Patroni): $1,260/month
- 3x t3.xlarge (etcd): $300/month
- 2x t3.large (App nodes): $150/month
Subtotal: $1,710/month

Storage:
- 6 TB EBS gp3 (PostgreSQL): $480/month
- 5 TB EBS gp3 (Backups): $400/month
- 500 GB S3 Standard-IA (Offsite): $10/month
Subtotal: $890/month

Network:
- Data transfer (1 TB/month): $90/month
- NAT Gateway (3 AZs): $98/month
Subtotal: $188/month

Load Balancing:
- Network Load Balancer: $22/month
Subtotal: $22/month

Total: ~$2,810/month

With Reserved Instances (1-year term):
Total: ~$1,970/month (30% savings)

With Reserved Instances (3-year term):
Total: ~$1,685/month (40% savings)
```

### 10.3 Cost Monitoring

```bash
# AWS Cost Tracking
aws ce get-cost-and-usage \
  --time-period Start=2024-02-01,End=2024-02-28 \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --group-by Type=TAG,Key=Service

# Set up cost alerts
aws budgets create-budget \
  --account-id 123456789012 \
  --budget file://budget.json \
  --notifications-with-subscribers file://notifications.json
```

---

## Conclusion

This production deployment architecture provides a robust, scalable, and highly available PostgreSQL cluster solution. The design incorporates industry best practices for:

- **High Availability:** 99.95% uptime with automatic failover
- **Disaster Recovery:** Comprehensive backup and recovery procedures
- **Security:** Defense-in-depth with encryption and access controls
- **Scalability:** Horizontal and vertical scaling capabilities
- **Observability:** Complete monitoring and alerting stack
- **Cost Efficiency:** Right-sized resources with optimization strategies

**Next Steps:**
1. Review infrastructure requirements with stakeholders
2. Provision cloud resources or prepare on-premises hardware
3. Execute deployment procedures
4. Conduct disaster recovery drills
5. Fine-tune performance based on actual workload
6. Schedule regular maintenance and reviews

**Support Resources:**
- Architecture documentation: `/docs/architecture/`
- Deployment scripts: `/scripts/deployment/`
- Monitoring dashboards: `/config/monitoring/`
- Runbooks: `/docs/operations/`

For questions or issues, consult the operations team or refer to the troubleshooting guide in `/docs/operations/TROUBLESHOOTING.md`.
