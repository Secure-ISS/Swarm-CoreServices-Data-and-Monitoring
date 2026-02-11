# Domain-Driven Design Architecture
## Distributed PostgreSQL Cluster

**Date:** 2026-02-11
**Version:** 1.0
**Status:** Active

---

## Executive Summary

This document defines the Domain-Driven Design (DDD) architecture for the Distributed PostgreSQL Cluster, organizing the system into 5 bounded contexts with clear boundaries, domain events, and anti-corruption layers.

### Domain Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     Domain Architecture                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │    Core      │  │ Intelligence │  │   Memory     │          │
│  │   Domain     │  │   Domain     │  │   Domain     │          │
│  │  (Cluster)   │  │  (RuVector)  │  │  (Storage)   │          │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘          │
│         │                 │                 │                   │
│         └─────────────────┼─────────────────┘                   │
│                           │                                     │
│         ┌─────────────────┴─────────────────┐                   │
│         │                                   │                   │
│  ┌──────▼────────┐                  ┌──────▼────────┐          │
│  │   Security    │                  │  Integration  │          │
│  │    Domain     │                  │    Domain     │          │
│  │ (Auth/Audit)  │                  │  (MCP/API)    │          │
│  └───────────────┘                  └───────────────┘          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Domain 1: Core Domain (Cluster Management)

**Status:** ✅ Implemented (3/5 complete)
**Bounded Context:** Distributed database cluster operations
**Ubiquitous Language:** Coordinator, Worker, Shard, Replication, Failover

### Responsibilities

- Cluster topology management (hierarchical-mesh)
- Coordinator and worker node lifecycle
- Citus distributed query execution
- Patroni high availability and failover
- etcd consensus and leader election
- Shard management and rebalancing

### Core Entities

```python
# Aggregates
class Cluster(AggregateRoot):
    cluster_id: UUID
    topology: TopologyType  # hierarchical-mesh
    coordinators: List[CoordinatorNode]
    worker_shards: List[WorkerShard]
    consensus_state: ConsensusState

class CoordinatorNode(Entity):
    node_id: UUID
    cluster_id: UUID
    is_primary: bool
    patroni_state: PatroniState
    citus_metadata: CitusMetadata

class WorkerShard(Entity):
    shard_id: UUID
    shard_number: int
    primary_node: WorkerNode
    standby_nodes: List[WorkerNode]
    replication_lag: timedelta

# Value Objects
class TopologyType(Enum):
    HIERARCHICAL = "hierarchical"
    MESH = "mesh"
    HIERARCHICAL_MESH = "hierarchical-mesh"
    RING = "ring"
    STAR = "star"

class ReplicationMode(Enum):
    SYNCHRONOUS = "sync"
    ASYNCHRONOUS = "async"
```

### Domain Events

```python
# Events published by Core Domain
class CoordinatorFailoverInitiated(DomainEvent):
    cluster_id: UUID
    failed_coordinator_id: UUID
    new_primary_id: UUID
    timestamp: datetime

class WorkerShardAdded(DomainEvent):
    cluster_id: UUID
    shard_id: UUID
    shard_number: int
    worker_nodes: List[UUID]

class ClusterTopologyChanged(DomainEvent):
    cluster_id: UUID
    old_topology: TopologyType
    new_topology: TopologyType
    reason: str

class ReplicationLagExceeded(DomainEvent):
    shard_id: UUID
    standby_node_id: UUID
    lag_ms: int
    threshold_ms: int
```

### Domain Services

```python
class ClusterOrchestratorService:
    """Coordinates cluster-wide operations"""

    def initiate_failover(
        self,
        cluster: Cluster,
        failed_node_id: UUID
    ) -> FailoverResult

    def add_worker_shard(
        self,
        cluster: Cluster,
        shard_config: ShardConfiguration
    ) -> WorkerShard

    def rebalance_cluster(
        self,
        cluster: Cluster,
        strategy: RebalanceStrategy
    ) -> RebalanceResult

class HealthMonitoringService:
    """Monitors node and cluster health"""

    def check_node_health(self, node_id: UUID) -> HealthStatus
    def detect_split_brain(self, cluster: Cluster) -> bool
    def measure_replication_lag(self, shard: WorkerShard) -> timedelta
```

