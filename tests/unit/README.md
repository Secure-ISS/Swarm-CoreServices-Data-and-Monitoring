# Unit Tests

This directory contains unit tests for the Distributed PostgreSQL Cluster project.

## Test Files

### test_cache.py (17 tests)
Tests for `src/db/cache.py` - Redis query caching layer

**Coverage**: ~95% of cache.py (53/56 lines)

**Test Areas**:
- Cache initialization (success/failure)
- Cache key generation
- Cache hit/miss scenarios
- TTL management
- Statistics tracking
- Error handling
- Factory functions

**Run**:
```bash
python3 tests/unit/test_cache.py
```

### test_monitoring.py (30 tests)
Tests for `src/db/monitoring.py` - Database index monitoring and query optimization

**Coverage**: ~90% of monitoring.py (86/95 lines)

**Test Areas**:
- IndexMonitor: unused indexes, missing indexes, statistics
- PreparedStatementPool: statement preparation, execution, statistics
- Common statements validation
- Initialization functions

**Run**:
```bash
python3 tests/unit/test_monitoring.py
```

### test_hooks_validation.py
Tests for pre-commit hooks validation

### test_sample.py
Sample tests for pytest-quick hook validation

## Running Tests

### Individual Test Files
```bash
python3 tests/unit/test_cache.py
python3 tests/unit/test_monitoring.py
```

### All Unit Tests
```bash
python3 -m unittest discover -s tests/unit -p "test_*.py" -v
```

### Quick Run Script
```bash
./tests/run_unit_tests.sh
```

## Test Results

```
Ran 47 tests in 0.054s
OK (17 cache + 30 monitoring)
```

## Coverage Impact

**Before**: 62.54% overall coverage
**After**: ~70%+ overall coverage

| Module | Before | After | Lines Tested |
|--------|--------|-------|--------------|
| cache.py | 0% | 95% | 53/56 |
| monitoring.py | 0% | 90% | 86/95 |

## Test Quality

- **Fast**: <100ms total execution time
- **Isolated**: No external dependencies (Redis/PostgreSQL mocked)
- **Comprehensive**: All major code paths tested
- **Maintainable**: Clear naming, good documentation

## Dependencies

Tests use only Python standard library:
- `unittest` - Test framework
- `unittest.mock` - Mocking framework

No external test dependencies required.

## Adding New Tests

Follow the existing patterns:

1. Import path setup:
```python
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../.."))
```

2. Use unittest.TestCase:
```python
class TestMyModule(unittest.TestCase):
    def setUp(self):
        # Setup fixtures
        pass

    def test_my_feature(self):
        # Test code
        self.assertEqual(expected, actual)
```

3. Mock external dependencies:
```python
from unittest.mock import MagicMock, patch

@patch("module.external_dependency")
def test_with_mock(self, mock_dependency):
    # Test with mocked dependency
    pass
```

## Continuous Integration

These tests should be run:
- On every commit (pre-commit hook)
- On every pull request (CI/CD)
- Before deployment

Add to CI/CD:
```yaml
- name: Run unit tests
  run: python3 -m unittest discover -s tests/unit -p "test_*.py"
```

## Documentation

See `/home/matt/projects/Distributed-Postgress-Cluster/docs/TEST_COVERAGE_SUMMARY.md` for detailed coverage analysis.
