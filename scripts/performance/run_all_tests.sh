#!/bin/bash
# Run All Performance Tests
#
# Usage:
#   ./run_all_tests.sh [quick|full|stress]
#
# Modes:
#   quick  - Quick smoke test (5 min)
#   full   - Full benchmark suite (30 min)
#   stress - Stress test with high load (60 min)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$SCRIPT_DIR/../.."
REPORTS_DIR="$PROJECT_ROOT/reports"

# Create reports directory
mkdir -p "$REPORTS_DIR"

# Parse mode
MODE="${1:-full}"

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}  Performance Test Suite - Mode: ${MODE}${NC}"
echo -e "${BLUE}======================================================${NC}"
echo ""

# Check dependencies
echo -e "${YELLOW}📦 Checking dependencies...${NC}"
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}✗ Python 3 not found${NC}"
    exit 1
fi

if ! python3 -c "import asyncpg" 2>/dev/null; then
    echo -e "${YELLOW}⚠ Installing Python dependencies...${NC}"
    pip install -r "$SCRIPT_DIR/requirements.txt"
fi

echo -e "${GREEN}✓ Dependencies OK${NC}"
echo ""

# Function to run benchmark
run_benchmark() {
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  1. Running Benchmark Suite${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""

    cd "$PROJECT_ROOT"
    python3 scripts/performance/benchmark_vector_search.py

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Benchmark completed${NC}"
        echo -e "   Results: $REPORTS_DIR/benchmark_results.json"
    else
        echo -e "${RED}✗ Benchmark failed${NC}"
        return 1
    fi
    echo ""
}

# Function to run load test
run_load_test() {
    local users=$1
    local duration=$2

    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  2. Running Load Test${NC}"
    echo -e "${BLUE}     Users: ${users}, Duration: ${duration}${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""

    # Check if locust is installed
    if ! command -v locust &> /dev/null; then
        echo -e "${YELLOW}⚠ Installing locust...${NC}"
        pip install locust
    fi

    cd "$PROJECT_ROOT"
    locust -f scripts/performance/load_test_locust.py \
        --host http://localhost:5432 \
        --users "$users" \
        --spawn-rate $((users / 10)) \
        --run-time "$duration" \
        --headless \
        --html "$REPORTS_DIR/load_test_results.html" \
        --csv "$REPORTS_DIR/load_test"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Load test completed${NC}"
        echo -e "   Report: $REPORTS_DIR/load_test_results.html"
        echo -e "   CSV: $REPORTS_DIR/load_test_*.csv"
    else
        echo -e "${RED}✗ Load test failed${NC}"
        return 1
    fi
    echo ""
}

# Function to check metrics
check_metrics() {
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  3. Checking Metrics Collector${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""

    # Check if metrics collector is running
    if pgrep -f "metrics_collector.py" > /dev/null; then
        echo -e "${GREEN}✓ Metrics collector is running${NC}"
        echo -e "   Metrics: http://localhost:9090/metrics"
    else
        echo -e "${YELLOW}⚠ Metrics collector not running${NC}"
        echo -e "   Start with: python3 scripts/performance/metrics_collector.py &"
    fi
    echo ""
}

# Function to generate summary
generate_summary() {
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  Test Summary${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""

    # Check if benchmark results exist
    if [ -f "$REPORTS_DIR/benchmark_results.json" ]; then
        echo -e "${GREEN}📊 Benchmark Results:${NC}"
        python3 -c "
import json
with open('$REPORTS_DIR/benchmark_results.json') as f:
    data = json.load(f)
    for result in data['results']:
        print(f\"  {result['operation']}:\")
        if 'p95_ms' in result:
            print(f\"    p95: {result['p95_ms']:.2f} ms\")
        if 'qps' in result:
            print(f\"    QPS: {result['qps']:.0f}\")
        if 'throughput_tps' in result:
            print(f\"    TPS: {result['throughput_tps']:.0f}\")
        print()
"
    fi

    # Check if load test results exist
    if [ -f "$REPORTS_DIR/load_test_stats.csv" ]; then
        echo -e "${GREEN}🔥 Load Test Results:${NC}"
        echo "  See: $REPORTS_DIR/load_test_results.html"
        echo ""
    fi

    echo -e "${GREEN}✓ All reports saved to: $REPORTS_DIR${NC}"
    echo ""
}

# Run tests based on mode
case "$MODE" in
    quick)
        echo -e "${YELLOW}Running quick smoke test (5 min)...${NC}"
        echo ""
        check_metrics
        run_load_test 50 "2m"
        ;;

    full)
        echo -e "${YELLOW}Running full test suite (30 min)...${NC}"
        echo ""
        run_benchmark
        check_metrics
        run_load_test 100 "5m"
        generate_summary
        ;;

    stress)
        echo -e "${YELLOW}Running stress test (60 min)...${NC}"
        echo ""
        run_benchmark
        check_metrics
        echo -e "${BLUE}Running multiple load test phases...${NC}"
        echo ""

        # Phase 1: Baseline
        echo -e "${YELLOW}Phase 1: Baseline (50 users, 5 min)${NC}"
        run_load_test 50 "5m"

        # Phase 2: Normal load
        echo -e "${YELLOW}Phase 2: Normal load (100 users, 10 min)${NC}"
        run_load_test 100 "10m"

        # Phase 3: Peak load
        echo -e "${YELLOW}Phase 3: Peak load (300 users, 10 min)${NC}"
        run_load_test 300 "10m"

        # Phase 4: Stress test
        echo -e "${YELLOW}Phase 4: Stress test (500 users, 15 min)${NC}"
        run_load_test 500 "15m"

        generate_summary
        ;;

    *)
        echo -e "${RED}Unknown mode: $MODE${NC}"
        echo "Usage: $0 [quick|full|stress]"
        exit 1
        ;;
esac

echo -e "${BLUE}======================================================${NC}"
echo -e "${GREEN}  Performance tests completed!${NC}"
echo -e "${BLUE}======================================================${NC}"
echo ""
echo -e "Next steps:"
echo -e "  1. Review results in: ${REPORTS_DIR}"
echo -e "  2. Import Grafana dashboard: scripts/performance/grafana_dashboard.json"
echo -e "  3. Configure alerts: scripts/performance/prometheus_alerts.yml"
echo ""
