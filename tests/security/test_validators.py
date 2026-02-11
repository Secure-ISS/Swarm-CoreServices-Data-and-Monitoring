"""Tests for security validators module."""

import pytest
from src.domains.security.validators import (
    InputValidator,
    ValidationError,
    validate_sql_input,
    validate_connection_params,
    sanitize_identifier,
)


class TestInputValidator:
    """Test InputValidator class."""

    def test_validate_sql_input_safe(self):
        """Test validation of safe SQL queries."""
        safe_queries = [
            "SELECT * FROM users WHERE id = 1",
            "SELECT name, email FROM customers",
            "INSERT INTO logs (message) VALUES ($1)",
        ]

        for query in safe_queries:
            assert InputValidator.validate_sql_input(query) is True

    def test_validate_sql_input_injection_patterns(self):
        """Test detection of SQL injection patterns."""
        injection_attempts = [
            "SELECT * FROM users WHERE id = 1 OR 1=1",
            "SELECT * FROM users; DROP TABLE users;",
            "SELECT * FROM users UNION SELECT * FROM passwords",
            "SELECT * FROM users WHERE name = 'admin'--",
            "SELECT * FROM users WHERE id = 1; DELETE FROM users;",
            "EXEC('malicious code')",
            "SELECT pg_read_file('/etc/passwd')",
            "COPY users FROM PROGRAM 'ls -la'",
        ]

        for query in injection_attempts:
            with pytest.raises(ValidationError):
                InputValidator.validate_sql_input(query)

    def test_validate_sql_input_empty(self):
        """Test validation of empty SQL input."""
        with pytest.raises(ValidationError):
            InputValidator.validate_sql_input("")

        with pytest.raises(ValidationError):
            InputValidator.validate_sql_input(None)

    def test_sanitize_identifier_valid(self):
        """Test sanitization of valid identifiers."""
        valid_identifiers = [
            "users",
            "user_table",
            "_private",
            "Table123",
            "a_b_c_123",
        ]

        for identifier in valid_identifiers:
            result = InputValidator.sanitize_identifier(identifier)
            assert result == identifier

    def test_sanitize_identifier_invalid(self):
        """Test rejection of invalid identifiers."""
        invalid_identifiers = [
            "123invalid",  # Starts with number
            "user-table",  # Contains hyphen
            "user.table",  # Contains dot
            "user table",  # Contains space
            "user;table",  # Contains semicolon
            "x" * 64,  # Too long (>63 chars)
        ]

        for identifier in invalid_identifiers:
            with pytest.raises(ValidationError):
                InputValidator.sanitize_identifier(identifier)

    def test_validate_connection_params_valid(self):
        """Test validation of valid connection parameters."""
        params = {
            'host': 'localhost',
            'port': 5432,
            'database': 'test_db',
            'user': 'test_user',
            'password': 'secret123'
        }

        result = InputValidator.validate_connection_params(params)
        assert result == params

    def test_validate_connection_params_missing_required(self):
        """Test validation fails with missing required params."""
        params = {
            'host': 'localhost',
            'port': 5432,
            # Missing database and user
        }

        with pytest.raises(ValidationError) as exc_info:
            InputValidator.validate_connection_params(params)

        assert "Missing required parameters" in str(exc_info.value)

    def test_validate_connection_params_invalid_port(self):
        """Test validation fails with invalid port."""
        params = {
            'host': 'localhost',
            'port': 99999,  # Invalid port
            'database': 'test_db',
            'user': 'test_user',
        }

        with pytest.raises(ValidationError) as exc_info:
            InputValidator.validate_connection_params(params)

        assert "Invalid port" in str(exc_info.value)

    def test_validate_connection_params_invalid_host(self):
        """Test validation fails with invalid host."""
        params = {
            'host': 'invalid;host',  # Suspicious characters
            'port': 5432,
            'database': 'test_db',
            'user': 'test_user',
        }

        with pytest.raises(ValidationError) as exc_info:
            InputValidator.validate_connection_params(params)

        assert "Invalid host" in str(exc_info.value)

    def test_validate_connection_string_valid(self):
        """Test validation of valid connection strings."""
        valid_strings = [
            "postgresql://user:pass@localhost:5432/dbname",
            "postgres://user@localhost/dbname",
            "postgresql://user:pass@10.0.0.1:5432/db",
        ]

        for conn_string in valid_strings:
            assert InputValidator.validate_connection_string(conn_string) is True

    def test_validate_connection_string_invalid(self):
        """Test validation fails with invalid connection strings."""
        invalid_strings = [
            "mysql://user:pass@localhost/db",  # Wrong scheme
            "postgresql://",  # No host
            "not a connection string",
            "",
            None,
        ]

        for conn_string in invalid_strings:
            with pytest.raises(ValidationError):
                InputValidator.validate_connection_string(conn_string)

    def test_convenience_functions(self):
        """Test convenience functions."""
        # validate_sql_input
        assert validate_sql_input("SELECT * FROM users") is True

        # validate_connection_params
        params = {
            'host': 'localhost',
            'port': 5432,
            'database': 'test_db',
            'user': 'test_user',
        }
        result = validate_connection_params(params)
        assert result == params

        # sanitize_identifier
        assert sanitize_identifier("valid_table") == "valid_table"


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
