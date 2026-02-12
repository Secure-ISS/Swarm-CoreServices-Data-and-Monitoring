#!/bin/bash
# Comprehensive Load Testing Orchestrator
#
# This script orchestrates all load tests including:
# - Benchmark suite (Python)
# - Stress tests (Bash)
# - Custom scenario tests
# - Report generation

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="$PROJECT_ROOT/tests/load/results/$TIMESTAMP"

# Test configuration (can be overridden)
RUN_BENCHMARK=${RUN_BENCHMARK:-true}
RUN_STRESS=${RUN_STRESS:-true}
RUN_SCENARIOS=${RUN_SCENARIOS:-true}
GENERATE_GRAPHS=${GENERATE_GRAPHS:-false}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

check_environment() {
    log_section "Environment Check"

    # Check .env file
    if [ ! -f "$PROJECT_ROOT/.env" ]; then
        log_error ".env file not found at $PROJECT_ROOT/.env"
        log_info "Create .env with database credentials"
        exit 1
    fi

    # Source environment
    source "$PROJECT_ROOT/.env"

    # Check required variables
    local required_vars=(
        "RUVECTOR_HOST"
        "RUVECTOR_PORT"
        "RUVECTOR_DB"
        "RUVECTOR_USER"
        "RUVECTOR_PASSWORD"
    )

    local missing=()
    for var in "${required_vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            missing+=("$var")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing environment variables: ${missing[*]}"
        exit 1
    fi

    log_info "✓ Environment configured"
    log_info "  Database: $RUVECTOR_DB @ $RUVECTOR_HOST:$RUVECTOR_PORT"
}

check_dependencies() {
    log_section "Dependency Check"

    local missing=()

    # Required commands
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    command -v psql >/dev/null 2>&1 || missing+=("psql (postgresql-client)")
    command -v pgbench >/dev/null 2>&1 || missing+=("pgbench (postgresql-contrib)")

    # Optional commands
    if [ "$GENERATE_GRAPHS" = "true" ]; then
        command -v gnuplot >/dev/null 2>&1 || log_warn "gnuplot not found - graphs will be skipped"
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing dependencies: ${missing[*]}"
        log_info "Install with: sudo apt-get install postgresql-client postgresql-contrib python3"
        exit 1
    fi

    # Check Python packages
    python3 -c "import psycopg2" 2>/dev/null || {
        log_error "Python package 'psycopg2' not found"
        log_info "Install with: pip3 install psycopg2-binary"
        exit 1
    }

    log_info "✓ All dependencies found"
}

check_database() {
    log_section "Database Health Check"

    export PGPASSWORD="$RUVECTOR_PASSWORD"

    if ! psql -h "$RUVECTOR_HOST" -p "$RUVECTOR_PORT" -U "$RUVECTOR_USER" -d "$RUVECTOR_DB" -c "SELECT 1" >/dev/null 2>&1; then
        log_error "Cannot connect to database"
        log_info "Ensure PostgreSQL is running and credentials are correct"
        exit 1
    fi

    log_info "✓ Database connection successful"

    # Check RuVector extension
    if psql -h "$RUVECTOR_HOST" -p "$RUVECTOR_PORT" -U "$RUVECTOR_USER" -d "$RUVECTOR_DB" \
            -t -c "SELECT extversion FROM pg_extension WHERE extname = 'ruvector'" 2>/dev/null | grep -q "."; then
        local version=$(psql -h "$RUVECTOR_HOST" -p "$RUVECTOR_PORT" -U "$RUVECTOR_USER" -d "$RUVECTOR_DB" \
                            -t -c "SELECT extversion FROM pg_extension WHERE extname = 'ruvector'" 2>/dev/null | tr -d ' ')
        log_info "✓ RuVector extension installed (v$version)"
    else
        log_warn "RuVector extension not found - some tests may fail"
    fi

    # Check table existence
    if psql -h "$RUVECTOR_HOST" -p "$RUVECTOR_PORT" -U "$RUVECTOR_USER" -d "$RUVECTOR_DB" \
            -t -c "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'claude_flow' AND table_name = 'embeddings')" \
            2>/dev/null | grep -q "t"; then
        log_info "✓ claude_flow.embeddings table exists"
    else
        log_error "claude_flow.embeddings table not found"
        log_info "Run database initialization scripts first"
        exit 1
    fi
}

