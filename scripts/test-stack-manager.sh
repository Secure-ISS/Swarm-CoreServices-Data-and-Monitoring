#!/usr/bin/env bash
#
# test-stack-manager.sh
#
# Comprehensive test suite for stack-manager.sh
# Tests all major functionality without actually starting containers
#
# Usage:
#   ./scripts/test-stack-manager.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_MANAGER="$SCRIPT_DIR/stack-manager.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# ============================================================
# Test Functions
# ============================================================

test_start() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "${BLUE}→ Test $TESTS_RUN: $test_name${NC}"
}

test_pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}  ✓ Passed${NC}"
    echo
}

test_fail() {
    local reason="$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}  ✗ Failed: $reason${NC}"
    echo
}

# ============================================================
# Tests
# ============================================================

echo
echo "========================================"
echo "Stack Manager Test Suite"
echo "========================================"
echo

# Test 1: Script exists and is executable
test_start "Script exists and is executable"
if [[ -f "$STACK_MANAGER" ]] && [[ -x "$STACK_MANAGER" ]]; then
    test_pass
else
    test_fail "Script not found or not executable: $STACK_MANAGER"
fi

# Test 2: Help command
test_start "Help command"
if "$STACK_MANAGER" help >/dev/null 2>&1; then
    test_pass
else
    test_fail "Help command failed"
fi

# Test 3: Status command
test_start "Status command"
if "$STACK_MANAGER" status >/dev/null 2>&1; then
    test_pass
else
    test_fail "Status command failed"
fi

# Test 4: Validate compose files exist
test_start "All compose files exist"
COMPOSE_FILES=(
    "$SCRIPT_DIR/../docker-compose.dev.yml"
    "$SCRIPT_DIR/../docker/citus/docker-compose.yml"
    "$SCRIPT_DIR/../docker/patroni/docker-compose.yml"
    "$SCRIPT_DIR/../docker/monitoring/docker-compose.yml"
    "$SCRIPT_DIR/../docker/production/docker-compose.yml"
)

all_exist=true
for file in "${COMPOSE_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        all_exist=false
        echo "  Missing: $file"
    fi
done

if $all_exist; then
    test_pass
else
    test_fail "Some compose files are missing"
fi

# Test 5: Invalid mode handling
test_start "Invalid mode handling"
if ! "$STACK_MANAGER" start invalid-mode 2>/dev/null; then
    test_pass
else
    test_fail "Should reject invalid mode"
fi

# Test 6: Invalid command handling
test_start "Invalid command handling"
if ! "$STACK_MANAGER" invalid-command 2>/dev/null; then
    test_pass
else
    test_fail "Should reject invalid command"
fi

# Test 7: Log directory creation
test_start "Log directory creation"
LOG_DIR="$SCRIPT_DIR/../logs"
if [[ -d "$LOG_DIR" ]]; then
    test_pass
else
    test_fail "Log directory not created: $LOG_DIR"
fi

# Test 8: Log file creation
test_start "Log file creation"
LOG_FILE="$LOG_DIR/stack-manager.log"
if [[ -f "$LOG_FILE" ]]; then
    test_pass
else
    test_fail "Log file not created: $LOG_FILE"
fi

# Test 9: Docker availability check
test_start "Docker availability check"
if command -v docker >/dev/null 2>&1; then
    test_pass
else
    test_fail "Docker not available"
fi

# Test 10: Docker daemon running
test_start "Docker daemon running"
if docker info >/dev/null 2>&1; then
    test_pass
else
    test_fail "Docker daemon not running"
fi

# Test 11: Bash completion script exists
test_start "Bash completion script exists"
COMPLETION_SCRIPT="$SCRIPT_DIR/stack-manager-completion.bash"
if [[ -f "$COMPLETION_SCRIPT" ]]; then
    test_pass
else
    test_fail "Completion script not found: $COMPLETION_SCRIPT"
fi

# Test 12: README exists
test_start "README documentation exists"
README="$SCRIPT_DIR/STACK_MANAGER_README.md"
if [[ -f "$README" ]]; then
    test_pass
else
    test_fail "README not found: $README"
fi

# Test 13: Quick reference exists
test_start "Quick reference exists"
QUICKREF="$SCRIPT_DIR/STACK_MANAGER_QUICKREF.md"
if [[ -f "$QUICKREF" ]]; then
    test_pass
else
    test_fail "Quick reference not found: $QUICKREF"
fi

# Test 14: Alias setup script exists
test_start "Alias setup script exists"
ALIAS_SCRIPT="$SCRIPT_DIR/setup-stack-manager-aliases.sh"
if [[ -f "$ALIAS_SCRIPT" ]] && [[ -x "$ALIAS_SCRIPT" ]]; then
    test_pass
