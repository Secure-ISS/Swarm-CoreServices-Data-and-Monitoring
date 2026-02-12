#!/bin/bash
# Integration Test Runner Script
# Runs integration tests with appropriate markers and configuration

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Distributed PostgreSQL Integration Tests${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if pytest is installed
if ! command -v pytest &> /dev/null; then
    echo -e "${RED}Error: pytest not found. Install with: pip install pytest${NC}"
    exit 1
fi

# Check required environment variables
check_env_var() {
    if [ -z "${!1}" ]; then
        echo -e "${YELLOW}Warning: $1 not set. Using default.${NC}"
        return 1
    fi
    return 0
}

echo "Checking environment configuration..."
check_env_var "RUVECTOR_HOST" || export RUVECTOR_HOST=localhost
check_env_var "RUVECTOR_PORT" || export RUVECTOR_PORT=5432
check_env_var "RUVECTOR_DB" || export RUVECTOR_DB=distributed_postgres_cluster
check_env_var "RUVECTOR_USER" || export RUVECTOR_USER=dpg_cluster
check_env_var "RUVECTOR_PASSWORD" || export RUVECTOR_PASSWORD=dpg_cluster_2026
check_env_var "REDIS_HOST" || export REDIS_HOST=localhost
check_env_var "REDIS_PORT" || export REDIS_PORT=6379

echo ""
echo "Configuration:"
echo "  Database: $RUVECTOR_USER@$RUVECTOR_HOST:$RUVECTOR_PORT/$RUVECTOR_DB"
echo "  Redis: $REDIS_HOST:$REDIS_PORT"
echo "  Patroni: ${ENABLE_PATRONI:-false}"
echo "  Citus: ${ENABLE_CITUS:-false}"
echo ""

# Parse command line arguments
TEST_SUITE="${1:-all}"
PYTEST_ARGS="${@:2}"

case "$TEST_SUITE" in
    all)
        echo -e "${GREEN}Running ALL integration tests...${NC}"
        pytest tests/integration/ -v ${PYTEST_ARGS}
        ;;

    basic|cluster)
        echo -e "${GREEN}Running distributed cluster tests...${NC}"
        pytest tests/integration/test_distributed_cluster.py -v ${PYTEST_ARGS}
        ;;

    citus|sharding)
        echo -e "${GREEN}Running Citus sharding tests...${NC}"
        if [ "${ENABLE_CITUS}" != "true" ]; then
            echo -e "${YELLOW}Warning: ENABLE_CITUS not set to 'true'${NC}"
            echo "Set: export ENABLE_CITUS=true"
        fi
        pytest tests/integration/test_citus_sharding.py -v -m citus ${PYTEST_ARGS}
        ;;

    ha|patroni|failover)
        echo -e "${GREEN}Running HA failover tests...${NC}"
        if [ "${ENABLE_PATRONI}" != "true" ]; then
            echo -e "${YELLOW}Warning: ENABLE_PATRONI not set to 'true'${NC}"
            echo "Set: export ENABLE_PATRONI=true"
        fi
        pytest tests/integration/test_ha_failover.py -v -m patroni ${PYTEST_ARGS}
        ;;

    cache|redis)
        echo -e "${GREEN}Running cache coherence tests...${NC}"
        pytest tests/integration/test_cache_coherence.py -v -m redis ${PYTEST_ARGS}
        ;;

    fast)
        echo -e "${GREEN}Running fast tests only (excluding slow tests)...${NC}"
        pytest tests/integration/ -v -m "not slow" ${PYTEST_ARGS}
        ;;

    slow|performance)
        echo -e "${GREEN}Running performance tests...${NC}"
        pytest tests/integration/ -v -m slow ${PYTEST_ARGS}
        ;;

    coverage)
        echo -e "${GREEN}Running tests with coverage report...${NC}"
        pytest tests/integration/ -v \
            --cov=src \
            --cov-report=html \
            --cov-report=term-missing \
            --cov-report=json \
            ${PYTEST_ARGS}
        echo ""
        echo -e "${GREEN}Coverage report generated in htmlcov/index.html${NC}"
        ;;

    help|--help|-h)
        echo "Usage: $0 [test_suite] [pytest_args]"
        echo ""
        echo "Test Suites:"
        echo "  all              - Run all integration tests (default)"
        echo "  basic|cluster    - Distributed cluster tests"
        echo "  citus|sharding   - Citus sharding tests (requires ENABLE_CITUS=true)"
        echo "  ha|patroni       - HA failover tests (requires ENABLE_PATRONI=true)"
        echo "  cache|redis      - Redis cache tests"
        echo "  fast             - Fast tests only (exclude slow tests)"
        echo "  slow|performance - Performance tests only"
        echo "  coverage         - Run with coverage report"
        echo ""
        echo "Examples:"
        echo "  $0 all                    # Run all tests"
        echo "  $0 basic                  # Run basic cluster tests"
        echo "  $0 cache --tb=short       # Run cache tests with short traceback"
        echo "  $0 coverage -n 4          # Run with coverage using 4 parallel workers"
        echo ""
        echo "Pytest Arguments:"
        echo "  Pass any pytest arguments after the test suite"
        echo "  Examples: --tb=short, -x (stop on first failure), -n 4 (parallel)"
        exit 0
        ;;

    *)
        echo -e "${RED}Error: Unknown test suite '$TEST_SUITE'${NC}"
        echo "Run '$0 help' for usage information"
        exit 1
        ;;
esac

EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}All tests passed! ✓${NC}"
    echo -e "${GREEN}========================================${NC}"
else
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}Some tests failed! ✗${NC}"
    echo -e "${RED}========================================${NC}"
fi

exit $EXIT_CODE
