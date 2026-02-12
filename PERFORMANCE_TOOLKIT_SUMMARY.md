# Performance Tuning and Optimization Toolkit - Summary

Complete performance optimization toolkit for the Distributed PostgreSQL Cluster with RuVector.

## Created Files

### Scripts (All Executable)

1. **`/scripts/performance/tune-postgresql.sh`** (13KB)
   - Auto-detect workload patterns (read-heavy, write-heavy, mixed)
   - Calculate optimal PostgreSQL parameters based on system resources
   - Configure memory, WAL, parallel queries, autovacuum
   - Generate detailed tuning reports
   - VACUUM and index optimization commands

2. **`/scripts/performance/analyze-slow-queries.sh`** (13KB)
   - Setup and configure pg_stat_statements extension
   - Identify slowest queries by total time and call frequency
   - Detect queries with high execution variance
   - Find sequential scans and missing indexes
   - Analyze table bloat
   - Generate optimization recommendations
   - Export results to CSV

3. **`/scripts/performance/optimize-ruvector.sh`** (21KB)
   - Analyze HNSW index parameters (m, ef_construction)
   - Benchmark different parameter configurations
   - Profile vector insert and search operations
   - Compare batch vs single insert performance
   - Optimize existing indexes with best parameters
   - Memory usage analysis
   - Detailed recommendations for different scenarios

4. **`/scripts/performance/benchmark-cluster.sh`** (18KB)
   - Comprehensive performance snapshot (8 metrics)
   - Connection, query, vector search, write performance
   - Cache hit ratio and connection pool usage
   - Database size tracking
   - Baseline comparison with regression detection
   - HTML report generation
   - JSON output for automation

### Documentation

5. **`/docs/PERFORMANCE_TUNING.md`** (23KB)
   - Complete performance tuning guide
   - PostgreSQL configuration by workload type
   - RuVector HNSW optimization guide
   - Query optimization techniques
   - Index strategies and best practices
   - Connection pooling configuration
   - Hardware recommendations
   - Capacity planning formulas
   - Monitoring key metrics
   - Common bottlenecks and solutions
   - Performance testing methodologies

6. **`/docs/PERFORMANCE_QUICK_REFERENCE.md`** (8.5KB)
   - One-page quick reference for common tasks
   - Command examples for each tool
   - Performance target table
   - Common fixes for typical issues
   - HNSW parameter reference
   - Useful SQL queries
   - Emergency procedures
   - Workflow diagram

## Quick Start

### Initial Setup (One-Time)

```bash
# 1. Enable slow query tracking
./scripts/performance/analyze-slow-queries.sh setup
docker restart ruvector-db

# 2. Establish performance baseline
./scripts/performance/benchmark-cluster.sh baseline

# 3. Auto-tune PostgreSQL
./scripts/performance/tune-postgresql.sh analyze
docker restart ruvector-db

# 4. Analyze RuVector indexes
./scripts/performance/optimize-ruvector.sh analyze
```

### Weekly Maintenance

```bash
# 1. VACUUM all tables
./scripts/performance/tune-postgresql.sh vacuum

# 2. Check for slow queries
./scripts/performance/analyze-slow-queries.sh report

# 3. Benchmark and compare
./scripts/performance/benchmark-cluster.sh run

# 4. Review index usage
./scripts/performance/tune-postgresql.sh indexes
```

### When Performance Issues Arise

```bash
# 1. Identify slow queries
./scripts/performance/analyze-slow-queries.sh report

# 2. Get index recommendations
./scripts/performance/analyze-slow-queries.sh indexes

# 3. Optimize PostgreSQL configuration
./scripts/performance/tune-postgresql.sh analyze

# 4. Optimize vector operations
./scripts/performance/optimize-ruvector.sh profile

# 5. Benchmark to verify improvements
./scripts/performance/benchmark-cluster.sh run
```

## Features by Script

### tune-postgresql.sh

**Capabilities:**
- System resource detection (RAM, CPU, disk)
- Workload pattern analysis (inserts, updates, deletes, scans)
- Automatic parameter calculation for optimal performance
- Configuration backup before changes
- Support for read-heavy, write-heavy, and mixed workloads

**Optimizes:**
- Memory: shared_buffers, effective_cache_size, work_mem, maintenance_work_mem
- WAL: wal_buffers, checkpoint settings, max_wal_size
- Query planning: random_page_cost, effective_io_concurrency
- Parallel queries: max_parallel_workers, max_worker_processes
- Autovacuum: naptime, scale_factor, max_workers
- Logging: slow queries, checkpoints, locks

**Actions:**
- `analyze [workload]` - Auto-tune parameters
- `vacuum` - Run VACUUM ANALYZE on all tables
- `indexes` - Analyze index usage and suggest optimizations

