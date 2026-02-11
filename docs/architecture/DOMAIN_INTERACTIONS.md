# Domain Interactions and Event Flows

**Date:** 2026-02-11
**Version:** 1.0
**Status:** Active

---

## Domain Interaction Diagram

```
┌────────────────────────────────────────────────────────────────────────┐
│                     Distributed PostgreSQL Cluster                      │
│                        5 Domain Architecture (DDD)                      │
└────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────────┐
│  External Systems (Clients, Monitoring, AI Agents)                     │
└────────────────┬───────────────────────────────────────────────────────┘
                 │
                 │  HTTP/MCP/PostgreSQL Protocol
                 │
┌────────────────▼────────────────────────────────────────────────────────┐
│  DOMAIN 5: INTEGRATION DOMAIN (External Systems)                        │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  API Gateway                                                      │  │
│  │  - Protocol Translation (MCP ↔ SQL, HTTP ↔ SQL)                  │  │
│  │  - Request Routing                                               │  │
│  │  - Load Balancing                                                │  │
│  │  - Health Checks                                                 │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  Anti-Corruption Layer (ACL)                                     │  │
│  │  - Protects domain integrity                                     │  │
│  │  - Translates external models to domain models                   │  │
│  │  - Routes to appropriate domain services                         │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└────────────────┬────────────────────────────────────────────────────────┘
                 │
                 │  Domain Events & Service Calls
                 │
┌────────────────┴────────────────────────────────────────────────────────┐
│  DOMAIN 4: SECURITY DOMAIN (Authentication & Authorization)             │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  Authentication Service                                           │  │
│  │  - Login (password + MFA)                                         │  │
│  │  - Session management                                             │  │
│  │  - Token validation                                               │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  Authorization Service (RBAC)                                     │  │
│  │  - Permission checks                                              │  │
│  │  - Namespace-level access control                                │  │
│  │  - Role management                                                │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  Audit Service                                                    │  │
│  │  - Log all actions                                                │  │
│  │  - Compliance reporting                                           │  │
│  │  - Security monitoring                                            │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└────────────────┬────────────────────────────────────────────────────────┘
                 │
                 │  Authorized Domain Events
                 │
         ┌───────┴───────┐
         │               │
┌────────▼─────────┐  ┌──▼─────────────┐  ┌────────────────────┐
│  DOMAIN 1:       │  │  DOMAIN 2:     │  │  DOMAIN 3:         │
│  CORE DOMAIN     │  │  INTELLIGENCE  │  │  MEMORY DOMAIN     │
│  (Cluster)       │  │  DOMAIN        │  │  (Storage)         │
│                  │  │  (Vectors)     │  │                    │
│ ┌──────────────┐ │  │ ┌────────────┐ │  │ ┌────────────────┐ │
│ │ Cluster      │ │  │ │ Vector     │ │  │ │ Memory         │ │
│ │ Orchestrator │ │  │ │ Search     │ │  │ │ Storage        │ │
│ │              │ │  │ │            │ │  │ │                │ │
│ │ - Coordinators│ │  │ │ - HNSW     │ │  │ │ - Namespaces   │ │
│ │ - Workers    │ │  │ │ - Patterns │ │  │ │ - Entries      │ │
│ │ - Shards     │ │  │ │ - SONA     │ │  │ │ - Graphs       │ │
│ │ - Failover   │ │  │ │ - MoE      │ │  │ │ - Sharding     │ │
│ └──────────────┘ │  │ └────────────┘ │  │ └────────────────┘ │
│                  │  │                │  │                    │
│ ┌──────────────┐ │  │ ┌────────────┐ │  │ ┌────────────────┐ │
│ │ Health       │ │  │ │ Pattern    │ │  │ │ Knowledge      │ │
│ │ Monitoring   │ │  │ │ Learning   │ │  │ │ Graph          │ │
│ └──────────────┘ │  │ └────────────┘ │  │ └────────────────┘ │
└──────────────────┘  └────────────────┘  └────────────────────┘
         │                    │                     │
         └────────────────────┴─────────────────────┘
                              │
                              │  Repository Pattern
                              │
┌─────────────────────────────▼─────────────────────────────────────────┐
│  Infrastructure Layer (PostgreSQL + RuVector + etcd + HAProxy)        │
│  - Citus distributed tables                                           │
│  - Patroni high availability                                          │
│  - RuVector HNSW indexes                                              │
│  - etcd consensus                                                     │
└───────────────────────────────────────────────────────────────────────┘
```

