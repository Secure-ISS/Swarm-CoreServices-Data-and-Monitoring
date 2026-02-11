# ADR-012: Security Domain Design

**Date:** 2026-02-11
**Status:** Accepted
**Deciders:** System Architecture Designer
**Related:** ADR-011 (Komodo MCP Integration), ADR-010 (Komodo MCP Integration)

---

## Context

The Distributed PostgreSQL Cluster requires comprehensive security controls:

1. **Multi-tenant access**: MCP users, application users, read-only users, and admins
2. **Data protection**: Sensitive data in memory entries and patterns
3. **Compliance**: Audit logging for all data access
4. **Threat protection**: SQL injection, unauthorized access, privilege escalation
5. **Cluster security**: Coordinator and worker node authentication
6. **Integration security**: Securing MCP and API endpoints

### Current State

- Basic PostgreSQL roles (MCP user, app user, admin)
- No formal authentication service
- No centralized authorization
- Limited audit logging
- No input validation framework
- Manual secret management

### Requirements

**Functional:**
- Multi-factor authentication support
- Role-Based Access Control (RBAC)
- Namespace-level permissions
- Comprehensive audit logging
- Secret rotation
- Input validation and sanitization

**Non-Functional:**
- Authentication latency <50ms (p95)
- Authorization check <10ms (p95)
- Audit log write <5ms (async)
- 99.99% availability
- Zero password storage in plaintext

---

## Decision

Implement a **Security Domain** as a bounded context with the following design:

### 1. Domain Model

```python
# Aggregates
class Principal(AggregateRoot):
    """Represents an authenticated entity"""
    principal_id: UUID
    principal_type: PrincipalType  # USER, SERVICE, AI_AGENT
    username: str
    roles: List[Role]
    credentials: EncryptedCredentials
    mfa_enabled: bool
    created_at: datetime
    last_login: Optional[datetime]

class Role(Entity):
    """Collection of permissions"""
    role_id: UUID
    name: str  # mcp_user, app_user, admin, readonly
    permissions: List[Permission]
    scope: SecurityScope  # GLOBAL, NAMESPACE, SHARD

class AuditLog(AggregateRoot):
    """Immutable audit record"""
    log_id: UUID
    principal_id: UUID
    action: AuditAction
    resource: Resource
    timestamp: datetime
    outcome: AuditOutcome  # SUCCESS, FAILURE, DENIED
    metadata: Dict[str, Any]
    ip_address: str
    session_id: UUID

# Value Objects
class Permission(ValueObject):
    resource_type: ResourceType  # TABLE, NAMESPACE, CLUSTER
    actions: List[Action]  # READ, WRITE, DELETE, EXECUTE
    constraints: Optional[Constraints]  # WHERE clauses, rate limits

class EncryptedCredentials(ValueObject):
    algorithm: str  # argon2, bcrypt
    hash: str
    salt: str
    iterations: int
```

### 2. Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Security Domain                           │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────┐     ┌──────────────────┐             │
│  │ Authentication   │     │ Authorization    │             │
│  │    Service       │     │    Service       │             │
│  │                  │     │                  │             │
│  │ - Login          │     │ - RBAC           │             │
│  │ - MFA            │     │ - Permissions    │             │
│  │ - Sessions       │     │ - Policies       │             │
│  └────────┬─────────┘     └─────────┬────────┘             │
│           │                         │                      │
│           └─────────┬───────────────┘                      │
│                     │                                      │
│           ┌─────────▼──────────┐                           │
│           │   Audit Service    │                           │
│           │                    │                           │
│           │ - Log all actions  │                           │
│           │ - Compliance       │                           │
│           │ - Queries          │                           │
│           └────────────────────┘                           │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │           Anti-Corruption Layer                      │  │
│  │  - Protects from external authentication systems    │  │
│  │  - Translates external roles to domain roles        │  │
│  │  - Validates external tokens                        │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 3. Key Services

**AuthenticationService:**
- Password-based authentication (argon2 hashing)
- Token-based sessions (JWT or opaque tokens)
- Multi-factor authentication (TOTP)
- Session management and expiration

**AuthorizationService:**
- RBAC policy enforcement
- Namespace-level permissions
- Dynamic policy evaluation
- Permission caching (10s TTL)

**AuditService:**
- Asynchronous audit logging
- Searchable audit trail
- Compliance reporting
- Real-time security monitoring

**EncryptionService:**
- Credential hashing (argon2)
- Secret encryption (AES-256-GCM)
- Secret rotation
- Key derivation

