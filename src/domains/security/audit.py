"""Security Audit Logging

Provides comprehensive security event logging for audit trails and
compliance requirements.
"""

# Standard library imports
import json
import logging
from dataclasses import asdict, dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any, Dict, Optional

logger = logging.getLogger(__name__)


class SecurityEventType(Enum):
    """Types of security events."""

    # Authentication
    AUTH_SUCCESS = "auth_success"
    AUTH_FAILURE = "auth_failure"
    AUTH_LOCKOUT = "auth_lockout"

    # Authorization
    AUTHZ_GRANTED = "authz_granted"
    AUTHZ_DENIED = "authz_denied"
    PRIVILEGE_ESCALATION = "privilege_escalation"

    # Data Access
    DATA_ACCESS = "data_access"
    DATA_EXPORT = "data_export"
    DATA_DELETION = "data_deletion"
    SENSITIVE_DATA_ACCESS = "sensitive_data_access"

    # Credential Management
    CREDENTIAL_CREATED = "credential_created"
    CREDENTIAL_ROTATED = "credential_rotated"
    CREDENTIAL_DELETED = "credential_deleted"
    CREDENTIAL_EXPOSED = "credential_exposed"

    # Input Validation
    SQL_INJECTION_ATTEMPT = "sql_injection_attempt"
    PATH_TRAVERSAL_ATTEMPT = "path_traversal_attempt"
    INVALID_INPUT = "invalid_input"

    # Security Configuration
    CONFIG_CHANGED = "config_changed"
    SECURITY_POLICY_CHANGED = "security_policy_changed"
    TLS_ERROR = "tls_error"

    # Incidents
    SECURITY_INCIDENT = "security_incident"
    BREACH_DETECTED = "breach_detected"
    ANOMALY_DETECTED = "anomaly_detected"


class SecurityEventSeverity(Enum):
    """Severity levels for security events."""

    DEBUG = "debug"
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"
    CRITICAL = "critical"


