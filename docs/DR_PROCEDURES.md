# Disaster Recovery Procedures

## Overview

This document outlines the disaster recovery procedures for the Distributed PostgreSQL Cluster. It provides step-by-step guidance for responding to various disaster scenarios, ensuring rapid recovery and minimal data loss.

---

## Quick Reference

### Emergency Contacts

| Role | Contact | Phone | Email |
|------|---------|-------|-------|
| DR Coordinator | [Name] | [Phone] | [Email] |
| Technical Lead | [Name] | [Phone] | [Email] |
| Database Administrator | [Name] | [Phone] | [Email] |
| Systems Administrator | [Name] | [Phone] | [Email] |
| Security Lead | [Name] | [Phone] | [Email] |
| Management Escalation | [Name] | [Phone] | [Email] |

### Critical Metrics

- **RTO (Recovery Time Objective)**: 15 minutes
- **RPO (Recovery Point Objective)**: 5 minutes
- **Maximum Acceptable Downtime**: 30 minutes
- **Data Loss Tolerance**: 5 minutes of transactions

---

## Incident Command Structure

### Roles and Responsibilities

#### 1. Incident Commander (DR Coordinator)
- Overall responsibility for disaster response
- Declares disaster state
- Coordinates all recovery activities
- Makes critical decisions
- Communicates with stakeholders
- Authorizes escalation

#### 2. Technical Lead
- Leads technical recovery efforts
- Coordinates technical team
- Reviews recovery procedures
- Makes technical decisions
- Reports status to Incident Commander

#### 3. Database Administrator
- Executes database recovery procedures
- Validates data integrity
- Performs backup/restore operations
- Monitors database health
- Documents all database actions

#### 4. Systems Administrator
- Manages infrastructure recovery
- Handles server/network issues
- Coordinates with cloud providers
- Monitors system resources
- Executes infrastructure changes

#### 5. Security Lead
- Assesses security implications
- Investigates security incidents
- Implements security measures
- Reviews access controls
- Coordinates with security teams

#### 6. Communications Lead
- Internal communications
- External communications (if needed)
- Status updates to stakeholders
- Documentation of timeline
- Post-incident communication

---

## Disaster Scenarios and Response Procedures

### Scenario 1: Complete Data Center Failure

**Symptoms:**
- Total loss of connectivity to primary data center
- All nodes in data center unreachable
- Network timeout errors
- Monitoring alerts for entire DC

**Immediate Response (0-5 minutes):**

1. **Declare Disaster**
   ```bash
   # Incident Commander declares disaster state
   echo "DISASTER DECLARED: DC1 Complete Failure" | tee -a /var/log/dr/incident.log
   ```

2. **Notify Team**
   - Alert all DR team members
   - Activate incident command structure
   - Open emergency communication channel

3. **Assess Impact**
   ```bash
   # Check cluster status
   patronictl list

   # Verify data center connectivity
   ping dc1-gateway
   curl -I https://dc1-api.example.com/health
   ```

**Recovery Actions (5-15 minutes):**

4. **Execute Emergency Failover**
   ```bash
   # Failover to secondary DC
   cd /path/to/scripts/dr
   ./dr-drill-runner.sh --scenario datacenter-failure

   # Or manual failover
   ./failover-drill.sh --automated --target postgres-dc2-1
   ```

5. **Redirect Application Traffic**
   ```bash
   # Update DNS records
   # Update load balancer configuration
   # Update application connection strings
   ```

6. **Verify Recovery**
   ```bash
   # Test database connectivity
   psql -h postgres-dc2-1 -U app_user -c "SELECT 1;"

   # Check replication status
   psql -h postgres-dc2-1 -U postgres -c "SELECT * FROM pg_stat_replication;"

   # Verify application functionality
   curl -I https://app.example.com/health
   ```

**Validation (15-30 minutes):**