### 4. Predefined Roles

| Role | Permissions | Use Case |
|------|-------------|----------|
| **mcp_user** | READ all tables, WRITE memory_entries | AI agents via Komodo MCP |
| **app_user** | Full CRUD on application tables | Production applications |
| **readonly** | SELECT only on all tables | Analytics, reporting |
| **admin** | Superuser (all permissions) | DBAs, emergency access |
| **auditor** | READ audit_logs only | Security compliance |

### 5. Permission Model

```python
class NamespacePermission(Permission):
    """Fine-grained namespace access"""
    resource_type = ResourceType.NAMESPACE
    namespace: str
    actions: List[Action]

    # Example: MCP user can only access their namespace
    # Permission(
    #     namespace="agent-123",
    #     actions=[Action.READ, Action.WRITE]
    # )

class RateLimitConstraint(Constraints):
    """Rate limiting per principal"""
    max_requests_per_minute: int
    max_concurrent_connections: int

    # Example: MCP users limited to 1000 req/min
```

---

## Consequences

### Positive

1. **Centralized Security**: Single source of truth for authentication and authorization
2. **Fine-Grained Control**: Namespace-level permissions for multi-tenancy
3. **Audit Trail**: Complete audit log for compliance (GDPR, SOC2)
4. **Defense in Depth**: Multiple layers (authentication, authorization, audit)
5. **Scalable**: Can add new roles and permissions without code changes
6. **Testable**: Domain services can be unit tested independently

### Negative

1. **Additional Latency**: Auth checks add 10-50ms per request
2. **Complexity**: More moving parts to manage
3. **Performance**: Audit logging adds write load
4. **Operational**: Need to manage credentials, rotate secrets

### Risks and Mitigation

| Risk | Mitigation |
|------|------------|
| **Auth service outage** | Cache permissions locally (10s TTL), fail-safe to deny |
| **Performance degradation** | Cache authorization decisions, async audit logging |
| **Credential leaks** | Encrypt at rest, regular rotation, audit all access |
| **Privilege escalation** | Immutable permissions, audit role changes, regular reviews |

---

## Implementation Plan

### Phase 1: Core Security (Week 1)
- [ ] Implement Principal and Role aggregates
- [ ] Build EncryptionService with argon2
- [ ] Create AuthenticationService (password + tokens)
- [ ] Create AuthorizationService (RBAC)
- [ ] Repository implementations

### Phase 2: Audit Logging (Week 1)
- [ ] Implement AuditLog aggregate
- [ ] Create AuditService with async logging
- [ ] Set up audit log database schema
- [ ] Build audit query API

### Phase 3: Integration (Week 2)
- [ ] Build Anti-Corruption Layer
- [ ] Integrate with Core Domain (cluster operations)
- [ ] Integrate with Memory Domain (namespace access)
- [ ] Integrate with Integration Domain (MCP authentication)

### Phase 4: Testing (Week 2)
- [ ] Unit tests for all services
- [ ] Integration tests for auth flows
- [ ] Performance tests (latency targets)
- [ ] Security penetration testing

### Phase 5: Production Hardening (Week 3)
- [ ] Implement MFA (TOTP)
- [ ] Add rate limiting
- [ ] Secret rotation automation
- [ ] Security monitoring dashboards

---

## Alternatives Considered

### Alternative 1: PostgreSQL Row-Level Security (RLS)

**Pros:**
- Native PostgreSQL feature
- No application code needed
- Highly performant

**Cons:**
- Hard to test
- Limited to SQL-level policies
- No audit logging built-in
- Difficult to debug

**Verdict:** ❌ Rejected - Not flexible enough for multi-tenant requirements

### Alternative 2: External Auth Service (OAuth2, Auth0)

**Pros:**
- Battle-tested
- MFA included
- SSO support
- Managed service

**Cons:**
- External dependency
- Network latency
- Vendor lock-in
- Cost

**Verdict:** ❌ Rejected - Adds external dependency, but can integrate later via ACL

### Alternative 3: Embedded Policy Engine (OPA)

**Pros:**
- Declarative policies (Rego)
- Very flexible
- Industry standard

**Cons:**
- Additional service to run
- Learning curve (Rego syntax)
- Performance overhead

**Verdict:** ⚠️ Consider for future - Good for complex policies, overkill for now

---

## Security Considerations

### Threat Model

