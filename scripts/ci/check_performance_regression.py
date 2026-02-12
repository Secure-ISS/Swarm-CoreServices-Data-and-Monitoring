#!/usr/bin/env python3
"""
Check for performance regressions by comparing benchmark results.
"""

# Standard library imports
import argparse
import json
import sys
from typing import Dict, List, Tuple


class PerformanceRegressionChecker:
    """Check for performance regressions in benchmark results."""

    def __init__(self, threshold: float = 10.0):
        """
        Initialize checker.

        Args:
            threshold: Percentage threshold for regression detection (default 10%)
        """
        self.threshold = threshold
        self.regressions: List[Dict] = []
        self.improvements: List[Dict] = []

    def compare_benchmarks(self, current_file: str, baseline_file: str) -> bool:
        """
        Compare current benchmarks against baseline.

        Args:
            current_file: Path to current benchmark results (JSON)
            baseline_file: Path to baseline benchmark results (JSON)

        Returns:
            True if no significant regressions detected
        """

        print("=" * 70)
        print("PERFORMANCE REGRESSION CHECK")
        print("=" * 70)

        # Load benchmark data
        try:
            with open(current_file, "r") as f:
                current_data = json.load(f)
        except FileNotFoundError:
            print(f"❌ Current benchmark file not found: {current_file}")
            return False

        try:
            with open(baseline_file, "r") as f:
                baseline_data = json.load(f)
        except FileNotFoundError:
            print(f"⚠️  Baseline file not found: {baseline_file}")
            print("Creating new baseline...")
            return True

        # Compare benchmarks
        self._compare_results(current_data, baseline_data)

        # Print results
        self._print_summary()

        return len(self.regressions) == 0

    def _compare_results(self, current: Dict, baseline: Dict) -> None:
        """Compare benchmark results."""

        # Handle pytest-benchmark format
        if "benchmarks" in current:
            self._compare_pytest_benchmarks(current["benchmarks"], baseline.get("benchmarks", []))
        # Handle custom format
        elif "results" in current:
            self._compare_custom_benchmarks(current["results"], baseline.get("results", {}))

    def _compare_pytest_benchmarks(self, current: List[Dict], baseline: List[Dict]) -> None:
        """Compare pytest-benchmark results."""

        # Create lookup dict for baseline
        baseline_dict = {b["name"]: b for b in baseline}

        for bench in current:
            name = bench["name"]
            current_mean = bench["stats"]["mean"]

            if name not in baseline_dict:
                print(f"ℹ️  New benchmark: {name}")
                continue

            baseline_mean = baseline_dict[name]["stats"]["mean"]

            # Calculate change percentage
            change_pct = ((current_mean - baseline_mean) / baseline_mean) * 100

            result = {
                "name": name,
                "current": current_mean,
                "baseline": baseline_mean,
                "change_pct": change_pct,
                "threshold": self.threshold,
            }

            if change_pct > self.threshold:
                self.regressions.append(result)
            elif change_pct < -self.threshold:
                self.improvements.append(result)

    def _compare_custom_benchmarks(self, current: Dict, baseline: Dict) -> None:
        """Compare custom benchmark format."""

        for key, current_value in current.items():
            if key not in baseline:
                print(f"ℹ️  New benchmark: {key}")
                continue

            baseline_value = baseline[key]

            # Handle different metric types
            if isinstance(current_value, dict):
                metric_name = current_value.get("metric", "duration")
                current_val = current_value.get("value")
                baseline_val = baseline_value.get("value")
            else:
                metric_name = "value"
                current_val = current_value
                baseline_val = baseline_value

            if current_val is None or baseline_val is None:
                continue

            # Calculate change
            change_pct = ((current_val - baseline_val) / baseline_val) * 100

            result = {
                "name": key,
                "metric": metric_name,
                "current": current_val,
                "baseline": baseline_val,
                "change_pct": change_pct,
                "threshold": self.threshold,
            }

            if change_pct > self.threshold:
                self.regressions.append(result)
            elif change_pct < -self.threshold:
                self.improvements.append(result)

    def _print_summary(self) -> None:
        """Print comparison summary."""

        print(f"\nThreshold: ±{self.threshold}%")

        if self.regressions:
            print(f"\n❌ REGRESSIONS DETECTED ({len(self.regressions)}):")
            print("-" * 70)
            for reg in self.regressions:
                print(f"\n  {reg['name']}")
                print(f"    Current:  {reg['current']:.6f}")
                print(f"    Baseline: {reg['baseline']:.6f}")
                print(f"    Change:   {reg['change_pct']:+.2f}% ⚠️")

        if self.improvements:
            print(f"\n✅ IMPROVEMENTS ({len(self.improvements)}):")
            print("-" * 70)
            for imp in self.improvements:
                print(f"\n  {imp['name']}")
                print(f"    Current:  {imp['current']:.6f}")
                print(f"    Baseline: {imp['baseline']:.6f}")
                print(f"    Change:   {imp['change_pct']:+.2f}% 🚀")

        if not self.regressions and not self.improvements:
            print("\n✅ No significant changes detected")

        print("\n" + "=" * 70)

        if self.regressions:
            print("❌ Performance regression detected!")
            print(f"   {len(self.regressions)} benchmark(s) slower than threshold")
        else:
            print("✅ No performance regressions")

        print()


def main():
    parser = argparse.ArgumentParser(description="Check for performance regressions")
    parser.add_argument("--current", required=True, help="Path to current benchmark results (JSON)")
    parser.add_argument(
        "--baseline", required=True, help="Path to baseline benchmark results (JSON)"
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=10.0,
        help="Percentage threshold for regression (default: 10%%)",
    )
    parser.add_argument("--output", help="Output file for detailed results (JSON)")

    args = parser.parse_args()

    checker = PerformanceRegressionChecker(threshold=args.threshold)

    success = checker.compare_benchmarks(current_file=args.current, baseline_file=args.baseline)

    # Save detailed results if requested
    if args.output:
        results = {
            "threshold": args.threshold,
            "regressions": checker.regressions,
            "improvements": checker.improvements,
            "status": "passed" if success else "failed",
        }

        with open(args.output, "w") as f:
            json.dump(results, f, indent=2)

        print(f"Detailed results saved to: {args.output}")

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