7. **Data Integrity Check**
   ```bash
   # Run data consistency checks
   ./validate-data-consistency.sh

   # Compare record counts
   psql -h postgres-dc2-1 -U postgres -c "
   SELECT
       schemaname,
       tablename,
       n_tup_ins,
       n_tup_upd,
       n_tup_del
   FROM pg_stat_user_tables
   ORDER BY schemaname, tablename;
   "
   ```

8. **Performance Validation**
   ```bash
   # Run performance tests
   pgbench -h postgres-dc2-1 -U postgres -c 10 -t 100
   ```

9. **Document Recovery**
   - Record recovery timeline
   - Document any data loss
   - Note any issues encountered
   - Prepare incident report

**Communication Template:**

```
INCIDENT UPDATE: Data Center Failure

Status: [RECOVERING/RECOVERED]
Impact: [description]
Current State: Cluster running in DC2
Data Loss: [estimate]
Expected Full Recovery: [time]

Actions Taken:
- Emergency failover executed at [time]
- Traffic redirected to DC2
- [additional actions]

Next Steps:
- [action items]
```

---

### Scenario 2: Database Corruption

**Symptoms:**
- Database crashes with corruption errors
- Checksum failures
- Inconsistent query results
- Unable to start database

**Immediate Response (0-5 minutes):**

1. **Isolate Corrupted Node**
   ```bash
   # Stop the corrupted node
   systemctl stop postgresql

   # Remove from cluster
   patronictl pause
   ```

2. **Assess Corruption Extent**
   ```bash
   # Check PostgreSQL logs
   tail -n 1000 /var/log/postgresql/postgresql.log | grep -i corrupt

   # Run corruption check
   pg_checksums -D /var/lib/postgresql/data -c
   ```

3. **Determine Recovery Strategy**
   - If single block: Attempt repair
   - If extensive: Full restore required
   - Check backup availability

**Recovery Actions (5-30 minutes):**

4. **Execute Point-in-Time Recovery**
   ```bash
   # Restore from backup
   cd /path/to/scripts/dr
   ./restore-drill.sh --pitr --time "before corruption"
   ```

5. **Alternative: Replication from Standby**
   ```bash
   # If standby is clean, rebuild from standby
   pg_basebackup -h standby-node -D /var/lib/postgresql/data -U replicator -P
   ```

6. **Verify Data Integrity**
   ```bash
   # Run data validation
   psql -U postgres << EOF
   -- Check for logical inconsistencies
   SELECT * FROM pg_stat_database WHERE datname = 'production';

   -- Verify key tables
   SELECT COUNT(*) FROM critical_table;
   EOF
   ```

**Validation:**

7. **Run Integrity Checks**
   ```bash
   # Full database consistency check
   vacuumdb --all --analyze --verbose

   # Check indexes
   reindexdb --all
   ```

**Prevention Measures:**
- Enable checksums: `initdb --data-checksums`
- Regular integrity checks
- Monitoring for I/O errors
- Hardware health monitoring

---

### Scenario 3: Ransomware Attack

**Symptoms:**
- Encrypted files on database servers
- Ransom notes in directories
- Unusual file modifications
- Locked accounts

**CRITICAL: DO NOT PAY RANSOM**

**Immediate Response (0-5 minutes):**

1. **Isolate Infected Systems**
   ```bash
   # Disconnect from network
   iptables -A INPUT -j DROP
   iptables -A OUTPUT -j DROP

   # Stop database
   systemctl stop postgresql

   # Kill all connections
   kill -9 $(pgrep postgres)
   ```

2. **Notify Security Team**
   - Contact security lead
   - Contact law enforcement (if required)
   - Contact legal team
   - Do NOT delete any evidence

3. **Assess Infection Scope**
   ```bash
   # Check for encryption
   find /var/lib/postgresql -name "*.encrypted" -o -name "*.locked"

   # Check running processes
   ps aux | grep -i ransom

   # Check network connections
   netstat -antp
   ```

**Recovery Actions (30-60 minutes):**

4. **Verify Backup Integrity**
   ```bash
   # Check backups are clean
   ./verify-backup-integrity.sh

   # Test backup restoration on isolated system
   ```