---

## Event Flow Example: MCP Vector Search Request

### 1. Request Entry (Integration Domain)

```
┌─────────────────────────────────────────────────────────────────┐
│ Event: MCPRequestReceived                                       │
├─────────────────────────────────────────────────────────────────┤
│ Source: Integration Domain                                      │
│ Payload:                                                        │
│   - integration_id: UUID                                        │
│   - request_id: UUID                                            │
│   - operation: "search_similar"                                 │
│   - parameters:                                                 │
│       namespace: "agent-123"                                    │
│       embedding: [0.1, 0.2, ...]                                │
│       limit: 10                                                 │
│       min_similarity: 0.7                                       │
└─────────────────────────────────────────────────────────────────┘
                           │
                           ▼
```

### 2. Authentication (Security Domain)

```
┌─────────────────────────────────────────────────────────────────┐
│ Event: PrincipalAuthenticated                                   │
├─────────────────────────────────────────────────────────────────┤
│ Source: Security Domain                                         │
│ Payload:                                                        │
│   - principal_id: UUID                                          │
│   - authentication_method: "token"                              │
│   - success: true                                               │
│   - ip_address: "192.168.1.100"                                 │
│   - timestamp: 2026-02-11T10:30:00Z                             │
└─────────────────────────────────────────────────────────────────┘
                           │
                           ▼
```

### 3. Authorization (Security Domain)

```
┌─────────────────────────────────────────────────────────────────┐
│ Event: PermissionChecked                                        │
├─────────────────────────────────────────────────────────────────┤
│ Source: Security Domain                                         │
│ Payload:                                                        │
│   - principal_id: UUID                                          │
│   - resource_type: "NAMESPACE"                                  │
│   - resource: "agent-123"                                       │
│   - action: "READ"                                              │
│   - result: "GRANTED"                                           │
│   - reason: "Principal has role 'mcp_user' with namespace access"│
└─────────────────────────────────────────────────────────────────┘
                           │
                           ▼
```

### 4. Vector Search (Intelligence Domain)

```
┌─────────────────────────────────────────────────────────────────┐
│ Event: VectorSearchInitiated                                    │
├─────────────────────────────────────────────────────────────────┤
│ Source: Intelligence Domain                                     │
│ Payload:                                                        │
│   - search_id: UUID                                             │
│   - namespace: "agent-123"                                      │
│   - dimensions: 384                                             │
│   - limit: 10                                                   │
│   - min_similarity: 0.7                                         │
│   - shard_ids: [shard-1, shard-2, shard-3]                      │
└─────────────────────────────────────────────────────────────────┘
                           │
                           ▼
```

### 5. Shard Query (Core Domain)

```
┌─────────────────────────────────────────────────────────────────┐
│ Event: ShardQueryExecuted                                       │
├─────────────────────────────────────────────────────────────────┤
│ Source: Core Domain                                             │
│ Payload:                                                        │
│   - shard_id: shard-1                                           │
│   - query_type: "vector_similarity"                             │
│   - execution_time_ms: 5                                        │
│   - results_count: 4                                            │
└─────────────────────────────────────────────────────────────────┘
                           │
                           ▼
```

### 6. Memory Retrieval (Memory Domain)

```
┌─────────────────────────────────────────────────────────────────┐
│ Event: MemoryEntriesRetrieved                                   │
├─────────────────────────────────────────────────────────────────┤
│ Source: Memory Domain                                           │
│ Payload:                                                        │
│   - namespace: "agent-123"                                      │
│   - entry_count: 10                                             │
│   - retrieval_time_ms: 3                                        │
│   - shard_distribution:                                         │
│       shard-1: 4 entries                                        │
│       shard-2: 3 entries                                        │
│       shard-3: 3 entries                                        │
└─────────────────────────────────────────────────────────────────┘
                           │
                           ▼
```

