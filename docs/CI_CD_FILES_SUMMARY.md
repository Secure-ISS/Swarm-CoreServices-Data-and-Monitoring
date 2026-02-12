# CI/CD Files Summary

This document provides an overview of all CI/CD pipeline files created for the Distributed PostgreSQL Cluster project.

## GitHub Actions Workflows

### 1. `.github/workflows/ci-full-stack.yml`
**Purpose:** Main CI/CD pipeline for testing, building, and deploying the application.

**Stages:**
1. **Code Quality & Security**
   - Black formatter check
   - isort import sorting
   - flake8 linting
   - pylint code analysis
   - mypy type checking
   - Trivy security scanning
   - Snyk dependency scanning
   - Bandit security linting

2. **Unit & Integration Tests**
   - Unit tests (Python 3.10, 3.11, 3.12)
   - Code coverage (80% minimum)
   - Integration tests with PostgreSQL and Redis
   - Coverage reporting to Codecov

3. **E2E & Performance Tests**
   - End-to-end tests
   - Performance benchmarks
   - Locust load testing
   - Regression detection

4. **Build Docker Images**
   - Multi-platform builds (amd64, arm64)
   - Push to GitHub Container Registry
   - Image security scanning

5. **Deploy to Staging**
   - Automated deployment to AWS ECS/Kubernetes
   - Smoke tests
   - Automatic rollback on failure

6. **Deploy to Production**
   - Manual approval required
   - Blue-green deployment
   - Production smoke tests
   - GitHub release creation
   - Automatic rollback on failure

**Triggers:**
- Push to main or develop branches
- Pull requests
- Manual workflow dispatch

---

### 2. `.github/workflows/database-migrations.yml`
**Purpose:** Automated database schema migrations with validation and rollback capabilities.

**Features:**
- **Validate Migrations**
  - SQL syntax validation
  - Migration order checking
  - Conflict detection
  - Reversibility verification

- **Test Migrations**
  - Fresh database migration testing
  - Upgrade testing with existing data
  - Data integrity validation
  - Rollback testing

- **RuVector Extension Upgrade**
  - Version upgrade testing
  - Backup and restore validation
  - Functionality verification

- **Deploy Migrations**
  - Staging deployment (automatic)
  - Production deployment (manual approval)
  - Pre-migration backups
  - Automatic rollback on failure

**Triggers:**
- Changes to `migrations/` or `scripts/sql/`
- Manual workflow dispatch with environment selection

---

### 3. `.github/workflows/monitoring-tests.yml`
**Purpose:** Validate monitoring configuration, Prometheus rules, and Grafana dashboards.

**Features:**
- **Prometheus Validation**
  - Configuration syntax checking
  - Recording rules validation
  - Alerting rules validation
  - Rule evaluation testing

- **Grafana Validation**
  - Dashboard JSON validation
  - Best practices checking
  - Compatibility verification

- **Integration Tests**
  - Full monitoring stack testing
  - End-to-end alert flow testing
  - Dashboard query validation

- **Performance Tests**
  - Metrics ingestion load testing
  - Query performance measurement

- **Security Scan**
  - Secrets detection
  - TLS configuration validation
  - Docker image scanning

**Triggers:**
- Changes to monitoring configuration files
- Daily scheduled run (2 AM UTC)
- Manual workflow dispatch

---

## CI Scripts

### 1. `scripts/ci/validate-pr.sh`
**Purpose:** Comprehensive pre-merge validation script for pull requests.

**Checks:**
- Code quality (Black, isort, flake8, pylint, mypy)
- Security scanning (Bandit, Snyk, Trivy)
- Dependency vulnerabilities
- Unit tests
- Integration tests
- Database compatibility
- Documentation completeness
- Docker image build
- Performance regression tests
- Git checks (commit format, large files, conflicts)
- Code coverage (80% minimum)

**Usage:**
```bash
./scripts/ci/validate-pr.sh
```

**Output:**
- Terminal output with colored status messages
- `pr-validation-report.md` - Detailed validation report

---

### 2. `scripts/ci/validate_migrations.py`
**Purpose:** Validate database migration files for syntax, order, and conflicts.

**Features:**
- SQL syntax validation using sqlparse
- Migration order checking
- Reversibility verification
- Naming convention validation
- Conflict detection (multi-branch)
- Dangerous operation detection (DROP DATABASE, TRUNCATE)

