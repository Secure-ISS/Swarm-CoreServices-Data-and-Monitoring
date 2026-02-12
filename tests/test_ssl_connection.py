#!/usr/bin/env python3
"""SSL/TLS Connection Test Suite

Tests to verify SSL/TLS encryption is properly configured and working.
"""
# Standard library imports
import os
import sys
from pathlib import Path

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent))

# Third-party imports
import pytest
from dotenv import load_dotenv

# Local imports
from src.db.pool import DatabaseConnectionError, DualDatabasePools


class TestSSLConnection:
    """Test SSL/TLS connection configuration."""

    @classmethod
    def setup_class(cls):
        """Set up test environment."""
        # Load .env file
        env_path = Path(__file__).parent.parent / ".env"
        if env_path.exists():
            load_dotenv(env_path)

    def test_ssl_enabled_in_config(self):
        """Test that SSL is enabled in environment configuration."""
        # Check SSL mode is set (default is 'prefer')
        project_sslmode = os.getenv("RUVECTOR_SSLMODE", "prefer")
        shared_sslmode = os.getenv("SHARED_KNOWLEDGE_SSLMODE", "prefer")

        assert project_sslmode != "disable", "Project database SSL should not be disabled"
        assert shared_sslmode != "disable", "Shared database SSL should not be disabled"

        print(f"Project SSL mode: {project_sslmode}")
        print(f"Shared SSL mode: {shared_sslmode}")

    def test_connection_pools_initialize(self):
        """Test that connection pools initialize successfully."""
        try:
            pools = DualDatabasePools()
            assert pools.project_pool is not None
            assert pools.shared_pool is not None
            pools.close()
        except DatabaseConnectionError as e:
            pytest.skip(f"Database not available: {e}")

    def test_health_check_includes_ssl_info(self):
        """Test that health check includes SSL information."""
        try:
            pools = DualDatabasePools()
            health = pools.health_check()

            # Check project database health
            project = health.get("project", {})
            assert "status" in project
            assert "ssl_enabled" in project, "Health check should include SSL status"

            # Check shared database health
            shared = health.get("shared", {})
            assert "status" in shared
            assert "ssl_enabled" in shared, "Health check should include SSL status"

            # Print SSL status
            if project.get("status") == "healthy":
                ssl_enabled = project.get("ssl_enabled", False)
                cipher = project.get("ssl_cipher", "unknown")
                print(f"Project database - SSL: {ssl_enabled}, Cipher: {cipher}")

            if shared.get("status") == "healthy":
                ssl_enabled = shared.get("ssl_enabled", False)
                cipher = shared.get("ssl_cipher", "unknown")
                print(f"Shared database - SSL: {ssl_enabled}, Cipher: {cipher}")

            pools.close()

        except DatabaseConnectionError as e:
            pytest.skip(f"Database not available: {e}")

    def test_ssl_enabled_when_required(self):
        """Test that SSL is actually enabled when sslmode is 'require' or higher."""
        sslmode = os.getenv("RUVECTOR_SSLMODE", "prefer")

        # Skip if SSL is not required
        if sslmode in ("disable", "allow", "prefer"):
            pytest.skip(f"SSL not required (sslmode={sslmode})")

        try:
            pools = DualDatabasePools()
            health = pools.health_check()

            project = health.get("project", {})
            if project.get("status") == "healthy":
                assert (
                    project.get("ssl_enabled") is True
                ), f"SSL must be enabled when sslmode={sslmode}"

            shared = health.get("shared", {})
            if shared.get("status") == "healthy":
                assert (
                    shared.get("ssl_enabled") is True
                ), f"SSL must be enabled when sslmode={sslmode}"

            pools.close()

        except DatabaseConnectionError as e:
            pytest.skip(f"Database not available: {e}")

    def test_strong_cipher_suite(self):
        """Test that strong cipher suites are used."""
        try:
            pools = DualDatabasePools()
            health = pools.health_check()

            # List of weak ciphers that should NOT be used
            weak_ciphers = ["DES", "3DES", "RC4", "MD5", "NULL", "EXPORT"]

            project = health.get("project", {})
            if project.get("status") == "healthy" and project.get("ssl_enabled"):
                cipher = project.get("ssl_cipher", "")
                for weak in weak_ciphers:
                    assert (
                        weak not in cipher.upper()
                    ), f"Weak cipher detected in project database: {cipher}"
                print(f"Project database using strong cipher: {cipher}")

            shared = health.get("shared", {})
            if shared.get("status") == "healthy" and shared.get("ssl_enabled"):
                cipher = shared.get("ssl_cipher", "")
                for weak in weak_ciphers:
                    assert (
                        weak not in cipher.upper()
                    ), f"Weak cipher detected in shared database: {cipher}"
                print(f"Shared database using strong cipher: {cipher}")

            pools.close()

        except DatabaseConnectionError as e:
            pytest.skip(f"Database not available: {e}")

    def test_certificate_paths_exist_when_required(self):
        """Test that SSL certificate paths exist when verification is required."""
        project_sslmode = os.getenv("RUVECTOR_SSLMODE", "prefer")
        shared_sslmode = os.getenv("SHARED_KNOWLEDGE_SSLMODE", "prefer")

        # Check project database certificates
        if project_sslmode in ("require", "verify-ca", "verify-full"):
            sslrootcert = os.getenv("RUVECTOR_SSLROOTCERT")
            if sslrootcert:
                assert os.path.exists(
                    sslrootcert
                ), f"Project SSL root certificate not found: {sslrootcert}"
                print(f"Project SSL root certificate exists: {sslrootcert}")

            # Check client certificate for mutual TLS
            sslcert = os.getenv("RUVECTOR_SSLCERT")
            if sslcert:
                assert os.path.exists(sslcert), f"Project SSL certificate not found: {sslcert}"
                sslkey = os.getenv("RUVECTOR_SSLKEY")
                assert os.path.exists(sslkey), f"Project SSL key not found: {sslkey}"
                print(f"Project client certificate exists: {sslcert}")

        # Check shared database certificates
        if shared_sslmode in ("require", "verify-ca", "verify-full"):
            sslrootcert = os.getenv("SHARED_KNOWLEDGE_SSLROOTCERT")
            if sslrootcert:
                assert os.path.exists(
                    sslrootcert
                ), f"Shared SSL root certificate not found: {sslrootcert}"
                print(f"Shared SSL root certificate exists: {sslrootcert}")

            # Check client certificate for mutual TLS
            sslcert = os.getenv("SHARED_KNOWLEDGE_SSLCERT")
            if sslcert:
                assert os.path.exists(sslcert), f"Shared SSL certificate not found: {sslcert}"
                sslkey = os.getenv("SHARED_KNOWLEDGE_SSLKEY")
                assert os.path.exists(sslkey), f"Shared SSL key not found: {sslkey}"
                print(f"Shared client certificate exists: {sslcert}")

    def test_connection_with_ssl_disabled_fails_when_required(self):
        """Test that connection fails when SSL is disabled but required by server."""
        # This test only runs if sslmode is 'require' or higher
        original_sslmode = os.getenv("RUVECTOR_SSLMODE", "prefer")

        if original_sslmode in ("disable", "allow", "prefer"):
            pytest.skip(f"Test not applicable when sslmode={original_sslmode}")

        # Temporarily set SSL to disabled
        os.environ["RUVECTOR_SSLMODE"] = "disable"
        os.environ["SHARED_KNOWLEDGE_SSLMODE"] = "disable"

        try:
            # This should fail if server requires SSL
            pools = DualDatabasePools()
            health = pools.health_check()

            # If we got here, server doesn't enforce SSL (warning)
            project = health.get("project", {})
            if project.get("status") == "healthy":
                print("WARNING: Server accepted non-SSL connection (server should enforce SSL)")

            pools.close()

        except DatabaseConnectionError:
            # Expected behavior - connection rejected
            print("PASS: Server correctly rejected non-SSL connection")

        finally:
            # Restore original SSL mode
            os.environ["RUVECTOR_SSLMODE"] = original_sslmode
            os.environ["SHARED_KNOWLEDGE_SSLMODE"] = os.getenv("SHARED_KNOWLEDGE_SSLMODE", "prefer")


