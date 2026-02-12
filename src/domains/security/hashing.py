"""Password Hashing Module - CVE-2 Remediation

Implements secure password hashing using bcrypt and argon2id to replace
weak hashing algorithms (MD5, SHA-256 with hardcoded salt).

Addresses CVE-2: Weak Password Hashing
"""

# Standard library imports
import logging
import secrets
from enum import Enum
from typing import Optional

try:
    # Third-party imports
    import bcrypt

    BCRYPT_AVAILABLE = True
except ImportError:
    BCRYPT_AVAILABLE = False
    logging.warning("bcrypt not installed. Install with: pip install bcrypt")

try:
    # Third-party imports
    from argon2 import PasswordHasher as Argon2PasswordHasher
    from argon2.exceptions import InvalidHash, VerifyMismatchError

    ARGON2_AVAILABLE = True
except ImportError:
    ARGON2_AVAILABLE = False
    logging.warning("argon2-cffi not installed. Install with: pip install argon2-cffi")

logger = logging.getLogger(__name__)


class HashAlgorithm(Enum):
    """Supported password hashing algorithms."""

    BCRYPT = "bcrypt"  # Default, industry standard
    ARGON2ID = "argon2id"  # Modern, memory-hard


class PasswordHashingError(Exception):
    """Raised when password hashing fails."""

    pass


class PasswordVerificationError(Exception):
    """Raised when password verification fails."""

    pass


class PasswordHasher:
    """Secure password hashing using bcrypt or argon2id.

    Features:
    - bcrypt with 12 rounds (default)
    - argon2id with secure parameters
    - Automatic salt generation
    - Timing-attack resistant verification

    CVE-2 Remediation:
    - Replaces SHA-256 with hardcoded salt
    - Implements industry-standard algorithms
    - Prevents rainbow table attacks
    """

    # bcrypt configuration
    BCRYPT_ROUNDS = 12  # Cost factor (2^12 = 4096 iterations)

    # argon2id configuration (OWASP recommended)
    ARGON2_TIME_COST = 2  # Number of iterations
    ARGON2_MEMORY_COST = 65536  # 64 MiB
    ARGON2_PARALLELISM = 4  # Number of threads
    ARGON2_HASH_LENGTH = 32  # 32 bytes
    ARGON2_SALT_LENGTH = 16  # 16 bytes

    def __init__(self, algorithm: HashAlgorithm = HashAlgorithm.BCRYPT):
        """Initialize password hasher with specified algorithm.

        Args:
            algorithm: Hashing algorithm to use (default: bcrypt)

        Raises:
            PasswordHashingError: If algorithm not available
        """
        self.algorithm = algorithm

        if algorithm == HashAlgorithm.BCRYPT and not BCRYPT_AVAILABLE:
            raise PasswordHashingError("bcrypt not available. Install with: pip install bcrypt")

        if algorithm == HashAlgorithm.ARGON2ID and not ARGON2_AVAILABLE:
            raise PasswordHashingError(
                "argon2-cffi not available. Install with: pip install argon2-cffi"
            )

        # Initialize argon2 hasher if using argon2id
        if algorithm == HashAlgorithm.ARGON2ID:
            self._argon2_hasher = Argon2PasswordHasher(
                time_cost=self.ARGON2_TIME_COST,
                memory_cost=self.ARGON2_MEMORY_COST,
                parallelism=self.ARGON2_PARALLELISM,
                hash_len=self.ARGON2_HASH_LENGTH,
                salt_len=self.ARGON2_SALT_LENGTH,
            )

        logger.info(f"PasswordHasher initialized with algorithm: {algorithm.value}")

    def hash_password(self, password: str) -> str:
        """Hash a password using the configured algorithm.

        Args:
            password: Plain-text password to hash

        Returns:
            Hashed password string (includes salt and algorithm parameters)

        Raises:
            PasswordHashingError: If hashing fails
        """
        if not password or not isinstance(password, str):
            raise PasswordHashingError("Password must be a non-empty string")

        try:
            if self.algorithm == HashAlgorithm.BCRYPT:
                return self._hash_bcrypt(password)
            elif self.algorithm == HashAlgorithm.ARGON2ID:
                return self._hash_argon2(password)
            else:
                raise PasswordHashingError(f"Unknown algorithm: {self.algorithm}")

        except Exception as e:
            logger.error(f"Password hashing failed: {e}")
            raise PasswordHashingError(f"Failed to hash password: {e}") from e

    def verify_password(self, password: str, hashed: str) -> bool:
        """Verify a password against a hash.

        Args:
            password: Plain-text password to verify
            hashed: Hashed password to verify against

        Returns:
            True if password matches, False otherwise

        Raises:
            PasswordVerificationError: If verification fails unexpectedly
        """
        if not password or not isinstance(password, str):
            raise PasswordVerificationError("Password must be a non-empty string")

        if not hashed or not isinstance(hashed, str):
            raise PasswordVerificationError("Hash must be a non-empty string")

        try:
            # Detect algorithm from hash format
            if hashed.startswith("$2a$") or hashed.startswith("$2b$") or hashed.startswith("$2y$"):
                return self._verify_bcrypt(password, hashed)
            elif hashed.startswith("$argon2id$"):
                return self._verify_argon2(password, hashed)
            else:
                raise PasswordVerificationError("Unknown hash format")

        except (PasswordVerificationError, VerifyMismatchError, InvalidHash):
            # Invalid password or hash format
            return False
        except Exception as e:
            logger.error(f"Password verification failed: {e}")
            raise PasswordVerificationError(f"Verification failed: {e}") from e

    def _hash_bcrypt(self, password: str) -> str:
        """Hash password using bcrypt."""
        password_bytes = password.encode("utf-8")
        salt = bcrypt.gensalt(rounds=self.BCRYPT_ROUNDS)
        hashed = bcrypt.hashpw(password_bytes, salt)
        return hashed.decode("utf-8")

    def _verify_bcrypt(self, password: str, hashed: str) -> bool:
        """Verify password using bcrypt."""
        password_bytes = password.encode("utf-8")
        hashed_bytes = hashed.encode("utf-8")
        return bcrypt.checkpw(password_bytes, hashed_bytes)

    def _hash_argon2(self, password: str) -> str:
        """Hash password using argon2id."""
        return self._argon2_hasher.hash(password)

    def _verify_argon2(self, password: str, hashed: str) -> bool:
        """Verify password using argon2id."""
        try:
            self._argon2_hasher.verify(hashed, password)
            return True
        except VerifyMismatchError:
            return False

    def needs_rehash(self, hashed: str) -> bool:
        """Check if a hash needs to be upgraded.

        Args:
            hashed: Password hash to check

        Returns:
            True if hash should be regenerated with new parameters
        """
        if self.algorithm == HashAlgorithm.ARGON2ID and ARGON2_AVAILABLE:
            try:
                return self._argon2_hasher.check_needs_rehash(hashed)
            except Exception:
                return True

        # For bcrypt, check if rounds match
        if hashed.startswith("$2"):
            try:
                # Extract rounds from hash
                parts = hashed.split("$")
                if len(parts) >= 3:
                    rounds = int(parts[2])
                    return rounds < self.BCRYPT_ROUNDS
            except Exception:
                return True

        return False