### Repository Interfaces

```python
class ClusterRepository(ABC):
    def get_cluster(self, cluster_id: UUID) -> Cluster
    def save_cluster(self, cluster: Cluster) -> None
    def get_coordinator_nodes(self, cluster_id: UUID) -> List[CoordinatorNode]
    def get_worker_shards(self, cluster_id: UUID) -> List[WorkerShard]

class NodeHealthRepository(ABC):
    def record_health_check(self, node_id: UUID, status: HealthStatus) -> None
    def get_health_history(self, node_id: UUID, duration: timedelta) -> List[HealthStatus]
```

---

## Domain 2: Intelligence Domain (Vector Operations)

**Status:** ✅ Implemented (3/5 complete)
**Bounded Context:** RuVector intelligence and pattern learning
**Ubiquitous Language:** Embedding, HNSW, Trajectory, Pattern, SONA

### Responsibilities

- Vector embedding generation and storage
- HNSW index management across shards
- Pattern recognition and learning
- Trajectory tracking and analysis
- Neural architecture optimization (SONA)
- Mixture of Experts (MoE) routing

### Core Entities

```python
# Aggregates
class VectorIndex(AggregateRoot):
    index_id: UUID
    shard_id: UUID
    index_type: IndexType  # HNSW
    dimensions: int
    parameters: HNSWParameters
    statistics: IndexStatistics

class Pattern(AggregateRoot):
    pattern_id: UUID
    namespace: str
    pattern_type: str
    embeddings: List[float]
    metadata: Dict[str, Any]
    learned_at: datetime

class Trajectory(AggregateRoot):
    trajectory_id: UUID
    agent_id: UUID
    steps: List[TrajectoryStep]
    outcome: Outcome
    verdict: Verdict  # success/failure

# Value Objects
class HNSWParameters(ValueObject):
    m: int = 16  # number of connections
    ef_construction: int = 200
    ef_search: int = 100

class Embedding(ValueObject):
    vector: List[float]
    dimensions: int

    def cosine_similarity(self, other: 'Embedding') -> float:
        """Calculate cosine similarity"""
```

### Domain Events

```python
class VectorIndexCreated(DomainEvent):
    index_id: UUID
    shard_id: UUID
    dimensions: int
    parameters: HNSWParameters

class PatternLearned(DomainEvent):
    pattern_id: UUID
    namespace: str
    pattern_type: str
    confidence: float

class TrajectoryCompleted(DomainEvent):
    trajectory_id: UUID
    agent_id: UUID
    steps_count: int
    outcome: Outcome
    verdict: Verdict

class EmbeddingStored(DomainEvent):
    embedding_id: UUID
    namespace: str
    dimensions: int
    shard_id: UUID
```

### Domain Services

```python
class VectorSearchService:
    """Distributed vector similarity search"""

    def search_similar(
        self,
        query_embedding: Embedding,
        namespace: Optional[str],
        limit: int,
        min_similarity: float
    ) -> List[SimilarityResult]

    def parallel_shard_search(
        self,
        query_embedding: Embedding,
        shard_ids: List[UUID]
    ) -> List[SimilarityResult]

class PatternLearningService:
    """Self-learning pattern recognition"""

    def extract_pattern(
        self,
        trajectories: List[Trajectory]
    ) -> Pattern

    def consolidate_patterns(
        self,
        patterns: List[Pattern]
    ) -> ConsolidatedPattern  # EWC++ prevents forgetting

class SOANOptimizationService:
    """Self-Optimizing Neural Architecture"""

    def adapt_architecture(
        self,
        performance_metrics: PerformanceMetrics
    ) -> AdaptationResult  # <0.05ms adaptation
```

### Repository Interfaces

