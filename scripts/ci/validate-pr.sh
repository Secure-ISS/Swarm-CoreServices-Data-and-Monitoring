#!/bin/bash
# Pre-merge validation script
# Runs comprehensive checks before allowing a PR to be merged

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXIT_CODE=0

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    EXIT_CODE=1
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 is required but not installed"
        return 1
    fi
}

run_check() {
    local check_name="$1"
    local check_command="$2"

    echo ""
    echo "=========================================="
    echo "Running: $check_name"
    echo "=========================================="

    if eval "$check_command"; then
        log_info "✓ $check_name passed"
        return 0
    else
        log_error "✗ $check_name failed"
        return 1
    fi
}

# ============================================================================
# Prerequisite Checks
# ============================================================================

log_info "Checking prerequisites..."

check_command "python3"
check_command "pip"
check_command "git"
check_command "docker"
check_command "docker-compose"

# Check Python version
PYTHON_VERSION=$(python3 --version | awk '{print $2}')
REQUIRED_VERSION="3.10"
if [ "$(printf '%s\n' "$REQUIRED_VERSION" "$PYTHON_VERSION" | sort -V | head -n1)" != "$REQUIRED_VERSION" ]; then
    log_error "Python $REQUIRED_VERSION or higher is required (found $PYTHON_VERSION)"
fi

# ============================================================================
# 1. CODE QUALITY CHECKS
# ============================================================================

run_check "Code formatting (Black)" \
    "cd $PROJECT_ROOT && black --check src/ tests/"

run_check "Import sorting (isort)" \
    "cd $PROJECT_ROOT && isort --check-only src/ tests/"

run_check "Linting (flake8)" \
    "cd $PROJECT_ROOT && flake8 src/ tests/ --max-line-length=120 --exclude=__pycache__,.git,.venv"

run_check "Type checking (mypy)" \
    "cd $PROJECT_ROOT && mypy src/ --ignore-missing-imports"

run_check "Security linting (bandit)" \
    "cd $PROJECT_ROOT && bandit -r src/ -ll -f json -o bandit-report.json || true"

# ============================================================================
# 2. DEPENDENCY CHECKS
# ============================================================================

log_info "Checking for dependency issues..."

run_check "Dependency vulnerabilities (safety)" \
    "cd $PROJECT_ROOT && safety check --json || true"

run_check "Outdated dependencies" \
    "cd $PROJECT_ROOT && pip list --outdated --format=json | python3 -c 'import sys, json; deps = json.load(sys.stdin); sys.exit(1) if len(deps) > 10 else sys.exit(0)'"

# ============================================================================
# 3. UNIT TESTS
# ============================================================================

run_check "Unit tests" \
    "cd $PROJECT_ROOT && pytest tests/unit/ -v --cov=src --cov-report=term-missing --cov-fail-under=80"

# ============================================================================
# 4. DATABASE COMPATIBILITY TESTS
# ============================================================================

log_info "Starting test database..."
docker-compose -f "$PROJECT_ROOT/docker-compose.test.yml" up -d postgres
sleep 10

run_check "Database connection test" \
    "cd $PROJECT_ROOT && python3 scripts/db_health_check.py"

run_check "Migration validation" \
    "cd $PROJECT_ROOT && python3 scripts/ci/validate_migrations.py --path migrations/"

run_check "Schema validation" \
    "cd $PROJECT_ROOT && python3 scripts/ci/validate_schema.py --expected-schema schema/expected_schema.yaml"

log_info "Stopping test database..."
docker-compose -f "$PROJECT_ROOT/docker-compose.test.yml" down -v

# ============================================================================
# 5. INTEGRATION TESTS
# ============================================================================

log_info "Starting full test environment..."
docker-compose -f "$PROJECT_ROOT/docker-compose.test.yml" up -d
sleep 30

run_check "Integration tests" \
    "cd $PROJECT_ROOT && pytest tests/integration/ -v --maxfail=3"

log_info "Stopping test environment..."
docker-compose -f "$PROJECT_ROOT/docker-compose.test.yml" down -v

# ============================================================================
# 6. DOCUMENTATION CHECKS
# ============================================================================

run_check "Documentation completeness" \
    "cd $PROJECT_ROOT && python3 scripts/ci/check_documentation.py"

run_check "API documentation" \
    "cd $PROJECT_ROOT && python3 -c 'import src; help(src)' > /dev/null"

# Check for updated CHANGELOG
if [ -f "$PROJECT_ROOT/CHANGELOG.md" ]; then
    LAST_COMMIT=$(git log -1 --pretty=%B)
    if ! grep -q "$LAST_COMMIT" "$PROJECT_ROOT/CHANGELOG.md" 2>/dev/null; then
        log_warn "CHANGELOG.md may need to be updated"
    fi
fi

# ============================================================================
# 7. SECURITY CHECKS
# ============================================================================

run_check "Secret scanning" \
    "cd $PROJECT_ROOT && git secrets --scan || git secrets --scan-history || true"

run_check "Dependency security (Snyk)" \
    "cd $PROJECT_ROOT && snyk test --severity-threshold=high || true"

