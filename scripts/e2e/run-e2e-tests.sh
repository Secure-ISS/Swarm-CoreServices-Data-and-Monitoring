#!/usr/bin/env bash
# Run End-to-End Test Suite for Distributed PostgreSQL Cluster
#
# This script orchestrates the complete E2E test suite including:
# - Environment setup
# - Test execution
# - Report generation
# - Cleanup

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Configuration
E2E_LOG_DIR="/tmp/dpg_e2e_logs"
E2E_REPORT_PATH="/tmp/dpg_e2e_report.html"
E2E_SCREENSHOTS_DIR="/tmp/dpg_e2e_screenshots"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Test configuration
export ENABLE_PATRONI="${ENABLE_PATRONI:-false}"
export RUN_FAILOVER_TESTS="${RUN_FAILOVER_TESTS:-true}"
export RUN_SCALING_TESTS="${RUN_SCALING_TESTS:-true}"
export RUN_BACKUP_TESTS="${RUN_BACKUP_TESTS:-true}"
export RUN_PERFORMANCE_TESTS="${RUN_PERFORMANCE_TESTS:-true}"
export RUN_SECURITY_TESTS="${RUN_SECURITY_TESTS:-true}"

# Cleanup on exit
cleanup() {
    local exit_code=$?

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Cleanup${NC}"
    echo -e "${BLUE}========================================${NC}"

    # Archive logs
    if [ -d "$E2E_LOG_DIR" ]; then
        local log_archive="/tmp/dpg_e2e_logs_${TIMESTAMP}.tar.gz"
        tar -czf "$log_archive" -C "$E2E_LOG_DIR" . 2>/dev/null || true
        echo -e "${GREEN}✓${NC} Logs archived to $log_archive"
    fi

    # Stop services if requested
    if [ "${CLEANUP_SERVICES:-true}" = "true" ]; then
        echo "Stopping services..."
        "$PROJECT_ROOT/scripts/dev/stop-dev-stack.sh" 2>/dev/null || true
    fi

    exit $exit_code
}

trap cleanup EXIT INT TERM

# Functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $*"
}

log_info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO:${NC} $*"
}

check_prerequisites() {
    log "Checking prerequisites..."

    local missing=0

    # Check Python
    if ! command -v python3 &> /dev/null; then
        log_error "Python 3 is not installed"
        missing=1
    else
        log "✓ Python 3: $(python3 --version)"
    fi

    # Check pytest
    if ! python3 -c "import pytest" 2>/dev/null; then
        log_error "pytest is not installed"
        log_info "Install with: pip install pytest pytest-asyncio psutil"
        missing=1
    else
        log "✓ pytest installed"
    fi

    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        missing=1
    else
        log "✓ Docker: $(docker --version)"
    fi

    # Check required Python packages
    for pkg in psycopg2 redis; do
        if ! python3 -c "import $pkg" 2>/dev/null; then
            log_warn "$pkg not installed (some tests may be skipped)"
        else
            log "✓ Python package: $pkg"
        fi
    done

    # Check .env file
    if [ ! -f "$PROJECT_ROOT/.env" ]; then
        log_error ".env file not found at $PROJECT_ROOT/.env"
        missing=1
    else
        log "✓ .env file found"
    fi

    if [ $missing -eq 1 ]; then
        log_error "Prerequisites check failed"
        exit 1
    fi

    log "All prerequisites satisfied"
}

setup_environment() {
    log "Setting up test environment..."

    # Create directories
    mkdir -p "$E2E_LOG_DIR"
    mkdir -p "$E2E_SCREENSHOTS_DIR"

    # Load environment
    if [ -f "$PROJECT_ROOT/.env" ]; then
        set -a
        # shellcheck disable=SC1091
        source "$PROJECT_ROOT/.env"
        set +a
        log "✓ Environment loaded from .env"
    fi

    # Set Python path
    export PYTHONPATH="$PROJECT_ROOT:${PYTHONPATH:-}"

    log "Environment setup complete"
}

start_services() {
    log "Starting distributed cluster services..."

    # Check if services are already running
    if docker ps --filter "name=dpg-" --format "{{.Names}}" | grep -q "dpg-"; then
        log_warn "Services already running, skipping startup"
        return 0
    fi

    # Start dev stack
    if [ -f "$PROJECT_ROOT/scripts/dev/start-dev-stack.sh" ]; then
        "$PROJECT_ROOT/scripts/dev/start-dev-stack.sh" 2>&1 | tee "$E2E_LOG_DIR/startup.log"

        # Wait for services to be healthy
        log "Waiting for services to become healthy..."
        local max_wait=120
        local waited=0

        while [ $waited -lt $max_wait ]; do
            if python3 "$PROJECT_ROOT/scripts/db_health_check.py" &> /dev/null; then
                log "✓ All services healthy"
                return 0
            fi
            sleep 5
            waited=$((waited + 5))
            echo -n "."
        done

        log_error "Services did not become healthy within ${max_wait}s"
        return 1
    else
        log_error "start-dev-stack.sh not found"
        return 1
    fi
}

