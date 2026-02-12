"""Input Validation and SQL Injection Prevention

Provides validation for user inputs, connection parameters, and SQL queries
to prevent SQL injection and other input-based attacks.
"""

# Standard library imports
import logging
import re
from typing import Any, Dict, List, Optional
from urllib.parse import urlparse

logger = logging.getLogger(__name__)


class ValidationError(Exception):
    """Raised when input validation fails."""

    pass


class InputValidator:
    """Input validation for SQL queries and connection parameters."""

    # SQL injection patterns to detect
    SQL_INJECTION_PATTERNS = [
        r"(\bUNION\b.*\bSELECT\b)",  # UNION SELECT
        r"(\bOR\b.*=.*)",  # OR 1=1
        r"(;.*DROP\b)",  # ; DROP TABLE
        r"(;.*DELETE\b)",  # ; DELETE FROM
        r"(;.*UPDATE\b)",  # ; UPDATE
        r"(;.*INSERT\b)",  # ; INSERT INTO
        r"(--)",  # SQL comments
        r"(/\*.*\*/)",  # Block comments
        r"(\bEXEC\b.*\()",  # EXEC(
        r"(\bEXECUTE\b.*\()",  # EXECUTE(
        r"(xp_cmdshell)",  # SQL Server command execution
        r"(pg_read_file)",  # PostgreSQL file read
        r"(pg_write_file)",  # PostgreSQL file write
        r"(COPY.*FROM.*PROGRAM)",  # COPY FROM PROGRAM
    ]

    # Valid identifier pattern (table/column names)
    IDENTIFIER_PATTERN = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]{0,62}$")

    # Valid database name pattern
    DATABASE_NAME_PATTERN = re.compile(r"^[a-zA-Z][a-zA-Z0-9_]{0,62}$")

    @classmethod
    def validate_sql_input(cls, sql: str) -> bool:
        """Validate SQL input for injection patterns.

        Args:
            sql: SQL query string to validate

        Returns:
            True if safe, False if suspicious patterns detected

        Raises:
            ValidationError: If injection pattern detected
        """
        if not sql or not isinstance(sql, str):
            raise ValidationError("SQL input must be a non-empty string")

        sql_upper = sql.upper()

        for pattern in cls.SQL_INJECTION_PATTERNS:
            if re.search(pattern, sql_upper, re.IGNORECASE):
                logger.warning(f"SQL injection pattern detected: {pattern}")
                raise ValidationError(f"Suspicious SQL pattern detected")

        return True

    @classmethod
    def sanitize_identifier(cls, identifier: str) -> str:
        """Sanitize and validate SQL identifier (table/column name).

        Args:
            identifier: SQL identifier to sanitize

        Returns:
            Sanitized identifier

        Raises:
            ValidationError: If identifier is invalid
        """
        if not identifier or not isinstance(identifier, str):
            raise ValidationError("Identifier must be a non-empty string")

        # Remove whitespace
        identifier = identifier.strip()

        # Validate against pattern
        if not cls.IDENTIFIER_PATTERN.match(identifier):
            raise ValidationError(
                f"Invalid identifier: {identifier}. "
                "Must start with letter/underscore, contain only alphanumeric/underscore, "
                "and be max 63 characters."
            )

        return identifier

    @classmethod
    def validate_connection_params(cls, params: Dict[str, Any]) -> Dict[str, Any]:
        """Validate database connection parameters.

        Args:
            params: Connection parameters dict

        Returns:
            Validated parameters dict

        Raises:
            ValidationError: If parameters are invalid
        """
        required = ["host", "port", "database", "user"]
        missing = [key for key in required if key not in params]

        if missing:
            raise ValidationError(f"Missing required parameters: {', '.join(missing)}")

        # Validate host (IP or hostname)
        host = params.get("host", "")
        if not cls._validate_host(host):
            raise ValidationError(f"Invalid host: {host}")

        # Validate port
        port = params.get("port")
        if not isinstance(port, int) or not (1 <= port <= 65535):
            raise ValidationError(f"Invalid port: {port}. Must be 1-65535.")

        # Validate database name
        database = params.get("database", "")
        if not cls.DATABASE_NAME_PATTERN.match(database):
            raise ValidationError(
                f"Invalid database name: {database}. "
                "Must start with letter, contain only alphanumeric/underscore."
            )

        # Validate user
        user = params.get("user", "")
        if not cls.IDENTIFIER_PATTERN.match(user):
            raise ValidationError(f"Invalid user: {user}")

        return params

    @staticmethod
    def _validate_host(host: str) -> bool:
        """Validate host is valid IP or hostname."""
        if not host:
            return False

        # Check for localhost
        if host in ["localhost", "127.0.0.1", "::1"]:
            return True

        # Check for valid hostname/IP pattern
        hostname_pattern = re.compile(
            r"^(?:(?:[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)*"
            r"[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)$"
        )

        # Simple IP pattern (v4)
        ip_pattern = re.compile(
            r"^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}"
            r"(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"
        )

        return bool(hostname_pattern.match(host) or ip_pattern.match(host))

    @classmethod
    def validate_connection_string(cls, conn_string: str) -> bool:
        """Validate PostgreSQL connection string format.

        Args:
            conn_string: Connection string (postgresql://...)

        Returns:
            True if valid

        Raises:
            ValidationError: If connection string is invalid
        """
        if not conn_string or not isinstance(conn_string, str):
            raise ValidationError("Connection string must be non-empty")

        try:
            parsed = urlparse(conn_string)

            # Validate scheme
            if parsed.scheme not in ["postgresql", "postgres"]:
                raise ValidationError(f"Invalid scheme: {parsed.scheme}")

            # Validate host
            if not parsed.hostname:
                raise ValidationError("Missing hostname in connection string")

            if not cls._validate_host(parsed.hostname):
                raise ValidationError(f"Invalid hostname: {parsed.hostname}")

            # Validate port
            if parsed.port and not (1 <= parsed.port <= 65535):
                raise ValidationError(f"Invalid port: {parsed.port}")

            return True

        except Exception as e:
            raise ValidationError(f"Invalid connection string: {e}")


# Convenience functions
def validate_sql_input(sql: str) -> bool:
    """Convenience function for SQL input validation."""
    return InputValidator.validate_sql_input(sql)


def validate_connection_params(params: Dict[str, Any]) -> Dict[str, Any]:
    """Convenience function for connection parameter validation."""
    return InputValidator.validate_connection_params(params)


def sanitize_identifier(identifier: str) -> str:
    """Convenience function for identifier sanitization."""
    return InputValidator.sanitize_identifier(identifier)
