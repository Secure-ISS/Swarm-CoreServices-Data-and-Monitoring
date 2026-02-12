# CI/CD Guide for Distributed PostgreSQL Cluster

## Table of Contents
- [Overview](#overview)
- [Pipeline Architecture](#pipeline-architecture)
- [Deployment Strategies](#deployment-strategies)
- [Environment Management](#environment-management)
- [Rollback Procedures](#rollback-procedures)
- [Secrets Management](#secrets-management)
- [Monitoring and Alerting](#monitoring-and-alerting)
- [Best Practices](#best-practices)

## Overview

This document describes the comprehensive CI/CD pipeline for the Distributed PostgreSQL Cluster project. The pipeline automates testing, building, and deployment processes to ensure code quality and reliable deployments.

### Pipeline Components

1. **Code Quality & Security** - Static analysis and security scanning
2. **Testing** - Unit, integration, E2E, and performance tests
3. **Build** - Docker image creation and scanning
4. **Deployment** - Automated deployment to staging and production
5. **Monitoring** - Post-deployment validation and monitoring

## Pipeline Architecture

### Multi-Stage Pipeline Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    Pull Request / Push                       │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ Stage 1: Code Quality & Security                             │
├─────────────────────────────────────────────────────────────┤
│ • Black formatter check          • Security scanning (Trivy) │
│ • isort import sorting           • Snyk dependency scan      │
│ • flake8 linting                 • Bandit security linting   │
│ • mypy type checking             • Secret detection          │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ Stage 2: Unit & Integration Tests                            │
├─────────────────────────────────────────────────────────────┤
│ • Unit tests (Python 3.10, 3.11, 3.12)                      │
│ • Code coverage (80% minimum)                                │
│ • Integration tests (PostgreSQL + Redis)                     │
│ • Database compatibility tests                               │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ Stage 3: E2E & Performance Tests                             │
├─────────────────────────────────────────────────────────────┤
│ • End-to-end tests                                           │
│ • Performance benchmarks                                     │
│ • Load testing (Locust)                                      │
│ • Regression detection                                       │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ Stage 4: Build Docker Images                                 │
├─────────────────────────────────────────────────────────────┤
│ • Build API image                                            │
│ • Multi-platform build (amd64, arm64)                        │
│ • Push to GHCR                                               │
│ • Security scan images                                       │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ Stage 5: Deploy to Staging                                   │
├─────────────────────────────────────────────────────────────┤
│ • Deploy to ECS/K8s staging                                  │
│ • Run smoke tests                                            │
│ • Verify health checks                                       │
│ • Automatic rollback on failure                              │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ Stage 6: Deploy to Production (Manual Approval)              │
├─────────────────────────────────────────────────────────────┤
│ • Blue-green deployment                                      │
│ • Traffic switching                                          │
│ • Production smoke tests                                     │
│ • Automatic rollback on failure                              │
│ • GitHub release creation                                    │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ Post-Deployment                                              │
├─────────────────────────────────────────────────────────────┤
│ • Slack/PagerDuty notifications                              │
│ • Monitoring alert verification                              │
│ • Performance baseline update                                │
└─────────────────────────────────────────────────────────────┘
```

### Workflow Files

| Workflow | Purpose | Trigger |
|----------|---------|---------|
| `ci-full-stack.yml` | Main CI/CD pipeline | Push, PR, Manual |
| `database-migrations.yml` | Database schema changes | Migration changes, Manual |
| `monitoring-tests.yml` | Monitoring config validation | Monitoring changes, Daily |

## Deployment Strategies

### 1. Blue-Green Deployment

Used for production deployments to minimize downtime and enable instant rollback.

**Process:**
1. Deploy new version to inactive environment (green)
2. Run health checks and smoke tests
3. Switch traffic from blue to green
4. Monitor for issues
5. Drain old environment if successful

**Benefits:**
- Zero-downtime deployments
- Instant rollback capability
- Full environment testing before traffic switch

**Implementation:**
```yaml
- name: Blue-Green Deployment
  run: |
    # Determine target environment
    CURRENT=$(get_active_environment)
    TARGET=$([ "$CURRENT" == "blue" ] && echo "green" || echo "blue")

    # Deploy to target
    deploy_to_environment $TARGET

    # Health check
    verify_health $TARGET

    # Switch traffic
    switch_traffic $TARGET

    # Drain old environment
    drain_environment $CURRENT
```

### 2. Canary Deployment

Gradually roll out changes to a subset of users to detect issues early.

**Process:**
1. Deploy new version to canary instances (10%)
2. Monitor metrics for 15 minutes
3. Gradually increase traffic (25%, 50%, 75%, 100%)
4. Rollback if error rate increases

**Benefits:**
- Risk mitigation
- Early issue detection
- Progressive rollout control

**Implementation:**
```bash
# Deploy canary
kubectl set image deployment/dpg-api \
  api=ghcr.io/myorg/dpg-api:$VERSION \
  -l track=canary

# Monitor metrics
python scripts/ci/monitor_canary.py \
  --duration 900 \
  --error-threshold 1.5 \
  --latency-threshold 1.2

# Promote or rollback
if [ $? -eq 0 ]; then
  kubectl set image deployment/dpg-api \
    api=ghcr.io/myorg/dpg-api:$VERSION \
    -l track=stable
else
  kubectl rollout undo deployment/dpg-api -l track=canary
fi
```

### 3. Rolling Deployment

Default strategy for staging environments.

**Process:**
1. Update instances one at a time
2. Wait for health check after each update
3. Continue if healthy, rollback if unhealthy

**Benefits:**
- No additional infrastructure required
- Gradual rollout
- Built-in rollback

## Environment Management

### Environment Configuration

| Environment | Purpose | Auto-Deploy | Approval Required |
|-------------|---------|-------------|-------------------|
| Development | Local testing | No | No |
| Staging | Pre-production testing | Yes (develop branch) | No |
| Production | Live environment | Yes (main branch) | Yes |

### Environment Variables

**Required Secrets:**
```bash
# AWS
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_REGION

# Database
DATABASE_URL
REDIS_URL

# Monitoring
PROMETHEUS_URL
GRAFANA_API_KEY

# Notifications
SLACK_WEBHOOK_URL
PAGERDUTY_API_KEY

# Container Registry
GHCR_TOKEN
```

**Environment-Specific Configuration:**
```yaml
# staging
cluster: dpg-cluster-staging
replicas: 2
resources:
  limits:
    cpu: "1"
    memory: "2Gi"

# production
cluster: dpg-cluster-production
replicas: 5
resources:
  limits:
    cpu: "4"
    memory: "8Gi"
```

### Infrastructure as Code

**Terraform Setup:**
```hcl
# environments/staging/main.tf
module "dpg_cluster" {
  source = "../../modules/dpg-cluster"

  environment = "staging"
  cluster_size = 3
  instance_type = "t3.medium"

  database_config = {
    max_connections = 100
    shared_buffers = "2GB"
  }
}
```

## Rollback Procedures

### Automatic Rollback

The pipeline includes automatic rollback triggers:

1. **Health Check Failure**
   - Triggered after deployment
   - Checks: HTTP 200 response, database connectivity
   - Rollback: Previous task definition/deployment

2. **Smoke Test Failure**
   - Triggered after health checks pass
   - Checks: Critical API endpoints, data integrity
   - Rollback: Previous version

3. **Error Rate Threshold**
   - Monitored continuously for 5 minutes post-deployment
   - Threshold: >2x baseline error rate
   - Rollback: Blue-green traffic switch or pod version

### Manual Rollback

**Production Rollback Script:**
```bash
#!/bin/bash
# scripts/ci/rollback-production.sh

set -e

CLUSTER="dpg-cluster-production"
SERVICE="dpg-api-production"

# Get current and previous task definitions
CURRENT=$(aws ecs describe-services \
  --cluster $CLUSTER \
  --services $SERVICE \
  --query 'services[0].taskDefinition' \
  --output text)

PREVIOUS=$(aws ecs describe-services \
  --cluster $CLUSTER \
  --services $SERVICE \
  --query 'services[0].deployments[1].taskDefinition' \
  --output text)

echo "Rolling back from $CURRENT to $PREVIOUS"

# Switch back to previous version
aws ecs update-service \
  --cluster $CLUSTER \
  --service $SERVICE \
  --task-definition $PREVIOUS \
  --force-new-deployment

# Wait for rollback to complete
aws ecs wait services-stable \
  --cluster $CLUSTER \
  --services $SERVICE

echo "Rollback complete"
```

**Database Rollback:**
```bash
# Rollback one migration
alembic downgrade -1

# Rollback to specific version
alembic downgrade <revision>

# Restore from backup
pg_restore -d $DATABASE_URL /path/to/backup.sql
```

**Manual Rollback via GitHub Actions:**
```bash
# Trigger rollback workflow
gh workflow run rollback.yml \
  --ref main \
  -f environment=production \
  -f target_version=v1.2.3
```

## Secrets Management

### GitHub Secrets

**Organization Secrets:**
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `GHCR_TOKEN`

**Environment Secrets:**
- `DATABASE_URL` (per environment)
- `REDIS_URL` (per environment)
- `GRAFANA_API_KEY` (per environment)

**Best Practices:**
1. Use environment-specific secrets
2. Rotate secrets regularly (quarterly)
3. Use service accounts with minimal permissions
4. Never log secrets or expose in error messages

### AWS Secrets Manager Integration

```python
# scripts/utils/secrets.py
import boto3
from botocore.exceptions import ClientError

def get_secret(secret_name: str, region: str = "us-west-2") -> dict:
    """Retrieve secret from AWS Secrets Manager."""
    client = boto3.client('secretsmanager', region_name=region)

    try:
        response = client.get_secret_value(SecretId=secret_name)
        return json.loads(response['SecretString'])
    except ClientError as e:
        raise Exception(f"Failed to retrieve secret: {e}")

# Usage
db_credentials = get_secret(f"dpg-cluster/{environment}/database")
DATABASE_URL = db_credentials['connection_string']
```

### Vault Integration (Alternative)

```bash
# Retrieve secrets from Vault
vault kv get -format=json secret/dpg-cluster/production | \
  jq -r '.data.data | to_entries[] | "\(.key)=\(.value)"' >> .env
```

## Monitoring and Alerting

### Deployment Metrics

**Tracked Metrics:**
- Deployment duration
- Success/failure rate
- Rollback frequency
- Time to detect issues
- Mean time to recovery (MTTR)

**Grafana Dashboard:**
```json
{
  "dashboard": "CI/CD Metrics",
  "panels": [
    {
      "title": "Deployment Success Rate",
      "query": "rate(deployments_total{status='success'}[1h])"
    },
    {
      "title": "Deployment Duration",
      "query": "histogram_quantile(0.95, deployment_duration_seconds)"
    }
  ]
}
```

### Deployment Alerts

**Critical Alerts:**
```yaml
# prometheus/alerts/ci_cd_alerts.yml
groups:
  - name: deployment_alerts
    interval: 30s
    rules:
      - alert: DeploymentFailed
        expr: |
          increase(deployments_total{status="failed"}[5m]) > 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Deployment failed in {{ $labels.environment }}"

      - alert: HighRollbackRate
        expr: |
          rate(deployments_total{status="rollback"}[1h]) > 0.2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High rollback rate detected"
```

### Post-Deployment Validation

```python
# scripts/ci/smoke_tests.py
import requests
import time
import sys

def run_smoke_tests(base_url: str, timeout: int = 300) -> bool:
    """Run critical path smoke tests."""

    tests = [
        {
            "name": "Health check",
            "url": f"{base_url}/health",
            "expected_status": 200,
            "critical": True
        },
        {
            "name": "Database connectivity",
            "url": f"{base_url}/api/v1/status",
            "expected_status": 200,
            "critical": True
        },
        {
            "name": "Vector search",
            "url": f"{base_url}/api/v1/vectors/search",
            "method": "POST",
            "data": {"query": [0.1] * 384, "limit": 10},
            "expected_status": 200,
            "critical": True
        }
    ]

    start_time = time.time()
    all_passed = True

    for test in tests:
        while time.time() - start_time < timeout:
            try:
                if test.get("method") == "POST":
                    response = requests.post(
                        test["url"],
                        json=test.get("data"),
                        timeout=10
                    )
                else:
                    response = requests.get(test["url"], timeout=10)

                if response.status_code == test["expected_status"]:
                    print(f"✓ {test['name']} passed")
                    break
                else:
                    print(f"✗ {test['name']} failed: {response.status_code}")
                    if test["critical"]:
                        all_passed = False
                        break
            except Exception as e:
                print(f"⚠ {test['name']} error: {e}")
                time.sleep(5)
        else:
            print(f"✗ {test['name']} timeout")
            if test["critical"]:
                all_passed = False

    return all_passed

if __name__ == "__main__":
    url = sys.argv[1]
    success = run_smoke_tests(url)
    sys.exit(0 if success else 1)
```

## Best Practices

### 1. Fast Feedback

- Run fast tests (linting, unit tests) first
- Parallelize independent test suites
- Cache dependencies (pip, Docker layers)
- Fail fast on critical issues

### 2. Reproducibility

- Pin all dependency versions
- Use identical environments (dev, staging, prod)
- Build once, deploy many
- Version all configurations

### 3. Security

- Scan for vulnerabilities at every stage
- Never commit secrets
- Use least-privilege IAM roles
- Sign container images

### 4. Observability

- Log all deployment events
- Track deployment metrics
- Set up alerts for failures
- Maintain deployment audit trail

### 5. Rollback Strategy

- Always have a rollback plan
- Test rollback procedures regularly
- Keep previous versions available
- Document rollback steps

## Troubleshooting

### Common Issues

**1. Failed Deployment - Health Check Timeout**
```bash
# Check pod/container logs
kubectl logs deployment/dpg-api -n production

# Check service status
kubectl describe service dpg-api -n production

# Check endpoints
kubectl get endpoints dpg-api -n production
```

**2. Database Migration Failure**
```bash
# Check migration logs
docker-compose logs postgres

# Manually inspect database
psql $DATABASE_URL

# Check current migration version
alembic current

# Rollback migration
alembic downgrade -1
```

**3. Docker Image Build Failure**
```bash
# Check build logs
docker build --progress=plain -f docker/Dockerfile.api .

# Test locally
docker run -it dpg-cluster:latest /bin/bash

# Check layer sizes
docker history dpg-cluster:latest
```

### Support Contacts

- **CI/CD Issues:** #devops-team
- **Database Issues:** #database-team
- **Security Issues:** #security-team
- **Emergency:** On-call via PagerDuty

## GitLab CI Examples

For teams using GitLab CI/CD:

```yaml
# .gitlab-ci.yml
stages:
  - test
  - build
  - deploy

variables:
  DOCKER_IMAGE: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA

test:unit:
  stage: test
  image: python:3.11
  script:
    - pip install -r requirements.txt -r requirements-dev.txt
    - pytest tests/unit/ --cov=src
  coverage: '/TOTAL.*\s+(\d+%)/'

build:
  stage: build
  image: docker:latest
  services:
    - docker:dind
  script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
    - docker build -t $DOCKER_IMAGE .
    - docker push $DOCKER_IMAGE

deploy:staging:
  stage: deploy
  script:
    - kubectl set image deployment/dpg-api api=$DOCKER_IMAGE
  environment:
    name: staging
  only:
    - develop

deploy:production:
  stage: deploy
  script:
    - kubectl set image deployment/dpg-api api=$DOCKER_IMAGE
  environment:
    name: production
  when: manual
  only:
    - main
```

## Jenkins Pipeline Examples

For teams using Jenkins:

```groovy
// Jenkinsfile
pipeline {
    agent any

    environment {
        DOCKER_IMAGE = "dpg-cluster:${BUILD_NUMBER}"
    }

    stages {
        stage('Test') {
            parallel {
                stage('Unit Tests') {
                    steps {
                        sh 'pytest tests/unit/ --junitxml=junit-unit.xml'
                    }
                }
                stage('Integration Tests') {
                    steps {
                        sh 'pytest tests/integration/ --junitxml=junit-integration.xml'
                    }
                }
            }
        }

        stage('Build') {
            steps {
                sh "docker build -t ${DOCKER_IMAGE} ."
                sh "docker tag ${DOCKER_IMAGE} dpg-cluster:latest"
            }
        }

        stage('Deploy to Staging') {
            when {
                branch 'develop'
            }
            steps {
                sh './scripts/deploy.sh staging ${DOCKER_IMAGE}'
            }
        }

        stage('Deploy to Production') {
            when {
                branch 'main'
            }
            steps {
                input message: 'Deploy to production?', ok: 'Deploy'
                sh './scripts/deploy.sh production ${DOCKER_IMAGE}'
            }
        }
    }

    post {
        always {
            junit '**/junit-*.xml'
            publishHTML([
                allowMissing: false,
                alwaysLinkToLastBuild: true,
                keepAll: true,
                reportDir: 'htmlcov',
                reportFiles: 'index.html',
                reportName: 'Coverage Report'
            ])
        }
        failure {
            slackSend(
                color: 'danger',
                message: "Build failed: ${env.JOB_NAME} ${env.BUILD_NUMBER}"
            )
        }
    }
}
```

## Automated Release Tagging

```bash
# scripts/ci/create_release.sh
#!/bin/bash

set -e

# Get version from git tags
CURRENT_VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
MAJOR=$(echo $CURRENT_VERSION | cut -d. -f1 | tr -d 'v')
MINOR=$(echo $CURRENT_VERSION | cut -d. -f2)
PATCH=$(echo $CURRENT_VERSION | cut -d. -f3)

# Increment based on commit messages
if git log $CURRENT_VERSION..HEAD --pretty=%B | grep -qi "BREAKING CHANGE"; then
    MAJOR=$((MAJOR + 1))
    MINOR=0
    PATCH=0
elif git log $CURRENT_VERSION..HEAD --pretty=%B | grep -qi "^feat"; then
    MINOR=$((MINOR + 1))
    PATCH=0
else
    PATCH=$((PATCH + 1))
fi

NEW_VERSION="v${MAJOR}.${MINOR}.${PATCH}"

# Create tag
git tag -a $NEW_VERSION -m "Release $NEW_VERSION"
git push origin $NEW_VERSION

# Generate changelog
git log $CURRENT_VERSION..HEAD --pretty=format:"- %s" > CHANGELOG_$NEW_VERSION.md

echo "Created release $NEW_VERSION"
```

## Change Log Generation

```python
# scripts/ci/generate_changelog.py
import subprocess
import re
from collections import defaultdict

def generate_changelog(since_tag: str) -> str:
    """Generate changelog from git commits."""

    # Get commits since tag
    result = subprocess.run(
        ['git', 'log', f'{since_tag}..HEAD', '--pretty=format:%s'],
        capture_output=True,
        text=True
    )

    commits = result.stdout.strip().split('\n')

    # Categorize commits
    categories = defaultdict(list)
    for commit in commits:
        match = re.match(r'^(feat|fix|docs|style|refactor|test|chore)(\(.+\))?: (.+)', commit)
        if match:
            category, scope, message = match.groups()
            categories[category].append(message)

    # Generate markdown
    changelog = f"# Changelog\n\n"

    category_names = {
        'feat': 'Features',
        'fix': 'Bug Fixes',
        'docs': 'Documentation',
        'refactor': 'Refactoring',
        'test': 'Tests',
        'chore': 'Chores'
    }

    for category, name in category_names.items():
        if category in categories:
            changelog += f"## {name}\n\n"
            for message in categories[category]:
                changelog += f"- {message}\n"
            changelog += "\n"

    return changelog

if __name__ == "__main__":
    import sys
    changelog = generate_changelog(sys.argv[1])
    print(changelog)
```

## Related Documentation

- [Monitoring Guide](MONITORING_GUIDE.md)
- [Database Migration Guide](DATABASE_MIGRATION.md)
- [Security Guide](SECURITY.md)
- [Contributing Guidelines](../CONTRIBUTING.md)
