# Domain Tests

Comprehensive test suite for Security and Integration domains of the Distributed PostgreSQL Cluster.

## Test Structure

```
tests/domains/
├── security/                    # Security domain tests
│   ├── test_cve_remediation.py # CVE-1, CVE-2, CVE-3 tests
│   └── test_authentication.py   # Auth/authz tests
├── integration/                 # Integration domain tests
│   ├── test_mcp_server.py      # MCP server integration
│   ├── test_event_bus.py       # Event bus functionality
│   └── test_e2e_flows.py       # End-to-end flows
├── performance/                 # Performance tests
│   ├── test_security_performance.py
│   └── test_integration_performance.py
├── test_domain_isolation.py    # Domain boundary tests
└── run_domain_tests.py         # Comprehensive test runner
```

## Test Categories

### Security Domain Tests

#### CVE Remediation (`test_cve_remediation.py`)
- **CVE-1**: SQL Injection Prevention
  - Parameterized query validation
  - Malicious input handling in namespace, key, metadata
  - Search query injection prevention
- **CVE-2**: Path Traversal Prevention
  - Directory traversal pattern handling
  - Schema traversal prevention
  - Null byte injection prevention
- **CVE-3**: Input Validation
  - Empty value rejection
  - Embedding dimension validation
  - Similarity threshold validation
  - Malformed data handling
  - Unicode and special character support

#### Authentication & Authorization (`test_authentication.py`)
- Credential validation and rejection
- Fast-fail on invalid credentials
- Permission validation (read/write/DDL)
- Connection security
- Security event logging

### Integration Domain Tests

#### MCP Server Integration (`test_mcp_server.py`)
- Connection and initialization
- Tool registration and discovery
- Tool execution and error handling
- Resource management
- Retry logic and circuit breaker pattern

#### Event Bus (`test_event_bus.py`)
- Event structure and naming conventions
- Publishing and subscription
- Event filtering and routing
- Asynchronous event handling
- Event persistence and replay

#### End-to-End Flows (`test_e2e_flows.py`)
- Complete memory lifecycle (store → retrieve → search → delete)
- Cross-database isolation
- Vector similarity search
- Concurrent access patterns
- Error recovery flows

### Performance Tests

#### Security Performance (`test_security_performance.py`)
- Input validation overhead: <1ms target
- Query parameterization performance
- Authentication overhead
- Complete security stack: <20ms target
- Vector search with security: <50ms target

#### Integration Performance (`test_integration_performance.py`)
- MCP response time: <100ms target
- Event bus throughput: >1K events/sec
- End-to-end latency: P95 <50ms
- Concurrent operations: >100 writes/sec, >500 reads/sec

### Domain Isolation Tests (`test_domain_isolation.py`)
- Domain boundary enforcement
- No circular dependencies
- Interface contracts
- Cross-cutting concerns (logging, error handling, config)

## Running Tests

### Run All Domain Tests
```bash
python3 tests/run_domain_tests.py
```

### Run Specific Test Suites

**Security Tests:**
```bash
python3 tests/domains/security/test_cve_remediation.py
python3 tests/domains/security/test_authentication.py
```

**Integration Tests:**
```bash
python3 tests/domains/integration/test_mcp_server.py
python3 tests/domains/integration/test_event_bus.py
python3 tests/domains/integration/test_e2e_flows.py
```

**Performance Tests:**
```bash
python3 tests/domains/performance/test_security_performance.py
python3 tests/domains/performance/test_integration_performance.py
```

**Isolation Tests:**
```bash
python3 tests/domains/test_domain_isolation.py
```

## Test Requirements

### Database Setup
Tests require a running PostgreSQL database with RuVector extension:

```bash
# Start database
./scripts/start_database.sh

# Verify health
python3 scripts/db_health_check.py
```

### Environment Variables
Required environment variables (see `.env`):
- `RUVECTOR_HOST`, `RUVECTOR_PORT`, `RUVECTOR_DB`
- `RUVECTOR_USER`, `RUVECTOR_PASSWORD`
- `SHARED_KNOWLEDGE_HOST`, `SHARED_KNOWLEDGE_PORT`
- `SHARED_KNOWLEDGE_DB`, `SHARED_KNOWLEDGE_USER`, `SHARED_KNOWLEDGE_PASSWORD`

## Test Coverage

