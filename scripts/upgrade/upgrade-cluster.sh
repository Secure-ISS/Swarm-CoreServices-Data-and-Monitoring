#!/bin/bash

###############################################################################
# Distributed PostgreSQL Cluster Rolling Upgrade Script
# Performs zero-downtime rolling upgrades for HA clusters
# Supports: Patroni, Citus, PostgreSQL, and RuVector upgrades
# Usage: ./upgrade-cluster.sh <component> <version>
# Example: ./upgrade-cluster.sh patroni 3.2.0
###############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Parse arguments
if [ $# -ne 2 ]; then
    log_error "Usage: $0 <component> <version>"
    log_error "Components: patroni, citus, postgresql, ruvector, all"
    log_error "Example: $0 patroni 3.2.0"
    exit 1
fi

COMPONENT=$1
TARGET_VERSION=$2
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/var/lib/postgresql/backups/cluster_upgrade_${COMPONENT}_${TARGET_VERSION}_${TIMESTAMP}"
LOGFILE="${BACKUP_DIR}/upgrade.log"

# Configuration
ETCD_ENDPOINTS="${ETCD_ENDPOINTS:-http://localhost:2379,http://localhost:2380,http://localhost:2381}"
PATRONI_NAMESPACE="${PATRONI_NAMESPACE:-/service/postgres-cluster}"
CLUSTER_NAME="${CLUSTER_NAME:-postgres-cluster}"
HEALTH_CHECK_INTERVAL=10
MAX_WAIT_TIME=300

# Create backup directory
mkdir -p "${BACKUP_DIR}"
exec > >(tee -a "${LOGFILE}") 2>&1

log_info "Starting cluster upgrade: ${COMPONENT} to version ${TARGET_VERSION}"
log_info "Timestamp: ${TIMESTAMP}"
log_info "Log file: ${LOGFILE}"

###############################################################################
# Helper functions
###############################################################################

# Get cluster topology from etcd
get_cluster_topology() {
    log_info "Discovering cluster topology..."

    # Get all members
    MEMBERS=$(etcdctl --endpoints="${ETCD_ENDPOINTS}" get "${PATRONI_NAMESPACE}/${CLUSTER_NAME}/members/" --prefix --keys-only | grep -v "^$" || echo "")

    if [ -z "${MEMBERS}" ]; then
        log_error "No cluster members found in etcd"
        exit 1
    fi

    # Get leader
    LEADER=$(etcdctl --endpoints="${ETCD_ENDPOINTS}" get "${PATRONI_NAMESPACE}/${CLUSTER_NAME}/leader" --print-value-only || echo "")

    log_info "Cluster members:"
    echo "${MEMBERS}" | while read -r MEMBER; do
        NODE=$(echo "${MEMBER}" | awk -F'/' '{print $NF}')
        if [ "${NODE}" == "${LEADER}" ]; then
            log_info "  ${NODE} (LEADER)"
        else
            log_info "  ${NODE} (REPLICA)"
        fi
    done

    echo "${MEMBERS}" > "${BACKUP_DIR}/cluster_members.txt"
    echo "${LEADER}" > "${BACKUP_DIR}/cluster_leader.txt"
}

# Check node health
check_node_health() {
    local NODE=$1
    log_info "Checking health of node: ${NODE}"

    # Get node status from Patroni API
    NODE_STATUS=$(curl -s "http://${NODE}:8008/health" || echo "")

    if [ -z "${NODE_STATUS}" ]; then
        log_error "Cannot reach node: ${NODE}"
        return 1
    fi

    echo "${NODE_STATUS}" | jq -r '.state' | grep -q 'running' || return 1
    log_success "Node ${NODE} is healthy"
    return 0
}

# Wait for replication to catch up
wait_for_replication() {
    local NODE=$1
    local MAX_LAG=10485760  # 10MB

    log_info "Waiting for replication to catch up on node: ${NODE}"

    local WAIT_TIME=0
    while [ ${WAIT_TIME} -lt ${MAX_WAIT_TIME} ]; do
        LAG=$(curl -s "http://${NODE}:8008/patroni" | jq -r '.replication[] | select(.application_name != "") | .replay_lag' | head -1 || echo "0")

        if [ "${LAG}" == "null" ] || [ -z "${LAG}" ]; then
            LAG=0
        fi

        if [ "${LAG}" -lt "${MAX_LAG}" ]; then
            log_success "Replication caught up (lag: ${LAG} bytes)"
            return 0
        fi

        log_info "  Replication lag: ${LAG} bytes (max: ${MAX_LAG})"
        sleep ${HEALTH_CHECK_INTERVAL}
        WAIT_TIME=$((WAIT_TIME + HEALTH_CHECK_INTERVAL))
    done

    log_error "Replication did not catch up within ${MAX_WAIT_TIME} seconds"
    return 1
}

# Perform switchover
perform_switchover() {
    local OLD_LEADER=$1
    local NEW_LEADER=$2

    log_info "Performing switchover from ${OLD_LEADER} to ${NEW_LEADER}"

    # Trigger switchover via Patroni API
    SWITCHOVER_RESULT=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "{\"leader\":\"${OLD_LEADER}\",\"candidate\":\"${NEW_LEADER}\"}" \
        "http://${OLD_LEADER}:8008/switchover" || echo "")

    if [ -z "${SWITCHOVER_RESULT}" ]; then
        log_error "Switchover failed"
        return 1
    fi

    log_info "Switchover initiated, waiting for completion..."
    sleep ${HEALTH_CHECK_INTERVAL}

    # Verify new leader
    NEW_LEADER_CHECK=$(etcdctl --endpoints="${ETCD_ENDPOINTS}" get "${PATRONI_NAMESPACE}/${CLUSTER_NAME}/leader" --print-value-only)

    if [ "${NEW_LEADER_CHECK}" == "${NEW_LEADER}" ]; then
        log_success "Switchover completed: ${NEW_LEADER} is now the leader"
        return 0
    else
        log_error "Switchover failed: leader is ${NEW_LEADER_CHECK}"
        return 1
    fi
}