```python
class VectorIndexRepository(ABC):
    def get_index(self, index_id: UUID) -> VectorIndex
    def get_shard_indexes(self, shard_id: UUID) -> List[VectorIndex]
    def save_index(self, index: VectorIndex) -> None

class PatternRepository(ABC):
    def get_pattern(self, pattern_id: UUID) -> Pattern
    def search_patterns(self, namespace: str) -> List[Pattern]
    def save_pattern(self, pattern: Pattern) -> None

class TrajectoryRepository(ABC):
    def get_trajectory(self, trajectory_id: UUID) -> Trajectory
    def get_agent_trajectories(self, agent_id: UUID) -> List[Trajectory]
    def save_trajectory(self, trajectory: Trajectory) -> None
```

---

## Domain 3: Memory Domain (Data Storage)

**Status:** ✅ Implemented (3/5 complete)
**Bounded Context:** Persistent data storage and retrieval
**Ubiquitous Language:** MemoryEntry, Namespace, Metadata, Knowledge Graph

### Responsibilities

- Memory entry storage and retrieval
- Namespace-based organization
- Metadata management
- Knowledge graph operations
- Cross-database coordination (project + shared)
- Connection pooling

### Core Entities

```python
# Aggregates
class MemoryEntry(AggregateRoot):
    entry_id: UUID
    namespace: str
    key: str
    value: str
    embedding: Optional[Embedding]
    metadata: Dict[str, Any]
    created_at: datetime
    updated_at: datetime

class Namespace(AggregateRoot):
    namespace_id: UUID
    name: str
    shard_id: UUID  # hash-based sharding
    entry_count: int
    total_size_bytes: int

class KnowledgeGraph(AggregateRoot):
    graph_id: UUID
    namespace: str
    nodes: List[GraphNode]
    edges: List[GraphEdge]

# Value Objects
class GraphNode(ValueObject):
    node_id: UUID
    node_type: str
    embedding: Embedding
    properties: Dict[str, Any]

class GraphEdge(ValueObject):
    edge_id: UUID
    source_id: UUID
    target_id: UUID
    edge_type: str
    weight: float
```

### Domain Events

```python
class MemoryEntryStored(DomainEvent):
    entry_id: UUID
    namespace: str
    key: str
    shard_id: UUID

class MemoryEntryRetrieved(DomainEvent):
    entry_id: UUID
    namespace: str
    access_time: datetime

class NamespaceCreated(DomainEvent):
    namespace_id: UUID
    name: str
    shard_id: UUID

class KnowledgeGraphUpdated(DomainEvent):
    graph_id: UUID
    namespace: str
    nodes_added: int
    edges_added: int
```

### Domain Services

```python
class MemoryStorageService:
    """Cross-database memory operations"""

    def store_memory(
        self,
        namespace: str,
        key: str,
        value: str,
        embedding: Optional[Embedding],
        metadata: Dict[str, Any]
    ) -> MemoryEntry

    def retrieve_memory(
        self,
        namespace: str,
        key: str
    ) -> Optional[MemoryEntry]

    def search_memories(
        self,
        namespace: str,
        query_embedding: Embedding
    ) -> List[MemoryEntry]

class NamespaceShardingService:
    """Determines shard placement for namespaces"""

    def calculate_shard(self, namespace: str) -> UUID
    def rebalance_namespace(self, namespace: Namespace) -> RebalanceResult

class ConnectionPoolService:
    """Manages database connection pools"""

    def get_project_connection(self) -> Connection
    def get_shared_connection(self) -> Connection
    def health_check(self) -> PoolHealthStatus
```

### Repository Interfaces