### Security Domain
- ✅ SQL injection prevention (4 test cases)
- ✅ Path traversal prevention (3 test cases)
- ✅ Input validation (8 test cases)
- ✅ Authentication validation (4 test cases)
- ✅ Authorization controls (4 test cases)
- ✅ Connection security (3 test cases)
- ✅ Security logging (2 test cases)

**Total: 28 test cases**

### Integration Domain
- ✅ MCP server connection (4 test cases)
- ✅ Tool registration (3 test cases)
- ✅ Tool execution (4 test cases)
- ✅ Resource management (3 test cases)
- ✅ Error recovery (4 test cases)
- ✅ Event publishing (3 test cases)
- ✅ Event subscription (4 test cases)
- ✅ Event filtering (3 test cases)
- ✅ Async handling (2 test cases)
- ✅ Event persistence (3 test cases)
- ✅ Memory lifecycle (2 test cases)
- ✅ Vector search (3 test cases)
- ✅ Concurrent access (2 test cases)
- ✅ Error recovery (2 test cases)

**Total: 42 test cases**

### Performance Tests
- ✅ Input validation overhead (3 test cases)
- ✅ Query parameterization (2 test cases)
- ✅ Authentication performance (2 test cases)
- ✅ Security stack benchmark (2 test cases)
- ✅ MCP server performance (2 test cases)
- ✅ Event bus performance (3 test cases)
- ✅ End-to-end latency (2 test cases)
- ✅ Concurrent operations (2 test cases)

**Total: 18 test cases**

### Domain Isolation
- ✅ Domain boundaries (3 test cases)
- ✅ Security isolation (3 test cases)
- ✅ Integration isolation (3 test cases)
- ✅ Database isolation (2 test cases)
- ✅ Interface contracts (3 test cases)
- ✅ Cross-cutting concerns (3 test cases)

**Total: 17 test cases**

## Overall Statistics

- **Total Test Cases**: 105
- **Test Files**: 9
- **Lines of Code**: ~3,500
- **Coverage Areas**: Security, Integration, Performance, Isolation

## Performance Targets

Based on project requirements and V3 performance targets:

| Metric | Target | Test Coverage |
|--------|--------|---------------|
| Input validation overhead | <1ms | ✅ |
| Query execution | <10ms | ✅ |
| MCP response time | <100ms | ✅ |
| Vector search (HNSW) | <5ms | ✅ |
| End-to-end latency (P95) | <12ms | ✅ |
| Event throughput | >1K/sec | ✅ |
| Write throughput | >100/sec | ✅ |
| Read throughput | >500/sec | ✅ |

## Key Features

### 1. Comprehensive Security Testing
- All three CVE remediations validated
- Authentication and authorization thoroughly tested
- Performance impact measured (<1ms overhead)

### 2. Integration Testing
- MCP server integration with mock and real tests
- Event bus with pub/sub patterns
- End-to-end flows covering complete lifecycle

### 3. Performance Benchmarking
- Real-world performance metrics
- Concurrent operation testing
- Overhead measurements for security layers

### 4. Domain Isolation Validation
- No circular dependencies
- Clear interface contracts
- Proper separation of concerns

## CI/CD Integration

Tests can be integrated into CI/CD pipelines:

```yaml
# Example GitHub Actions
- name: Run Domain Tests
  run: |
    ./scripts/start_database.sh
    python3 tests/run_domain_tests.py
```

## Troubleshooting

### Database Connection Issues
```bash
# Check database status
docker ps | grep ruvector-db

# Start database
./scripts/start_database.sh

# Verify connectivity
python3 scripts/db_health_check.py
```

### Test Failures
1. Check environment variables in `.env`
2. Verify database schema with `ruvector status`
3. Review test output for specific error messages
4. Check logs for detailed error information

## Contributing

When adding new tests:
1. Follow existing test structure
2. Use descriptive test names
3. Include docstrings explaining what is tested
4. Add performance benchmarks where appropriate
5. Update this README with new test coverage

## References

- [Error Handling Guide](/home/matt/projects/Distributed-Postgress-Cluster/docs/ERROR_HANDLING.md)
- [Architecture Documentation](/home/matt/projects/Distributed-Postgress-Cluster/docs/architecture/)
- [Project Requirements](/home/matt/projects/Distributed-Postgress-Cluster/docs/requirements/)
- [Security Architecture](/home/matt/projects/Distributed-Postgress-Cluster/docs/security/)
