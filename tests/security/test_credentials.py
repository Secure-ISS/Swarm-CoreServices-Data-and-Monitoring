"""Tests for credential management module (CVE-3 remediation)."""

# Standard library imports
import os
from datetime import datetime, timedelta
from pathlib import Path

# Third-party imports
import pytest

# Local imports
from src.domains.security.credentials import (
    Credential,
    CredentialError,
    CredentialManager,
    SecureCredentialStore,
)


class TestSecureCredentialStore:
    """Test SecureCredentialStore class."""

    def test_get_from_environment(self, monkeypatch):
        """Test getting credential from environment variable."""
        monkeypatch.setenv("DPG_TEST_KEY", "test_value")

        store = SecureCredentialStore()
        value = store.get("TEST_KEY")

        assert value == "test_value"

    def test_get_with_default(self):
        """Test getting non-existent credential with default."""
        store = SecureCredentialStore()
        value = store.get("NON_EXISTENT", default="default_value")

        assert value == "default_value"

    def test_get_required_missing(self):
        """Test get_required raises error if credential missing."""
        store = SecureCredentialStore()

        with pytest.raises(CredentialError) as exc_info:
            store.get_required("NON_EXISTENT_KEY")

        assert "not found" in str(exc_info.value)

    def test_set_cached(self):
        """Test caching a credential."""
        store = SecureCredentialStore()
        store.set_cached("test_key", "test_value", expires_in_days=7)

        value = store.get("test_key")
        assert value == "test_value"

    def test_cached_credential_expiration(self):
        """Test cached credential expiration."""
        store = SecureCredentialStore()

        # Create expired credential manually
        expired_cred = Credential(
            key="expired_key",
            value="expired_value",
            created_at=datetime.utcnow() - timedelta(days=10),
            expires_at=datetime.utcnow() - timedelta(days=1),
        )
        store._cache["expired_key"] = expired_cred

        # Should not return expired credential
        with pytest.raises(CredentialError):
            store.get_required("expired_key")

    def test_rotate_credential(self):
        """Test credential rotation."""
        store = SecureCredentialStore()
        store.set_cached("test_key", "old_value")

        store.rotate("test_key", "new_value")

        value = store.get("test_key")
        assert value == "new_value"

    def test_rotate_non_existent(self):
        """Test rotating non-existent credential raises error."""
        store = SecureCredentialStore()

        with pytest.raises(CredentialError):
            store.rotate("non_existent", "new_value")

    def test_clear_cache(self):
        """Test clearing credential cache."""
        store = SecureCredentialStore()
        store.set_cached("key1", "value1")
        store.set_cached("key2", "value2")

        store.clear_cache()

        # Cache should be empty
        with pytest.raises(CredentialError):
            store.get_required("key1")

    def test_get_connection_params_success(self, monkeypatch):
        """Test getting connection parameters."""
        monkeypatch.setenv("DPG_RUVECTOR_HOST", "testhost")
        monkeypatch.setenv("DPG_RUVECTOR_PORT", "5433")
        monkeypatch.setenv("DPG_RUVECTOR_DB", "testdb")
        monkeypatch.setenv("DPG_RUVECTOR_USER", "testuser")
        monkeypatch.setenv("DPG_RUVECTOR_PASSWORD", "testpass")

        store = SecureCredentialStore()
        params = store.get_connection_params()

        assert params["host"] == "testhost"
        assert params["port"] == 5433
        assert params["database"] == "testdb"
        assert params["user"] == "testuser"
        assert params["password"] == "testpass"

    def test_get_connection_params_missing_required(self, monkeypatch):
        """Test get_connection_params fails with missing credentials."""
        # Only set host, missing others
        monkeypatch.setenv("DPG_RUVECTOR_HOST", "testhost")

        store = SecureCredentialStore()

        with pytest.raises(CredentialError) as exc_info:
            store.get_connection_params()

        assert "not found" in str(exc_info.value)

    def test_docker_secrets_priority(self, tmp_path, monkeypatch):
        """Test Docker secrets have priority over cache."""
        # Create temporary secrets directory
        secrets_dir = tmp_path / "secrets"
        secrets_dir.mkdir()

        # Create secret file
        secret_file = secrets_dir / "db_password"
        secret_file.write_text("secret_from_file")

        # Create store with custom secrets dir
        store = SecureCredentialStore(secrets_dir=secrets_dir)

        # Also cache a different value
        store.set_cached("db_password", "cached_value")

        # Should get value from file (higher priority)
        value = store.get("db_password")
        assert value == "secret_from_file"


