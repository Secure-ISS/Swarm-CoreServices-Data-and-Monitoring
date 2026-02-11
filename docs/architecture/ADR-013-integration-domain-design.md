# ADR-013: Integration Domain Design

**Date:** 2026-02-11
**Status:** Accepted
**Deciders:** System Architecture Designer
**Related:** ADR-011 (Komodo MCP), ADR-010 (Komodo MCP), ADR-007 (HAProxy)

---

## Context

The Distributed PostgreSQL Cluster must integrate with multiple external systems:

1. **Komodo MCP Server**: AI agent database access
2. **HAProxy**: Load balancing and health checks
3. **PgBouncer**: Connection pooling
4. **Monitoring Systems**: Prometheus, Grafana
5. **Client Applications**: PostgreSQL wire protocol
6. **Future Integrations**: REST API, GraphQL, gRPC

### Current State

- Direct PostgreSQL connections via HAProxy
- Komodo MCP integration (basic)
- No unified API gateway
- No protocol translation layer
- Manual monitoring configuration
- Limited observability

### Requirements

**Functional:**
- Support multiple protocols (PostgreSQL, MCP, HTTP, gRPC)
- Protocol translation and adaptation
- Unified API gateway
- Load balancing and health checks
- Request routing and service discovery
- Monitoring and observability

**Non-Functional:**
- Request latency <10ms (gateway overhead)
- Protocol translation <5ms
- 99.99% availability
- Support 10K concurrent connections
- Horizontal scalability

---

## Decision

Implement an **Integration Domain** as a bounded context with the following design:

### 1. Domain Model

```python
# Aggregates
class MCPIntegration(AggregateRoot):
    """Komodo MCP server integration"""
    integration_id: UUID
    server_name: str
    protocol: Protocol  # MCP
    endpoint: Endpoint
    configuration: MCPConfiguration
    status: IntegrationStatus
    health_check: HealthCheckConfig

    # Behavior
    def handle_request(self, request: MCPRequest) -> MCPResponse
    def check_health(self) -> HealthStatus
    def update_configuration(self, config: MCPConfiguration) -> None

class APIGateway(AggregateRoot):
    """Unified API gateway"""
    gateway_id: UUID
    routes: List[Route]
    load_balancer: LoadBalancerConfig
    health_checks: List[HealthCheck]
    rate_limits: List[RateLimit]

    # Behavior
    def route_request(self, request: APIRequest) -> Route
    def select_backend(self, route: Route) -> Backend
    def apply_rate_limit(self, principal: Principal) -> bool

class ExternalAdapter(AggregateRoot):
    """Adapts external systems to domain models"""
    adapter_id: UUID
    adapter_type: AdapterType
    source_system: str  # "prometheus", "grafana", etc.
    target_domain: DomainType  # CORE, MEMORY, INTELLIGENCE
    mapping_rules: List[MappingRule]

    # Behavior
    def translate_request(self, external_request: Any) -> DomainRequest
    def translate_response(self, domain_response: Any) -> ExternalResponse

# Value Objects
class Endpoint(ValueObject):
    protocol: Protocol
    host: str
    port: int
    path: str

    def to_url(self) -> str:
        return f"{self.protocol}://{self.host}:{self.port}{self.path}"

class Route(ValueObject):
    path: str
    method: str
    backend: Backend
    middleware: List[Middleware]

class Backend(ValueObject):
    backend_id: UUID
    endpoint: Endpoint
    weight: int  # for weighted load balancing
    health_status: HealthStatus

# Enums
class Protocol(Enum):
    POSTGRESQL = "postgresql"
    HTTP = "http"
    HTTPS = "https"
    GRPC = "grpc"
    MCP = "mcp"

class IntegrationStatus(Enum):
    ACTIVE = "active"
    INACTIVE = "inactive"
    ERROR = "error"
    DEGRADED = "degraded"

class LoadBalanceStrategy(Enum):
    ROUND_ROBIN = "round_robin"
    LEAST_CONNECTIONS = "least_connections"
    WEIGHTED = "weighted"
    IP_HASH = "ip_hash"
```