**Usage:**
```bash
python scripts/ci/validate_migrations.py \
  --path migrations/ \
  --check-syntax \
  --check-order \
  --check-reversibility \
  --check-conflicts \
  --base-branch origin/main
```

---

### 3. `scripts/ci/check_performance_regression.py`
**Purpose:** Detect performance regressions by comparing benchmark results.

**Features:**
- Compare current vs baseline benchmarks
- Configurable threshold (default 10%)
- Support for pytest-benchmark format
- Support for custom benchmark formats
- Detailed regression reporting
- Performance improvement detection

**Usage:**
```bash
python scripts/ci/check_performance_regression.py \
  --current benchmark.json \
  --baseline performance-baseline.json \
  --threshold 10 \
  --output regression-report.json
```

---

### 4. `scripts/ci/create_release.sh`
**Purpose:** Automated release creation with semantic versioning and changelog generation.

**Features:**
- Semantic versioning (major, minor, patch)
- Automatic version bump detection from commits
- Changelog generation by category:
  - Breaking changes
  - Features
  - Bug fixes
  - Refactoring
  - Documentation
  - Tests
  - Chores
- Git tag creation
- GitHub release creation
- Contributor listing

**Usage:**
```bash
# Auto-detect version bump
./scripts/ci/create_release.sh

# Explicit version bump
./scripts/ci/create_release.sh --major
./scripts/ci/create_release.sh --minor
./scripts/ci/create_release.sh --patch

# Dry run (preview without changes)
./scripts/ci/create_release.sh --dry-run

# Skip GitHub release
./scripts/ci/create_release.sh --skip-github
```

**Output:**
- Git tag (e.g., `v1.2.3`)
- `CHANGELOG_v1.2.3.md` - Version-specific changelog
- Updated `CHANGELOG.md` - Main changelog file
- GitHub release (optional)

---

## Alternative CI/CD Platforms

### 1. `.gitlab-ci.yml.example`
**Purpose:** GitLab CI/CD pipeline configuration.

**Features:**
- Multi-stage pipeline (validate, test, build, deploy)
- Parallel job execution
- Docker-based builds
- Kubernetes deployment
- Blue-green deployment for production
- Database migration jobs
- Monitoring configuration updates
- Slack notifications

**Usage:**
```bash
# Rename to use
mv .gitlab-ci.yml.example .gitlab-ci.yml
```

---

### 2. `Jenkinsfile.example`
**Purpose:** Jenkins pipeline configuration.

**Features:**
- Declarative pipeline syntax
- Parallel stage execution
- Docker agent support
- Integration with Kubernetes
- Blue-green deployment
- Manual approval gates
- Slack notifications
- HTML coverage reports
- Automatic GitHub release creation

**Usage:**
```bash
# Rename to use
mv Jenkinsfile.example Jenkinsfile
```

---

## Documentation

### 1. `docs/CI_CD_GUIDE.md`
**Purpose:** Comprehensive CI/CD guide covering all aspects of the pipeline.

**Contents:**
- Pipeline architecture overview
- Multi-stage pipeline flow diagram
- Deployment strategies:
  - Blue-green deployment
  - Canary deployment
  - Rolling deployment
- Environment management
- Rollback procedures:
  - Automatic rollback triggers
  - Manual rollback scripts
  - Database rollback
- Secrets management:
  - GitHub Secrets
  - AWS Secrets Manager
  - Vault integration
- Monitoring and alerting:
  - Deployment metrics
  - Critical alerts
  - Post-deployment validation
- Best practices
- Troubleshooting guide
- Alternative platform examples (GitLab CI, Jenkins)
- Automated release tagging
- Changelog generation

---

## Environment Variables Required

### GitHub Actions Secrets

**AWS:**
- `AWS_ACCESS_KEY_ID` - AWS access key
- `AWS_SECRET_ACCESS_KEY` - AWS secret key

**Database:**
- `STAGING_DATABASE_URL` - Staging database connection string
- `PRODUCTION_DATABASE_URL` - Production database connection string

**Container Registry:**
- `GHCR_TOKEN` - GitHub Container Registry token (auto-provided)

**Monitoring:**
- `PROMETHEUS_URL` - Prometheus server URL
- `ALERTMANAGER_URL` - AlertManager server URL
- `GRAFANA_URL` - Grafana server URL
- `GRAFANA_API_KEY` - Grafana API key