### 7. Audit Logging (Security Domain)

```
┌─────────────────────────────────────────────────────────────────┐
│ Event: AuditLogCreated                                          │
├─────────────────────────────────────────────────────────────────┤
│ Source: Security Domain                                         │
│ Payload:                                                        │
│   - log_id: UUID                                                │
│   - principal_id: UUID                                          │
│   - action: "VECTOR_SEARCH"                                     │
│   - resource: "memory_entries (namespace: agent-123)"           │
│   - outcome: "SUCCESS"                                          │
│   - metadata:                                                   │
│       results_count: 10                                         │
│       execution_time_ms: 12                                     │
│   - timestamp: 2026-02-11T10:30:00.012Z                         │
└─────────────────────────────────────────────────────────────────┘
                           │
                           ▼
```

### 8. Response Sent (Integration Domain)

```
┌─────────────────────────────────────────────────────────────────┐
│ Event: MCPResponseSent                                          │
├─────────────────────────────────────────────────────────────────┤
│ Source: Integration Domain                                      │
│ Payload:                                                        │
│   - integration_id: UUID                                        │
│   - request_id: UUID                                            │
│   - status_code: 200                                            │
│   - response_time_ms: 15                                        │
│   - results_count: 10                                           │
└─────────────────────────────────────────────────────────────────┘
```

---

## Domain Communication Patterns

### 1. Synchronous Communication (Direct Service Calls)

Used when immediate response is required:

```python
# Integration Domain → Security Domain (via ACL)
class IntegrationACL:
    def execute_mcp_request(self, mcp_request: MCPRequest) -> MCPResponse:
        # Synchronous call to Security Domain
        principal = self.auth_service.authenticate(token)

        # Synchronous authorization check
        if not self.authz_service.check_permission(principal, resource, action):
            raise UnauthorizedException()

        # Synchronous call to Intelligence Domain
        results = self.vector_service.search_similar(query_embedding)

        return self._translate_to_mcp_response(results)
```

**When to use:**
- Authentication and authorization checks
- Simple queries
- Operations requiring immediate response
- Cross-domain reads

**Performance targets:**
- <10ms for authorization checks
- <50ms for domain service calls

---

### 2. Asynchronous Communication (Domain Events)

Used for eventual consistency and decoupling:

```python
# Example: When memory is stored, multiple domains react

# Memory Domain publishes event
event_bus.publish(
    MemoryEntryStored(
        entry_id=UUID("..."),
        namespace="agent-123",
        key="memory-key-1",
        shard_id=UUID("...")
    )
)

# Intelligence Domain subscribes (update vector index)
class VectorIndexingHandler(EventHandler):
    def handle(self, event: MemoryEntryStored):
        # Update HNSW index asynchronously
        self.vector_service.index_entry(event.entry_id)

# Security Domain subscribes (audit logging)
class AuditLoggingHandler(EventHandler):
    def handle(self, event: MemoryEntryStored):
        # Log action asynchronously
        self.audit_service.log_action(
            action=AuditAction.WRITE,
            resource=f"memory_entries.{event.namespace}",
            outcome=AuditOutcome.SUCCESS
        )

# Core Domain subscribes (replication monitoring)
class ReplicationMonitorHandler(EventHandler):
    def handle(self, event: MemoryEntryStored):
        # Check replication lag
        self.health_service.check_replication_lag(event.shard_id)
```

**When to use:**
- Cross-domain notifications
- Audit logging
- Analytics and reporting
- Non-critical updates
- Event sourcing

**Performance targets:**
- Event publish: <1ms
- Event delivery: <100ms (async)
- Eventual consistency window: <5s

---

### 3. Anti-Corruption Layer (ACL) Pattern

Protects domain integrity by translating between external and internal models:

