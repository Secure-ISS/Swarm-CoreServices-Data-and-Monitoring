# High Availability Testing Suite

Comprehensive automated testing for Patroni-based PostgreSQL HA cluster.

## Test Suites

### 1. Failover Testing (`test_patroni_failover.py`)
Tests automatic failover scenarios:
- Primary node failure simulation
- Automatic standby promotion
- Data consistency validation
- Failover timing measurement (<30s target)
- Split-brain prevention
- Failed node rejoin

**Run failover tests:**
```bash
pytest tests/ha/test_patroni_failover.py -v
```

### 2. Replication Testing (`test_replication.py`)
Tests streaming replication:
- Replication health and status
- Replication lag monitoring
- Synchronous vs asynchronous modes
- Data integrity across nodes
- WAL archiving
- Bulk data replication

**Run replication tests:**
```bash
pytest tests/ha/test_replication.py -v
```

### 3. Consensus Testing (`test_etcd_consensus.py`)
Tests etcd consensus mechanisms:
- Cluster health verification
- Leader election
- Network partition handling
- Quorum requirements
- Data consistency after partition
- Consensus under load

**Run consensus tests:**
```bash
pytest tests/ha/test_etcd_consensus.py -v
```

### 4. Integration Testing (`test_ha_integration.py`)
End-to-end HA scenarios:
- Complete HA workflow validation
- Load testing during failover
- RuVector operations during failover
- Parallel load distribution
- Recovery time measurement
- Data integrity after multiple failovers

**Run integration tests:**
```bash
pytest tests/ha/test_ha_integration.py -v
```

## Chaos Testing

The chaos testing script (`scripts/patroni/chaos-test.sh`) simulates various failure scenarios:

### Available Scenarios
- **Random node failure**: Stop/start random nodes
- **Primary failure**: Simulate primary node crash
- **Network partition**: Isolate nodes from cluster
- **Network delay**: Add latency between nodes
- **Cascading failures**: Multiple simultaneous failures
- **etcd failure**: Consensus layer disruption
- **Sustained load**: Operations during failures

### Running Chaos Tests

**Full chaos test suite (5 minutes):**
```bash
./scripts/patroni/chaos-test.sh run
```

**Specific scenarios:**
```bash
# Primary failover test
./scripts/patroni/chaos-test.sh primary-failure

# Network partition test
./scripts/patroni/chaos-test.sh network-partition

# Cascading failures
./scripts/patroni/chaos-test.sh cascading

# Sustained load test
./scripts/patroni/chaos-test.sh sustained-load

# Health check only
./scripts/patroni/chaos-test.sh health
```

**View logs:**
```bash
tail -f logs/chaos-tests/chaos_test_<timestamp>.log
```

## Prerequisites

### Docker Setup
Ensure all containers are running:
```bash
# Patroni nodes
docker ps | grep patroni-node

# etcd nodes
docker ps | grep etcd-node
```

### Python Dependencies
```bash
pip install pytest psycopg2-binary requests numpy
```

### Database Setup
```bash
# Create test tables (run from primary)
psql -U postgres -d postgres -c "
CREATE TABLE IF NOT EXISTS ha_test_transactions (
    id SERIAL PRIMARY KEY,
    transaction_id VARCHAR(100) UNIQUE,
    data TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);
"
```

## Test Configuration

Edit `tests/ha/conftest.py` to configure:
- Node hostnames and ports
- Timeout values
- Replication lag thresholds

## Running All Tests

**Run complete test suite:**
```bash
pytest tests/ha/ -v --tb=short
```

**Run with coverage:**
```bash
pytest tests/ha/ -v --cov=. --cov-report=html
```

**Run only fast tests:**
```bash
pytest tests/ha/ -v -m "not slow"
```

**Run only non-destructive tests:**
```bash
pytest tests/ha/ -v -m "not destructive"
```

## Success Criteria

### Failover Tests
- ✓ Failover time < 30 seconds
- ✓ Zero data loss in synchronous mode
- ✓ Automatic standby promotion
- ✓ Failed node rejoins as standby
- ✓ No split-brain scenarios

### Replication Tests
- ✓ Replication lag < 5 seconds
- ✓ Data consistency across all nodes
- ✓ Successful bulk replication
- ✓ WAL level configured correctly

### Consensus Tests
- ✓ Single leader at all times
- ✓ Quorum maintained (majority)
- ✓ Leader election < 30 seconds
- ✓ Data consistency after partition
- ✓ All nodes agree on leader

### Integration Tests
- ✓ End-to-end workflow successful
- ✓ 90%+ success rate under load
- ✓ RuVector operations functional
- ✓ Recovery time < 30 seconds
- ✓ Data integrity after multiple failovers

## Troubleshooting

### Connection Failures
```bash
# Check node connectivity
for port in 5432 5433 5434; do
    psql -h localhost -p $port -U postgres -c "SELECT 1"
done
```

### Replication Issues
```bash
# Check replication status
psql -U postgres -c "SELECT * FROM pg_stat_replication;"
```

### etcd Issues
```bash
# Check etcd health
curl http://localhost:2379/health
curl http://localhost:2381/health
curl http://localhost:2383/health
```

### Container Issues
```bash
# Restart all containers
docker restart patroni-node-1 patroni-node-2 patroni-node-3
docker restart etcd-node-1 etcd-node-2 etcd-node-3
```

## CI/CD Integration

Add to your CI pipeline:
```yaml
- name: Run HA Tests
  run: |
    pytest tests/ha/ -v --junitxml=test-results.xml

- name: Run Chaos Tests
  run: |
    ./scripts/patroni/chaos-test.sh run
```

## Performance Benchmarks

Expected performance metrics:
- Failover time: 10-20 seconds (target: <30s)
- Replication lag: 0.5-2 seconds (target: <5s)
- Leader election: 5-10 seconds (target: <30s)
- Transaction throughput: 1000+ TPS during normal operation
- Success rate during failover: >95%

## Additional Resources

- [Patroni Documentation](https://patroni.readthedocs.io/)
- [PostgreSQL Replication](https://www.postgresql.org/docs/current/high-availability.html)
- [etcd Documentation](https://etcd.io/docs/)
- [Project HA Design](../../docs/architecture/DETAILED_DESIGN.md)