# Convenience functions with defaults
_default_hasher = None


def get_default_hasher() -> PasswordHasher:
    """Get or create default password hasher."""
    global _default_hasher
    if _default_hasher is None:
        # Prefer argon2id if available, fallback to bcrypt
        algorithm = HashAlgorithm.ARGON2ID if ARGON2_AVAILABLE else HashAlgorithm.BCRYPT
        _default_hasher = PasswordHasher(algorithm=algorithm)
    return _default_hasher


def hash_password(password: str, algorithm: Optional[HashAlgorithm] = None) -> str:
    """Convenience function to hash a password.

    Args:
        password: Plain-text password
        algorithm: Optional algorithm override

    Returns:
        Hashed password
    """
    if algorithm:
        hasher = PasswordHasher(algorithm=algorithm)
        return hasher.hash_password(password)
    return get_default_hasher().hash_password(password)


def verify_password(password: str, hashed: str) -> bool:
    """Convenience function to verify a password.

    Args:
        password: Plain-text password
        hashed: Hashed password

    Returns:
        True if password matches
    """
    return get_default_hasher().verify_password(password, hashed)


def generate_secure_password(length: int = 32) -> str:
    """Generate a cryptographically secure random password.

    Args:
        length: Password length (default: 32)

    Returns:
        Random password string
    """
    if length < 16:
        raise ValueError("Password length must be at least 16 characters")

    # Use URL-safe base64 alphabet (62 characters)
    return secrets.token_urlsafe(length)[:length]
