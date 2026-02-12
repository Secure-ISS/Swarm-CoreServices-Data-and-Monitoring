#!/bin/bash
# Performance benchmark for individual hooks

echo "=== Hook Performance Benchmark ==="
echo ""

# Test files
TEST_FILE="tests/unit/test_sample.py"

# Measure each hook individually
echo "1. black (code formatter):"
time pre-commit run black --files $TEST_FILE 2>&1 | grep -E "(Passed|Failed)"
echo ""

echo "2. isort (import organizer):"
time pre-commit run isort --files $TEST_FILE 2>&1 | grep -E "(Passed|Failed)"
echo ""

echo "3. flake8 (linter):"
time pre-commit run flake8 --files $TEST_FILE 2>&1 | grep -E "(Passed|Failed)"
echo ""

echo "4. mypy (type checker):"
time pre-commit run mypy --files $TEST_FILE 2>&1 | grep -E "(Passed|Failed)"
echo ""

echo "5. bandit (security):"
time pre-commit run bandit --files $TEST_FILE 2>&1 | grep -E "(Passed|Failed)"
echo ""

echo "6. detect-secrets:"
time pre-commit run detect-secrets --files $TEST_FILE 2>&1 | grep -E "(Passed|Failed)"
echo ""

echo "7. File checks (trailing-whitespace):"
time pre-commit run trailing-whitespace --files $TEST_FILE 2>&1 | grep -E "(Passed|Failed)"
echo ""

echo "8. pytest-quick:"
time pre-commit run pytest-quick 2>&1 | grep -E "(Passed|Failed)"
echo ""

echo "=== Summary: All individual hooks tested ==="