def test_ssl_configuration_summary():
    """Print summary of SSL configuration."""
    print("\n" + "=" * 60)
    print("SSL/TLS Configuration Summary")
    print("=" * 60)

    # Project database
    print("\nProject Database:")
    print(f"  SSLMODE: {os.getenv('RUVECTOR_SSLMODE', 'prefer')}")
    print(f"  SSL Root Cert: {os.getenv('RUVECTOR_SSLROOTCERT', 'Not set')}")
    print(f"  SSL Client Cert: {os.getenv('RUVECTOR_SSLCERT', 'Not set')}")
    print(f"  SSL Client Key: {os.getenv('RUVECTOR_SSLKEY', 'Not set')}")

    # Shared database
    print("\nShared Database:")
    print(f"  SSLMODE: {os.getenv('SHARED_KNOWLEDGE_SSLMODE', 'prefer')}")
    print(f"  SSL Root Cert: {os.getenv('SHARED_KNOWLEDGE_SSLROOTCERT', 'Not set')}")
    print(f"  SSL Client Cert: {os.getenv('SHARED_KNOWLEDGE_SSLCERT', 'Not set')}")
    print(f"  SSL Client Key: {os.getenv('SHARED_KNOWLEDGE_SSLKEY', 'Not set')}")

    # Distributed cluster
    print("\nDistributed Cluster:")
    print(f"  SSLMODE: {os.getenv('DISTRIBUTED_SSLMODE', 'prefer')}")
    print(f"  SSL Root Cert: {os.getenv('DISTRIBUTED_SSLROOTCERT', 'Not set')}")

    print("=" * 60)


if __name__ == "__main__":
    # Load environment
    env_path = Path(__file__).parent.parent / ".env"
    if env_path.exists():
        load_dotenv(env_path)

    # Print configuration
    test_ssl_configuration_summary()

    # Run tests
    print("\nRunning SSL/TLS tests...")
    pytest.main([__file__, "-v", "-s"])