```python
class MemoryEntryRepository(ABC):
    def get_entry(self, namespace: str, key: str) -> Optional[MemoryEntry]
    def save_entry(self, entry: MemoryEntry) -> None
    def search_entries(self, namespace: str, query: str) -> List[MemoryEntry]

class NamespaceRepository(ABC):
    def get_namespace(self, name: str) -> Namespace
    def save_namespace(self, namespace: Namespace) -> None
    def list_namespaces(self) -> List[Namespace]

class KnowledgeGraphRepository(ABC):
    def get_graph(self, namespace: str) -> KnowledgeGraph
    def save_graph(self, graph: KnowledgeGraph) -> None
    def query_graph(self, cypher_query: str) -> List[Dict[str, Any]]
```

---

## Domain 4: Security Domain (Authentication & Authorization)

**Status:** 🚧 Design Phase (4/5 - new domain)
**Bounded Context:** Security, authentication, authorization, and audit
**Ubiquitous Language:** Principal, Permission, Role, AuditLog, Credential

### Responsibilities

- User authentication and session management
- Role-based access control (RBAC)
- Database user management (MCP, App, Admin, Read-only)
- Audit logging and compliance
- Encryption and secret management
- Network security and TLS/SSL
- Input validation and SQL injection prevention

### Core Entities

```python
# Aggregates
class Principal(AggregateRoot):
    principal_id: UUID
    principal_type: PrincipalType  # USER, SERVICE, AI_AGENT
    username: str
    roles: List[Role]
    credentials: EncryptedCredentials
    created_at: datetime
    last_login: Optional[datetime]

class Role(Entity):
    role_id: UUID
    name: str
    permissions: List[Permission]
    scope: SecurityScope  # GLOBAL, NAMESPACE, SHARD

class AuditLog(AggregateRoot):
    log_id: UUID
    principal_id: UUID
    action: AuditAction
    resource: Resource
    timestamp: datetime
    outcome: AuditOutcome
    metadata: Dict[str, Any]

# Value Objects
class Permission(ValueObject):
    resource_type: ResourceType
    actions: List[Action]  # READ, WRITE, DELETE, EXECUTE

class PrincipalType(Enum):
    USER = "user"
    SERVICE = "service"
    AI_AGENT = "ai_agent"

class AuditAction(Enum):
    LOGIN = "login"
    QUERY = "query"
    WRITE = "write"
    DDL = "ddl"
    FAILOVER = "failover"

class SecurityScope(Enum):
    GLOBAL = "global"
    NAMESPACE = "namespace"
    SHARD = "shard"
```

### Domain Events

```python
class PrincipalAuthenticated(DomainEvent):
    principal_id: UUID
    authentication_method: str
    success: bool
    ip_address: str

class PermissionGranted(DomainEvent):
    principal_id: UUID
    permission: Permission
    granted_by: UUID

class PermissionRevoked(DomainEvent):
    principal_id: UUID
    permission: Permission
    revoked_by: UUID

class SecurityViolationDetected(DomainEvent):
    principal_id: UUID
    violation_type: ViolationType
    severity: Severity
    resource: Resource

class AuditLogCreated(DomainEvent):
    log_id: UUID
    principal_id: UUID
    action: AuditAction
    resource: Resource
```

### Domain Services

```python
class AuthenticationService:
    """Handles principal authentication"""

    def authenticate(
        self,
        username: str,
        password: str,
        auth_method: AuthMethod
    ) -> AuthenticationResult

    def create_session(
        self,
        principal: Principal,
        ttl: timedelta
    ) -> Session

    def validate_token(
        self,
        token: str
    ) -> Optional[Principal]

class AuthorizationService:
    """Checks permissions and enforces policies"""

    def check_permission(
        self,
        principal: Principal,
        resource: Resource,
        action: Action
    ) -> bool

    def grant_permission(
        self,
        principal: Principal,
        permission: Permission,
        granted_by: Principal
    ) -> None

    def enforce_rbac(
        self,
        principal: Principal,
        operation: Operation
    ) -> AuthorizationResult

class AuditService:
    """Records and queries audit logs"""

    def log_action(
        self,
        principal: Principal,
        action: AuditAction,
        resource: Resource,
        outcome: AuditOutcome
    ) -> AuditLog

    def query_logs(
        self,
        filters: AuditFilters,
        time_range: TimeRange
    ) -> List[AuditLog]

class EncryptionService:
    """Manages encryption and secret storage"""

    def encrypt_credential(
        self,
        plaintext: str
    ) -> EncryptedCredentials

    def decrypt_credential(
        self,
        encrypted: EncryptedCredentials
    ) -> str

    def rotate_secrets(
        self,
        principal: Principal
    ) -> RotationResult
```