else
    test_fail "Alias setup script not found or not executable: $ALIAS_SCRIPT"
fi

# Test 15: Script has proper shebang
test_start "Script has proper shebang"
if head -n1 "$STACK_MANAGER" | grep -q "#!/usr/bin/env bash"; then
    test_pass
else
    test_fail "Script missing proper shebang"
fi

# Test 16: Script uses strict mode
test_start "Script uses strict error handling"
if grep -q "set -euo pipefail" "$STACK_MANAGER"; then
    test_pass
else
    test_fail "Script not using strict mode (set -euo pipefail)"
fi

# Test 17: Check for required functions
test_start "Required functions present"
REQUIRED_FUNCTIONS=(
    "start_stack"
    "stop_stack"
    "restart_stack"
    "show_all_status"
    "show_logs"
    "clean_stack"
    "interactive_mode"
)

all_present=true
for func in "${REQUIRED_FUNCTIONS[@]}"; do
    if ! grep -q "$func()" "$STACK_MANAGER"; then
        all_present=false
        echo "  Missing function: $func"
    fi
done

if $all_present; then
    test_pass
else
    test_fail "Some required functions are missing"
fi

# Test 18: Check for logging functions
test_start "Logging functions present"
LOGGING_FUNCTIONS=(
    "log_info"
    "log_success"
    "log_warning"
    "log_error"
)

all_present=true
for func in "${LOGGING_FUNCTIONS[@]}"; do
    if ! grep -q "$func()" "$STACK_MANAGER"; then
        all_present=false
        echo "  Missing function: $func"
    fi
done

if $all_present; then
    test_pass
else
    test_fail "Some logging functions are missing"
fi

# Test 19: Check for color definitions
test_start "Color definitions present"
COLOR_VARS=(
    "RED"
    "GREEN"
    "YELLOW"
    "BLUE"
    "NC"
)

all_present=true
for var in "${COLOR_VARS[@]}"; do
    if ! grep -q "$var=" "$STACK_MANAGER"; then
        all_present=false
        echo "  Missing color: $var"
    fi
done

if $all_present; then
    test_pass
else
    test_fail "Some color definitions are missing"
fi

# Test 20: Check for port conflict detection
test_start "Port conflict detection present"
if grep -q "check_port_conflicts" "$STACK_MANAGER"; then
    test_pass
else
    test_fail "Port conflict detection not implemented"
fi

# Test 21: Check for health check functions
test_start "Health check functions present"
if grep -q "get_stack_status" "$STACK_MANAGER" && grep -q "is_stack_running" "$STACK_MANAGER"; then
    test_pass
else
    test_fail "Health check functions not implemented"
fi

# Test 22: Check for resource monitoring
test_start "Resource monitoring present"
if grep -q "show_resource_usage" "$STACK_MANAGER"; then
    test_pass
else
    test_fail "Resource monitoring not implemented"
fi

# Test 23: Verify all stack modes defined
test_start "All stack modes defined"
STACK_MODES=("dev" "citus" "patroni" "monitoring" "production")
all_defined=true

for mode in "${STACK_MODES[@]}"; do
    if ! grep -q "\"$mode\"" "$STACK_MANAGER"; then
        all_defined=false
        echo "  Mode not defined: $mode"
    fi
done

if $all_defined; then
    test_pass
else
    test_fail "Some stack modes not defined"
fi

# Test 24: Check for documentation strings
test_start "Documentation strings present"
if grep -q "# Description:" "$STACK_MANAGER" && grep -q "# Usage:" "$STACK_MANAGER"; then
    test_pass
else
    test_fail "Documentation strings missing"
fi

# Test 25: Check for version information
test_start "Version information present"
if grep -q "# Version:" "$STACK_MANAGER"; then
    test_pass
else
    test_fail "Version information missing"
fi

# ============================================================
# Summary
# ============================================================

echo
echo "========================================"
echo "Test Summary"
echo "========================================"
echo
echo "Total tests run:    $TESTS_RUN"
echo -e "${GREEN}Tests passed:       $TESTS_PASSED${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "${RED}Tests failed:       $TESTS_FAILED${NC}"
else
    echo "Tests failed:       $TESTS_FAILED"
fi
echo

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    echo
    exit 0
else
    PASS_RATE=$((TESTS_PASSED * 100 / TESTS_RUN))
    echo -e "${YELLOW}⚠ Pass rate: ${PASS_RATE}%${NC}"
    echo
    exit 1
fi
