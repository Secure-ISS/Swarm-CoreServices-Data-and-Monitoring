#!/bin/bash
# Patroni Replication Configuration Script
# Version: 1.0.0
# Description: Configure streaming replication and synchronous replication

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
PATRONI_PRIMARY=${PATRONI_PRIMARY:-patroni-node-1}
CLUSTER_NAME=${CLUSTER_NAME:-postgres-ha-cluster}
LOG_FILE="${LOG_FILE:-/var/log/patroni/replication-config.log}"

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "${BLUE}$*${NC}"; }
log_success() { log "SUCCESS" "${GREEN}$*${NC}"; }
log_warning() { log "WARNING" "${YELLOW}$*${NC}"; }
log_error() { log "ERROR" "${RED}$*${NC}"; }

# Get cluster topology
get_cluster_topology() {
    log_info "Getting cluster topology..."

    docker exec "$PATRONI_PRIMARY" patronictl -c /etc/patroni/patroni.yml list | tee -a "$LOG_FILE"
}

# Configure replication slots
configure_replication_slots() {
    log_info "Configuring replication slots..."

    # Get list of standby nodes
    local standbys=$(docker exec "$PATRONI_PRIMARY" patronictl -c /etc/patroni/patroni.yml list | grep -v Leader | grep -v "+" | awk '{print $2}')

    for standby in $standbys; do
        log_info "Creating replication slot for $standby..."

        docker exec "$PATRONI_PRIMARY" psql -U postgres <<EOF
SELECT pg_create_physical_replication_slot('${standby}_slot', true, false);
EOF

        if [ $? -eq 0 ]; then
            log_success "Replication slot created for $standby"
        else
            log_warning "Replication slot may already exist for $standby"
        fi
    done
}

# Enable synchronous replication
enable_synchronous_replication() {
    log_info "Enabling synchronous replication..."

    # Get number of standby nodes
    local standby_count=$(docker exec "$PATRONI_PRIMARY" patronictl -c /etc/patroni/patroni.yml list | grep -v Leader | grep -v "+" | wc -l)

    if [ $standby_count -eq 0 ]; then
        log_error "No standby nodes found"
        return 1
    fi

    # Configure synchronous_standby_names
    log_info "Configuring synchronous_standby_names for $standby_count standbys..."

    docker exec "$PATRONI_PRIMARY" psql -U postgres <<EOF
ALTER SYSTEM SET synchronous_standby_names TO 'ANY 1 (*)';
SELECT pg_reload_conf();
EOF

    log_success "Synchronous replication enabled"
}

# Verify replication status
verify_replication_status() {
    log_info "Verifying replication status..."

    log_info "Checking pg_stat_replication..."
    docker exec "$PATRONI_PRIMARY" psql -U postgres -c "
        SELECT
            application_name,
            client_addr,
            state,
            sync_state,
            replay_lag,
            write_lag,
            flush_lag
        FROM pg_stat_replication;
    " | tee -a "$LOG_FILE"

    log_info "Checking replication slots..."
    docker exec "$PATRONI_PRIMARY" psql -U postgres -c "
        SELECT
            slot_name,
            slot_type,
            active,
            restart_lsn,
            confirmed_flush_lsn
        FROM pg_replication_slots;
    " | tee -a "$LOG_FILE"
}

# Configure replication monitoring
configure_monitoring() {
    log_info "Configuring replication monitoring..."

    docker exec "$PATRONI_PRIMARY" psql -U postgres <<EOF
-- Create monitoring function
CREATE OR REPLACE FUNCTION check_replication_lag()
RETURNS TABLE (
    application_name TEXT,
    client_addr INET,
    state TEXT,
    sync_state TEXT,
    replay_lag_bytes BIGINT,
    replay_lag_seconds NUMERIC
) AS \$\$
BEGIN
    RETURN QUERY
    SELECT
        r.application_name::TEXT,
        r.client_addr,
        r.state::TEXT,
        r.sync_state::TEXT,
        pg_wal_lsn_diff(pg_current_wal_lsn(), r.replay_lsn) AS replay_lag_bytes,
        EXTRACT(EPOCH FROM (now() - r.replay_lag))::NUMERIC AS replay_lag_seconds
    FROM pg_stat_replication r;
END;
\$\$ LANGUAGE plpgsql;

-- Create alert view for high lag
CREATE OR REPLACE VIEW replication_lag_alerts AS
SELECT
    application_name,
    client_addr,
    state,
    sync_state,
    replay_lag_bytes,
    replay_lag_seconds,
    CASE
        WHEN replay_lag_bytes > 104857600 THEN 'CRITICAL'  -- 100MB
        WHEN replay_lag_bytes > 52428800 THEN 'WARNING'    -- 50MB
        ELSE 'OK'
    END AS lag_status
FROM check_replication_lag();
EOF

    log_success "Replication monitoring configured"
}

# Test failover readiness
test_failover_readiness() {
    log_info "Testing failover readiness..."

    # Check if standbys are in sync
    docker exec "$PATRONI_PRIMARY" psql -U postgres -c "
        SELECT
            application_name,
            sync_state,
            replay_lag,
            CASE
                WHEN sync_state IN ('sync', 'potential') AND replay_lag < interval '10 seconds'
                THEN 'READY'
                ELSE 'NOT_READY'
            END AS failover_ready
        FROM pg_stat_replication;
    " | tee -a "$LOG_FILE"
}

# Configure WAL archiving
configure_wal_archiving() {
    log_info "Configuring WAL archiving..."

    docker exec "$PATRONI_PRIMARY" psql -U postgres <<EOF
ALTER SYSTEM SET archive_mode TO 'on';
ALTER SYSTEM SET archive_command TO 'test ! -f /var/lib/postgresql/wal_archive/%f && cp %p /var/lib/postgresql/wal_archive/%f';
SELECT pg_reload_conf();
EOF

    # Create archive directory on all nodes
    for node in $(docker exec "$PATRONI_PRIMARY" patronictl -c /etc/patroni/patroni.yml list | grep -v "+" | awk 'NR>1 {print $2}'); do
        log_info "Creating WAL archive directory on $node..."
        docker exec "$node" mkdir -p /var/lib/postgresql/wal_archive
        docker exec "$node" chown postgres:postgres /var/lib/postgresql/wal_archive
    done

    log_success "WAL archiving configured"
}

# Print configuration summary
print_summary() {
    log_info "Replication Configuration Summary"
    log_info "================================="

    echo -e "\nCluster Topology:" | tee -a "$LOG_FILE"
    get_cluster_topology

    echo -e "\nReplication Status:" | tee -a "$LOG_FILE"
    verify_replication_status

    echo -e "\nFailover Readiness:" | tee -a "$LOG_FILE"
    test_failover_readiness

    log_success "Configuration complete!"
}

# Main execution
main() {
    log_info "Starting replication configuration..."

    get_cluster_topology
    configure_replication_slots
    enable_synchronous_replication
    configure_monitoring
    configure_wal_archiving
    verify_replication_status
    test_failover_readiness
    print_summary

    log_success "Replication configuration completed successfully!"
}

main "$@"
