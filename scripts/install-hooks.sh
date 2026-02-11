#!/bin/bash
# Pre-commit hooks installation and validation script
# For Distributed PostgreSQL Cluster
#
# Usage: bash scripts/install-hooks.sh

set -e  # Exit on error

echo "========================================="
echo "Pre-commit Hooks Installation"
echo "========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check Python version
echo -n "Checking Python version... "
PYTHON_VERSION=$(python3 --version 2>&1 | awk '{print $2}')
PYTHON_MAJOR=$(echo "$PYTHON_VERSION" | cut -d. -f1)
PYTHON_MINOR=$(echo "$PYTHON_VERSION" | cut -d. -f2)

if [ "$PYTHON_MAJOR" -lt 3 ] || { [ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 8 ]; }; then
    echo -e "${RED}✗ Python 3.8+ required (found $PYTHON_VERSION)${NC}"
    exit 1
fi
echo -e "${GREEN}✓ $PYTHON_VERSION${NC}"

# Check if git repository
echo -n "Checking git repository... "
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo -e "${RED}✗ Not a git repository${NC}"
    exit 1
fi
echo -e "${GREEN}✓${NC}"

# Install pre-commit framework
echo ""
echo "Installing pre-commit framework..."
pip install --upgrade pre-commit

# Install code quality tools
echo ""
echo "Installing code quality tools..."
pip install --upgrade \
    black==24.2.0 \
    flake8==7.0.0 \
    flake8-docstrings \
    flake8-bugbear \
    flake8-comprehensions \
    flake8-simplify \
    isort==5.13.2 \
    mypy==1.8.0 \
    types-redis \
    types-psycopg2 \
    types-PyYAML \
    types-requests \
    bandit==1.7.6 \
    detect-secrets==1.4.0

# Install pytest if not already installed
if ! pip show pytest > /dev/null 2>&1; then
    echo ""
    echo "Installing pytest..."
    pip install pytest pytest-cov pytest-asyncio
fi

# Install pre-commit hooks
echo ""
echo "Installing pre-commit hooks..."
pre-commit install
pre-commit install --hook-type commit-msg
pre-commit install --hook-type pre-push

# Generate secrets baseline if it doesn't exist
if [ ! -f .secrets.baseline ]; then
    echo ""
    echo "Generating secrets baseline..."
    detect-secrets scan > .secrets.baseline
fi

# Validate hook configuration
echo ""
echo "Validating hook configuration..."
pre-commit validate-config

# Run hooks on all files (optional - can be slow)
echo ""
echo -e "${YELLOW}Do you want to run hooks on all existing files? (y/N)${NC}"
read -r response
if [[ "$response" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Running pre-commit on all files (this may take a while)..."
    if pre-commit run --all-files; then
        echo -e "${GREEN}✓ All hooks passed${NC}"
    else
        echo -e "${YELLOW}⚠ Some hooks failed - review output above${NC}"
        echo "  You can fix issues and run: pre-commit run --all-files"
    fi
else
    echo "Skipping full validation. Run 'pre-commit run --all-files' when ready."
fi

# Success message
echo ""
echo "========================================="
echo -e "${GREEN}✓ Pre-commit hooks installed successfully!${NC}"
echo "========================================="
echo ""
echo "Usage:"
echo "  • Hooks run automatically on git commit"
echo "  • Manual run: pre-commit run --all-files"
echo "  • Skip hook:  SKIP=hook-name git commit -m 'message'"
echo "  • Update:     pre-commit autoupdate"
echo ""
echo "Installed hooks:"
echo "  • black          - Python code formatter"
echo "  • isort          - Import statement organizer"
echo "  • flake8         - Python linter"
echo "  • mypy           - Static type checker"
echo "  • bandit         - Security linter"
echo "  • detect-secrets - Secret detection"
echo "  • pytest-quick   - Fast unit tests"
echo "  • File checks    - Whitespace, YAML, JSON, etc."
echo ""
echo "Configuration:"
echo "  • .pre-commit-config.yaml - Hook configuration"
echo "  • .secrets.baseline       - Known secrets baseline"
echo "  • pytest.ini              - Test configuration"
echo ""
