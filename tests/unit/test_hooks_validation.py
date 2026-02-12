"""
Pre-commit hooks validation tests.

This module contains tests to validate that pre-commit hooks are working correctly.
"""

# Standard library imports
import subprocess
from pathlib import Path


def test_black_available():
    """Test that black is available."""
    result = subprocess.run(["black", "--version"], capture_output=True, text=True)
    assert result.returncode == 0
    assert "black" in result.stdout.lower()


def test_isort_available():
    """Test that isort is available."""
    result = subprocess.run(["isort", "--version"], capture_output=True, text=True)
    assert result.returncode == 0
    assert "isort" in result.stdout.lower()


def test_flake8_available():
    """Test that flake8 is available."""
    result = subprocess.run(["flake8", "--version"], capture_output=True, text=True)
    assert result.returncode == 0
    assert "flake8" in result.stdout.lower()


def test_mypy_available():
    """Test that mypy is available."""
    result = subprocess.run(["mypy", "--version"], capture_output=True, text=True)
    assert result.returncode == 0
    assert "mypy" in result.stdout.lower()


def test_bandit_available():
    """Test that bandit is available."""
    result = subprocess.run(["bandit", "--version"], capture_output=True, text=True)
    assert result.returncode == 0
    assert "bandit" in result.stdout.lower()


def test_detect_secrets_available():
    """Test that detect-secrets is available."""
    result = subprocess.run(["detect-secrets", "--version"], capture_output=True, text=True)
    assert result.returncode == 0


def test_pre_commit_installed():
    """Test that pre-commit is installed."""
    result = subprocess.run(["pre-commit", "--version"], capture_output=True, text=True)
    assert result.returncode == 0
    assert "pre-commit" in result.stdout.lower()


def test_pre_commit_config_valid():
    """Test that pre-commit configuration is valid."""
    result = subprocess.run(["pre-commit", "validate-config"], capture_output=True, text=True)
    assert result.returncode == 0


def test_git_hooks_installed():
    """Test that git hooks are installed."""
    hooks_dir = Path(".git/hooks")
    assert (hooks_dir / "pre-commit").exists()
    assert (hooks_dir / "commit-msg").exists()
    assert (hooks_dir / "pre-push").exists()


def test_secrets_baseline_exists():
    """Test that secrets baseline exists."""
    baseline = Path(".secrets.baseline")
    assert baseline.exists()
    assert baseline.stat().st_size > 0