### 2. Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                    Integration Domain                           │
├────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              API Gateway (Unified Entry Point)          │   │
│  │                                                          │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐             │   │
│  │  │   MCP    │  │   HTTP   │  │   gRPC   │             │   │
│  │  │ Listener │  │ Listener │  │ Listener │             │   │
│  │  └────┬─────┘  └────┬─────┘  └────┬─────┘             │   │
│  │       └────────────┬─────────────┘                     │   │
│  │                    │                                    │   │
│  │         ┌──────────▼──────────┐                         │   │
│  │         │  Request Router     │                         │   │
│  │         │  - Rate Limiting    │                         │   │
│  │         │  - Authentication   │                         │   │
│  │         │  - Load Balancing   │                         │   │
│  │         └──────────┬──────────┘                         │   │
│  └────────────────────┼────────────────────────────────────┘   │
│                       │                                        │
│         ┌─────────────┼─────────────┐                          │
│         │             │             │                          │
│  ┌──────▼──────┐ ┌───▼────────┐ ┌─▼──────────┐               │
│  │   MCP       │ │ Protocol   │ │ Monitoring │               │
│  │ Integration │ │  Adapter   │ │  Adapter   │               │
│  │  Service    │ │  Service   │ │  Service   │               │
│  └──────┬──────┘ └───┬────────┘ └─┬──────────┘               │
│         │            │             │                          │
│  ┌──────▼────────────▼─────────────▼──────┐                   │
│  │     Anti-Corruption Layer              │                   │
│  │  - Translates external to domain       │                   │
│  │  - Protects domain integrity           │                   │
│  │  - Routes to Core/Memory/Intelligence  │                   │
│  └────────────────────────────────────────┘                   │
│                                                                 │
└────────────────────────────────────────────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────┐
        │    Target Domains (via ACL)      │
        │  - Core (Cluster)                │
        │  - Memory (Storage)              │
        │  - Intelligence (Vectors)        │
        │  - Security (Auth)               │
        └──────────────────────────────────┘
```

### 3. Key Services

**MCPIntegrationService:**
- Handle MCP protocol requests
- Translate MCP operations to SQL
- Route to appropriate cluster nodes
- Return results in MCP format

**APIGatewayService:**
- Accept requests from multiple protocols
- Route based on path, method, headers
- Apply middleware (auth, rate limiting)
- Select backend using load balancing strategy
- Health check backends

**ProtocolAdapterService:**
- Translate between protocols (MCP ↔ SQL, HTTP ↔ SQL, gRPC ↔ SQL)
- Handle protocol-specific concerns
- Validate requests per protocol spec
- Format responses per protocol spec

**MonitoringIntegrationService:**
- Export metrics to Prometheus
- Export traces to Jaeger/Zipkin
- Export logs to Loki/Elasticsearch
- Provide health endpoints
- Expose cluster statistics

**LoadBalancerService:**
- Implement load balancing strategies
- Track backend health
- Handle failover
- Distribute load evenly

### 4. Protocol Translation Examples

**MCP → SQL:**

```python
# MCP Request
{
    "operation": "search_similar",
    "table": "memory_entries",
    "parameters": {
        "namespace": "agent-123",
        "embedding": [0.1, 0.2, ...],
        "limit": 10
    }
}

# Translated SQL
SELECT
    entry_id, namespace, key, value,
    embedding <-> '[0.1,0.2,...]'::ruvector AS distance
FROM memory_entries
WHERE namespace = 'agent-123'
ORDER BY embedding <-> '[0.1,0.2,...]'::ruvector
LIMIT 10;
```

**HTTP → SQL:**

```python
# HTTP Request
GET /api/v1/memories?namespace=agent-123&limit=10