```python
class SecurityACL:
    """Protects Security Domain from external systems"""

    def authorize_cluster_operation(
        self,
        external_user: ExternalUser,  # From external system
        cluster_id: str,
        operation: str
    ) -> bool:
        # Translate external user to domain Principal
        principal = self._translate_user(external_user)

        # Translate operation to domain Action
        action = self._translate_operation(operation)

        # Use pure domain service
        return self.authz_service.check_permission(
            principal,
            resource=Resource(
                resource_type=ResourceType.CLUSTER,
                resource_id=UUID(cluster_id)
            ),
            action=action
        )

    def _translate_user(self, external_user: ExternalUser) -> Principal:
        """Convert external user to domain Principal"""
        return Principal(
            principal_id=UUID(external_user.id),
            username=external_user.username,
            principal_type=self._map_user_type(external_user.type),
            roles=self._map_roles(external_user.roles)
        )

    def _translate_operation(self, operation: str) -> Action:
        """Convert operation string to domain Action"""
        mapping = {
            "read": Action.READ,
            "write": Action.WRITE,
            "delete": Action.DELETE,
            "execute": Action.EXECUTE
        }
        return mapping.get(operation.lower(), Action.READ)
```

**When to use:**
- Integrating with external systems
- Protecting domain models from external changes
- Translating between different ubiquitous languages
- Version compatibility (e.g., API v1 → domain, API v2 → domain)

---

## Domain Event Catalog

### Core Domain Events

| Event | Source | Consumers |
|-------|--------|-----------|
| `CoordinatorFailoverInitiated` | Core | Security (audit), Integration (monitoring) |
| `WorkerShardAdded` | Core | Intelligence (reindex), Memory (rebalance) |
| `ClusterTopologyChanged` | Core | Integration (route update), Security (audit) |
| `ReplicationLagExceeded` | Core | Integration (monitoring), Security (audit) |

### Intelligence Domain Events

| Event | Source | Consumers |
|-------|--------|-----------|
| `VectorIndexCreated` | Intelligence | Core (track resources), Security (audit) |
| `PatternLearned` | Intelligence | Memory (store pattern), Security (audit) |
| `TrajectoryCompleted` | Intelligence | Memory (analyze), Security (audit) |
| `EmbeddingStored` | Intelligence | Memory (update), Security (audit) |

### Memory Domain Events

| Event | Source | Consumers |
|-------|--------|-----------|
| `MemoryEntryStored` | Memory | Intelligence (index), Security (audit) |
| `MemoryEntryRetrieved` | Memory | Security (audit), Core (track access) |
| `NamespaceCreated` | Memory | Core (assign shard), Security (audit) |
| `KnowledgeGraphUpdated` | Memory | Intelligence (analyze), Security (audit) |

### Security Domain Events

| Event | Source | Consumers |
|-------|--------|-----------|
| `PrincipalAuthenticated` | Security | Integration (session), Core (audit) |
| `PermissionGranted` | Security | Core (update ACL), Integration (notify) |
| `SecurityViolationDetected` | Security | Integration (alert), Core (block IP) |
| `AuditLogCreated` | Security | Integration (monitoring) |

### Integration Domain Events

| Event | Source | Consumers |
|-------|--------|-----------|
| `MCPRequestReceived` | Integration | Security (audit), Core (route) |
| `APIEndpointCalled` | Integration | Security (audit), Core (metrics) |
| `LoadBalancerRouteChanged` | Integration | Core (update routing), Security (audit) |
| `IntegrationHealthChanged` | Integration | Core (failover), Security (alert) |

---

## Cross-Domain Workflows

### Workflow 1: Cluster Failover

```
1. Core Domain: Detect coordinator failure
   └→ Event: CoordinatorFailoverInitiated

2. Core Domain: Patroni promotes new primary
   └→ Update cluster topology

3. Integration Domain: Update API Gateway routes
   └→ Event: LoadBalancerRouteChanged

4. Security Domain: Audit the failover
   └→ Event: AuditLogCreated

5. Integration Domain: Notify monitoring
   └→ Send alert to Prometheus/Grafana
```

### Workflow 2: New Namespace Creation