###############################################################################
# Upgrade functions
###############################################################################

upgrade_patroni() {
    local VERSION=$1
    log_info "Upgrading Patroni to version ${VERSION}"

    # Upgrade Patroni on all nodes (rolling)
    while read -r MEMBER; do
        NODE=$(echo "${MEMBER}" | awk -F'/' '{print $NF}')
        log_info "Upgrading Patroni on node: ${NODE}"

        # Check if node is leader
        if [ "${NODE}" == "$(cat ${BACKUP_DIR}/cluster_leader.txt)" ]; then
            log_info "  Node is leader, will upgrade last"
            continue
        fi

        # Stop Patroni
        ssh "${NODE}" "sudo systemctl stop patroni"

        # Upgrade Patroni
        ssh "${NODE}" "pip install --upgrade patroni[etcd]==${VERSION}"

        # Start Patroni
        ssh "${NODE}" "sudo systemctl start patroni"

        # Wait for node to become healthy
        sleep ${HEALTH_CHECK_INTERVAL}
        check_node_health "${NODE}" || {
            log_error "Node ${NODE} did not become healthy after upgrade"
            exit 1
        }

        # Wait for replication to catch up
        wait_for_replication "${NODE}" || {
            log_error "Replication did not catch up on node ${NODE}"
            exit 1
        }

        log_success "Patroni upgraded on node: ${NODE}"
    done < "${BACKUP_DIR}/cluster_members.txt"

    # Now upgrade leader
    LEADER=$(cat "${BACKUP_DIR}/cluster_leader.txt")
    log_info "Upgrading Patroni on leader: ${LEADER}"

    # Find a healthy replica for switchover
    REPLICA=$(grep -v "${LEADER}" "${BACKUP_DIR}/cluster_members.txt" | head -1 | awk -F'/' '{print $NF}')

    # Perform switchover
    perform_switchover "${LEADER}" "${REPLICA}" || {
        log_error "Switchover failed"
        exit 1
    }

    # Upgrade old leader
    ssh "${LEADER}" "sudo systemctl stop patroni"
    ssh "${LEADER}" "pip install --upgrade patroni[etcd]==${VERSION}"
    ssh "${LEADER}" "sudo systemctl start patroni"

    # Wait for old leader to rejoin as replica
    sleep ${HEALTH_CHECK_INTERVAL}
    check_node_health "${LEADER}" || {
        log_error "Old leader ${LEADER} did not rejoin cluster"
        exit 1
    }

    log_success "Patroni upgrade completed on all nodes"
}