@dataclass
class SecurityEvent:
    """Represents a security event."""

    event_type: SecurityEventType
    severity: SecurityEventSeverity
    timestamp: datetime
    user: Optional[str] = None
    source_ip: Optional[str] = None
    resource: Optional[str] = None
    action: Optional[str] = None
    result: Optional[str] = None
    details: Dict[str, Any] = field(default_factory=dict)
    metadata: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary with JSON-serializable values."""
        data = asdict(self)
        data["event_type"] = self.event_type.value
        data["severity"] = self.severity.value
        data["timestamp"] = self.timestamp.isoformat()
        return data

    def to_json(self) -> str:
        """Convert to JSON string."""
        return json.dumps(self.to_dict(), indent=2)


class SecurityAuditor:
    """Security event auditor with structured logging.

    Features:
    - Structured security event logging
    - Multiple output formats (JSON, syslog)
    - Severity-based filtering
    - Compliance-ready audit trails
    - SIEM integration support
    """

    def __init__(
        self,
        logger_name: str = "security_audit",
        min_severity: SecurityEventSeverity = SecurityEventSeverity.INFO,
        output_format: str = "json",
    ):
        """Initialize security auditor.

        Args:
            logger_name: Logger name for audit events
            min_severity: Minimum severity to log
            output_format: Output format (json, text)
        """
        self.audit_logger = logging.getLogger(logger_name)
        self.min_severity = min_severity
        self.output_format = output_format

        # Configure audit logger
        if not self.audit_logger.handlers:
            handler = logging.StreamHandler()
            formatter = logging.Formatter("%(asctime)s - %(name)s - %(levelname)s - %(message)s")
            handler.setFormatter(formatter)
            self.audit_logger.addHandler(handler)
            self.audit_logger.setLevel(logging.INFO)

    def log_event(self, event: SecurityEvent) -> None:
        """Log a security event.

        Args:
            event: SecurityEvent to log
        """
        # Check severity threshold
        severity_order = {
            SecurityEventSeverity.DEBUG: 0,
            SecurityEventSeverity.INFO: 1,
            SecurityEventSeverity.WARNING: 2,
            SecurityEventSeverity.ERROR: 3,
            SecurityEventSeverity.CRITICAL: 4,
        }

        if severity_order[event.severity] < severity_order[self.min_severity]:
            return

        # Format message
        if self.output_format == "json":
            message = event.to_json()
        else:
            message = self._format_text_message(event)

        # Log at appropriate level
        log_level = self._get_log_level(event.severity)
        self.audit_logger.log(log_level, message)

    def log_auth_success(
        self, user: str, source_ip: Optional[str] = None, details: Optional[Dict[str, Any]] = None
    ) -> None:
        """Log successful authentication."""
        event = SecurityEvent(
            event_type=SecurityEventType.AUTH_SUCCESS,
            severity=SecurityEventSeverity.INFO,
            timestamp=datetime.utcnow(),
            user=user,
            source_ip=source_ip,
            action="authenticate",
            result="success",
            details=details or {},
        )
        self.log_event(event)

    def log_auth_failure(
        self,
        user: str,
        source_ip: Optional[str] = None,
        reason: Optional[str] = None,
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        """Log failed authentication."""
        event = SecurityEvent(
            event_type=SecurityEventType.AUTH_FAILURE,
            severity=SecurityEventSeverity.WARNING,
            timestamp=datetime.utcnow(),
            user=user,
            source_ip=source_ip,
            action="authenticate",
            result="failure",
            details=details or {},
        )
        if reason:
            event.details["reason"] = reason
        self.log_event(event)

    def log_authz_denied(
        self,
        user: str,
        resource: str,
        action: str,
        reason: Optional[str] = None,
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        """Log authorization denial."""
        event = SecurityEvent(
            event_type=SecurityEventType.AUTHZ_DENIED,
            severity=SecurityEventSeverity.WARNING,
            timestamp=datetime.utcnow(),
            user=user,
            resource=resource,
            action=action,
            result="denied",
            details=details or {},
        )
        if reason:
            event.details["reason"] = reason
        self.log_event(event)

    def log_sql_injection_attempt(
        self,
        user: Optional[str] = None,
        source_ip: Optional[str] = None,
        query: Optional[str] = None,
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        """Log SQL injection attempt."""
        event = SecurityEvent(
            event_type=SecurityEventType.SQL_INJECTION_ATTEMPT,
            severity=SecurityEventSeverity.CRITICAL,
            timestamp=datetime.utcnow(),
            user=user,
            source_ip=source_ip,
            action="sql_query",
            result="blocked",
            details=details or {},
        )
        if query:
            # Don't log full query for security
            event.details["query_length"] = len(query)
            event.details["query_preview"] = query[:50] + "..."
        self.log_event(event)

    def log_path_traversal_attempt(
        self,
        user: Optional[str] = None,
        path: Optional[str] = None,
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        """Log path traversal attempt."""
        event = SecurityEvent(
            event_type=SecurityEventType.PATH_TRAVERSAL_ATTEMPT,
            severity=SecurityEventSeverity.CRITICAL,
            timestamp=datetime.utcnow(),
            user=user,
            action="file_access",
            result="blocked",
            details=details or {},
        )
        if path:
            event.details["requested_path"] = path
        self.log_event(event)

    def log_credential_rotated(
        self,
        credential_key: str,
        user: Optional[str] = None,
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        """Log credential rotation."""
        event = SecurityEvent(
            event_type=SecurityEventType.CREDENTIAL_ROTATED,
            severity=SecurityEventSeverity.INFO,
            timestamp=datetime.utcnow(),
            user=user,
            resource=credential_key,
            action="rotate",
            result="success",
            details=details or {},
        )
        self.log_event(event)

    def log_security_incident(
        self,
        incident_type: str,
        description: str,
        user: Optional[str] = None,
        source_ip: Optional[str] = None,
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        """Log security incident."""
        event = SecurityEvent(
            event_type=SecurityEventType.SECURITY_INCIDENT,
            severity=SecurityEventSeverity.CRITICAL,
            timestamp=datetime.utcnow(),
            user=user,
            source_ip=source_ip,
            action=incident_type,
            result="incident",
            details=details or {},
        )
        event.details["description"] = description
        self.log_event(event)

    @staticmethod
    def _format_text_message(event: SecurityEvent) -> str:
        """Format event as text message."""
        parts = [
            f"[{event.event_type.value}]",
            f"severity={event.severity.value}",
        ]

        if event.user:
            parts.append(f"user={event.user}")
        if event.source_ip:
            parts.append(f"source_ip={event.source_ip}")
        if event.resource:
            parts.append(f"resource={event.resource}")
        if event.action:
            parts.append(f"action={event.action}")
        if event.result:
            parts.append(f"result={event.result}")

        message = " ".join(parts)

        if event.details:
            details_str = json.dumps(event.details)
            message += f" details={details_str}"

        return message

    @staticmethod
    def _get_log_level(severity: SecurityEventSeverity) -> int:
        """Map severity to logging level."""
        mapping = {
            SecurityEventSeverity.DEBUG: logging.DEBUG,
            SecurityEventSeverity.INFO: logging.INFO,
            SecurityEventSeverity.WARNING: logging.WARNING,
            SecurityEventSeverity.ERROR: logging.ERROR,
            SecurityEventSeverity.CRITICAL: logging.CRITICAL,
        }
        return mapping[severity]


# Global auditor instance
_default_auditor: Optional[SecurityAuditor] = None


def get_security_auditor() -> SecurityAuditor:
    """Get or create default security auditor."""
    global _default_auditor
    if _default_auditor is None:
        _default_auditor = SecurityAuditor()
    return _default_auditor


def log_security_event(event: SecurityEvent) -> None:
    """Convenience function to log security event."""
    auditor = get_security_auditor()
    auditor.log_event(event)