5. **Clean Restore from Backup**
   ```bash
   # Restore to isolated environment
   cd /path/to/scripts/dr
   ./restore-drill.sh --clean-restore --verify
   ```

6. **Malware Scanning**
   ```bash
   # Scan restored data
   clamscan -r /var/lib/postgresql/restore_test

   # Additional security scanning
   # Use enterprise security tools
   ```

7. **Rebuild Infrastructure**
   - Deploy fresh OS images
   - Reinstall PostgreSQL from trusted sources
   - Restore data to clean systems
   - Update all passwords and keys

**Security Measures:**

8. **Post-Recovery Hardening**
   ```bash
   # Update all credentials
   # Rotate encryption keys
   # Review access logs
   # Implement additional monitoring
   # Apply security patches
   ```

**Communication Template:**

```
SECURITY INCIDENT: Ransomware Attack

Status: [CONTAINED/RECOVERING]
Impact: [description]
Current State: Systems isolated, clean restore in progress
Data Loss: [estimate based on backup age]
Expected Recovery: [time]

Actions Taken:
- Infected systems isolated at [time]
- Security team notified
- Clean restore initiated
- [additional actions]

Security Measures:
- All credentials being rotated
- Enhanced monitoring deployed
- [additional measures]

Next Steps:
- Complete restore and validation
- Forensic analysis
- Implement additional security controls
```

---

### Scenario 4: Network Partition (Split-Brain)

**Symptoms:**
- Network connectivity loss between DCs
- Multiple leaders reported
- Inconsistent data between sites
- Quorum loss warnings

**Immediate Response (0-5 minutes):**

1. **Verify Partition**
   ```bash
   # Check network connectivity
   ping other-dc-node

   # Check Patroni cluster status
   patronictl list

   # Check for multiple leaders
   for node in node1 node2 node3; do
       ssh $node "patronictl list | grep Leader"
   done
   ```

2. **Assess Quorum Status**
   ```bash
   # Check DCS (etcd/consul) status
   etcdctl member list
   etcdctl endpoint health
   ```

**Recovery Actions (5-15 minutes):**

3. **Prevent Split-Brain**
   ```bash
   # If split-brain detected, fence minority partition
   # Stop PostgreSQL on minority side
   ssh minority-node "systemctl stop postgresql"
   ```

4. **Wait for Partition Healing**
   ```bash
   # Monitor network recovery
   while ! ping -c 1 other-dc-node; do
       sleep 5
       echo "Waiting for network recovery..."
   done
   ```

5. **Verify Cluster Convergence**
   ```bash
   # Check Patroni reconverges
   patronictl list

   # Verify single leader
   # Verify replication resumed
   ```

**Validation:**

6. **Data Consistency Check**
   ```bash
   # Compare checksums across nodes
   for node in node1 node2 node3; do
       echo "Node: $node"
       ssh $node "psql -U postgres -t -c \"
           SELECT md5(string_agg(oid::text, ',' ORDER BY oid))
           FROM pg_class WHERE relkind = 'r';
       \""
   done
   ```

---

### Scenario 5: Hardware Failure Cascade

**Symptoms:**
- Multiple hardware failures in sequence
- Disk failures
- Memory errors
- Network interface failures
- Power issues

**Response Procedure:**

1. **Triage Failures**
   ```bash
   # Check system logs
   dmesg | tail -n 100

   # Check hardware health
   smartctl -H /dev/sda
   ipmitool sensor list
   ```

2. **Prioritize Recovery**
   - Identify critical nodes
   - Determine fastest recovery path
   - Allocate resources

3. **Execute Parallel Recovery**
   ```bash
   # Replace failed hardware
   # Rebuild nodes from standby
   # Restore from backup if necessary
   ```

4. **Maintain Cluster Quorum**
   ```bash
   # Ensure quorum maintained during recovery
   patronictl list

   # Add temporary nodes if needed
   ```

---

## Recovery Checklists