upgrade_citus() {
    local VERSION=$1
    log_info "Upgrading Citus to version ${VERSION}"

    # Upgrade Citus extension on coordinator first
    log_info "Upgrading Citus on coordinator..."

    # Get coordinator node
    COORDINATOR=$(psql -h localhost -U postgres -d postgres -At -c "
        SELECT nodename FROM pg_dist_node WHERE noderole = 'primary' AND nodeport = 5432 LIMIT 1
    " || echo "localhost")

    # Upgrade Citus extension
    psql -h "${COORDINATOR}" -U postgres -d postgres -c "
        ALTER EXTENSION citus UPDATE TO '${VERSION}';
    "

    # Upgrade Citus on workers (rolling)
    WORKERS=$(psql -h "${COORDINATOR}" -U postgres -d postgres -At -c "
        SELECT nodename FROM pg_dist_node WHERE noderole = 'secondary'
    ")

    for WORKER in ${WORKERS}; do
        log_info "Upgrading Citus on worker: ${WORKER}"

        # Drain worker (move shards to other workers)
        log_info "  Draining worker..."
        psql -h "${COORDINATOR}" -U postgres -d postgres -c "
            SELECT citus_drain_node('${WORKER}', 5432);
        "

        # Upgrade Citus extension
        psql -h "${WORKER}" -U postgres -d postgres -c "
            ALTER EXTENSION citus UPDATE TO '${VERSION}';
        "

        # Reactivate worker
        log_info "  Reactivating worker..."
        psql -h "${COORDINATOR}" -U postgres -d postgres -c "
            SELECT citus_activate_node('${WORKER}', 5432);
        "

        # Rebalance shards
        log_info "  Rebalancing shards..."
        psql -h "${COORDINATOR}" -U postgres -d postgres -c "
            SELECT citus_rebalance_start();
        "

        log_success "Citus upgraded on worker: ${WORKER}"
    done

    log_success "Citus upgrade completed on all nodes"
}

upgrade_postgresql() {
    local VERSION=$1
    log_info "Upgrading PostgreSQL to version ${VERSION}"

    log_warning "PostgreSQL major version upgrade requires downtime"
    log_warning "Use ./upgrade-postgresql.sh for detailed upgrade procedure"
    log_error "Rolling PostgreSQL upgrade not implemented"
    exit 1
}

upgrade_ruvector() {
    local VERSION=$1
    log_info "Upgrading RuVector to version ${VERSION}"

    # Upgrade RuVector on all nodes (can be done simultaneously)
    while read -r MEMBER; do
        NODE=$(echo "${MEMBER}" | awk -F'/' '{print $NF}')
        log_info "Upgrading RuVector on node: ${NODE}"

        # Run upgrade script on node
        ssh "${NODE}" "
            cd /home/postgres/scripts/upgrade
            ./upgrade-ruvector.sh 0.1.0 ${VERSION}
        "

        log_success "RuVector upgraded on node: ${NODE}"
    done < "${BACKUP_DIR}/cluster_members.txt"

    log_success "RuVector upgrade completed on all nodes"
}

###############################################################################
# Main execution
###############################################################################

log_info "Phase 1: Pre-upgrade checks"

# Discover cluster topology
get_cluster_topology

# Check cluster health
log_info "Checking cluster health..."
while read -r MEMBER; do
    NODE=$(echo "${MEMBER}" | awk -F'/' '{print $NF}')
    check_node_health "${NODE}" || {
        log_error "Cluster is not healthy, aborting upgrade"
        exit 1
    }
done < "${BACKUP_DIR}/cluster_members.txt"

log_success "Cluster is healthy"

# Check replication status
log_info "Checking replication status..."
LEADER=$(cat "${BACKUP_DIR}/cluster_leader.txt")
REPL_STATUS=$(curl -s "http://${LEADER}:8008/patroni" | jq -r '.replication[] | select(.application_name != "") | "\(.application_name): \(.state) (lag: \(.replay_lag))"')
log_info "Replication status:"
echo "${REPL_STATUS}" | while read -r LINE; do
    log_info "  ${LINE}"
done

# Perform upgrade based on component
case "${COMPONENT}" in
    patroni)
        upgrade_patroni "${TARGET_VERSION}"
        ;;
    citus)
        upgrade_citus "${TARGET_VERSION}"
        ;;
    postgresql)
        upgrade_postgresql "${TARGET_VERSION}"
        ;;
    ruvector)
        upgrade_ruvector "${TARGET_VERSION}"
        ;;
    all)
        log_warning "Upgrading all components requires careful coordination"
        log_error "Not implemented yet"
        exit 1
        ;;
    *)
        log_error "Unknown component: ${COMPONENT}"
        log_error "Valid components: patroni, citus, postgresql, ruvector, all"
        exit 1
        ;;
esac

###############################################################################
# Post-upgrade validation
###############################################################################

log_info "Phase 2: Post-upgrade validation"

# Check cluster health again
log_info "Checking cluster health after upgrade..."
while read -r MEMBER; do
    NODE=$(echo "${MEMBER}" | awk -F'/' '{print $NF}')
    check_node_health "${NODE}" || {
        log_error "Cluster is not healthy after upgrade"
        exit 1
    }
done < "${BACKUP_DIR}/cluster_members.txt"

log_success "Cluster is healthy after upgrade"

# Check replication status
log_info "Checking replication status after upgrade..."
LEADER=$(etcdctl --endpoints="${ETCD_ENDPOINTS}" get "${PATRONI_NAMESPACE}/${CLUSTER_NAME}/leader" --print-value-only)
REPL_STATUS=$(curl -s "http://${LEADER}:8008/patroni" | jq -r '.replication[] | select(.application_name != "") | "\(.application_name): \(.state) (lag: \(.replay_lag))"')
log_info "Replication status:"
echo "${REPL_STATUS}" | while read -r LINE; do
    log_info "  ${LINE}"
done

log_success "Cluster upgrade completed successfully!"
log_info "Upgrade log: ${LOGFILE}"

exit 0
