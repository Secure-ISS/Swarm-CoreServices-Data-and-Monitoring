"""Security Domain - Application-Layer Security Controls

This module provides security controls for the distributed PostgreSQL cluster
application layer, addressing:

- CVE-1: Vulnerable Dependencies (dependency management)
- CVE-2: Weak Password Hashing (bcrypt/argon2)
- CVE-3: Hardcoded Credentials (secure credential management)

Modules:
- validators: Input validation and SQL injection prevention
- credentials: Secure credential management
- hashing: Password hashing (bcrypt/argon2)
- path_security: Path traversal protection
- audit: Security event logging
"""

from .validators import (
    InputValidator,
    validate_sql_input,
    validate_connection_params,
    sanitize_identifier,
)
from .credentials import (
    CredentialManager,
    SecureCredentialStore,
    rotate_credentials,
)
from .hashing import (
    PasswordHasher,
    hash_password,
    verify_password,
    HashAlgorithm,
)
from .path_security import (
    PathValidator,
    validate_file_path,
    secure_path_join,
)
from .audit import (
    SecurityAuditor,
    log_security_event,
    SecurityEventType,
)

__all__ = [
    # Validators
    "InputValidator",
    "validate_sql_input",
    "validate_connection_params",
    "sanitize_identifier",
    # Credentials
    "CredentialManager",
    "SecureCredentialStore",
    "rotate_credentials",
    # Hashing
    "PasswordHasher",
    "hash_password",
    "verify_password",
    "HashAlgorithm",
    # Path Security
    "PathValidator",
    "validate_file_path",
    "secure_path_join",
    # Audit
    "SecurityAuditor",
    "log_security_event",
    "SecurityEventType",
]

__version__ = "1.0.0"