### Repository Interfaces

```python
class PrincipalRepository(ABC):
    def get_principal(self, principal_id: UUID) -> Principal
    def get_by_username(self, username: str) -> Optional[Principal]
    def save_principal(self, principal: Principal) -> None
    def list_principals(self) -> List[Principal]

class RoleRepository(ABC):
    def get_role(self, role_id: UUID) -> Role
    def get_by_name(self, name: str) -> Optional[Role]
    def save_role(self, role: Role) -> None

class AuditLogRepository(ABC):
    def save_log(self, log: AuditLog) -> None
    def query_logs(self, filters: AuditFilters) -> List[AuditLog]
    def get_logs_by_principal(self, principal_id: UUID) -> List[AuditLog]
```

### Anti-Corruption Layer

```python
class SecurityAdapter:
    """Isolates Security Domain from external systems"""

    def __init__(
        self,
        core_cluster_repo: ClusterRepository,
        memory_entry_repo: MemoryEntryRepository
    ):
        self.core_cluster_repo = core_cluster_repo
        self.memory_entry_repo = memory_entry_repo

    def authorize_cluster_operation(
        self,
        principal: Principal,
        cluster_id: UUID,
        operation: ClusterOperation
    ) -> bool:
        """Check if principal can perform cluster operation"""

    def authorize_memory_access(
        self,
        principal: Principal,
        namespace: str,
        action: Action
    ) -> bool:
        """Check if principal can access namespace"""
```

---

## Domain 5: Integration Domain (External Systems)

**Status:** 🚧 Design Phase (5/5 - new domain)
**Bounded Context:** External system integration and API management
**Ubiquitous Language:** MCP, Endpoint, Protocol, Adapter, Gateway

### Responsibilities

- Komodo MCP server integration
- External API management
- Protocol translation (PostgreSQL wire protocol, HTTP, gRPC)
- HAProxy and PgBouncer coordination
- Load balancing and routing
- Client SDK support
- Monitoring and observability integration

### Core Entities

```python
# Aggregates
class MCPIntegration(AggregateRoot):
    integration_id: UUID
    server_name: str
    protocol: Protocol
    endpoint: Endpoint
    configuration: MCPConfiguration
    status: IntegrationStatus

class APIGateway(AggregateRoot):
    gateway_id: UUID
    routes: List[Route]
    load_balancer: LoadBalancerConfig
    health_checks: List[HealthCheck]

class ExternalAdapter(AggregateRoot):
    adapter_id: UUID
    adapter_type: AdapterType
    source_system: str
    target_domain: DomainType
    mapping_rules: List[MappingRule]

# Value Objects
class Endpoint(ValueObject):
    protocol: Protocol
    host: str
    port: int
    path: str

    def to_url(self) -> str:
        return f"{self.protocol}://{self.host}:{self.port}{self.path}"

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
```

### Domain Events

```python
class MCPConnectionEstablished(DomainEvent):
    integration_id: UUID
    client_id: str
    timestamp: datetime

class MCPRequestReceived(DomainEvent):
    integration_id: UUID
    request_id: UUID
    operation: str
    parameters: Dict[str, Any]

class APIEndpointCalled(DomainEvent):
    gateway_id: UUID
    route: str
    method: str
    response_time_ms: int
    status_code: int

class LoadBalancerRouteChanged(DomainEvent):
    gateway_id: UUID
    old_backend: str
    new_backend: str
    reason: str

class IntegrationHealthChanged(DomainEvent):
    integration_id: UUID
    old_status: IntegrationStatus
    new_status: IntegrationStatus
    details: str
```

