"""Path Traversal Protection

Provides secure file path handling to prevent path traversal attacks
and unauthorized file system access.
"""

# Standard library imports
import logging
import os
from pathlib import Path
from typing import Optional, Union

logger = logging.getLogger(__name__)


class PathSecurityError(Exception):
    """Raised when path security validation fails."""

    pass


class PathValidator:
    """Secure path validation and sanitization.

    Security features:
    - Path traversal prevention (../)
    - Symlink attack prevention
    - Whitelist-based path validation
    - Normalized path resolution

    Prevents attacks like:
    - /etc/passwd access
    - ../../../sensitive-file
    - Symlink to system files
    """

    def __init__(self, allowed_base_paths: Optional[list] = None):
        """Initialize path validator with allowed base paths.

        Args:
            allowed_base_paths: List of allowed base directory paths
        """
        self.allowed_base_paths = []

        if allowed_base_paths:
            for base_path in allowed_base_paths:
                resolved = Path(base_path).resolve()
                self.allowed_base_paths.append(resolved)
                logger.debug(f"Allowed base path: {resolved}")

    def validate_path(
        self, path: Union[str, Path], base_path: Optional[Union[str, Path]] = None
    ) -> Path:
        """Validate and resolve a file path securely.

        Args:
            path: File path to validate
            base_path: Optional base path to validate against

        Returns:
            Resolved, validated Path object

        Raises:
            PathSecurityError: If path is invalid or outside allowed paths
        """
        if not path:
            raise PathSecurityError("Path cannot be empty")

        # Convert to Path object
        path_obj = Path(path) if isinstance(path, str) else path

        # Check for null bytes (path injection)
        path_str = str(path_obj)
        if "\x00" in path_str:
            raise PathSecurityError("Path contains null bytes")

        # Resolve to absolute path (follows symlinks and normalizes)
        try:
            resolved_path = path_obj.resolve()
        except Exception as e:
            raise PathSecurityError(f"Failed to resolve path: {e}")

        # If base_path provided, validate against it
        if base_path:
            base_path_obj = Path(base_path) if isinstance(base_path, str) else base_path
            resolved_base = base_path_obj.resolve()

            # Check if resolved path is within base path
            try:
                resolved_path.relative_to(resolved_base)
            except ValueError:
                raise PathSecurityError(
                    f"Path '{resolved_path}' is outside allowed base path '{resolved_base}'"
                )

        # If allowed_base_paths configured, validate against whitelist
        if self.allowed_base_paths:
            is_allowed = False
            for allowed_base in self.allowed_base_paths:
                try:
                    resolved_path.relative_to(allowed_base)
                    is_allowed = True
                    break
                except ValueError:
                    continue

            if not is_allowed:
                raise PathSecurityError(
                    f"Path '{resolved_path}' is not within any allowed base paths"
                )

        # Check for suspicious patterns (even after resolution)
        self._check_suspicious_patterns(resolved_path)

        return resolved_path

    @staticmethod
    def _check_suspicious_patterns(path: Path) -> None:
        """Check for suspicious patterns in resolved path.

        Args:
            path: Resolved path to check

        Raises:
            PathSecurityError: If suspicious pattern detected
        """
        path_str = str(path)

        # Suspicious patterns (even in resolved paths)
        suspicious = [
            "/etc/passwd",
            "/etc/shadow",
            "/root/",
            "/proc/",
            "/sys/",
            "/.ssh/",
            "/private/",  # macOS
        ]

        for pattern in suspicious:
            if pattern in path_str:
                logger.warning(f"Suspicious path pattern detected: {pattern} in {path_str}")
                raise PathSecurityError(f"Access to '{pattern}' is not allowed")

    def secure_join(self, base_path: Union[str, Path], *parts: str) -> Path:
        """Securely join path components.

        Args:
            base_path: Base directory path
            *parts: Path components to join

        Returns:
            Validated joined path

        Raises:
            PathSecurityError: If resulting path is invalid
        """
        if not base_path:
            raise PathSecurityError("Base path cannot be empty")

        # Start with base path
        base = Path(base_path) if isinstance(base_path, str) else base_path
        result = base

        # Join each part
        for part in parts:
            if not part:
                continue

            # Check for traversal attempts
            if ".." in part or part.startswith("/"):
                raise PathSecurityError(f"Path component contains traversal: {part}")

            result = result / part

        # Validate final path
        return self.validate_path(result, base_path)

    def is_safe_filename(self, filename: str) -> bool:
        """Check if filename is safe (no path components).

        Args:
            filename: Filename to check

        Returns:
            True if safe, False otherwise
        """
        if not filename:
            return False

        # Check for path separators
        if "/" in filename or "\\" in filename:
            return False

        # Check for traversal
        if ".." in filename:
            return False

        # Check for null bytes
        if "\x00" in filename:
            return False

        # Check for suspicious characters
        suspicious_chars = ["<", ">", ":", '"', "|", "?", "*"]
        if any(char in filename for char in suspicious_chars):
            return False

        return True


# Convenience functions
def validate_file_path(
    path: Union[str, Path],
    base_path: Optional[Union[str, Path]] = None,
    allowed_bases: Optional[list] = None,
) -> Path:
    """Convenience function to validate a file path.

    Args:
        path: Path to validate
        base_path: Optional base path
        allowed_bases: Optional list of allowed base paths

    Returns:
        Validated Path object
    """
    validator = PathValidator(allowed_base_paths=allowed_bases)
    return validator.validate_path(path, base_path)


def secure_path_join(base_path: Union[str, Path], *parts: str) -> Path:
    """Convenience function to securely join path components.

    Args:
        base_path: Base directory
        *parts: Path components

    Returns:
        Validated joined path
    """
    validator = PathValidator()
    return validator.secure_join(base_path, *parts)