### Pre-Recovery Checklist

- [ ] Disaster declared by authorized personnel
- [ ] Incident command structure activated
- [ ] All team members notified
- [ ] Communication channels established
- [ ] Impact assessment completed
- [ ] Recovery strategy selected
- [ ] Backup availability verified
- [ ] Required resources identified
- [ ] Change authorization obtained (if needed)

### During Recovery Checklist

- [ ] All actions documented with timestamps
- [ ] Regular status updates provided
- [ ] Metrics being monitored and recorded
- [ ] Team members coordinated
- [ ] Escalation process ready
- [ ] Rollback plan identified
- [ ] Validation procedures prepared

### Post-Recovery Checklist

- [ ] All services restored
- [ ] Data integrity verified
- [ ] Performance validated
- [ ] Replication confirmed
- [ ] Backups resumed
- [ ] Monitoring restored
- [ ] Alerts acknowledged
- [ ] Team members notified of completion
- [ ] Incident timeline documented
- [ ] Lessons learned session scheduled

---

## Escalation Procedures

### Escalation Levels

#### Level 1: Standard DR Response
- **Trigger**: Planned failover, single node failure
- **Response**: DR team handles
- **Notification**: Technical team only

#### Level 2: Emergency DR Response
- **Trigger**: Data center failure, significant data loss
- **Response**: Full DR team + management
- **Notification**: Technical + management

#### Level 3: Critical Incident
- **Trigger**: Security breach, cascading failures, extended outage
- **Response**: Full incident response + executive team
- **Notification**: All stakeholders + legal

### Escalation Decision Matrix

| Criteria | Level 1 | Level 2 | Level 3 |
|----------|---------|---------|---------|
| Expected RTO | < 15 min | < 30 min | > 30 min |
| Data Loss | None | < RPO | > RPO |
| Impact | Single system | Multiple systems | Business critical |
| Security | No | Possible | Confirmed |

### Escalation Process

1. **Assess situation against criteria**
2. **Incident Commander makes escalation decision**
3. **Notify next level per contact list**
4. **Brief escalated personnel**
5. **Transfer command if appropriate**
6. **Continue recovery under new command structure**

---

## Communication Templates

### Initial Incident Notification

```
SUBJECT: [SEVERITY] DR Incident Declared - [Brief Description]

Classification: [P1-Critical/P2-Major/P3-Minor]
Start Time: [timestamp]
Status: [Investigating/Responding/Recovering]

Impact:
- Systems Affected: [list]
- User Impact: [description]
- Data Impact: [description]

Actions:
- [action 1]
- [action 2]

Current Response:
- Incident Commander: [name]
- Technical Lead: [name]
- Team Status: [Assembled/Responding]

Next Update: [time]
```

### Status Update Template

```
SUBJECT: DR Update #[N] - [Brief Description]

Status: [Investigating/Responding/Recovering/Resolved]
Time Elapsed: [duration]

Progress:
- [progress point 1]
- [progress point 2]

Challenges:
- [challenge 1 and mitigation]

Metrics:
- RTO Progress: [current/target]
- Data Loss: [estimate]
- Services Online: [count]

Next Steps:
- [action 1] - ETA [time]
- [action 2] - ETA [time]

Next Update: [time]
```

### Recovery Complete Template

```
SUBJECT: DR Recovery Complete - [Brief Description]

Incident Closed: [timestamp]
Total Duration: [duration]

Final Status:
- All services restored
- RTO Achieved: [actual vs target]
- RPO Achieved: [actual vs target]
- Data Loss: [none/description]

Recovery Summary:
- [summary of actions taken]

Validation Complete:
- ✓ Data integrity verified
- ✓ Performance validated
- ✓ Replication confirmed
- ✓ Backups operational

Next Steps:
- Post-mortem scheduled: [date/time]
- Incident report: [due date]

Thank you to the DR team for their rapid response.
```

---

## Post-Incident Activities

### Post-Mortem Meeting

**Timing**: Within 48 hours of incident resolution

