"""Secure Credential Management - CVE-3 Remediation

Implements secure credential storage and retrieval to prevent hardcoded
credentials and insecure credential management.

Addresses CVE-3: Hardcoded Credentials
"""

# Standard library imports
import json
import logging
import os
import secrets
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, Optional

logger = logging.getLogger(__name__)


class CredentialError(Exception):
    """Raised when credential operation fails."""

    pass


@dataclass
class Credential:
    """Represents a secure credential."""

    key: str
    value: str
    created_at: datetime
    expires_at: Optional[datetime] = None
    rotated_at: Optional[datetime] = None
    metadata: Optional[Dict[str, Any]] = None

    def is_expired(self) -> bool:
        """Check if credential is expired."""
        if self.expires_at is None:
            return False
        return datetime.utcnow() > self.expires_at

    def needs_rotation(self, rotation_days: int = 90) -> bool:
        """Check if credential needs rotation."""
        if self.rotated_at is None:
            check_date = self.created_at
        else:
            check_date = self.rotated_at

        return datetime.utcnow() > (check_date + timedelta(days=rotation_days))


class SecureCredentialStore:
    """Secure credential storage using environment variables and secrets.

    Security features:
    - No hardcoded credentials
    - Environment variable priority
    - Docker secrets support
    - Credential rotation tracking
    - Automatic expiration

    CVE-3 Remediation:
    - Replaces hardcoded passwords in code
    - Supports Docker secrets (/run/secrets/)
    - Environment-based configuration
    - Credential lifecycle management
    """

    SECRETS_DIR = Path("/run/secrets")  # Docker secrets mount point
    ENV_PREFIX = "DPG_"  # Distributed PostgreSQL prefix

    def __init__(self, secrets_dir: Optional[Path] = None):
        """Initialize credential store.

        Args:
            secrets_dir: Custom secrets directory (default: /run/secrets)
        """
        self.secrets_dir = secrets_dir or self.SECRETS_DIR
        self._cache: Dict[str, Credential] = {}
        logger.info(f"SecureCredentialStore initialized (secrets_dir: {self.secrets_dir})")

    def get(self, key: str, default: Optional[str] = None) -> Optional[str]:
        """Get credential value from secure sources.

        Priority order:
        1. Environment variable (DPG_<KEY>)
        2. Docker secret (/run/secrets/<key>)
        3. Cached credential
        4. Default value

        Args:
            key: Credential key
            default: Default value if not found

        Returns:
            Credential value or default

        Raises:
            CredentialError: If credential not found and no default
        """
        # 1. Check environment variable
        env_key = f"{self.ENV_PREFIX}{key.upper()}"
        env_value = os.getenv(env_key)
        if env_value:
            logger.debug(f"Credential '{key}' loaded from environment")
            return env_value

        # 2. Check Docker secret
        secret_file = self.secrets_dir / key
        if secret_file.exists():
            try:
                value = secret_file.read_text().strip()
                logger.debug(f"Credential '{key}' loaded from Docker secret")
                return value
            except Exception as e:
                logger.error(f"Failed to read secret file {secret_file}: {e}")

        # 3. Check cache
        if key in self._cache:
            cred = self._cache[key]
            if not cred.is_expired():
                logger.debug(f"Credential '{key}' loaded from cache")
                return cred.value
            else:
                logger.warning(f"Cached credential '{key}' is expired")
                del self._cache[key]

        # 4. Return default or raise error
        if default is not None:
            logger.debug(f"Credential '{key}' not found, using default")
            return default

        raise CredentialError(
            f"Credential '{key}' not found. Set environment variable {env_key} "
            f"or create Docker secret at {secret_file}"
        )

    def get_required(self, key: str) -> str:
        """Get required credential (raises error if not found).

        Args:
            key: Credential key

        Returns:
            Credential value

        Raises:
            CredentialError: If credential not found
        """
        return self.get(key)

    def set_cached(
        self,
        key: str,
        value: str,
        expires_in_days: Optional[int] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> None:
        """Cache a credential temporarily.

        Note: This should only be used for runtime-generated credentials.
        Use environment variables or Docker secrets for persistent credentials.

        Args:
            key: Credential key
            value: Credential value
            expires_in_days: Optional expiration in days
            metadata: Optional metadata
        """
        expires_at = None
        if expires_in_days:
            expires_at = datetime.utcnow() + timedelta(days=expires_in_days)

        cred = Credential(
            key=key,
            value=value,
            created_at=datetime.utcnow(),
            expires_at=expires_at,
            metadata=metadata,
        )

        self._cache[key] = cred
        logger.info(f"Credential '{key}' cached (expires: {expires_at})")

    def rotate(self, key: str, new_value: str) -> None:
        """Rotate a cached credential.

        Args:
            key: Credential key
            new_value: New credential value
        """
        if key not in self._cache:
            raise CredentialError(f"Credential '{key}' not in cache")

        cred = self._cache[key]
        cred.value = new_value
        cred.rotated_at = datetime.utcnow()

        logger.info(f"Credential '{key}' rotated")

    def clear_cache(self) -> None:
        """Clear all cached credentials."""
        count = len(self._cache)
        self._cache.clear()
        logger.info(f"Cleared {count} cached credentials")

    def get_connection_params(self) -> Dict[str, Any]:
        """Get database connection parameters from secure sources.

        Returns:
            Dict with host, port, database, user, password

        Raises:
            CredentialError: If required parameters not found
        """
        return {
            "host": self.get("RUVECTOR_HOST", "localhost"),
            "port": int(self.get("RUVECTOR_PORT", "5432")),
            "database": self.get_required("RUVECTOR_DB"),
            "user": self.get_required("RUVECTOR_USER"),
            "password": self.get_required("RUVECTOR_PASSWORD"),
        }


class CredentialManager:
    """High-level credential management with rotation support.

    Features:
    - Automatic credential generation
    - Rotation scheduling
    - Multi-environment support
    - Audit logging
    """

    def __init__(self, store: Optional[SecureCredentialStore] = None):
        """Initialize credential manager.

        Args:
            store: Optional custom credential store
        """
        self.store = store or SecureCredentialStore()
        logger.info("CredentialManager initialized")

    def generate_password(self, length: int = 32, complexity: str = "high") -> str:
        """Generate a secure random password.

        Args:
            length: Password length (default: 32)
            complexity: Complexity level (low, medium, high)

        Returns:
            Generated password
        """
        if length < 16:
            raise ValueError("Password length must be at least 16 characters")

        if complexity == "high":
            # Mix of alphanumeric + special characters
            alphabet = (
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()-_=+"
            )
            password = "".join(secrets.choice(alphabet) for _ in range(length))
        elif complexity == "medium":
            # Alphanumeric only
            password = secrets.token_urlsafe(length)[:length]
        else:
            # Simple alphanumeric
            alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
            password = "".join(secrets.choice(alphabet) for _ in range(length))

        return password

    def get_credentials_status(self) -> Dict[str, Any]:
        """Get status of all credentials for monitoring.

        Returns:
            Dict with credential status information
        """
        status = {
            "total_cached": len(self.store._cache),
            "expired": [],
            "needs_rotation": [],
            "healthy": [],
        }

        for key, cred in self.store._cache.items():
            if cred.is_expired():
                status["expired"].append(key)
            elif cred.needs_rotation():
                status["needs_rotation"].append(key)
            else:
                status["healthy"].append(key)

        return status


# Global instance
_default_store: Optional[SecureCredentialStore] = None


def get_credential_store() -> SecureCredentialStore:
    """Get or create default credential store."""
    global _default_store
    if _default_store is None:
        _default_store = SecureCredentialStore()
    return _default_store


def rotate_credentials(credentials: Dict[str, str]) -> None:
    """Rotate multiple credentials.

    Args:
        credentials: Dict of credential key -> new value
    """
    store = get_credential_store()
    for key, value in credentials.items():
        store.rotate(key, value)
    logger.info(f"Rotated {len(credentials)} credentials")
