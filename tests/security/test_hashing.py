"""Tests for password hashing module (CVE-2 remediation)."""

import pytest
from src.domains.security.hashing import (
    PasswordHasher,
    HashAlgorithm,
    PasswordHashingError,
    PasswordVerificationError,
    hash_password,
    verify_password,
    generate_secure_password,
    BCRYPT_AVAILABLE,
    ARGON2_AVAILABLE,
)


@pytest.mark.skipif(not BCRYPT_AVAILABLE, reason="bcrypt not installed")
class TestBcryptHashing:
    """Test bcrypt password hashing."""

    def test_hash_password(self):
        """Test password hashing with bcrypt."""
        hasher = PasswordHasher(algorithm=HashAlgorithm.BCRYPT)
        password = "test_password_123"

        hashed = hasher.hash_password(password)

        assert hashed is not None
        assert isinstance(hashed, str)
        assert hashed.startswith('$2b$')  # bcrypt prefix
        assert len(hashed) == 60  # bcrypt hash length

    def test_verify_password_correct(self):
        """Test verification of correct password."""
        hasher = PasswordHasher(algorithm=HashAlgorithm.BCRYPT)
        password = "test_password_123"

        hashed = hasher.hash_password(password)
        assert hasher.verify_password(password, hashed) is True

    def test_verify_password_incorrect(self):
        """Test verification of incorrect password."""
        hasher = PasswordHasher(algorithm=HashAlgorithm.BCRYPT)
        password = "test_password_123"
        wrong_password = "wrong_password"

        hashed = hasher.hash_password(password)
        assert hasher.verify_password(wrong_password, hashed) is False

    def test_hash_uniqueness(self):
        """Test that same password produces different hashes (due to salt)."""
        hasher = PasswordHasher(algorithm=HashAlgorithm.BCRYPT)
        password = "test_password_123"

        hash1 = hasher.hash_password(password)
        hash2 = hasher.hash_password(password)

        assert hash1 != hash2  # Different salts
        assert hasher.verify_password(password, hash1)
        assert hasher.verify_password(password, hash2)

    def test_empty_password(self):
        """Test hashing empty password raises error."""
        hasher = PasswordHasher(algorithm=HashAlgorithm.BCRYPT)

        with pytest.raises(PasswordHashingError):
            hasher.hash_password("")

        with pytest.raises(PasswordHashingError):
            hasher.hash_password(None)

    def test_invalid_hash_format(self):
        """Test verification with invalid hash format."""
        hasher = PasswordHasher(algorithm=HashAlgorithm.BCRYPT)

        assert hasher.verify_password("password", "invalid_hash") is False


@pytest.mark.skipif(not ARGON2_AVAILABLE, reason="argon2-cffi not installed")
class TestArgon2Hashing:
    """Test argon2id password hashing."""

    def test_hash_password(self):
        """Test password hashing with argon2id."""
        hasher = PasswordHasher(algorithm=HashAlgorithm.ARGON2ID)
        password = "test_password_123"

        hashed = hasher.hash_password(password)

        assert hashed is not None
        assert isinstance(hashed, str)
        assert hashed.startswith('$argon2id$')

    def test_verify_password_correct(self):
        """Test verification of correct password."""
        hasher = PasswordHasher(algorithm=HashAlgorithm.ARGON2ID)
        password = "test_password_123"

        hashed = hasher.hash_password(password)
        assert hasher.verify_password(password, hashed) is True

    def test_verify_password_incorrect(self):
        """Test verification of incorrect password."""
        hasher = PasswordHasher(algorithm=HashAlgorithm.ARGON2ID)
        password = "test_password_123"
        wrong_password = "wrong_password"

        hashed = hasher.hash_password(password)
        assert hasher.verify_password(wrong_password, hashed) is False

    def test_needs_rehash(self):
        """Test checking if hash needs rehashing."""
        hasher = PasswordHasher(algorithm=HashAlgorithm.ARGON2ID)
        password = "test_password_123"

        hashed = hasher.hash_password(password)
        # Fresh hash should not need rehashing
        assert hasher.needs_rehash(hashed) is False


class TestConvenienceFunctions:
    """Test convenience functions."""

    @pytest.mark.skipif(not (BCRYPT_AVAILABLE or ARGON2_AVAILABLE),
                       reason="No hashing library installed")
    def test_hash_password_function(self):
        """Test hash_password convenience function."""
        password = "test_password_123"

        hashed = hash_password(password)

        assert hashed is not None
        assert isinstance(hashed, str)
        assert verify_password(password, hashed) is True

    @pytest.mark.skipif(not (BCRYPT_AVAILABLE or ARGON2_AVAILABLE),
                       reason="No hashing library installed")
    def test_verify_password_function(self):
        """Test verify_password convenience function."""
        password = "test_password_123"
        hashed = hash_password(password)

        assert verify_password(password, hashed) is True
        assert verify_password("wrong", hashed) is False

    def test_generate_secure_password(self):
        """Test secure password generation."""
        password = generate_secure_password(32)

        assert len(password) == 32
        assert isinstance(password, str)

        # Generate multiple, ensure uniqueness
        passwords = [generate_secure_password(32) for _ in range(10)]
        assert len(set(passwords)) == 10  # All unique

    def test_generate_secure_password_min_length(self):
        """Test password generation enforces minimum length."""
        with pytest.raises(ValueError):
            generate_secure_password(8)  # Too short


class TestSecurityProperties:
    """Test security properties of password hashing."""

    @pytest.mark.skipif(not BCRYPT_AVAILABLE, reason="bcrypt not installed")
    def test_timing_attack_resistance(self):
        """Test that verification takes similar time for valid/invalid passwords."""
        import time

        hasher = PasswordHasher(algorithm=HashAlgorithm.BCRYPT)
        password = "test_password_123"
        hashed = hasher.hash_password(password)

        # Time correct password
        start = time.time()
        hasher.verify_password(password, hashed)
        time_correct = time.time() - start

        # Time incorrect password
        start = time.time()
        hasher.verify_password("wrong_password", hashed)
        time_incorrect = time.time() - start

        # Both should take similar time (within 2x)
        ratio = max(time_correct, time_incorrect) / min(time_correct, time_incorrect)
        assert ratio < 2.0

    @pytest.mark.skipif(not BCRYPT_AVAILABLE, reason="bcrypt not installed")
    def test_no_plaintext_in_hash(self):
        """Test that hash does not contain plaintext password."""
        hasher = PasswordHasher(algorithm=HashAlgorithm.BCRYPT)
        password = "my_secret_password_12345"

        hashed = hasher.hash_password(password)

        # Hash should not contain any substring of password
        assert password.lower() not in hashed.lower()
        for i in range(len(password) - 4):
            substring = password[i:i+5]
            assert substring.lower() not in hashed.lower()


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