run_test_suite() {
    local suite=$1
    local description=$2

    log_info "Running $description..."

    local test_markers=""

    case $suite in
        "deployment")
            test_markers="-k TestCompleteDeployment"
            ;;
        "data_flow")
            test_markers="-k TestDataFlow"
            ;;
        "failover")
            if [ "$RUN_FAILOVER_TESTS" != "true" ]; then
                log_warn "Skipping failover tests (RUN_FAILOVER_TESTS=false)"
                return 0
            fi
            test_markers="-k TestFailover"
            ;;
        "scaling")
            if [ "$RUN_SCALING_TESTS" != "true" ]; then
                log_warn "Skipping scaling tests (RUN_SCALING_TESTS=false)"
                return 0
            fi
            test_markers="-k TestScaling"
            ;;
        "backup")
            if [ "$RUN_BACKUP_TESTS" != "true" ]; then
                log_warn "Skipping backup tests (RUN_BACKUP_TESTS=false)"
                return 0
            fi
            test_markers="-k TestBackupRestore"
            ;;
        "performance")
            if [ "$RUN_PERFORMANCE_TESTS" != "true" ]; then
                log_warn "Skipping performance tests (RUN_PERFORMANCE_TESTS=false)"
                return 0
            fi
            test_markers="-k TestPerformanceRegression"
            ;;
        "security")
            if [ "$RUN_SECURITY_TESTS" != "true" ]; then
                log_warn "Skipping security tests (RUN_SECURITY_TESTS=false)"
                return 0
            fi
            test_markers="-k TestSecurity"
            ;;
        "all")
            test_markers=""
            ;;
        *)
            log_error "Unknown test suite: $suite"
            return 1
            ;;
    esac

    # Run pytest
    python3 -m pytest \
        "$PROJECT_ROOT/tests/e2e/test_full_stack.py" \
        $test_markers \
        -v \
        --tb=short \
        --color=yes \
        --maxfail=5 \
        2>&1 | tee "$E2E_LOG_DIR/${suite}_tests.log"

    local exit_code=${PIPESTATUS[0]}

    if [ $exit_code -eq 0 ]; then
        log "✓ $description completed successfully"
    else
        log_error "$description failed with exit code $exit_code"
    fi

    return $exit_code
}

capture_system_state() {
    local label=$1
    local output_file="$E2E_LOG_DIR/system_state_${label}.log"

    log_info "Capturing system state: $label"

    {
        echo "========================================="
        echo "System State: $label"
        echo "Timestamp: $(date)"
        echo "========================================="
        echo ""

        echo "Docker Containers:"
        docker ps -a --filter "name=dpg-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
        echo ""

        echo "Database Health:"
        python3 "$PROJECT_ROOT/scripts/db_health_check.py" 2>&1 || true
        echo ""

        echo "Disk Usage:"
        df -h | grep -E "(Filesystem|/dev/)" || true
        echo ""

        echo "Memory Usage:"
        free -h || true
        echo ""

        if command -v docker-compose &> /dev/null; then
            echo "Docker Compose Logs (last 50 lines):"
            docker-compose -f "$PROJECT_ROOT/docker-compose.yml" logs --tail=50 2>&1 || true
        fi

    } > "$output_file"

    log "✓ System state captured to $output_file"
}