```
1. Memory Domain: Create namespace
   └→ Event: NamespaceCreated

2. Core Domain: Calculate shard assignment
   └→ Assign to shard based on hash(namespace)

3. Intelligence Domain: Initialize vector index
   └→ Create HNSW index for namespace

4. Security Domain: Set default permissions
   └→ Grant permissions to creator

5. Security Domain: Audit creation
   └→ Event: AuditLogCreated
```

### Workflow 3: Pattern Learning

```
1. Intelligence Domain: Trajectory completed
   └→ Event: TrajectoryCompleted

2. Intelligence Domain: Extract pattern
   └→ Analyze trajectory steps

3. Memory Domain: Store pattern
   └→ Event: PatternLearned

4. Intelligence Domain: Update neural architecture (SONA)
   └→ Consolidate learning (EWC++)

5. Security Domain: Audit learning
   └→ Event: AuditLogCreated
```

---

## Domain Isolation Boundaries

### What Can Cross Boundaries

✅ **Domain Events** - All domains can publish and subscribe
✅ **Value Objects** - Immutable, safe to share (UUID, Timestamp, etc.)
✅ **Enums** - Shared enums (Action, ResourceType, etc.)
✅ **DTOs** - Data Transfer Objects for API responses

### What Cannot Cross Boundaries

❌ **Aggregates** - Never directly access another domain's aggregates
❌ **Entities** - Domain entities are private to the domain
❌ **Domain Services** - Access only via ACL or domain events
❌ **Repositories** - Infrastructure is domain-private

### Anti-Corruption Layer Enforcement

```python
# ❌ BAD: Direct access to another domain's repository
class IntegrationService:
    def __init__(self, memory_repo: MemoryEntryRepository):
        self.memory_repo = memory_repo  # VIOLATES BOUNDARY

    def get_memory(self, namespace: str, key: str):
        return self.memory_repo.get_entry(namespace, key)  # WRONG


# ✅ GOOD: Access via Anti-Corruption Layer
class IntegrationService:
    def __init__(self, integration_acl: IntegrationACL):
        self.acl = integration_acl  # RESPECTS BOUNDARY

    def get_memory(self, mcp_request: MCPRequest):
        return self.acl.execute_memory_query(mcp_request)  # CORRECT
```

---

## Performance Considerations

### Event Bus Performance

| Metric | Target | Notes |
|--------|--------|-------|
| Event publish | <1ms | Synchronous publish to bus |
| Event delivery | <100ms | Asynchronous delivery to handlers |
| Event persistence | <5ms | Optional event store |
| Subscriber count | <10 per event | Limit to prevent fan-out issues |

### Cross-Domain Call Latency

| Call Type | Target (p95) | Example |
|-----------|--------------|---------|
| ACL translation | <2ms | External model → domain model |
| Authorization check | <10ms | Security Domain via ACL |
| Vector search | <50ms | Intelligence Domain via ACL |
| Cluster status | <20ms | Core Domain via ACL |
| Audit log write | <5ms | Security Domain (async) |

---

## Summary

### Domain Maturity

| Domain | Status | Completion |
|--------|--------|------------|
| Core (Cluster) | ✅ Implemented | 3/5 (60%) |
| Intelligence (Vectors) | ✅ Implemented | 3/5 (60%) |
| Memory (Storage) | ✅ Implemented | 3/5 (60%) |
| Security (Auth) | 🚧 Design Phase | 4/5 (80%) |
| Integration (API) | 🚧 Design Phase | 5/5 (100%) |

### Communication Patterns

- **Synchronous**: Used for critical operations (auth, authorization)
- **Asynchronous**: Used for notifications and eventual consistency
- **ACL**: Used for all cross-domain interactions

### Next Steps

1. ✅ Complete Security Domain implementation (Week 1)
2. ✅ Complete Integration Domain implementation (Week 2)
3. ⏳ Wire domain event bus (Week 3)
4. ⏳ Integration testing (Week 3)
5. ⏳ Performance testing (Week 4)

---

**Version:** 1.0
**Last Updated:** 2026-02-11
**Author:** System Architecture Designer (Claude)