**Attendees**:
- Incident Commander
- All DR team members
- Management representatives
- Any relevant stakeholders

**Agenda**:
1. Incident timeline review
2. What went well
3. What could be improved
4. Root cause analysis
5. Action items identification
6. Procedure updates needed

### Post-Mortem Template

```markdown
# Post-Mortem Report: [Incident Description]

## Incident Summary

**Date**: [date]
**Duration**: [duration]
**Severity**: [P1/P2/P3]
**Systems Affected**: [list]

## Timeline

[Detailed timeline with timestamps]

## Root Cause Analysis

### Primary Cause
[Description]

### Contributing Factors
- [Factor 1]
- [Factor 2]

## Impact Analysis

### User Impact
[Description and metrics]

### Data Impact
[Description and metrics]

### Business Impact
[Description and metrics]

## Response Analysis

### What Went Well
- [Item 1]
- [Item 2]

### What Could Be Improved
- [Item 1]
- [Item 2]

### Lessons Learned
- [Lesson 1]
- [Lesson 2]

## Action Items

| Action | Owner | Due Date | Priority |
|--------|-------|----------|----------|
| [Action 1] | [Owner] | [Date] | [P1/P2/P3] |
| [Action 2] | [Owner] | [Date] | [P1/P2/P3] |

## Procedure Updates

[List any procedure changes needed]

## Training Needs

[List any training gaps identified]

## Sign-Off

**Reviewed By**: [Name, Title]
**Date**: [Date]
```

---

## Documentation Requirements

### During Incident

**Required Documentation**:
1. Timeline of all actions (automated logging)
2. Decision points and rationale
3. Commands executed
4. Metrics captured
5. Issues encountered

**Tools**:
- Incident log file: `/var/log/dr/incident_[timestamp].log`
- Automated drill logs: `/var/log/dr-drills/`
- Manual notes: Shared incident document

### Post-Incident

**Required Reports**:
1. Incident summary
2. Full timeline
3. Post-mortem document
4. Action item tracking
5. Procedure updates

**Retention**:
- All incident documentation: 7 years
- Logs: 1 year
- Post-mortems: Permanent

---

## Training and Drills

### Required Training

**All DR Team Members**:
- DR procedures overview
- Communication protocols
- Tool usage
- Escalation procedures

**Role-Specific Training**:
- Incident Commander: Command structure, decision making
- Technical roles: Technical procedures, tools
- Communications: Templates, stakeholder management

### Drill Schedule

See `DR_DRILL_SCHEDULE.md` for detailed schedule.

**Quarterly Drills**:
- Q1: Database corruption + restoration
- Q2: Data center failure + failover
- Q3: Security incident + clean restore
- Q4: Network partition + convergence

---

## Appendices

### Appendix A: Tool Reference

#### DR Scripts Location
```
/path/to/scripts/dr/
├── dr-drill-runner.sh      # Main drill orchestrator
├── failover-drill.sh       # Failover testing
└── restore-drill.sh        # Restore testing
```

#### Key Commands
```bash
# Check cluster status
patronictl list

# Manual failover
patronictl failover --candidate <node> --force

# Restore from backup
pgbackrest restore --stanza=main

# Verify data integrity
vacuumdb --all --analyze
```

### Appendix B: Runbooks

See individual runbooks for detailed procedures:
- `runbooks/failover.md`
- `runbooks/restore.md`
- `runbooks/security-incident.md`

### Appendix C: Configuration Files

Key configuration files:
- `/etc/patroni/patroni.yml` - Patroni configuration
- `/etc/pgbackrest/pgbackrest.conf` - Backup configuration
- `.claude-flow/config.yaml` - Automation configuration

---

## Document Control

**Version**: 1.0
**Last Updated**: 2026-02-12
**Next Review**: 2026-05-12
**Owner**: DR Coordinator
**Approver**: Technical Lead

**Revision History**:

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-02-12 | DR Team | Initial version |

---

**This is a living document. Update after each incident and drill.**
