"""Tests for path security module."""

# Standard library imports
from pathlib import Path

# Third-party imports
import pytest

# Local imports
from src.domains.security.path_security import (
    PathSecurityError,
    PathValidator,
    secure_path_join,
    validate_file_path,
)


class TestPathValidator:
    """Test PathValidator class."""

    def test_validate_path_safe(self, tmp_path):
        """Test validation of safe paths."""
        safe_path = tmp_path / "safe_file.txt"
        safe_path.touch()

        validator = PathValidator()
        result = validator.validate_path(safe_path)

        assert result == safe_path.resolve()

    def test_validate_path_traversal_blocked(self, tmp_path):
        """Test path traversal attempts are blocked."""
        base_path = tmp_path / "base"
        base_path.mkdir()

        validator = PathValidator()

        # Try to traverse outside base path
        with pytest.raises(PathSecurityError):
            validator.validate_path("../etc/passwd", base_path)

    def test_validate_path_null_byte(self):
        """Test paths with null bytes are rejected."""
        validator = PathValidator()

        with pytest.raises(PathSecurityError):
            validator.validate_path("/tmp/file\x00.txt")

    def test_validate_path_suspicious_patterns(self, tmp_path):
        """Test suspicious path patterns are blocked."""
        validator = PathValidator()

        # These should be blocked even if they resolve
        suspicious_paths = [
            "/etc/passwd",
            "/etc/shadow",
            "/root/.ssh/id_rsa",
        ]

        for path in suspicious_paths:
            with pytest.raises(PathSecurityError):
                validator.validate_path(path)

    def test_validate_path_with_whitelist(self, tmp_path):
        """Test path validation with whitelist."""
        allowed_dir = tmp_path / "allowed"
        allowed_dir.mkdir()

        blocked_dir = tmp_path / "blocked"
        blocked_dir.mkdir()

        validator = PathValidator(allowed_base_paths=[allowed_dir])

        # Should allow path in whitelist
        allowed_file = allowed_dir / "file.txt"
        allowed_file.touch()
        result = validator.validate_path(allowed_file)
        assert result == allowed_file.resolve()

        # Should block path outside whitelist
        blocked_file = blocked_dir / "file.txt"
        blocked_file.touch()
        with pytest.raises(PathSecurityError):
            validator.validate_path(blocked_file)

    def test_secure_join_safe(self, tmp_path):
        """Test secure path joining with safe components."""
        base = tmp_path / "base"
        base.mkdir()

        validator = PathValidator()
        result = validator.secure_join(base, "subdir", "file.txt")

        expected = base / "subdir" / "file.txt"
        assert result == expected.resolve()

    def test_secure_join_traversal_blocked(self, tmp_path):
        """Test secure join blocks traversal attempts."""
        base = tmp_path / "base"
        base.mkdir()

        validator = PathValidator()

        # Try to traverse with ..
        with pytest.raises(PathSecurityError):
            validator.secure_join(base, "..", "etc", "passwd")

        # Try absolute path component
        with pytest.raises(PathSecurityError):
            validator.secure_join(base, "/etc/passwd")

    def test_is_safe_filename(self):
        """Test filename safety checking."""
        validator = PathValidator()

        # Safe filenames
        assert validator.is_safe_filename("document.pdf") is True
        assert validator.is_safe_filename("file_123.txt") is True
        assert validator.is_safe_filename("image.png") is True

        # Unsafe filenames
        assert validator.is_safe_filename("../etc/passwd") is False
        assert validator.is_safe_filename("/etc/passwd") is False
        assert validator.is_safe_filename("file\x00.txt") is False
        assert validator.is_safe_filename("file<>.txt") is False
        assert validator.is_safe_filename("file?.txt") is False
        assert validator.is_safe_filename("") is False

    def test_empty_path(self):
        """Test validation of empty paths."""
        validator = PathValidator()

        with pytest.raises(PathSecurityError):
            validator.validate_path("")

        with pytest.raises(PathSecurityError):
            validator.validate_path(None)

    def test_empty_base_path(self, tmp_path):
        """Test secure_join with empty base path."""
        validator = PathValidator()

        with pytest.raises(PathSecurityError):
            validator.secure_join("", "file.txt")


class TestConvenienceFunctions:
    """Test convenience functions."""

    def test_validate_file_path_function(self, tmp_path):
        """Test validate_file_path convenience function."""
        test_file = tmp_path / "test.txt"
        test_file.touch()

        result = validate_file_path(test_file, base_path=tmp_path)
        assert result == test_file.resolve()

    def test_validate_file_path_with_allowed_bases(self, tmp_path):
        """Test validate_file_path with allowed bases."""
        allowed = tmp_path / "allowed"
        allowed.mkdir()

        test_file = allowed / "test.txt"
        test_file.touch()

        result = validate_file_path(test_file, allowed_bases=[allowed])
        assert result == test_file.resolve()

    def test_secure_path_join_function(self, tmp_path):
        """Test secure_path_join convenience function."""
        base = tmp_path / "base"
        base.mkdir()

        result = secure_path_join(base, "subdir", "file.txt")
        expected = base / "subdir" / "file.txt"
        assert result == expected.resolve()

    def test_secure_path_join_blocks_traversal(self, tmp_path):
        """Test secure_path_join blocks traversal."""
        base = tmp_path / "base"
        base.mkdir()

        with pytest.raises(PathSecurityError):
            secure_path_join(base, "..", "etc", "passwd")


class TestSecurityProperties:
    """Test security properties of path validation."""

    def test_symlink_resolution(self, tmp_path):
        """Test that symlinks are properly resolved."""
        # Create directory structure
        real_dir = tmp_path / "real"
        real_dir.mkdir()

        real_file = real_dir / "file.txt"
        real_file.write_text("content")

        # Create symlink
        link_dir = tmp_path / "link"
        link_dir.symlink_to(real_dir)

        validator = PathValidator()
        result = validator.validate_path(link_dir / "file.txt")

        # Should resolve to real path
        assert result == real_file.resolve()

    def test_case_sensitivity(self, tmp_path):
        """Test path validation is case-sensitive on case-sensitive filesystems."""
        test_file = tmp_path / "TestFile.txt"
        test_file.touch()

        validator = PathValidator()

        # Original case should work
        result = validator.validate_path(test_file)
        assert result == test_file.resolve()

    def test_unicode_paths(self, tmp_path):
        """Test handling of Unicode paths."""
        unicode_file = tmp_path / "файл.txt"  # Russian characters
        unicode_file.touch()

        validator = PathValidator()
        result = validator.validate_path(unicode_file)

        assert result == unicode_file.resolve()


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