### Domain Services

```python
class MCPIntegrationService:
    """Manages Komodo MCP server integration"""

    def handle_mcp_request(
        self,
        request: MCPRequest
    ) -> MCPResponse

    def translate_to_sql(
        self,
        mcp_operation: MCPOperation
    ) -> SQLQuery

    def execute_on_cluster(
        self,
        sql_query: SQLQuery,
        principal: Principal
    ) -> QueryResult

class APIGatewayService:
    """Manages API gateway and routing"""

    def route_request(
        self,
        request: APIRequest
    ) -> Route

    def select_backend(
        self,
        route: Route,
        strategy: LoadBalanceStrategy
    ) -> Backend

    def health_check_backend(
        self,
        backend: Backend
    ) -> HealthStatus

class ProtocolAdapterService:
    """Translates between protocols"""

    def translate_request(
        self,
        source_protocol: Protocol,
        target_protocol: Protocol,
        request: Request
    ) -> TranslatedRequest

    def translate_response(
        self,
        source_protocol: Protocol,
        target_protocol: Protocol,
        response: Response
    ) -> TranslatedResponse

class MonitoringIntegrationService:
    """Integrates with monitoring systems"""

    def export_metrics(
        self,
        metrics: Metrics
    ) -> None

    def export_traces(
        self,
        traces: List[Trace]
    ) -> None

    def export_logs(
        self,
        logs: List[LogEntry]
    ) -> None
```

### Repository Interfaces

```python
class MCPIntegrationRepository(ABC):
    def get_integration(self, integration_id: UUID) -> MCPIntegration
    def save_integration(self, integration: MCPIntegration) -> None
    def list_active_integrations(self) -> List[MCPIntegration]

class APIGatewayRepository(ABC):
    def get_gateway(self, gateway_id: UUID) -> APIGateway
    def save_gateway(self, gateway: APIGateway) -> None
    def get_route(self, path: str) -> Optional[Route]

class ExternalAdapterRepository(ABC):
    def get_adapter(self, adapter_id: UUID) -> ExternalAdapter
    def save_adapter(self, adapter: ExternalAdapter) -> None
    def get_by_type(self, adapter_type: AdapterType) -> List[ExternalAdapter]
```

### Anti-Corruption Layer

```python
class IntegrationAdapter:
    """Isolates Integration Domain from Core/Memory/Intelligence domains"""

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

    def execute_cluster_query(
        self,
        mcp_request: MCPRequest,
        principal: Principal
    ) -> MCPResponse:
        """Execute MCP request on cluster with authorization"""

        # Authorize
        if not self.auth_service.check_permission(
            principal,
            resource=mcp_request.target_table,
            action=Action.READ
        ):
            raise UnauthorizedException()

        # Translate MCP → SQL
        sql_query = self._translate_mcp_to_sql(mcp_request)

        # Execute via cluster service
        result = self.cluster_service.execute_query(sql_query)

        # Translate result → MCP response
        return self._translate_result_to_mcp(result)

    def search_memories(
        self,
        mcp_request: MCPRequest,
        principal: Principal
    ) -> MCPResponse:
        """Execute vector search via MCP"""

        # Authorize namespace access
        namespace = mcp_request.parameters.get("namespace")
        if not self.auth_service.authorize_memory_access(
            principal,
            namespace,
            Action.READ
        ):
            raise UnauthorizedException()

        # Execute search
        query_embedding = mcp_request.parameters.get("embedding")
        results = self.vector_service.search_similar(
            query_embedding=Embedding(query_embedding),
            namespace=namespace,
            limit=mcp_request.parameters.get("limit", 10),
            min_similarity=mcp_request.parameters.get("min_similarity", 0.7)
        )

        # Translate to MCP response
        return self._translate_search_results_to_mcp(results)
```

---

## Domain Relationships and Boundaries

### Domain Interaction Map