# Translated SQL
SELECT entry_id, namespace, key, value, metadata
FROM memory_entries
WHERE namespace = 'agent-123'
LIMIT 10;
```

### 5. Anti-Corruption Layer

```python
class IntegrationACL:
    """Protects Integration Domain from external systems"""

    def __init__(
        self,
        cluster_service: ClusterOrchestratorService,
        memory_service: MemoryStorageService,
        vector_service: VectorSearchService,
        auth_service: AuthorizationService
    ):
        self.cluster_service = cluster_service
        self.memory_service = memory_service
        self.vector_service = vector_service
        self.auth_service = auth_service

    def execute_mcp_request(
        self,
        mcp_request: MCPRequest,
        principal: Principal
    ) -> MCPResponse:
        """Execute MCP request with domain isolation"""

        # 1. Authenticate (Security Domain)
        if not self.auth_service.check_permission(
            principal,
            resource=self._extract_resource(mcp_request),
            action=self._extract_action(mcp_request)
        ):
            raise UnauthorizedException()

        # 2. Route to appropriate domain
        if mcp_request.operation == "search_similar":
            # Intelligence Domain
            result = self._execute_vector_search(mcp_request, principal)
        elif mcp_request.operation == "cluster_status":
            # Core Domain
            result = self._execute_cluster_query(mcp_request, principal)
        else:
            # Memory Domain
            result = self._execute_memory_query(mcp_request, principal)

        # 3. Translate back to MCP format
        return self._translate_to_mcp_response(result)

    def _execute_vector_search(
        self,
        mcp_request: MCPRequest,
        principal: Principal
    ) -> SearchResult:
        """Delegate to Intelligence Domain"""

        query_embedding = Embedding(mcp_request.parameters["embedding"])
        namespace = mcp_request.parameters["namespace"]

        return self.vector_service.search_similar(
            query_embedding=query_embedding,
            namespace=namespace,
            limit=mcp_request.parameters.get("limit", 10),
            min_similarity=mcp_request.parameters.get("min_similarity", 0.7)
        )

    def _execute_cluster_query(
        self,
        mcp_request: MCPRequest,
        principal: Principal
    ) -> ClusterStatus:
        """Delegate to Core Domain"""

        cluster_id = UUID(mcp_request.parameters["cluster_id"])
        cluster = self.cluster_service.get_cluster_status(cluster_id)

        return cluster

    def _execute_memory_query(
        self,
        mcp_request: MCPRequest,
        principal: Principal
    ) -> MemoryResult:
        """Delegate to Memory Domain"""

        namespace = mcp_request.parameters["namespace"]
        key = mcp_request.parameters.get("key")

        if key:
            return self.memory_service.retrieve_memory(namespace, key)
        else:
            return self.memory_service.search_memories(
                namespace,
                query=mcp_request.parameters.get("query")
            )
