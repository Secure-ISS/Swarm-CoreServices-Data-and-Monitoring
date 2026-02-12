# Backup and Restore Guide

Comprehensive guide for backup and disaster recovery in the Distributed PostgreSQL Cluster.

## Table of Contents

1. [Overview](#overview)
2. [Backup Strategies](#backup-strategies)
3. [RPO/RTO Targets](#rporto-targets)
4. [Backup Manager](#backup-manager)
5. [Restore Manager](#restore-manager)
6. [Verification](#verification)
7. [Cloud Storage](#cloud-storage)
8. [Disaster Recovery](#disaster-recovery)
9. [Best Practices](#best-practices)

## Overview

### Backup Types

| Type | Frequency | Retention | Storage | Use Case |
|------|-----------|-----------|---------|----------|
| Full | Daily | 7 days | Local + Cloud | Complete recovery |
| Weekly | Weekly | 4 weeks | Cloud | Long-term recovery |
| Monthly | Monthly | 6 months | Cloud | Historical data |
| WAL | Continuous | 7 days | Local + Cloud | PITR, replication |
| Config | Daily | 10 backups | Local + Cloud | Configuration recovery |
| Indexes | Daily | 5 backups | Local | Quick rebuild |

### Features

- **Multiple deployment modes**: Single-node, Citus, Patroni
- **Compression**: gzip, bzip2, xz, zstd
- **Encryption**: AES-256-CBC with pbkdf2
- **Cloud storage**: S3, GCS, Azure Blob
- **PITR**: Point-in-time recovery
- **Verification**: Automated integrity checks
- **Monitoring**: Storage capacity planning

## Backup Strategies

### Strategy Comparison

| Strategy | RPO | RTO | Storage | Complexity | Cost |
|----------|-----|-----|---------|------------|------|
| Full Only | 24h | 2-4h | High | Low | Low |
| Full + WAL | 5min | 1-2h | Medium | Medium | Medium |
| PITR | <1min | 30min-1h | High | High | High |
| Replication | 0 | 5-15min | Very High | Very High | Very High |

### Recommended Configuration

```bash
# Daily full backup at 2:00 AM
0 2 * * * /path/to/backup-manager.sh full daily

# Weekly backup on Sunday at 3:00 AM
0 3 * * 0 /path/to/backup-manager.sh full weekly

# Monthly backup on 1st at 4:00 AM
0 4 1 * * /path/to/backup-manager.sh full monthly

# Config backup daily at 1:00 AM
0 1 * * * /path/to/backup-manager.sh config

# Index backup daily at 1:30 AM
30 1 * * * /path/to/backup-manager.sh indexes

# Retention policy at 5:00 AM
0 5 * * * /path/to/backup-manager.sh retention

# Verification daily at 6:00 AM
0 6 * * * /path/to/verify-backups.sh all
```

## RPO/RTO Targets

### Recovery Point Objective (RPO)

**RPO**: Maximum acceptable data loss

| Tier | RPO | Backup Method |
|------|-----|---------------|
| Critical | <5 minutes | WAL archiving + Streaming replication |
| Important | <1 hour | WAL archiving |
| Standard | <24 hours | Daily full backups |
| Archival | <1 week | Weekly backups |

### Recovery Time Objective (RTO)

**RTO**: Maximum acceptable downtime

| Tier | RTO | Recovery Method |
|------|-----|-----------------|
| Critical | <15 minutes | Hot standby + automatic failover |
| Important | <1 hour | Warm standby + manual failover |
| Standard | <4 hours | Full restore from backup |
| Archival | <24 hours | Restore from cloud storage |

### Calculating RPO/RTO

```bash
# RPO Calculation
# Data loss = Time since last backup

# With daily backups
RPO_daily = 24 hours

# With WAL archiving (5 min intervals)
RPO_wal = 5 minutes

# RTO Calculation
# Downtime = Detection + Decision + Recovery + Validation

# Full restore example
RTO_full = 5min (detection) + 10min (decision) + 2h (restore) + 15min (validation)
RTO_full = ~2.5 hours

# PITR example
RTO_pitr = 5min + 10min + 1h + 15min = ~1.5 hours

# Hot standby failover
RTO_standby = 5min + 2min + 5min + 3min = ~15 minutes
```

## Backup Manager

### Installation

```bash
cd /path/to/project
chmod +x scripts/backup/backup-manager.sh

# Initialize backup directories
./scripts/backup/backup-manager.sh init

# Generate cron schedule
./scripts/backup/backup-manager.sh schedule
```

### Configuration

Create or update `.env` file:

```bash
# Backup configuration
BACKUP_DIR=/var/backups/postgresql
WAL_ARCHIVE_DIR=/var/backups/postgresql/wal
RETENTION_DAYS=7
RETENTION_WEEKS=4
RETENTION_MONTHS=6

# Compression (gzip|bzip2|xz|zstd|none)
COMPRESSION=gzip
PARALLEL_JOBS=4

# Encryption
ENCRYPTION=true
ENCRYPTION_KEY=your-secret-key-here

# Notifications
EMAIL_NOTIFICATIONS=true
EMAIL_TO=admin@example.com

# Cloud storage
CLOUD_PROVIDER=s3  # s3|gcs|azure|none
CLOUD_BUCKET=my-backups

# Deployment mode
DEPLOYMENT_MODE=single-node  # single-node|citus|patroni

# Database connection
PGHOST=localhost
PGPORT=5432
PGUSER=postgres
PGDATABASE=postgres
```

### Usage Examples

#### Full Backup

```bash
# Manual full backup
./scripts/backup/backup-manager.sh full manual

# Daily backup (for cron)
./scripts/backup/backup-manager.sh full daily

# Weekly backup (for cron)
./scripts/backup/backup-manager.sh full weekly

# Monthly backup (for cron)
./scripts/backup/backup-manager.sh full monthly
```

#### WAL Archiving

Configure PostgreSQL for WAL archiving:

```sql
-- Edit postgresql.conf
wal_level = replica
archive_mode = on
archive_command = '/path/to/backup-manager.sh wal %p'
archive_timeout = 300  -- 5 minutes
```

Restart PostgreSQL:

```bash
# Docker
docker restart ruvector-db

# System service
sudo systemctl restart postgresql
```

#### Configuration Backup

```bash
./scripts/backup/backup-manager.sh config
```

#### Index Backup

```bash
./scripts/backup/backup-manager.sh indexes
```

#### Apply Retention

```bash
./scripts/backup/backup-manager.sh retention
```

#### Show Statistics

```bash
./scripts/backup/backup-manager.sh stats
```

## Restore Manager

### Installation

```bash
cd /path/to/project
chmod +x scripts/backup/restore-manager.sh

# Initialize restore environment
./scripts/backup/restore-manager.sh init
```

### Usage Examples

#### List Available Backups

```bash
./scripts/backup/restore-manager.sh list
```

#### Full Restore

```bash
# Restore to default database
./scripts/backup/restore-manager.sh full /var/backups/postgresql/full/full-daily-20260212.sql.gz

# Restore to specific database
./scripts/backup/restore-manager.sh full /var/backups/postgresql/full/full-daily-20260212.sql.gz my_database
```

#### Point-in-Time Recovery (PITR)

```bash
# Restore to specific timestamp
./scripts/backup/restore-manager.sh pitr \
  /var/backups/postgresql/full/full-daily-20260212.sql.gz \
  "2026-02-12 10:30:00" \
  my_database
```

PITR Requirements:

1. Base backup (full backup)
2. WAL archives from backup time to target time
3. `restore_command` configured

#### Partial Restore

Restore single table:

```bash
./scripts/backup/restore-manager.sh partial \
  /var/backups/postgresql/full/full-daily-20260212.sql.gz \
  table \
  users \
  my_database
```

Restore single schema:

```bash
./scripts/backup/restore-manager.sh partial \
  /var/backups/postgresql/full/full-daily-20260212.sql.gz \
  schema \
  public \
  my_database
```

#### Rebuild Indexes

```bash
./scripts/backup/restore-manager.sh indexes my_database
```

#### Validate Restore

```bash
./scripts/backup/restore-manager.sh validate my_database
```

#### Test Restore

```bash
# Automated restore test (creates temp DB)
./scripts/backup/restore-manager.sh test /var/backups/postgresql/full/full-daily-20260212.sql.gz
```

## Verification

### Installation

```bash
cd /path/to/project
chmod +x scripts/backup/verify-backups.sh
```

### Usage Examples

#### Verify All Backups

```bash
./scripts/backup/verify-backups.sh all
```

#### Verify File Integrity

```bash
./scripts/backup/verify-backups.sh file /var/backups/postgresql/full/full-daily-20260212.sql.gz
```

#### Test Restore

```bash
./scripts/backup/verify-backups.sh restore /var/backups/postgresql/full/full-daily-20260212.sql.gz
```

#### Test RuVector Indexes

```bash
./scripts/backup/verify-backups.sh indexes /var/backups/postgresql/full/full-daily-20260212.sql.gz
```

#### Monitor Sizes

```bash
./scripts/backup/verify-backups.sh sizes
```

#### Check Capacity

```bash
./scripts/backup/verify-backups.sh capacity
```

#### Generate Report

```bash
./scripts/backup/verify-backups.sh report
```

## Cloud Storage

### AWS S3

#### Setup

```bash
# Install AWS CLI
pip install awscli

# Configure credentials
aws configure
```

#### Configuration

```bash
CLOUD_PROVIDER=s3
CLOUD_BUCKET=my-postgresql-backups
AWS_DEFAULT_REGION=us-east-1
```

#### Manual Upload

```bash
aws s3 cp /var/backups/postgresql/full/backup.sql.gz \
  s3://my-postgresql-backups/full/backup.sql.gz \
  --storage-class STANDARD_IA
```

#### Lifecycle Policy

```json
{
  "Rules": [{
    "Id": "PostgreSQL Backup Lifecycle",
    "Status": "Enabled",
    "Transitions": [
      {
        "Days": 30,
        "StorageClass": "GLACIER"
      }
    ],
    "Expiration": {
      "Days": 180
    }
  }]
}
```

### Google Cloud Storage (GCS)

#### Setup

```bash
# Install gcloud SDK
curl https://sdk.cloud.google.com | bash

# Authenticate
gcloud auth login
```

#### Configuration

```bash
CLOUD_PROVIDER=gcs
CLOUD_BUCKET=my-postgresql-backups
```

#### Manual Upload

```bash
gsutil cp /var/backups/postgresql/full/backup.sql.gz \
  gs://my-postgresql-backups/full/backup.sql.gz
```

#### Lifecycle Policy

```json
{
  "lifecycle": {
    "rule": [{
      "action": {
        "type": "SetStorageClass",
        "storageClass": "NEARLINE"
      },
      "condition": {
        "age": 30
      }
    }]
  }
}
```

### Azure Blob Storage

#### Setup

```bash
# Install Azure CLI
pip install azure-cli

# Login
az login
```

#### Configuration

```bash
CLOUD_PROVIDER=azure
CLOUD_BUCKET=postgresql-backups
AZURE_STORAGE_ACCOUNT=mystorageaccount
```

#### Manual Upload

```bash
az storage blob upload \
  --account-name mystorageaccount \
  --container-name postgresql-backups \
  --name full/backup.sql.gz \
  --file /var/backups/postgresql/full/backup.sql.gz \
  --tier Cool
```

## Disaster Recovery

### Disaster Recovery Plan

#### 1. Preparation Phase

- [ ] Document backup procedures
- [ ] Configure automated backups
- [ ] Set up cloud storage
- [ ] Test restore procedures
- [ ] Train operations team
- [ ] Create runbooks

#### 2. Detection Phase

Monitor for:

- Database crashes
- Data corruption
- Hardware failures
- Accidental deletions
- Security breaches
- Natural disasters

#### 3. Response Phase

```bash
# Step 1: Assess the situation
# - What happened?
# - What data is affected?
# - What is the target recovery point?

# Step 2: Stop the problem
# - Shut down affected systems
# - Prevent further damage

# Step 3: Initiate recovery
# - Choose recovery method
# - Start restore process

# Step 4: Validate recovery
# - Test database connectivity
# - Verify data integrity
# - Check application functionality

# Step 5: Resume operations
# - Switch traffic to recovered database
# - Monitor for issues
# - Document incident
```

### Recovery Scenarios

#### Scenario 1: Accidental Table Drop

**Problem**: User accidentally dropped a table

**Solution**: Partial restore

```bash
# 1. Identify backup containing the table
./scripts/backup/restore-manager.sh list

# 2. Restore the table
./scripts/backup/restore-manager.sh partial \
  /var/backups/postgresql/full/full-daily-20260212.sql.gz \
  table \
  users \
  production_db
```

**RPO**: 24 hours (daily backup)
**RTO**: 30 minutes

#### Scenario 2: Data Corruption

**Problem**: Application bug corrupted data 2 hours ago

**Solution**: Point-in-time recovery

```bash
# 1. Identify corruption time
CORRUPTION_TIME="2026-02-12 10:30:00"

# 2. Find backup before corruption
BACKUP_FILE="/var/backups/postgresql/full/full-daily-20260212.sql.gz"

# 3. Restore to time before corruption
./scripts/backup/restore-manager.sh pitr \
  "$BACKUP_FILE" \
  "$CORRUPTION_TIME" \
  production_db
```

**RPO**: 5 minutes (WAL archiving)
**RTO**: 1-2 hours

#### Scenario 3: Complete Database Loss

**Problem**: Server hardware failure, complete database loss

**Solution**: Full restore from cloud backup

```bash
# 1. Download latest backup from cloud
aws s3 cp s3://my-backups/full/full-daily-20260212.sql.gz \
  /var/backups/postgresql/full/

# 2. Restore full backup
./scripts/backup/restore-manager.sh full \
  /var/backups/postgresql/full/full-daily-20260212.sql.gz \
  production_db

# 3. Validate restore
./scripts/backup/restore-manager.sh validate production_db
```

**RPO**: 24 hours (daily backup)
**RTO**: 4-6 hours (including hardware provisioning)

#### Scenario 4: Ransomware Attack

**Problem**: Ransomware encrypted database files

**Solution**: Restore from offsite backup, rebuild from scratch

```bash
# 1. Isolate affected systems
# 2. Provision new clean environment
# 3. Download clean backups from cloud

# 4. Restore to new environment
./scripts/backup/restore-manager.sh full \
  /var/backups/postgresql/full/full-weekly-20260209.sql.gz \
  production_db

# 5. Apply WAL archives up to infection point
# 6. Validate data integrity
./scripts/backup/restore-manager.sh validate production_db

# 7. Update security measures
# 8. Switch applications to new database
```

**RPO**: 1 week (last clean backup)
**RTO**: 8-12 hours

### Disaster Recovery Drills

#### Monthly Drill: Partial Restore

```bash
#!/bin/bash
# Test partial restore capability

echo "DR Drill: Partial Restore - $(date)"

# 1. Create test database
psql -c "CREATE DATABASE dr_test_$(date +%s);"

# 2. Perform restore test
./scripts/backup/verify-backups.sh restore \
  /var/backups/postgresql/full/full-daily-latest.sql.gz

# 3. Validate
./scripts/backup/restore-manager.sh validate dr_test_*

# 4. Cleanup
psql -c "DROP DATABASE dr_test_*;"

echo "DR Drill completed"
```

#### Quarterly Drill: Full PITR

```bash
#!/bin/bash
# Test full point-in-time recovery

echo "DR Drill: PITR - $(date)"

# 1. Create test database
TEST_DB="dr_pitr_test_$(date +%s)"
psql -c "CREATE DATABASE $TEST_DB;"

# 2. Get timestamp 1 hour ago
TARGET_TIME=$(date -d '1 hour ago' '+%Y-%m-%d %H:%M:%S')

# 3. Perform PITR
./scripts/backup/restore-manager.sh pitr \
  /var/backups/postgresql/full/full-daily-latest.sql.gz \
  "$TARGET_TIME" \
  "$TEST_DB"

# 4. Validate
./scripts/backup/restore-manager.sh validate "$TEST_DB"

# 5. Cleanup
psql -c "DROP DATABASE $TEST_DB;"

echo "DR Drill completed"
```

#### Annual Drill: Complete Disaster Scenario

```bash
#!/bin/bash
# Simulate complete data center loss

echo "DR Drill: Complete Disaster - $(date)"

# 1. Download backup from cloud
aws s3 cp s3://my-backups/full/full-weekly-latest.sql.gz /tmp/

# 2. Provision new environment (simulated)
# 3. Restore database
# 4. Reconfigure applications
# 5. Test application functionality
# 6. Measure total recovery time

echo "DR Drill completed - Recovery time: $SECONDS seconds"
```

## Best Practices

### 1. Backup Best Practices

- **3-2-1 Rule**: 3 copies, 2 different media, 1 offsite
- **Test regularly**: Monthly restore tests minimum
- **Encrypt**: Always encrypt sensitive data
- **Automate**: Use cron/systemd for automation
- **Monitor**: Set up alerts for backup failures
- **Document**: Keep recovery procedures updated
- **Verify**: Always verify backup integrity

### 2. Security Best Practices

```bash
# Secure backup directory
chmod 700 /var/backups/postgresql
chown postgres:postgres /var/backups/postgresql

# Use strong encryption keys
openssl rand -base64 32 > /secure/path/encryption-key

# Rotate encryption keys quarterly
# Store keys in separate location from backups

# Use IAM roles for cloud access (avoid access keys)
# Enable MFA for cloud accounts
# Audit backup access logs regularly
```

### 3. Performance Best Practices

```bash
# Use parallel compression
PARALLEL_JOBS=4
COMPRESSION=zstd

# Schedule backups during low-traffic periods
0 2 * * * /path/to/backup-manager.sh full daily

# Use incremental backups (WAL archiving)
# Reduce full backup frequency for large databases

# Monitor backup performance
time /path/to/backup-manager.sh full manual
```

### 4. Storage Best Practices

```bash
# Implement lifecycle policies
# - Move to cold storage after 30 days
# - Delete after retention period

# Monitor storage costs
aws s3 ls s3://my-backups --recursive --summarize --human-readable

# Use compression
# - gzip: Good balance (default)
# - zstd: Best compression ratio
# - lz4: Fastest compression

# Clean up old backups
./scripts/backup/backup-manager.sh retention
```

### 5. Monitoring Best Practices

```bash
# Monitor backup status
./scripts/backup/backup-manager.sh stats

# Check storage capacity weekly
./scripts/backup/verify-backups.sh capacity

# Set up alerts
# - Backup failure
# - Storage capacity > 80%
# - Backup age > 48 hours
# - Restore test failure

# Generate monthly reports
./scripts/backup/verify-backups.sh report
```

## Troubleshooting

### Common Issues

#### Backup Failure: Disk Space

```bash
# Check disk space
df -h /var/backups/postgresql

# Clean up old backups
./scripts/backup/backup-manager.sh retention

# Increase compression
COMPRESSION=xz ./scripts/backup/backup-manager.sh full manual

# Move to cloud storage
CLOUD_PROVIDER=s3 ./scripts/backup/backup-manager.sh full manual
```

#### Restore Failure: Corrupted Backup

```bash
# Verify backup integrity
./scripts/backup/verify-backups.sh file /path/to/backup.sql.gz

# Try alternative backup
./scripts/backup/restore-manager.sh list

# Restore from cloud if local backup corrupted
aws s3 cp s3://my-backups/full/backup.sql.gz /tmp/
./scripts/backup/restore-manager.sh full /tmp/backup.sql.gz
```

#### WAL Archive Failure

```bash
# Check archive_command
psql -c "SHOW archive_command;"

# Check WAL directory permissions
ls -la /var/backups/postgresql/wal

# Check disk space
df -h /var/backups/postgresql/wal

# Force WAL archive
psql -c "SELECT pg_switch_wal();"
```

## Appendix

### Backup File Naming Convention

```
Format: {type}-{schedule}-{timestamp}.{ext}

Examples:
full-daily-20260212-020000.sql.gz
full-weekly-20260209-030000.sql.gz
full-monthly-20260201-040000.sql.gz
config-20260212-010000.tar.gz
ruvector-indexes-20260212-013000.sql.gz
```

### Recovery Time Estimation

```
Recovery Time = Download + Decompress + Restore + Validate

Small DB (<1GB):   10min + 2min + 5min + 2min = ~20min
Medium DB (10GB):  30min + 5min + 20min + 5min = ~1h
Large DB (100GB):  2h + 15min + 2h + 15min = ~4.5h
XL DB (1TB):       8h + 1h + 8h + 1h = ~18h
```

### Backup Storage Estimation

```
Storage = Database Size × Compression Ratio × Retention

Example:
Database: 100GB
Compression: 0.3 (gzip)
Retention: 7 daily + 4 weekly + 6 monthly

Daily: 100GB × 0.3 × 7 = 210GB
Weekly: 100GB × 0.3 × 4 = 120GB
Monthly: 100GB × 0.3 × 6 = 180GB
WAL: 100GB × 0.1 × 7 = 70GB

Total: 580GB
```

## Support

For issues or questions:

- GitHub Issues: https://github.com/yourusername/distributed-postgres-cluster/issues
- Documentation: /docs
- Contact: admin@example.com