```
┌─────────────────────────────────────────────────────────────────┐
│                        Domain Interactions                       │
└─────────────────────────────────────────────────────────────────┘

Integration Domain (Gateway)
    │
    ├─→ Security Domain (Authorize)
    │        │
    │        ├─→ Core Domain (Cluster Operations)
    │        │        │
    │        │        └─→ Memory Domain (Store/Retrieve)
    │        │                 │
    │        └─→ Intelligence Domain (Vector Search)
    │                     │
    └─────────────────────┘


Event Flow:
  MCPRequestReceived → PrincipalAuthenticated → ClusterQueryExecuted
                                              ↓
                                        MemoryEntryStored
                                              ↓
                                        VectorIndexUpdated
                                              ↓
                                        AuditLogCreated
```

### Bounded Context Relationships

| Source Domain | Target Domain | Relationship Type | Integration Pattern |
|--------------|--------------|-------------------|---------------------|
| Integration | Security | Customer-Supplier | Anti-Corruption Layer |
| Integration | Core | Customer-Supplier | Anti-Corruption Layer |
| Integration | Memory | Customer-Supplier | Anti-Corruption Layer |
| Integration | Intelligence | Customer-Supplier | Anti-Corruption Layer |
| Security | Core | Conformist | Shared Kernel (minimal) |
| Security | Memory | Conformist | Shared Kernel (minimal) |
| Core | Memory | Partnership | Domain Events |
| Core | Intelligence | Partnership | Domain Events |
| Memory | Intelligence | Partnership | Shared Database |

### Shared Kernel

Minimal shared concepts across domains:

```python
# Shared Value Objects (immutable, safe to share)
class UUID(ValueObject):
    value: str

class Timestamp(ValueObject):
    value: datetime

class Namespace(ValueObject):
    name: str

    def validate(self) -> bool:
        return bool(re.match(r'^[a-z0-9-_]+$', self.name))

# Shared Enums
class Action(Enum):
    READ = "read"
    WRITE = "write"
    DELETE = "delete"
    EXECUTE = "execute"
```

---

## Domain Events and Event Storming

### Event Flow Choreography

```
1. User initiates MCP request
   └→ MCPRequestReceived (Integration)

2. Authentication check
   └→ PrincipalAuthenticated (Security)

3. Authorization check
   └→ PermissionChecked (Security)

4. Query routing
   └→ ClusterQueryRouted (Core)

5. Shard execution
   └→ ShardQueryExecuted (Core)

6. Memory storage
   └→ MemoryEntryStored (Memory)

7. Vector indexing
   └→ VectorIndexUpdated (Intelligence)

8. Pattern learning
   └→ PatternLearned (Intelligence)

9. Audit logging
   └→ AuditLogCreated (Security)

10. Response sent
    └→ MCPResponseSent (Integration)
```

### Event Bus Architecture

```python
class DomainEventBus:
    """Publishes and subscribes to domain events"""

    subscribers: Dict[Type[DomainEvent], List[EventHandler]]

    def publish(self, event: DomainEvent) -> None:
        """Publish event to all subscribers"""

    def subscribe(
        self,
        event_type: Type[DomainEvent],
        handler: EventHandler
    ) -> None:
        """Subscribe handler to event type"""

# Example subscription
event_bus = DomainEventBus()
event_bus.subscribe(
    MemoryEntryStored,
    VectorIndexingHandler()  # Intelligence Domain
)
event_bus.subscribe(
    MemoryEntryStored,
    AuditLoggingHandler()  # Security Domain
)
```

---

## Anti-Corruption Layers (ACL)

### Purpose

Anti-Corruption Layers protect domain integrity by:
- Translating external concepts to domain models
- Preventing external changes from breaking the domain
- Isolating domain logic from infrastructure
- Enabling independent domain evolution

### ACL for Security Domain