**Notifications:**
- `SLACK_WEBHOOK_URL` - Slack webhook for notifications
- `SLACK_WEBHOOK_TEST_URL` - Slack webhook for testing
- `PAGERDUTY_API_KEY` - PagerDuty integration key
- `PAGERDUTY_TEST_KEY` - PagerDuty test key

**Security:**
- `SNYK_TOKEN` - Snyk API token for security scanning
- `CODECOV_TOKEN` - Codecov token for coverage reporting

**Kubernetes:**
- `KUBE_URL` - Kubernetes API server URL
- `KUBE_TOKEN` - Kubernetes authentication token

**Maintenance:**
- `MAINTENANCE_MODE_URL` - Maintenance mode API endpoint
- `MAINTENANCE_TOKEN` - Maintenance mode API token

---

## Quick Start

### 1. Setup GitHub Actions

```bash
# Ensure secrets are configured in GitHub repository settings
# Settings > Secrets and variables > Actions

# The workflows will run automatically on:
# - Push to main or develop
# - Pull requests
# - Manual trigger via GitHub Actions UI
```

### 2. Run PR Validation Locally

```bash
# Install dependencies
pip install -r requirements.txt -r requirements-dev.txt

# Run validation
./scripts/ci/validate-pr.sh
```

### 3. Create a Release

```bash
# Auto-detect version bump from commits
./scripts/ci/create_release.sh

# Or specify version bump explicitly
./scripts/ci/create_release.sh --minor
```

### 4. Manual Database Migration

```bash
# Staging
gh workflow run database-migrations.yml \
  -f environment=staging \
  -f action=migrate

# Production (requires approval)
gh workflow run database-migrations.yml \
  -f environment=production \
  -f action=migrate
```

---

## Pipeline Metrics

**Target Performance:**
- Code quality checks: < 2 minutes
- Unit tests: < 5 minutes
- Integration tests: < 10 minutes
- E2E tests: < 15 minutes
- Docker build: < 5 minutes
- Total pipeline: < 30 minutes (staging), < 45 minutes (production)

**Coverage Requirements:**
- Unit test coverage: ≥ 80%
- Integration test coverage: ≥ 60%
- Critical path coverage: 100%

**Deployment Frequency:**
- Staging: Multiple times per day
- Production: Daily (with manual approval)

**Change Failure Rate Target:** < 5%

**Mean Time to Recovery (MTTR):** < 15 minutes

---

## Monitoring Dashboards

**CI/CD Metrics Dashboard:**
- Deployment success rate
- Deployment duration
- Time to detect issues
- Rollback frequency
- Test execution time
- Code coverage trends

**Access:**
- Grafana: https://grafana.dpg-cluster.example.com/d/cicd
- GitHub Actions: Repository > Actions tab

---

## Support and Troubleshooting

**Common Issues:**

1. **Pipeline failing on code quality checks**
   - Run `black src/ tests/` to format code
   - Run `isort src/ tests/` to fix imports
   - Fix linting issues reported by flake8

2. **Tests failing locally but passing in CI**
   - Check Python version matches CI (3.11)
   - Ensure all dependencies are installed
   - Check environment variables

3. **Deployment failing**
   - Check service logs: `kubectl logs deployment/dpg-api`
   - Verify secrets are configured correctly
   - Check database connectivity

4. **Docker image build failing**
   - Test locally: `docker build -f docker/Dockerfile.api .`
   - Check for dependency conflicts
   - Verify base image is available

**Get Help:**
- CI/CD issues: #devops-team
- Database issues: #database-team
- Security issues: #security-team

---

## Related Documentation

- [CI/CD Guide](CI_CD_GUIDE.md) - Detailed guide with examples
- [Monitoring Guide](MONITORING_GUIDE.md) - Monitoring configuration
- [Database Migration Guide](DATABASE_MIGRATION.md) - Migration procedures
- [Security Guide](SECURITY.md) - Security best practices
- [Contributing Guidelines](../CONTRIBUTING.md) - How to contribute

---

## Version History

- **v1.0.0** (2026-02-12): Initial CI/CD pipeline implementation
  - GitHub Actions workflows
  - GitLab CI example
  - Jenkins pipeline example
  - Validation scripts
  - Automated release creation
  - Comprehensive documentation