```

---

## Consequences

### Positive

1. **Protocol Agnostic**: Support multiple protocols without changing domain logic
2. **Single Entry Point**: API Gateway provides unified access
3. **Scalability**: Can scale gateway independently from domains
4. **Flexibility**: Easy to add new protocols or integrations
5. **Domain Protection**: ACL prevents external changes from breaking domains
6. **Observability**: Centralized monitoring and logging

### Negative

1. **Additional Latency**: Gateway adds 5-10ms overhead
2. **Complexity**: More components to manage
3. **Single Point of Failure**: Gateway outage affects all access (mitigate with HA)
4. **Operational Overhead**: Need to configure routes, backends, health checks

### Risks and Mitigation

| Risk | Mitigation |
|------|------------|
| **Gateway outage** | HA deployment (2+ instances), health checks |
| **Performance bottleneck** | Horizontal scaling, caching, connection pooling |
| **Protocol bugs** | Extensive protocol compliance tests |
| **Security vulnerabilities** | Input validation, rate limiting, authentication |

---

## Implementation Plan

### Phase 1: API Gateway (Week 1)
- [ ] Implement APIGateway aggregate
- [ ] Build request routing logic
- [ ] Implement load balancing strategies
- [ ] Add health checking
- [ ] Create route configuration system

### Phase 2: MCP Integration (Week 1)
- [ ] Implement MCPIntegration aggregate
- [ ] Build MCP protocol adapter
- [ ] Implement MCP → SQL translation
- [ ] Handle MCP-specific operations (search_similar, etc.)
- [ ] Error handling and validation

### Phase 3: Protocol Adapters (Week 2)
- [ ] HTTP/REST adapter
- [ ] gRPC adapter (future)
- [ ] WebSocket adapter (future)
- [ ] Protocol validation and testing

### Phase 4: Anti-Corruption Layer (Week 2)
- [ ] Build IntegrationACL
- [ ] Wire to Security Domain
- [ ] Wire to Core Domain
- [ ] Wire to Memory Domain
- [ ] Wire to Intelligence Domain

### Phase 5: Monitoring Integration (Week 3)
- [ ] Prometheus metrics exporter
- [ ] Trace exporter (Jaeger)
- [ ] Log aggregation (Loki)
- [ ] Health check endpoints
- [ ] Dashboards

---

## Alternatives Considered

### Alternative 1: Direct Protocol Support in Each Domain

**Pros:**
- No gateway overhead
- Simpler architecture
- Lower latency

**Cons:**
- Protocol logic mixed with domain logic
- Hard to add new protocols
- Violates separation of concerns
- No centralized monitoring

**Verdict:** ❌ Rejected - Violates DDD principles, hard to maintain

### Alternative 2: External API Gateway (Kong, Nginx, Envoy)

**Pros:**
- Battle-tested
- Rich feature set
- High performance
- Community support

**Cons:**
- External dependency
- Limited customization
- Learning curve
- Operational complexity

**Verdict:** ⚠️ Consider for production - Can use Envoy behind our gateway

### Alternative 3: GraphQL Federation

**Pros:**
- Unified schema
- Type safety
- Client flexibility
- Resolver pattern

**Cons:**
- Limited to GraphQL protocol
- N+1 query problem
- Additional complexity
- Caching challenges

**Verdict:** ❌ Rejected - Too restrictive, doesn't support MCP protocol

---

## Performance Targets

| Operation | Target (p95) | Notes |
|-----------|--------------|-------|
| Gateway routing | <5ms | Request routing decision |
| Protocol translation | <5ms | MCP → SQL, HTTP → SQL |
| Load balancing | <2ms | Backend selection |
| Health check | <10ms | Per backend check |
| End-to-end (MCP) | <50ms | Including domain execution |

---

## API Gateway Configuration Example

```yaml
# API Gateway Configuration
gateway:
  id: "gateway-001"
  host: "0.0.0.0"
  port: 8080

  routes:
    - path: "/api/v1/memories"
      methods: ["GET", "POST"]
      backend: "memory-service"
      middleware:
        - authentication
        - rate_limit
        - logging

    - path: "/api/v1/cluster"
      methods: ["GET"]
      backend: "cluster-service"
      middleware:
        - authentication
        - admin_only
        - logging

    - path: "/mcp"
      methods: ["POST"]
      backend: "mcp-service"
      protocol: "mcp"
      middleware:
        - mcp_authentication
        - rate_limit

  backends:
    - id: "memory-service"
      endpoints:
        - host: "coordinator-1"
          port: 5432
          weight: 100
        - host: "coordinator-2"
          port: 5432
          weight: 100
      health_check:
        path: "/health"
        interval: 5s
        timeout: 2s

    - id: "cluster-service"
      endpoints:
        - host: "coordinator-1"
          port: 5432
          weight: 100

    - id: "mcp-service"
      endpoints:
        - host: "haproxy"
          port: 5432
          weight: 100

  load_balancing:
    strategy: "round_robin"
    sticky_sessions: false

  rate_limiting:
    - principal_type: "AI_AGENT"
      max_requests_per_minute: 1000
    - principal_type: "USER"
      max_requests_per_minute: 5000