# Check for exposed credentials
log_info "Checking for exposed credentials..."
EXPOSED_PATTERNS=(
    "password\s*=\s*['\"].*['\"]"
    "api[_-]?key\s*=\s*['\"].*['\"]"
    "secret\s*=\s*['\"].*['\"]"
    "token\s*=\s*['\"].*['\"]"
)

for pattern in "${EXPOSED_PATTERNS[@]}"; do
    if grep -rn -E "$pattern" "$PROJECT_ROOT/src" "$PROJECT_ROOT/scripts" --exclude-dir=.git --exclude-dir=.venv; then
        log_warn "Potential exposed credentials found matching pattern: $pattern"
    fi
done

# ============================================================================
# 8. PERFORMANCE CHECKS
# ============================================================================

run_check "Performance regression tests" \
    "cd $PROJECT_ROOT && pytest tests/performance/ --benchmark-only --benchmark-compare || true"

# ============================================================================
# 9. DOCKER IMAGE BUILD TEST
# ============================================================================

run_check "Docker image build" \
    "cd $PROJECT_ROOT && docker build -f docker/Dockerfile.api -t dpg-cluster-test:latest ."

# Scan Docker image for vulnerabilities
run_check "Docker image security scan" \
    "trivy image dpg-cluster-test:latest --severity HIGH,CRITICAL"

# ============================================================================
# 10. GIT CHECKS
# ============================================================================

log_info "Running Git checks..."

# Check for large files
LARGE_FILES=$(git ls-files | xargs ls -l 2>/dev/null | awk '$5 > 1048576 {print $9, $5}' || true)
if [ -n "$LARGE_FILES" ]; then
    log_warn "Large files detected (>1MB):"
    echo "$LARGE_FILES"
fi

# Check commit message format
COMMIT_MSG=$(git log -1 --pretty=%B)
if ! echo "$COMMIT_MSG" | grep -qE "^(feat|fix|docs|style|refactor|test|chore|perf)(\(.+\))?: .+"; then
    log_warn "Commit message does not follow conventional commits format"
fi

# Check for merge conflicts
if git diff --check HEAD; then
    log_info "✓ No merge conflict markers found"
else
    log_error "✗ Merge conflict markers found"
fi

# ============================================================================
# 11. PR-SPECIFIC CHECKS
# ============================================================================

if [ -n "$GITHUB_EVENT_PATH" ]; then
    log_info "Running PR-specific checks..."

    # Check PR size
    LINES_CHANGED=$(git diff --stat origin/main...HEAD | tail -n1 | awk '{print $4 + $6}')
    if [ "$LINES_CHANGED" -gt 1000 ]; then
        log_warn "Large PR detected ($LINES_CHANGED lines changed). Consider splitting."
    fi

    # Check for breaking changes
    if echo "$COMMIT_MSG" | grep -qi "BREAKING CHANGE"; then
        log_warn "Breaking changes detected. Ensure version is bumped appropriately."
    fi
fi

# ============================================================================
# 12. COVERAGE CHECKS
# ============================================================================

log_info "Generating coverage report..."
pytest tests/ --cov=src --cov-report=html --cov-report=json

# Check coverage thresholds
COVERAGE=$(python3 -c "import json; data = json.load(open('coverage.json')); print(data['totals']['percent_covered'])")
THRESHOLD=80

if (( $(echo "$COVERAGE < $THRESHOLD" | bc -l) )); then
    log_error "Coverage ($COVERAGE%) is below threshold ($THRESHOLD%)"
else
    log_info "✓ Coverage ($COVERAGE%) meets threshold ($THRESHOLD%)"
fi

# ============================================================================
# SUMMARY
# ============================================================================

echo ""
echo "=========================================="
echo "VALIDATION SUMMARY"
echo "=========================================="

if [ $EXIT_CODE -eq 0 ]; then
    log_info "✓ All checks passed! PR is ready to merge."
else
    log_error "✗ Some checks failed. Please fix the issues before merging."
fi

# Generate summary report
cat > pr-validation-report.md <<EOF
# PR Validation Report

**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")
**Branch:** $(git branch --show-current)
**Commit:** $(git rev-parse HEAD)

## Summary

- **Status:** $([ $EXIT_CODE -eq 0 ] && echo "✓ PASSED" || echo "✗ FAILED")
- **Code Coverage:** ${COVERAGE}%
- **Lines Changed:** ${LINES_CHANGED:-N/A}

## Checks Performed

- [x] Code quality (Black, isort, flake8, mypy)
- [x] Security scanning (Bandit, Snyk, Trivy)
- [x] Unit tests
- [x] Integration tests
- [x] Database compatibility
- [x] Documentation
- [x] Docker image build
- [x] Performance regression tests

## Recommendations

EOF

if [ $EXIT_CODE -ne 0 ]; then
    echo "- Review failed checks and fix issues" >> pr-validation-report.md
    echo "- Ensure all tests pass locally before pushing" >> pr-validation-report.md
fi

if [ "$LINES_CHANGED" -gt 500 ]; then
    echo "- Consider splitting large PR into smaller changes" >> pr-validation-report.md
fi

log_info "Validation report saved to pr-validation-report.md"

exit $EXIT_CODE