```python
class SecurityACL:
    """Protects Security Domain from external systems"""

    def __init__(
        self,
        auth_service: AuthenticationService,
        authz_service: AuthorizationService
    ):
        self.auth_service = auth_service
        self.authz_service = authz_service

    def authorize_cluster_operation(
        self,
        external_user: ExternalUser,
        cluster_id: str,
        operation: str
    ) -> bool:
        """Translate external authorization to domain model"""

        # Translate external user to domain Principal
        principal = self._translate_user(external_user)

        # Translate operation to domain Action
        action = self._translate_operation(operation)

        # Use domain service
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

    def _translate_operation(self, operation: str) -> Action:
        """Convert operation string to domain Action"""
```

### ACL for Integration Domain

```python
class IntegrationACL:
    """Protects Integration Domain from database specifics"""

    def __init__(
        self,
        mcp_service: MCPIntegrationService,
        gateway_service: APIGatewayService
    ):
        self.mcp_service = mcp_service
        self.gateway_service = gateway_service

    def handle_postgres_query(
        self,
        pg_query: PostgreSQLQuery
    ) -> PostgreSQLResult:
        """Translate PostgreSQL query to domain operations"""

        # Convert to domain model
        api_request = self._translate_pg_to_api(pg_query)

        # Route via gateway
        route = self.gateway_service.route_request(api_request)

        # Execute
        result = self._execute_route(route, api_request)

        # Translate back
        return self._translate_api_to_pg(result)

    def handle_mcp_request(
        self,
        mcp_request: ExternalMCPRequest
    ) -> ExternalMCPResponse:
        """Translate MCP request to domain operations"""

        # Convert to domain model
        domain_request = self._translate_mcp_request(mcp_request)

        # Execute via service
        domain_response = self.mcp_service.handle_mcp_request(domain_request)

        # Translate back
        return self._translate_mcp_response(domain_response)
```

---

## Implementation Checklist

### Domain 1: Core Domain ✅
- [x] Cluster aggregate
- [x] Coordinator and worker entities
- [x] Topology value objects
- [x] Failover domain events
- [x] Cluster orchestrator service
- [x] Repository interfaces

### Domain 2: Intelligence Domain ✅
- [x] VectorIndex aggregate
- [x] Pattern and trajectory entities
- [x] HNSW value objects
- [x] Pattern learning events
- [x] Vector search service
- [x] Repository interfaces

### Domain 3: Memory Domain ✅
- [x] MemoryEntry aggregate
- [x] Namespace entity
- [x] Graph value objects
- [x] Storage events
- [x] Memory storage service
- [x] Repository interfaces

### Domain 4: Security Domain 🚧
- [ ] Principal aggregate
- [ ] Role and permission entities
- [ ] Audit log aggregate
- [ ] Authentication events
- [ ] Authorization service
- [ ] Encryption service
- [ ] Repository interfaces
- [ ] Anti-Corruption Layer

### Domain 5: Integration Domain 🚧
- [ ] MCPIntegration aggregate
- [ ] APIGateway entity
- [ ] Protocol value objects
- [ ] Integration events
- [ ] MCP integration service
- [ ] Protocol adapter service
- [ ] Repository interfaces
- [ ] Anti-Corruption Layer

---

## Next Steps

1. **Security Domain Implementation** (Week 1)
   - Implement Principal and Role aggregates
   - Build authentication service
   - Build authorization service with RBAC
   - Create audit logging infrastructure
   - Implement encryption service
   - Build anti-corruption layer

2. **Integration Domain Implementation** (Week 2)
   - Implement MCPIntegration aggregate
   - Build MCP protocol adapter
   - Create API gateway routing
   - Implement load balancing logic
   - Build anti-corruption layer
   - Integrate with monitoring systems

3. **Domain Integration** (Week 3)
   - Wire domain event bus
   - Test cross-domain event flows
   - Validate anti-corruption layers
   - Performance testing
   - Security audit

4. **Documentation** (Week 4)
   - Complete ADRs for Security and Integration domains
   - Update architecture diagrams
   - Create domain interaction sequence diagrams
   - Write operational runbooks

---

**Version:** 1.0
**Status:** Active
**Last Updated:** 2026-02-11
**Author:** System Architecture Designer (Claude)