```

---

## MCP Integration Specification

### Supported Operations

| MCP Operation | Translation | Target Domain |
|--------------|-------------|---------------|
| `search_similar` | Vector similarity search | Intelligence |
| `get_memory` | SELECT by namespace+key | Memory |
| `store_memory` | INSERT/UPDATE | Memory |
| `cluster_status` | Patroni/Citus queries | Core |
| `list_namespaces` | SELECT DISTINCT namespace | Memory |

### Example MCP Request/Response

```json
// Request
{
  "jsonrpc": "2.0",
  "method": "search_similar",
  "params": {
    "table": "memory_entries",
    "namespace": "agent-123",
    "embedding": [0.1, 0.2, 0.3, ...],
    "limit": 10,
    "min_similarity": 0.7
  },
  "id": 1
}

// Response
{
  "jsonrpc": "2.0",
  "result": {
    "matches": [
      {
        "entry_id": "uuid-123",
        "namespace": "agent-123",
        "key": "key-1",
        "value": "Some memory content",
        "similarity": 0.95,
        "metadata": {"type": "conversation"}
      },
      ...
    ],
    "count": 10,
    "execution_time_ms": 12
  },
  "id": 1
}
```

---

## Monitoring and Observability

### Metrics

- Request rate (per protocol, per route)
- Request latency (p50, p95, p99)
- Error rate (per protocol, per route)
- Backend health status
- Load balancing distribution
- Connection pool utilization

### Traces

- Request → Gateway → ACL → Domain → Repository → Database
- Distributed tracing with OpenTelemetry
- Trace sampling (1% for production)

### Logs

- All requests (structured JSON)
- Error logs with stack traces
- Audit logs for authentication/authorization
- Performance logs for slow queries (>100ms)

### Dashboards

1. **Gateway Overview**: Request rate, latency, error rate
2. **Protocol Breakdown**: Metrics per protocol (MCP, HTTP, gRPC)
3. **Backend Health**: Health status, response times
4. **Load Balancing**: Distribution across backends

---

## Testing Strategy

### Unit Tests

```python
def test_route_request():
    gateway = APIGateway(...)
    request = APIRequest(path="/api/v1/memories", method="GET")

    route = gateway.route_request(request)

    assert route.backend == "memory-service"
    assert "authentication" in route.middleware

def test_mcp_translation():
    adapter = ProtocolAdapterService()
    mcp_request = MCPRequest(
        operation="search_similar",
        parameters={"namespace": "test", "embedding": [...]}
    )

    sql_query = adapter.translate_mcp_to_sql(mcp_request)

    assert "SELECT" in sql_query
    assert "memory_entries" in sql_query
    assert "namespace = 'test'" in sql_query
```

### Integration Tests

```python
@pytest.mark.integration
def test_end_to_end_mcp_request():
    # 1. Send MCP request to gateway
    response = gateway.handle_request(
        MCPRequest(
            operation="search_similar",
            parameters={
                "namespace": "test",
                "embedding": test_embedding,
                "limit": 5
            }
        )
    )

    # 2. Verify response
    assert response.result.count == 5
    assert all(r.similarity > 0.7 for r in response.result.matches)

    # 3. Verify audit log
    logs = audit_service.query_logs(operation="search_similar")
    assert len(logs) > 0
```

---

## Security Considerations

### Input Validation

- Validate all MCP requests against schema
- Sanitize SQL inputs (use parameterized queries)
- Limit request size (max 10MB)
- Validate embedding dimensions (384 for current model)

### Rate Limiting

- Per-principal rate limiting
- Global rate limiting (prevent DoS)
- Burst allowance (2x normal rate for 10s)

### Authentication

- All requests must be authenticated
- Token validation at gateway
- Principal context propagated to domains

---

## References

- [Komodo MCP Documentation](https://github.com/ComodoHQ/komodo)
- [HAProxy Configuration](http://www.haproxy.org/)
- [OpenTelemetry](https://opentelemetry.io/)
- [API Gateway Pattern](https://microservices.io/patterns/apigateway.html)

---

**Decision:** Accepted
**Date:** 2026-02-11
**Review Date:** 2026-05-11 (3 months)
