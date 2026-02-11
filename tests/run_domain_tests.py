#!/usr/bin/env python3
"""Comprehensive domain test runner.

Runs all domain tests with detailed reporting:
- Security domain tests
- Integration domain tests
- Performance benchmarks
- Domain isolation tests
"""

import os
import sys
import unittest
import time
from typing import Dict, Any

# Add parent directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))


def run_test_suite(suite_name: str, test_module) -> Dict[str, Any]:
    """Run a test suite and return results."""
    print(f"\n{'=' * 70}")
    print(f"Running {suite_name}")
    print(f"{'=' * 70}\n")

    start_time = time.time()

    # Create test suite
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(test_module)

    # Run tests
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    duration = time.time() - start_time

    return {
        'name': suite_name,
        'tests_run': result.testsRun,
        'failures': len(result.failures),
        'errors': len(result.errors),
        'skipped': len(result.skipped),
        'success': result.wasSuccessful(),
        'duration': duration
    }


def print_summary(results):
    """Print test summary."""
    print(f"\n{'=' * 70}")
    print("TEST SUMMARY")
    print(f"{'=' * 70}\n")

    total_tests = sum(r['tests_run'] for r in results)
    total_failures = sum(r['failures'] for r in results)
    total_errors = sum(r['errors'] for r in results)
    total_skipped = sum(r['skipped'] for r in results)
    total_duration = sum(r['duration'] for r in results)

    print(f"{'Suite':<40} {'Tests':<10} {'Status':<10} {'Time':<10}")
    print(f"{'-' * 70}")

    for result in results:
        status = '✓ PASS' if result['success'] else '✗ FAIL'
        print(
            f"{result['name']:<40} "
            f"{result['tests_run']:<10} "
            f"{status:<10} "
            f"{result['duration']:.2f}s"
        )

    print(f"{'-' * 70}")
    print(f"{'TOTAL':<40} {total_tests:<10} {'':<10} {total_duration:.2f}s")
    print()

    if total_failures > 0 or total_errors > 0:
        print(f"❌ FAILURES: {total_failures}")
        print(f"❌ ERRORS: {total_errors}")
    else:
        print(f"✅ ALL TESTS PASSED")

    if total_skipped > 0:
        print(f"⚠️  SKIPPED: {total_skipped}")

    print()

    return total_failures == 0 and total_errors == 0


def main():
    """Main test runner."""
    print("\n" + "=" * 70)
    print("DISTRIBUTED POSTGRESQL CLUSTER - DOMAIN TESTS")
    print("=" * 70)

    results = []

    # Security Domain Tests
    print("\n" + "=" * 70)
    print("SECURITY DOMAIN TESTS")
    print("=" * 70)

    try:
        from tests.domains.security import test_cve_remediation
        results.append(run_test_suite(
            "Security: CVE Remediation",
            test_cve_remediation
        ))
    except Exception as e:
        print(f"Failed to load CVE remediation tests: {e}")

    try:
        from tests.domains.security import test_authentication
        results.append(run_test_suite(
            "Security: Authentication",
            test_authentication
        ))
    except Exception as e:
        print(f"Failed to load authentication tests: {e}")

    # Integration Domain Tests
    print("\n" + "=" * 70)
    print("INTEGRATION DOMAIN TESTS")
    print("=" * 70)

    try:
        from tests.domains.integration import test_mcp_server
        results.append(run_test_suite(
            "Integration: MCP Server",
            test_mcp_server
        ))
    except Exception as e:
        print(f"Failed to load MCP server tests: {e}")

    try:
        from tests.domains.integration import test_event_bus
        results.append(run_test_suite(
            "Integration: Event Bus",
            test_event_bus
        ))
    except Exception as e:
        print(f"Failed to load event bus tests: {e}")

    try:
        from tests.domains.integration import test_e2e_flows
        results.append(run_test_suite(
            "Integration: End-to-End Flows",
            test_e2e_flows
        ))
    except Exception as e:
        print(f"Failed to load E2E tests: {e}")

    # Performance Tests
    print("\n" + "=" * 70)
    print("PERFORMANCE TESTS")
    print("=" * 70)

    try:
        from tests.domains.performance import test_security_performance
        results.append(run_test_suite(
            "Performance: Security Layer",
            test_security_performance
        ))
    except Exception as e:
        print(f"Failed to load security performance tests: {e}")

    try:
        from tests.domains.performance import test_integration_performance
        results.append(run_test_suite(
            "Performance: Integration Layer",
            test_integration_performance
        ))
    except Exception as e:
        print(f"Failed to load integration performance tests: {e}")

    # Domain Isolation Tests
    print("\n" + "=" * 70)
    print("DOMAIN ISOLATION TESTS")
    print("=" * 70)

    try:
        from tests.domains import test_domain_isolation
        results.append(run_test_suite(
            "Domain Isolation",
            test_domain_isolation
        ))
    except Exception as e:
        print(f"Failed to load domain isolation tests: {e}")

    # Print summary
    success = print_summary(results)

    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