### analyze-slow-queries.sh

**Capabilities:**
- pg_stat_statements extension setup
- Multi-dimensional slow query analysis
- Index recommendation generation
- Table bloat detection
- CSV export for external tools

**Reports:**
- Top 20 slowest queries by total execution time
- Most frequently called slow queries
- Queries with high execution time variance
- Sequential scans on large tables
- Table bloat percentage
- Query statistics summary
- Actionable recommendations

**Actions:**
- `setup` - Enable pg_stat_statements (requires restart)
- `report` - Generate comprehensive slow query report
- `indexes` - Generate index recommendations
- `reset` - Clear statistics (start fresh)
- `export` - Export to CSV

### optimize-ruvector.sh

**Capabilities:**
- HNSW index parameter analysis
- Comprehensive benchmarking (m, ef_construction)
- Vector operation profiling
- Batch vs single operation comparison
- Index rebuilding with optimal parameters

**Analyzes:**
- Current HNSW indexes and parameters
- Index usage statistics (scans, tuples read)
- Table statistics for vector columns
- Vector insert performance
- Search performance at different settings
- Memory usage

**Actions:**
- `analyze` - Analyze current indexes
- `tune` - Rebuild indexes with optimal parameters
- `benchmark` - Full parameter benchmarking (slow)
- `profile` - Profile vector operations
- `quick` - Quick performance test
- `recommendations` - Show optimization guidelines

### benchmark-cluster.sh

**Capabilities:**
- 8 comprehensive performance metrics
- Baseline management
- Regression detection
- HTML report generation
- JSON output for automation

**Metrics:**
- Connection time (avg)
- Simple query latency
- Index scan performance
- Vector search time
- Write throughput (1000 rows)
- Cache hit ratio
- Connection pool usage
- Database/table/index sizes

**Actions:**
- `run` - Run benchmark and compare with baseline
- `baseline` - Set new performance baseline
- `compare <file>` - Compare specific result with baseline
- `report` - Generate HTML report from latest

## Performance Targets

| Metric | Target | Warning | Critical |
|--------|--------|---------|----------|
| Connection avg | < 10ms | 10-50ms | > 50ms |
| Simple query | < 10ms | 10-50ms | > 50ms |
| Index scan | < 50ms | 50-100ms | > 100ms |
| Vector search | < 50ms | 50-100ms | > 100ms |
| Write 1000 rows | < 500ms | 500-1000ms | > 1000ms |
| Cache hit ratio | > 95% | 90-95% | < 90% |
| Connection usage | < 50% | 50-80% | > 80% |

## HNSW Parameter Guidelines

| Scenario | m | ef_construction | ef_search | Use Case |
|----------|---|-----------------|-----------|----------|
| Development | 16 | 100 | 100 | Fast builds, testing |
| Production | 16 | 200 | 100-200 | Balanced performance |
| High Accuracy | 32 | 200 | 200-400 | Best recall |
| Fast Build | 8 | 50 | 50-100 | Quick prototyping |

## PostgreSQL Configuration Profiles

### Read-Heavy Workload
```sql
shared_buffers = 4GB
effective_cache_size = 12GB
work_mem = 64MB
random_page_cost = 1.1
effective_io_concurrency = 200
default_statistics_target = 500
```

### Write-Heavy Workload
```sql
shared_buffers = 4GB
wal_buffers = 16MB
checkpoint_completion_target = 0.9
max_wal_size = 4GB
random_page_cost = 1.5
```

### Mixed Workload
```sql
shared_buffers = 4GB
effective_cache_size = 10GB
work_mem = 32MB
random_page_cost = 1.3
effective_io_concurrency = 150
```

## Output Locations

| Output | Location |
|--------|----------|
| Benchmark results | `/tmp/benchmarks/benchmark_*.json` |
| Baseline | `/tmp/benchmarks/baseline.json` |
| HTML reports | `/tmp/benchmarks/benchmark_*.html` |
| Tuning reports | `/tmp/postgresql_tuning_report_*.txt` |
| Slow query reports | `/tmp/slow_queries_report_*.txt` |
| Slow query CSV | `/tmp/slow_queries_*.csv` |
| RuVector profiles | `/tmp/ruvector_profile_*.txt` |
| HNSW benchmarks | `/tmp/hnsw_benchmark_*.txt` |

## Common Optimization Scenarios

### Scenario 1: Slow Queries
```bash
# 1. Identify slow queries
./scripts/performance/analyze-slow-queries.sh report

# 2. Check for missing indexes
./scripts/performance/analyze-slow-queries.sh indexes

# 3. Create recommended indexes
# (Follow suggestions from report)

# 4. Update statistics
./scripts/performance/tune-postgresql.sh vacuum

# 5. Verify improvement
./scripts/performance/benchmark-cluster.sh run
```