generate_report() {
    log "Generating comprehensive test report..."

    # HTML report is generated by pytest fixture
    if [ -f "$E2E_REPORT_PATH" ]; then
        log "✓ HTML report generated: $E2E_REPORT_PATH"

        # Copy to project directory
        cp "$E2E_REPORT_PATH" "$PROJECT_ROOT/tests/e2e/last_run_report.html"
        log "✓ Report copied to: $PROJECT_ROOT/tests/e2e/last_run_report.html"
    else
        log_warn "HTML report not found at $E2E_REPORT_PATH"
    fi

    # Generate summary
    local summary_file="$E2E_LOG_DIR/summary.txt"
    {
        echo "========================================="
        echo "E2E Test Summary"
        echo "Timestamp: $(date)"
        echo "========================================="
        echo ""

        echo "Test Results:"
        for log_file in "$E2E_LOG_DIR"/*_tests.log; do
            if [ -f "$log_file" ]; then
                echo ""
                echo "$(basename "$log_file"):"
                grep -E "(PASSED|FAILED|ERROR|passed|failed)" "$log_file" | tail -5 || true
            fi
        done

        echo ""
        echo "Reports:"
        echo "- HTML Report: $E2E_REPORT_PATH"
        echo "- Logs: $E2E_LOG_DIR"
        echo "- Screenshots: $E2E_SCREENSHOTS_DIR"

    } | tee "$summary_file"

    log "✓ Summary saved to $summary_file"
}

display_results() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}E2E Test Results${NC}"
    echo -e "${BLUE}========================================${NC}"

    if [ -f "$E2E_REPORT_PATH" ]; then
        echo -e "${GREEN}✓${NC} HTML Report: file://$E2E_REPORT_PATH"

        # Try to open in browser
        if command -v xdg-open &> /dev/null; then
            xdg-open "$E2E_REPORT_PATH" 2>/dev/null &
        elif command -v open &> /dev/null; then
            open "$E2E_REPORT_PATH" 2>/dev/null &
        fi
    fi

    echo -e "${GREEN}✓${NC} Logs: $E2E_LOG_DIR"
    echo -e "${GREEN}✓${NC} Screenshots: $E2E_SCREENSHOTS_DIR"
    echo ""

    # Display summary from logs
    if [ -f "$E2E_LOG_DIR/summary.txt" ]; then
        cat "$E2E_LOG_DIR/summary.txt"
    fi
}

# Main execution
main() {
    local test_suite="${1:-all}"

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}E2E Test Suite - Distributed PostgreSQL Cluster${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "Test Suite: $test_suite"
    echo "Timestamp: $TIMESTAMP"
    echo ""

    # Check prerequisites
    check_prerequisites

    # Setup environment
    setup_environment

    # Capture initial state
    capture_system_state "before_tests"

    # Start services
    if [ "${SKIP_SERVICE_START:-false}" != "true" ]; then
        start_services || {
            log_error "Failed to start services"
            exit 1
        }
    else
        log_warn "Skipping service startup (SKIP_SERVICE_START=true)"
    fi

    # Run tests
    local test_failed=0

    case $test_suite in
        "all")
            run_test_suite "deployment" "Complete Deployment Tests" || test_failed=1
            run_test_suite "data_flow" "Data Flow Tests" || test_failed=1
            run_test_suite "failover" "Failover Tests" || test_failed=1
            run_test_suite "scaling" "Scaling Tests" || test_failed=1
            run_test_suite "backup" "Backup/Restore Tests" || test_failed=1
            run_test_suite "performance" "Performance Regression Tests" || test_failed=1
            run_test_suite "security" "Security Tests" || test_failed=1
            ;;
        *)
            run_test_suite "$test_suite" "${test_suite} Tests" || test_failed=1
            ;;
    esac

    # Capture final state
    capture_system_state "after_tests"

    # Generate report
    generate_report

    # Display results
    display_results

    if [ $test_failed -eq 0 ]; then
        echo ""
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}All E2E tests passed!${NC}"
        echo -e "${GREEN}========================================${NC}"
        exit 0
    else
        echo ""
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}Some E2E tests failed${NC}"
        echo -e "${RED}========================================${NC}"
        exit 1
    fi
}

# Usage information
usage() {
    cat << EOF
Usage: $0 [TEST_SUITE] [OPTIONS]

Test Suites:
  all                Run all test suites (default)
  deployment         Complete deployment tests
  data_flow          Data flow tests
  failover           Failover tests
  scaling            Scaling tests
  backup             Backup/restore tests
  performance        Performance regression tests
  security           Security tests

Environment Variables:
  ENABLE_PATRONI              Enable Patroni HA mode (default: false)
  RUN_FAILOVER_TESTS          Run failover tests (default: true)
  RUN_SCALING_TESTS           Run scaling tests (default: true)
  RUN_BACKUP_TESTS            Run backup tests (default: true)
  RUN_PERFORMANCE_TESTS       Run performance tests (default: true)
  RUN_SECURITY_TESTS          Run security tests (default: true)
  SKIP_SERVICE_START          Skip service startup (default: false)
  CLEANUP_SERVICES            Cleanup services on exit (default: true)

Examples:
  $0                          # Run all tests
  $0 deployment               # Run only deployment tests
  $0 failover                 # Run only failover tests

  RUN_FAILOVER_TESTS=false $0 # Run all except failover
  ENABLE_PATRONI=true $0      # Run with Patroni HA mode

EOF
}

# Parse arguments
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

# Run main
main "${1:-all}"