prepare_results_directory() {
    log_section "Preparing Results Directory"

    mkdir -p "$RESULTS_DIR"

    # Create subdirectories
    mkdir -p "$RESULTS_DIR/benchmark"
    mkdir -p "$RESULTS_DIR/stress"
    mkdir -p "$RESULTS_DIR/scenarios"
    mkdir -p "$RESULTS_DIR/graphs"

    log_info "✓ Results directory: $RESULTS_DIR"
}

run_benchmark_suite() {
    if [ "$RUN_BENCHMARK" != "true" ]; then
        log_info "Benchmark suite skipped (RUN_BENCHMARK=false)"
        return
    fi

    log_section "Running Benchmark Suite"

    cd "$PROJECT_ROOT"

    log_info "Starting Python benchmark suite..."

    if python3 "$PROJECT_ROOT/tests/load/benchmark_suite.py" 2>&1 | tee "$RESULTS_DIR/benchmark/output.log"; then
        log_info "✓ Benchmark suite completed successfully"

        # Move generated report
        if [ -f "$PROJECT_ROOT/tests/load/benchmark_report.md" ]; then
            mv "$PROJECT_ROOT/tests/load/benchmark_report.md" "$RESULTS_DIR/benchmark/report.md"
            log_info "  Report: $RESULTS_DIR/benchmark/report.md"
        fi
    else
        log_error "Benchmark suite failed - check logs"
    fi
}

run_stress_tests() {
    if [ "$RUN_STRESS" != "true" ]; then
        log_info "Stress tests skipped (RUN_STRESS=false)"
        return
    fi

    log_section "Running Stress Tests"

    log_info "Starting stress test suite..."

    # Override results directory for stress tests
    export RESULTS_DIR="$RESULTS_DIR/stress"
    mkdir -p "$RESULTS_DIR/stress"

    if bash "$PROJECT_ROOT/tests/load/stress_test.sh" 2>&1 | tee "$RESULTS_DIR/stress/output.log"; then
        log_info "✓ Stress tests completed successfully"
    else
        log_warn "Stress tests completed with warnings - check logs"
    fi
}

run_scenario_tests() {
    if [ "$RUN_SCENARIOS" != "true" ]; then
        log_info "Scenario tests skipped (RUN_SCENARIOS=false)"
        return
    fi

    log_section "Running Scenario Tests"

    # Scenario 1: Peak load simulation
    log_info "Scenario 1: Peak Load (100 concurrent connections for 60s)"
    python3 - <<EOF | tee "$RESULTS_DIR/scenarios/peak_load.log"
from tests.load.benchmark_suite import LoadTestRunner
import os

db_config = {
    'host': os.getenv('RUVECTOR_HOST'),
    'port': int(os.getenv('RUVECTOR_PORT')),
    'database': os.getenv('RUVECTOR_DB'),
    'user': os.getenv('RUVECTOR_USER'),
    'password': os.getenv('RUVECTOR_PASSWORD'),
}

runner = LoadTestRunner(db_config)
result = runner.test_mixed_workload(duration_seconds=60, concurrency=100)
print(f"Peak load: {result.ops_per_second:.2f} ops/sec, {result.success_rate:.1f}% success")
EOF

    # Scenario 2: Vector search at scale
    log_info "Scenario 2: Vector Search at Scale (10K searches)"
    python3 - <<EOF | tee "$RESULTS_DIR/scenarios/vector_search_scale.log"
from tests.load.benchmark_suite import LoadTestRunner
import os

db_config = {
    'host': os.getenv('RUVECTOR_HOST'),
    'port': int(os.getenv('RUVECTOR_PORT')),
    'database': os.getenv('RUVECTOR_DB'),
    'user': os.getenv('RUVECTOR_USER'),
    'password': os.getenv('RUVECTOR_PASSWORD'),
}

runner = LoadTestRunner(db_config)
result = runner.test_vector_search_performance(num_searches=10000, top_k=10)
print(f"Vector search: {result.ops_per_second:.2f} ops/sec, P95={result.latency_p95:.2f}ms")
EOF

    # Scenario 3: Write-heavy batch processing
    log_info "Scenario 3: Write-Heavy Batch Processing (1K writes)"
    python3 - <<EOF | tee "$RESULTS_DIR/scenarios/batch_writes.log"
from tests.load.benchmark_suite import LoadTestRunner
import os

db_config = {
    'host': os.getenv('RUVECTOR_HOST'),
    'port': int(os.getenv('RUVECTOR_PORT')),
    'database': os.getenv('RUVECTOR_DB'),
    'user': os.getenv('RUVECTOR_USER'),
    'password': os.getenv('RUVECTOR_PASSWORD'),
}

runner = LoadTestRunner(db_config)
result = runner.test_write_heavy_load(num_operations=1000, concurrency=20)
print(f"Batch writes: {result.ops_per_second:.2f} ops/sec, P95={result.latency_p95:.2f}ms")
EOF

    log_info "✓ Scenario tests completed"
}