| Threat | Mitigation |
|--------|------------|
| **SQL Injection** | Input validation, parameterized queries, ORM/repository pattern |
| **Brute Force** | Rate limiting, account lockout, CAPTCHA |
| **Privilege Escalation** | Immutable permissions, audit all role changes |
| **Credential Theft** | Argon2 hashing, encrypted storage, MFA |
| **Session Hijacking** | Secure cookies, short session TTL, IP validation |
| **Insider Threat** | Audit logging, least privilege, separation of duties |

### Encryption Standards

- **Password Hashing**: Argon2id (OWASP recommended)
- **Token Encryption**: AES-256-GCM
- **TLS**: TLS 1.3 minimum for all connections
- **Secrets**: Stored in Docker Secrets (encrypted at rest)

### Compliance

- **GDPR**: Audit logs for data access, right to be forgotten
- **SOC2**: Comprehensive audit trail, access controls
- **HIPAA**: Encryption at rest and in transit (if handling PHI)

---

## Performance Targets

| Operation | Target (p95) | Notes |
|-----------|--------------|-------|
| Authentication | <50ms | Password hash verification |
| Authorization check | <10ms | With permission caching |
| Audit log write | <5ms | Asynchronous, non-blocking |
| Session validation | <5ms | Token validation |
| Permission cache hit | <1ms | In-memory cache |

---

## Monitoring and Observability

### Metrics

- Authentication success/failure rate
- Authorization denial rate
- Average auth latency
- Audit log write rate
- Failed login attempts per user
- Active sessions count

### Alerts

- **Critical**: >100 failed logins in 1 minute (brute force)
- **Critical**: Authorization service unavailable
- **Warning**: Auth latency >100ms (p95)
- **Warning**: Audit log backlog >1000 entries

### Dashboards

1. **Security Overview**: Auth success rate, active sessions, failed logins
2. **Audit Trail**: Recent actions, top users, top resources
3. **Performance**: Auth latency, permission cache hit rate

---

## Testing Strategy

### Unit Tests

```python
def test_authenticate_valid_credentials():
    auth_service = AuthenticationService()
    principal = auth_service.authenticate(
        username="test_user",
        password="correct_password"
    )
    assert principal.username == "test_user"

def test_check_permission_granted():
    authz_service = AuthorizationService()
    principal = create_test_principal(roles=[Role("mcp_user")])

    result = authz_service.check_permission(
        principal,
        resource=Resource(ResourceType.TABLE, "memory_entries"),
        action=Action.READ
    )

    assert result == True

def test_audit_log_creation():
    audit_service = AuditService()
    log = audit_service.log_action(
        principal=test_principal,
        action=AuditAction.QUERY,
        resource=test_resource,
        outcome=AuditOutcome.SUCCESS
    )

    assert log.log_id is not None
    assert log.timestamp is not None
```

### Integration Tests

```python
@pytest.mark.integration
def test_end_to_end_authentication_flow():
    # 1. User logs in
    auth_result = authenticate(username="test", password="test123")
    assert auth_result.success == True

    # 2. Check permission
    can_access = check_permission(
        principal=auth_result.principal,
        resource="memory_entries",
        action="READ"
    )
    assert can_access == True

    # 3. Verify audit log created
    logs = query_audit_logs(principal_id=auth_result.principal.id)
    assert len(logs) > 0
```

---

## Migration Path

### From Current State

```sql
-- Current: Basic PostgreSQL roles
CREATE ROLE mcp_user WITH LOGIN PASSWORD 'xxx';
GRANT SELECT, INSERT ON memory_entries TO mcp_user;

-- Future: Domain-managed principals
INSERT INTO principals (principal_id, username, principal_type)
VALUES (gen_random_uuid(), 'mcp_user', 'SERVICE');

INSERT INTO roles (role_id, name, scope)
VALUES (gen_random_uuid(), 'mcp_user', 'NAMESPACE');

INSERT INTO permissions (role_id, resource_type, actions, namespace)
VALUES (
    (SELECT role_id FROM roles WHERE name = 'mcp_user'),
    'TABLE',
    ARRAY['READ', 'WRITE'],
    'agent-*'
);
```

### Backward Compatibility

- Keep existing PostgreSQL roles during migration
- Map PostgreSQL roles to domain Principals
- Gradual rollout (read from domain, write to both)
- Decommission old roles after validation

---

## References

- [OWASP Authentication Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html)
- [NIST Digital Identity Guidelines](https://pages.nist.gov/800-63-3/)
- [PostgreSQL Row-Level Security](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
- Domain-Driven Design (Evans, 2003)

---

**Decision:** Accepted
**Date:** 2026-02-11
**Review Date:** 2026-05-11 (3 months)
