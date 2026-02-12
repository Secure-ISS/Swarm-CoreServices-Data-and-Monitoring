# Contributing to Distributed PostgreSQL Cluster

Thank you for your interest in contributing to the Distributed PostgreSQL Cluster project. This document provides guidelines for contributing code, documentation, and other improvements.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Code Style Guidelines](#code-style-guidelines)
- [Git Workflow](#git-workflow)
- [Testing Requirements](#testing-requirements)
- [Documentation Standards](#documentation-standards)
- [Pull Request Process](#pull-request-process)
- [Review Process](#review-process)

## Code of Conduct

### Our Standards

- Be respectful and inclusive
- Welcome newcomers and help them get started
- Focus on constructive feedback
- Accept responsibility for mistakes
- Prioritize community benefit over individual gain

### Enforcement

Violations can be reported to the project maintainers. All complaints will be reviewed and investigated promptly and fairly.

## Getting Started

### Prerequisites

- Python 3.9+
- Docker and Docker Compose
- PostgreSQL 14+ knowledge
- Git
- Node.js 20+ (for CLI tools)

### Quick Start

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/Distributed-Postgress-Cluster.git
   cd Distributed-Postgress-Cluster
   ```

3. Set up your development environment (see [Development Setup](#development-setup))

4. Create a feature branch:
   ```bash
   git checkout -b feature/your-feature-name
   ```

5. Make your changes and commit following our guidelines

6. Push to your fork and submit a pull request

## Development Setup

See [docs/DEVELOPER_GUIDE.md](docs/DEVELOPER_GUIDE.md) for detailed setup instructions.

### Quick Setup

```bash
# 1. Copy environment template
cp .env.example .env

# 2. Start database
./scripts/start_database.sh

# 3. Install Python dependencies
pip install -r requirements.txt

# 4. Run health check
python3 scripts/db_health_check.py

# 5. Run tests
python3 src/test_vector_ops.py
```

## Code Style Guidelines

### Python

We follow [PEP 8](https://www.python.org/dev/peps/pep-0008/) with these specific requirements:

#### Formatting

- **Line length**: Maximum 100 characters
- **Indentation**: 4 spaces (no tabs)
- **Quotes**: Double quotes for strings, single quotes for dict keys
- **Blank lines**: 2 blank lines between top-level definitions

#### Naming Conventions

```python
# Classes: PascalCase
class DatabasePool:
    pass

# Functions/methods: snake_case
def get_connection_pool():
    pass

# Constants: UPPER_SNAKE_CASE
MAX_CONNECTIONS = 100

# Private methods: _leading_underscore
def _internal_helper():
    pass

# Variables: snake_case
user_count = 0
connection_pool = None
```

#### Docstrings

Use Google-style docstrings:

```python
def store_memory(
    cursor,
    namespace: str,
    key: str,
    value: str,
    embedding: Optional[List[float]] = None,
) -> None:
    """Store a memory entry with optional vector embedding.

    Args:
        cursor: Database cursor from pool
        namespace: Namespace for organizing memories
        key: Unique key within the namespace
        value: The content to store
        embedding: Optional 384-dimensional vector

    Raises:
        InvalidEmbeddingError: If embedding dimensions != 384
        VectorOperationError: If database operation fails

    Example:
        >>> with pools.project_cursor() as cur:
        ...     store_memory(cur, "test", "key1", "value", [0.1] * 384)
    """
    pass
```

#### Type Hints

Always use type hints for function signatures:

```python
from typing import Any, Dict, List, Optional

def search_memory(
    cursor,
    namespace: str,
    query_embedding: List[float],
    limit: int = 10,
) -> List[Dict[str, Any]]:
    pass
```

#### Error Handling

```python
# Good - specific exceptions
try:
    result = database_operation()
except DatabaseConnectionError as e:
    logger.error(f"Connection failed: {e}")
    raise
except InvalidEmbeddingError as e:
    logger.error(f"Invalid embedding: {e}")
    return None

# Bad - catch-all
try:
    result = database_operation()
except Exception as e:
    pass
```

#### Imports

Order imports in 3 groups with blank lines:

```python
# 1. Standard library
import json
import logging
from typing import Any, Dict

# 2. Third-party
import psycopg2
from psycopg2.extras import RealDictCursor

# 3. Local modules
from .pool import get_pools
from .vector_ops import store_memory
```

#### Comments

```python
# Good - explain WHY, not WHAT
# Use cosine distance for HNSW index performance
embedding_str = f"[{','.join(str(v) for v in embedding)}]"

# Bad - explain obvious things
# Convert embedding to string
embedding_str = str(embedding)
```

### SQL

#### Style

- Keywords in UPPERCASE
- Identifiers in lowercase
- Indent 4 spaces
- One column per line in SELECT

```sql
-- Good
SELECT
    namespace,
    key,
    value,
    created_at
FROM memory_entries
WHERE namespace = %s
    AND created_at > NOW() - INTERVAL '1 day'
ORDER BY created_at DESC
LIMIT 10;

-- Bad
select namespace,key,value from memory_entries where namespace=%s;
```

#### Parameterization

Always use parameterized queries:

```python
# Good - prevents SQL injection
cursor.execute(
    "SELECT * FROM memory_entries WHERE namespace = %s",
    (namespace,)
)

# Bad - vulnerable to SQL injection
cursor.execute(
    f"SELECT * FROM memory_entries WHERE namespace = '{namespace}'"
)
```

### Shell Scripts

- Use `#!/bin/bash` shebang
- Set error handling: `set -euo pipefail`
- Quote variables: `"${VAR}"`
- Use descriptive function names

```bash
#!/bin/bash
set -euo pipefail

# Function to start database
start_database() {
    local db_name="${1}"
    local port="${2:-5432}"

    docker start "${db_name}" || {
        echo "Failed to start ${db_name}"
        return 1
    }
}
```

## Git Workflow

### Branch Naming

Use descriptive branch names with prefixes:

```
feature/add-patroni-support
bugfix/connection-pool-leak
hotfix/security-vulnerability
docs/update-contributing-guide
refactor/simplify-vector-ops
test/add-integration-tests
```

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

#### Types

- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only
- `style`: Code style changes (formatting)
- `refactor`: Code refactoring
- `perf`: Performance improvement
- `test`: Adding/updating tests
- `chore`: Build/config changes

#### Examples

```
feat(pool): add SSL/TLS support for database connections

Add SSL/TLS configuration options to connection pools with support
for certificate-based authentication.

Closes #123

---

fix(vector): validate embedding dimensions before database insert

Prevents InvalidEmbeddingError by checking dimensions (must be 384)
before attempting database operations.

---

docs(contributing): add code style guidelines

---

test(pool): add connection pool capacity tests

Test concurrent connection handling up to 40 agents.
```

#### Commit Best Practices

- Keep commits atomic (one logical change per commit)
- Write descriptive commit messages
- Reference issues/PRs in commit footer
- Sign commits when possible: `git commit -S`

### Branching Strategy

```
main (production-ready)
  ├── develop (integration branch)
  │   ├── feature/new-feature
  │   ├── bugfix/fix-issue
  │   └── refactor/improve-code
  └── hotfix/critical-fix
```

**Workflow:**

1. Create feature branch from `develop`
2. Make changes and commit
3. Push to your fork
4. Create PR to `develop`
5. After review and approval, merge to `develop`
6. Periodically merge `develop` to `main`

## Testing Requirements

### Test Coverage

- Minimum 80% code coverage
- All new features must have tests
- Bug fixes must include regression tests

### Test Types

#### Unit Tests

Test individual functions/methods in isolation:

```python
import unittest
from src.db.vector_ops import store_memory, InvalidEmbeddingError

class TestVectorOps(unittest.TestCase):
    def test_store_memory_validates_embedding_dimensions(self):
        """Test that store_memory validates embedding dimensions."""
        cursor = Mock()
        embedding = [0.1] * 512  # Wrong dimension

        with self.assertRaises(InvalidEmbeddingError):
            store_memory(cursor, "test", "key", "value", embedding)
```

#### Integration Tests

Test interaction between components:

```python
def test_end_to_end_memory_operations(self):
    """Test complete workflow: store, search, retrieve."""
    pools = DualDatabasePools()

    # Store
    with pools.project_cursor() as cur:
        store_memory(cur, "test", "key1", "value1", embedding)

    # Search
    with pools.project_cursor() as cur:
        results = search_memory(cur, "test", query_embedding)
        assert len(results) == 1

    # Retrieve
    with pools.project_cursor() as cur:
        result = retrieve_memory(cur, "test", "key1")
        assert result["value"] == "value1"
```

#### Performance Tests

Test performance characteristics:

```python
def test_search_performance(self):
    """Test that vector search completes within 50ms."""
    import time

    with pools.project_cursor() as cur:
        start = time.time()
        results = search_memory(cur, "test", embedding, limit=100)
        duration = (time.time() - start) * 1000

        assert duration < 50, f"Search took {duration}ms (max 50ms)"
```

### Running Tests

```bash
# Run all tests
python3 -m pytest

# Run specific test file
python3 -m pytest src/test_vector_ops.py

# Run with coverage
python3 -m pytest --cov=src --cov-report=html

# Run integration tests only
python3 -m pytest -m integration

# Run performance tests
python3 -m pytest -m performance
```

### Test Requirements for PRs

Before submitting a PR:

1. All existing tests pass
2. New code has tests
3. Coverage doesn't decrease
4. Performance tests pass (if applicable)
5. Integration tests pass
6. No flaky tests

## Documentation Standards

### Code Documentation

- All public functions/classes must have docstrings
- Use Google-style docstrings
- Include examples for complex functions
- Document exceptions raised

### File Headers

Include module docstring at top of file:

```python
"""Vector operations for memory storage and retrieval.

This module provides functions for storing, retrieving, and searching
vector embeddings in PostgreSQL with RuVector extension.

Example:
    >>> from src.db import get_pools
    >>> pools = get_pools()
    >>> with pools.project_cursor() as cur:
    ...     store_memory(cur, "test", "key", "value", embedding)
"""
```

### README Updates

Update README.md if you:

- Add new features
- Change installation process
- Modify configuration
- Add dependencies

### Documentation Files

When adding new major features:

1. Update relevant docs in `/docs`
2. Add examples to `/examples`
3. Update API reference
4. Add troubleshooting section

### Documentation Style

- Use Markdown for all documentation
- Use code fences with language tags
- Include command output examples
- Use tables for structured data
- Add diagrams for complex concepts

## Pull Request Process

### Before Submitting

1. **Update from develop**:
   ```bash
   git checkout develop
   git pull upstream develop
   git checkout your-branch
   git rebase develop
   ```

2. **Run all tests**:
   ```bash
   python3 -m pytest
   python3 scripts/db_health_check.py
   ```

3. **Check code style**:
   ```bash
   black src/
   flake8 src/
   mypy src/
   ```

4. **Update documentation**:
   - Update docstrings
   - Update README if needed
   - Add examples if applicable

### PR Template

When creating a PR, include:

```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix (non-breaking change fixing an issue)
- [ ] New feature (non-breaking change adding functionality)
- [ ] Breaking change (fix or feature causing existing functionality to change)
- [ ] Documentation update

## Testing
- [ ] All existing tests pass
- [ ] Added new tests for new functionality
- [ ] Integration tests pass
- [ ] Performance tests pass (if applicable)

## Checklist
- [ ] Code follows project style guidelines
- [ ] Self-reviewed code
- [ ] Commented complex sections
- [ ] Updated documentation
- [ ] No new warnings
- [ ] Added tests for new code
- [ ] All tests pass

## Related Issues
Closes #123
Related to #456

## Screenshots (if applicable)
```

### PR Size Guidelines

- Keep PRs focused and reasonably sized
- Large PRs should be split into smaller ones
- Maximum ~500 lines of code changes
- Exception: Auto-generated code, migrations

## Review Process

### For Reviewers

#### What to Check

1. **Functionality**: Does it work as intended?
2. **Tests**: Are there adequate tests?
3. **Code Quality**: Follows style guidelines?
4. **Performance**: Any performance concerns?
5. **Security**: Any security implications?
6. **Documentation**: Is it documented?

#### Review Checklist

```markdown
- [ ] Code is clear and maintainable
- [ ] Follows project conventions
- [ ] Tests are comprehensive
- [ ] No obvious bugs
- [ ] No security vulnerabilities
- [ ] Performance is acceptable
- [ ] Documentation is updated
- [ ] Commit messages are clear
```

#### Providing Feedback

```markdown
# Good feedback - specific and actionable
The error handling here could be improved. Consider catching specific
exceptions (DatabaseError) instead of a generic Exception.

# Bad feedback - vague
This doesn't look right.
```

### For Contributors

#### Responding to Feedback

- Be open to feedback
- Ask questions if unclear
- Make requested changes promptly
- Push updates to same branch
- Respond to comments

#### After Approval

1. Maintainer will merge PR
2. Delete feature branch after merge
3. Pull latest changes from develop

### Review Timeline

- Simple PRs: 1-2 days
- Complex PRs: 3-5 days
- Breaking changes: 5-7 days

## Development Tips

### Local Testing

```bash
# Quick test cycle
./scripts/start_database.sh
python3 scripts/db_health_check.py
python3 src/test_vector_ops.py
```

### Debugging

```python
# Enable debug logging
import logging
logging.basicConfig(level=logging.DEBUG)

# Use breakpoint()
def search_memory(cursor, namespace, embedding):
    breakpoint()  # Debugger will stop here
    cursor.execute(...)
```

### Performance Profiling

```python
import cProfile
import pstats

# Profile function
cProfile.run('search_memory(cur, "test", embedding)', 'profile.stats')

# View results
stats = pstats.Stats('profile.stats')
stats.sort_stats('cumulative')
stats.print_stats(10)
```

## Getting Help

- **Documentation**: Check [docs/](docs/) directory
- **Issues**: Search existing issues
- **Discussions**: Use GitHub Discussions
- **Chat**: Join our Discord (link in README)

## License

By contributing, you agree that your contributions will be licensed under the project's MIT License.

## Acknowledgments

Thank you for contributing to making this project better!