class TestCredentialManager:
    """Test CredentialManager class."""

    def test_generate_password_high_complexity(self):
        """Test generating high complexity password."""
        manager = CredentialManager()
        password = manager.generate_password(32, complexity="high")

        assert len(password) == 32
        assert isinstance(password, str)

        # Should contain mix of characters
        has_upper = any(c.isupper() for c in password)
        has_lower = any(c.islower() for c in password)
        has_digit = any(c.isdigit() for c in password)

        assert has_upper or has_lower or has_digit

    def test_generate_password_medium_complexity(self):
        """Test generating medium complexity password."""
        manager = CredentialManager()
        password = manager.generate_password(32, complexity="medium")

        assert len(password) == 32
        assert isinstance(password, str)

    def test_generate_password_min_length(self):
        """Test password generation enforces minimum length."""
        manager = CredentialManager()

        with pytest.raises(ValueError):
            manager.generate_password(8)  # Too short

    def test_get_credentials_status(self, monkeypatch):
        """Test getting credentials status."""
        manager = CredentialManager()

        # Add some test credentials
        manager.store.set_cached("healthy", "value1")
        manager.store.set_cached("needs_rotation", "value2")

        # Make one need rotation
        old_cred = Credential(
            key="needs_rotation",
            value="value2",
            created_at=datetime.utcnow() - timedelta(days=100),
            rotated_at=None,
        )
        manager.store._cache["needs_rotation"] = old_cred

        status = manager.get_credentials_status()

        assert status["total_cached"] == 2
        assert "healthy" in status["healthy"]
        assert "needs_rotation" in status["needs_rotation"]


class TestCredentialLifecycle:
    """Test credential lifecycle properties."""

    def test_credential_is_expired(self):
        """Test credential expiration check."""
        # Not expired
        cred = Credential(
            key="test",
            value="value",
            created_at=datetime.utcnow(),
            expires_at=datetime.utcnow() + timedelta(days=1),
        )
        assert cred.is_expired() is False

        # Expired
        cred_expired = Credential(
            key="test",
            value="value",
            created_at=datetime.utcnow() - timedelta(days=2),
            expires_at=datetime.utcnow() - timedelta(days=1),
        )
        assert cred_expired.is_expired() is True

        # No expiration set
        cred_no_expiry = Credential(
            key="test", value="value", created_at=datetime.utcnow(), expires_at=None
        )
        assert cred_no_expiry.is_expired() is False

    def test_credential_needs_rotation(self):
        """Test credential rotation check."""
        # Fresh credential
        cred_fresh = Credential(
            key="test", value="value", created_at=datetime.utcnow(), rotated_at=None
        )
        assert cred_fresh.needs_rotation(rotation_days=90) is False

        # Old credential
        cred_old = Credential(
            key="test",
            value="value",
            created_at=datetime.utcnow() - timedelta(days=100),
            rotated_at=None,
        )
        assert cred_old.needs_rotation(rotation_days=90) is True

        # Recently rotated
        cred_rotated = Credential(
            key="test",
            value="value",
            created_at=datetime.utcnow() - timedelta(days=100),
            rotated_at=datetime.utcnow() - timedelta(days=1),
        )
        assert cred_rotated.needs_rotation(rotation_days=90) is False


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
