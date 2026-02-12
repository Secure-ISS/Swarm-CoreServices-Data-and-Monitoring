#!/bin/bash
# Run unit tests for cache and monitoring modules

echo "======================================"
echo "Running Unit Tests"
echo "======================================"
echo ""

# Run tests
python3 -m unittest tests.unit.test_cache tests.unit.test_monitoring -v

# Capture exit code
EXIT_CODE=$?

echo ""
echo "======================================"
if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ All tests passed!"
else
    echo "❌ Some tests failed (exit code: $EXIT_CODE)"
fi
echo "======================================"

exit $EXIT_CODE
