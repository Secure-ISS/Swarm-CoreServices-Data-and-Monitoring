#!/bin/bash
# Quick Production Validation for Patroni HA Cluster
# Distributed PostgreSQL Cluster with RuVector

set +e  # Continue on errors to complete all checks

echo "╔════════════════════════════════════════════════════════════╗"
echo "║         Production Deployment Validation                  ║"
echo "║     Patroni HA Cluster + RuVector                         ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

PASS=0
FAIL=0

# Helper functions
check_pass() {
    echo "✓ PASS: $1"
    ((PASS++))
}

check_fail() {
    echo "✗ FAIL: $1"
    ((FAIL++))
}

# 1. Container Health Check
echo "========================================"
echo "1. Container Health Validation"
echo "========================================"

if docker ps --format "{{.Names}}" | grep -q "^patroni-1$"; then
    check_pass "patroni-1 container running"
else
    check_fail "patroni-1 container not found"
fi

if docker ps --format "{{.Names}}" | grep -q "^patroni-2$"; then
    check_pass "patroni-2 container running"
else
    check_fail "patroni-2 container not found"
fi

if docker ps --format "{{.Names}}" | grep -q "^patroni-3$"; then
    check_pass "patroni-3 container running"
else
    check_fail "patroni-3 container not found"
fi

if docker ps --format "{{.Names}}" | grep -q "^haproxy$"; then
    check_pass "HAProxy container running"
else
    check_fail "HAProxy container not found"
fi

if docker ps --format "{{.Names}}" | grep -q "^etcd-1$"; then
    check_pass "etcd-1 container running"
else
    check_fail "etcd-1 container not found"
fi

if docker ps --format "{{.Names}}" | grep -q "^etcd-2$"; then
    check_pass "etcd-2 container running"
else
    check_fail "etcd-2 container not found"
fi

if docker ps --format "{{.Names}}" | grep -q "^etcd-3$"; then
    check_pass "etcd-3 container running"
else
    check_fail "etcd-3 container not found"
fi

# 2. Cluster Topology Check
echo ""
echo "========================================"
echo "2. Patroni Cluster Topology"
echo "========================================"

CLUSTER_STATUS=$(docker exec patroni-1 patronictl -c /etc/patroni/patroni.yml list 2>&1)
echo "$CLUSTER_STATUS"
echo ""

# Check for leader
if echo "$CLUSTER_STATUS" | grep -q "Leader"; then
    check_pass "Cluster has a leader"
else
    check_fail "No leader found in cluster"
fi

# Check for replicas
REPLICA_COUNT=$(echo "$CLUSTER_STATUS" | grep -c "Replica" || true)
if [ "$REPLICA_COUNT" -ge 2 ]; then
    check_pass "Cluster has $REPLICA_COUNT replicas"
else
    check_fail "Insufficient replicas (found: $REPLICA_COUNT, expected: 2)"
fi

# Check for streaming replication
if echo "$CLUSTER_STATUS" | grep -q "streaming"; then
    check_pass "Replication is streaming"
else
    check_fail "Replication not in streaming state"
fi

# 3. PostgreSQL Connectivity
echo ""
echo "========================================"
echo "3. Database Connectivity"
echo "========================================"

# Test connection to leader
if docker exec patroni-1 psql -U postgres -c "SELECT 1;" &>/dev/null; then
    check_pass "PostgreSQL connection successful on patroni-1"
else
    check_fail "Cannot connect to PostgreSQL on patroni-1"
fi

# Check PostgreSQL version
PG_VERSION=$(docker exec patroni-1 psql -U postgres -t -c "SELECT version();" 2>/dev/null | head -1)
echo "PostgreSQL Version: $PG_VERSION"
if echo "$PG_VERSION" | grep -q "PostgreSQL 17"; then
    check_pass "PostgreSQL 17.x confirmed"
else
    check_fail "PostgreSQL version mismatch"
fi

# 4. Replication Health
echo ""
echo "========================================"
echo "4. Replication Health"
echo "========================================"

# Find current leader
LEADER=$(echo "$CLUSTER_STATUS" | grep "Leader" | awk '{print $2}')
echo "Current Leader: $LEADER"

# Check replication lag
REP_STATUS=$(docker exec "$LEADER" psql -U postgres -t -c "SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;" 2>/dev/null || echo "")
if [ -n "$REP_STATUS" ]; then
    echo "$REP_STATUS"
    REP_COUNT=$(echo "$REP_STATUS" | grep -c "streaming" || true)
    if [ "$REP_COUNT" -ge 2 ]; then
        check_pass "All replicas connected and streaming"
    else
        check_fail "Some replicas not streaming (found: $REP_COUNT)"
    fi
else
    check_fail "Cannot query replication status"
fi

# 5. RuVector Extension
echo ""
echo "========================================"
echo "5. RuVector Extension"
echo "========================================"

RUVECTOR_CHECK=$(docker exec patroni-1 psql -U postgres -t -c "SELECT COUNT(*) FROM pg_available_extensions WHERE name='ruvector';" 2>/dev/null | xargs)
if [ "$RUVECTOR_CHECK" = "1" ]; then
    check_pass "RuVector extension available"
else
    check_fail "RuVector extension not found"
fi

# 6. Port Configuration
echo ""
echo "========================================"
echo "6. Port Configuration"
echo "========================================"

# Check port bindings
if docker ps | grep patroni-1 | grep -q "5435"; then
    check_pass "patroni-1 exposed on port 5435"
else
    check_fail "patroni-1 port not exposed correctly"
fi

if docker ps | grep patroni-2 | grep -q "5433"; then
    check_pass "patroni-2 exposed on port 5433"
else
    check_fail "patroni-2 port not exposed correctly"
fi

if docker ps | grep patroni-3 | grep -q "5434"; then
    check_pass "patroni-3 exposed on port 5434"
else
    check_fail "patroni-3 port not exposed correctly"
fi

if docker ps | grep haproxy | grep -q "5000-5001"; then
    check_pass "HAProxy ports 5000-5001 exposed"
else
    check_fail "HAProxy ports not exposed correctly"
fi

# 7. Development Database (ruvector-db)
echo ""
echo "========================================"
echo "7. Development Database"
echo "========================================"

if docker ps | grep ruvector-db | grep -q "5432"; then
    check_pass "Development database (ruvector-db) running on port 5432"
else
    check_fail "Development database not accessible"
fi

# Final Summary
echo ""
echo "========================================"
echo "VALIDATION SUMMARY"
echo "========================================"
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
TOTAL=$((PASS + FAIL))
SCORE=$(awk "BEGIN {printf \"%.1f\", ($PASS/$TOTAL)*100}")
echo "SCORE: $SCORE%"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo "✓ ALL CHECKS PASSED - PRODUCTION READY"
    exit 0
elif [ "$SCORE" != "${SCORE%.*}" ] && [ "${SCORE%.*}" -ge 90 ]; then
    echo "⚠ MOSTLY READY - $FAIL minor issues detected"
    exit 0
else
    echo "✗ NOT PRODUCTION READY - $FAIL critical issues detected"
    exit 1
fi