### Scenario 2: Poor Vector Performance
```bash
# 1. Analyze current HNSW indexes
./scripts/performance/optimize-ruvector.sh analyze

# 2. Profile operations
./scripts/performance/optimize-ruvector.sh profile

# 3. Adjust ef_search at query time
# SET hnsw.ef_search = 200;

# 4. Rebuild indexes if needed
./scripts/performance/optimize-ruvector.sh tune

# 5. Verify improvement
./scripts/performance/benchmark-cluster.sh run
```

### Scenario 3: Memory Issues
```bash
# 1. Auto-tune based on system resources
./scripts/performance/tune-postgresql.sh analyze

# 2. Restart PostgreSQL
docker restart ruvector-db

# 3. Run VACUUM to reclaim space
./scripts/performance/tune-postgresql.sh vacuum

# 4. Monitor cache hit ratio
./scripts/performance/benchmark-cluster.sh run
```

### Scenario 4: Connection Exhaustion
```bash
# 1. Check current usage
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster \
  -c "SELECT count(*) FROM pg_stat_activity;"

# 2. Kill idle connections
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state = 'idle' AND state_change < now() - interval '10 minutes';"

# 3. Increase connection pool or max_connections
# Edit src/db/pool.py or postgresql.conf
```

## Integration with Monitoring

### Cron Jobs
```bash
# Daily VACUUM
0 2 * * * /path/to/scripts/performance/tune-postgresql.sh vacuum

# Weekly slow query report
0 3 * * 0 /path/to/scripts/performance/analyze-slow-queries.sh report

# Daily benchmark
0 4 * * * /path/to/scripts/performance/benchmark-cluster.sh run
```

### Alerting from JSON
```bash
# Example: Alert on low cache hit ratio
CACHE_RATIO=$(jq '.metrics.cache_hit_ratio_percent' /tmp/benchmarks/benchmark_*.json | tail -1)
if (( $(echo "$CACHE_RATIO < 90" | bc -l) )); then
    echo "ALERT: Cache hit ratio is ${CACHE_RATIO}%"
fi
```

## Best Practices

1. **Establish Baseline First**
   - Run `benchmark-cluster.sh baseline` before making changes
   - Use for regression detection

2. **Optimize Incrementally**
   - Make one change at a time
   - Benchmark after each change
   - Keep what works, revert what doesn't

3. **Schedule Regular Maintenance**
   - Weekly VACUUM ANALYZE
   - Weekly slow query review
   - Monthly index optimization

4. **Monitor Key Metrics**
   - Cache hit ratio (target > 95%)
   - Query latency (target < 50ms)
   - Connection usage (target < 50%)

5. **Use Appropriate Tools**
   - Quick issue → Quick reference guide
   - Deep dive → Full tuning guide
   - Automation → JSON output + scripts

## Troubleshooting

### Scripts Not Working
```bash
# Ensure executable
chmod +x /scripts/performance/*.sh

# Check container is running
docker ps | grep ruvector-db

# Check PostgreSQL is accessible
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT 1;"
```

### pg_stat_statements Not Available
```bash
# Run setup
./scripts/performance/analyze-slow-queries.sh setup

# Restart PostgreSQL
docker restart ruvector-db

# Verify extension
docker exec ruvector-db psql -U dpg_cluster -d distributed_postgres_cluster \
  -c "SELECT * FROM pg_extension WHERE extname = 'pg_stat_statements';"
```

### No Baseline Found
```bash
# Create baseline first
./scripts/performance/benchmark-cluster.sh baseline

# Then run benchmarks
./scripts/performance/benchmark-cluster.sh run
```

## Documentation Reference

- **Full Guide**: `/docs/PERFORMANCE_TUNING.md` (23KB)
- **Quick Reference**: `/docs/PERFORMANCE_QUICK_REFERENCE.md` (8.5KB)
- **Scripts README**: `/scripts/performance/README.md`
- **This Summary**: `/PERFORMANCE_TOOLKIT_SUMMARY.md`

## Next Steps

1. Run initial setup:
   ```bash
   ./scripts/performance/analyze-slow-queries.sh setup
   docker restart ruvector-db
   ./scripts/performance/benchmark-cluster.sh baseline
   ```

2. Auto-tune PostgreSQL:
   ```bash
   ./scripts/performance/tune-postgresql.sh analyze
   docker restart ruvector-db
   ```

3. Optimize RuVector:
   ```bash
   ./scripts/performance/optimize-ruvector.sh analyze
   ```

4. Verify improvements:
   ```bash
   ./scripts/performance/benchmark-cluster.sh run
   ```

---

**Created:** 2026-02-12
**Version:** 1.0.0
**Total Files:** 6 (4 scripts + 2 docs)
**Total Size:** ~75KB
