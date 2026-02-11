# Domain Tests - Quick Start Guide

## 🚀 Run All Tests (Recommended)

```bash
python3 tests/run_domain_tests.py
```

This runs all 105 test cases and provides a comprehensive summary.

---

## 📋 Prerequisites

### 1. Start Database
```bash
./scripts/start_database.sh
```

### 2. Verify Health
```bash
python3 scripts/db_health_check.py
```

Should show:
- ✓ Docker container running
- ✓ Database connectivity
- ✓ RuVector extension loaded
- ✓ Schemas exist

---

## 🧪 Run Individual Test Suites

### Security Tests (31 tests)
```bash
# CVE Remediation - SQL injection, path traversal, input validation
python3 tests/domains/security/test_cve_remediation.py

# Authentication & Authorization
python3 tests/domains/security/test_authentication.py
```

### Integration Tests (44 tests)
```bash
# MCP Server Integration
python3 tests/domains/integration/test_mcp_server.py

# Event Bus
python3 tests/domains/integration/test_event_bus.py

# End-to-End Flows
python3 tests/domains/integration/test_e2e_flows.py
```

### Performance Tests (18 tests)
```bash
# Security Layer Performance
python3 tests/domains/performance/test_security_performance.py

# Integration Layer Performance
python3 tests/domains/performance/test_integration_performance.py
```

### Domain Isolation Tests (17 tests)
```bash
python3 tests/domains/test_domain_isolation.py
```

---

## 📊 Expected Output

```
======================================================================
DISTRIBUTED POSTGRESQL CLUSTER - DOMAIN TESTS
======================================================================

Running Security: CVE Remediation
----------------------------------------------------------------------
test_sql_injection_in_namespace ... ok
test_sql_injection_in_key ... ok
...

======================================================================
TEST SUMMARY
======================================================================

Suite                                    Tests      Status     Time
----------------------------------------------------------------------
Security: CVE Remediation                18         ✓ PASS     2.34s
Security: Authentication                 13         ✓ PASS     1.87s
Integration: MCP Server                  18         ✓ PASS     0.45s
Integration: Event Bus                   17         ✓ PASS     0.52s
Integration: End-to-End Flows            9          ✓ PASS     3.21s
Performance: Security Layer              9          ✓ PASS     5.67s
Performance: Integration Layer           9          ✓ PASS     4.23s
Domain Isolation                         17         ✓ PASS     0.34s
----------------------------------------------------------------------
TOTAL                                    105                   18.63s

✅ ALL TESTS PASSED
```

---

## 🔍 What Each Test Suite Validates

### Security Domain
- **CVE-1**: SQL injection prevention (parameterized queries)
- **CVE-2**: Path traversal prevention (directory/schema isolation)
- **CVE-3**: Input validation (dimensions, thresholds, data types)
- **Auth**: Credential validation, permission checks, timeouts

### Integration Domain
- **MCP**: Server connection, tool registration, execution, errors
- **Event Bus**: Pub/sub, filtering, async handling, persistence
- **E2E**: Complete flows (store→retrieve→search→delete)

### Performance
- **Security**: <1ms validation overhead
- **Integration**: <100ms MCP response, >1K events/sec
- **Latency**: P95 <50ms end-to-end

### Domain Isolation
- **Boundaries**: No circular dependencies
- **Interfaces**: Clear contracts between layers
- **Concerns**: Logging, errors, config properly isolated

---

## ⚠️ Troubleshooting

### Database Not Available
```bash
# Error: "Database not available"

# Solution:
docker ps | grep ruvector-db  # Check if running
./scripts/start_database.sh    # Start if needed
```

### Import Errors
```bash
# Error: "ModuleNotFoundError: No module named 'src'"

# Solution: Run from project root
cd /home/matt/projects/Distributed-Postgress-Cluster
python3 tests/run_domain_tests.py
```

### Permission Errors
```bash
# Error: "Permission denied: test_cve_remediation.py"

# Solution: Make executable
chmod +x tests/domains/security/*.py
chmod +x tests/domains/integration/*.py
chmod +x tests/run_domain_tests.py
```

### Environment Variables Missing
```bash
# Error: "Missing required environment variables"

# Solution: Check .env file exists
ls -la .env
cat .env | grep RUVECTOR
```

---

## 📈 Performance Benchmarks

After running performance tests, you'll see:

```
Small input validation: 2.34ms per operation ✓ (<10ms target)
Large input validation: 12.45ms per operation ✓ (<50ms target)
Embedding validation: 3.21ms per operation ✓ (<10ms target)

MCP Response Time:
  Average: 23.45ms ✓ (<100ms target)
  P95: 45.67ms ✓ (<100ms target)

Event Publishing:
  Throughput: 5432 events/sec ✓ (>1K target)

Vector Search with security: 4.32ms per search ✓ (<50ms target)
```

---

## 🎯 Test Coverage Summary

| Domain | Test Files | Test Cases | Lines of Code |
|--------|-----------|------------|---------------|
| Security | 2 | 31 | ~500 |
| Integration | 3 | 44 | ~900 |
| Performance | 2 | 18 | ~600 |
| Isolation | 1 | 17 | ~250 |
| **TOTAL** | **8** | **105** | **~2,250** |

Plus 4 infrastructure files (~1,100 lines) for test runner, README, and documentation.

**Grand Total: 12 files, 3,346 lines, 105 test cases**

---

## 🔗 Additional Resources

- **Full Documentation**: `/tests/domains/README.md`
- **Implementation Summary**: `/tests/domains/TEST_SUMMARY.md`
- **Error Handling Guide**: `/docs/ERROR_HANDLING.md`
- **Architecture Docs**: `/docs/architecture/`

---

## ✅ Quick Health Check

Run this to verify everything is ready:

```bash
# 1. Check database
python3 scripts/db_health_check.py

# 2. Run quick test
python3 tests/domains/test_domain_isolation.py

# 3. If both pass, run full suite
python3 tests/run_domain_tests.py
```

---

**Ready to test!** 🚀

Run `python3 tests/run_domain_tests.py` to execute all 105 test cases.