generate_summary() {
    log_section "Generating Summary Report"

    local summary="$RESULTS_DIR/SUMMARY.md"

    cat > "$summary" <<EOF
# Load Testing Summary

**Date:** $(date)
**Test Suite:** Distributed PostgreSQL Cluster Load Tests

## Configuration

- **Database:** $RUVECTOR_DB @ $RUVECTOR_HOST:$RUVECTOR_PORT
- **User:** $RUVECTOR_USER

## Test Results

### Benchmark Suite
$([ -f "$RESULTS_DIR/benchmark/report.md" ] && echo "✅ Completed - See: \`benchmark/report.md\`" || echo "⏭️ Skipped")

### Stress Tests
$([ -d "$RESULTS_DIR/stress" ] && echo "✅ Completed - See: \`stress/\`" || echo "⏭️ Skipped")

### Scenario Tests
$([ -d "$RESULTS_DIR/scenarios" ] && echo "✅ Completed - See: \`scenarios/\`" || echo "⏭️ Skipped")

## Quick Stats

EOF

    # Extract key metrics if available
    if [ -f "$RESULTS_DIR/benchmark/report.md" ]; then
        echo "### Benchmark Results" >> "$summary"
        grep "^|" "$RESULTS_DIR/benchmark/report.md" | head -8 >> "$summary"
        echo "" >> "$summary"
    fi

    cat >> "$summary" <<EOF

## Files Generated

\`\`\`
$(find "$RESULTS_DIR" -type f -name "*.log" -o -name "*.md" | sed "s|$RESULTS_DIR/||" | sort)
\`\`\`

## Next Steps

1. Review benchmark results for performance baselines
2. Analyze stress test logs for error patterns
3. Check scenario tests for specific use case performance
4. Compare results with previous runs (if available)

## Performance Baselines

| Metric | Target | Achieved | Status |
|--------|--------|----------|--------|
| Connection Pool | 40+ concurrent | TBD | ⏳ |
| Vector Search P95 | <50ms | TBD | ⏳ |
| Read Throughput | >1000 ops/sec | TBD | ⏳ |
| Write Throughput | >500 ops/sec | TBD | ⏳ |
| Success Rate | >99% | TBD | ⏳ |

EOF

    log_info "✓ Summary report: $summary"

    # Display summary
    cat "$summary"
}

create_baseline_document() {
    log_section "Creating Performance Baseline"

    local baseline="$RESULTS_DIR/PERFORMANCE_BASELINE.md"

    cat > "$baseline" <<EOF
# Performance Baseline Document

**Generated:** $(date -Iseconds)
**Environment:** $RUVECTOR_DB @ $RUVECTOR_HOST:$RUVECTOR_PORT

## Overview

This document establishes performance baselines for the distributed PostgreSQL cluster.
Use these metrics to track performance over time and identify regressions.

## Connection Pool Performance

### Targets
- Maximum concurrent connections: 40 (pool capacity)
- Success rate at capacity: >95%
- Connection acquisition latency P95: <10ms

### Measured Values
- *Run benchmark suite to populate*

## Vector Search Performance

### Targets
- Search latency P50: <20ms
- Search latency P95: <50ms
- Search latency P99: <100ms
- Throughput: >500 searches/sec (10 concurrent)

### Measured Values
- *Run benchmark suite to populate*

## Read Performance

### Targets
- Read latency P95: <10ms
- Read throughput: >1000 ops/sec (20 concurrent)
- Success rate: >99%

### Measured Values
- *Run benchmark suite to populate*

## Write Performance

### Targets
- Write latency P95: <50ms
- Write throughput: >500 ops/sec (10 concurrent)
- Success rate: >99%

### Measured Values
- *Run benchmark suite to populate*

## Mixed Workload

### Targets
- Mixed ops throughput: >800 ops/sec (20 concurrent)
- Success rate: >99%
- 70% reads, 20% writes, 10% searches

### Measured Values
- *Run benchmark suite to populate*

## Stress Test Resilience

### Targets
- Pool exhaustion handling: Graceful degradation at >40 connections
- Rapid connection churn: >100 connections/sec sustained
- Long-running stability: No degradation over 60s sustained load

### Measured Values
- *Run stress tests to populate*

## Bottleneck Analysis

### Potential Bottlenecks
1. **Connection Pool Exhaustion**: Pool size limits concurrent operations
2. **HNSW Index Performance**: Vector search degrades with large datasets
3. **Write Contention**: Lock contention during batch inserts
4. **Network Latency**: Cross-region replication lag

### Mitigation Strategies
1. Increase pool size (maxconn parameter)
2. Optimize HNSW parameters (m, ef_construction)
3. Use batch inserts with COPY for bulk writes
4. Implement connection pooling (PgBouncer)

## Monitoring Recommendations

1. **Connection Pool Metrics**
   - Active connections
   - Idle connections
   - Connection wait time

2. **Query Performance**
   - Query duration P50/P95/P99
   - Slow query log (>100ms)
   - Cache hit ratio

3. **Vector Operations**
   - HNSW index build time
   - Search latency distribution
   - Index size vs performance

4. **Resource Utilization**
   - CPU usage per connection
   - Memory per connection
   - Disk I/O patterns

## Historical Tracking

| Date | Version | Conn Pool | Vector P95 | Read Ops/s | Write Ops/s | Notes |
|------|---------|-----------|------------|------------|-------------|-------|
| $(date +%Y-%m-%d) | 1.0.0 | TBD | TBD | TBD | TBD | Initial baseline |

EOF

    log_info "✓ Performance baseline: $baseline"
}

main() {
    echo "╔════════════════════════════════════════════════════════════════════════╗"
    echo "║     Distributed PostgreSQL Cluster - Load Testing Orchestrator        ║"
    echo "╚════════════════════════════════════════════════════════════════════════╝"
    echo ""

    # Pre-flight checks
    check_environment
    check_dependencies
    check_database
    prepare_results_directory

    # Run test suites
    run_benchmark_suite
    run_stress_tests
    run_scenario_tests

    # Generate reports
    generate_summary
    create_baseline_document

    # Final summary
    log_section "Test Suite Complete"

    echo ""
    echo "╔════════════════════════════════════════════════════════════════════════╗"
    echo "║                       All Tests Complete                               ║"
    echo "╚════════════════════════════════════════════════════════════════════════╝"
    echo ""
    log_info "Results directory: $RESULTS_DIR"
    log_info "Summary report: $RESULTS_DIR/SUMMARY.md"
    log_info "Performance baseline: $RESULTS_DIR/PERFORMANCE_BASELINE.md"
    echo ""
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --benchmark-only)
            RUN_STRESS=false
            RUN_SCENARIOS=false
            shift
            ;;
        --stress-only)
            RUN_BENCHMARK=false
            RUN_SCENARIOS=false
            shift
            ;;
        --scenarios-only)
            RUN_BENCHMARK=false
            RUN_STRESS=false
            shift
            ;;
        --with-graphs)
            GENERATE_GRAPHS=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --benchmark-only    Run only benchmark suite"
            echo "  --stress-only       Run only stress tests"
            echo "  --scenarios-only    Run only scenario tests"
            echo "  --with-graphs       Generate performance graphs (requires gnuplot)"
            echo "  --help              Show this help message"
            echo ""
            echo "Environment Variables:"
            echo "  RUN_BENCHMARK       Enable/disable benchmark suite (default: true)"
            echo "  RUN_STRESS          Enable/disable stress tests (default: true)"
            echo "  RUN_SCENARIOS       Enable/disable scenario tests (default: true)"
            echo "  GENERATE_GRAPHS     Enable/disable graph generation (default: false)"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Run main function
main "$@"
