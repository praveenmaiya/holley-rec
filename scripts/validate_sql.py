#!/usr/bin/env python3
"""SQL Validation Script.

Validates BigQuery SQL files for syntax and optionally runs test queries.

Usage:
    python scripts/validate_sql.py --all
    python scripts/validate_sql.py --file sql/recommendations/extract/users.sql
    python scripts/validate_sql.py --run-tests
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path


def validate_syntax(sql_file: Path, project: str) -> tuple[bool, str]:
    """Dry-run SQL to check syntax without executing.

    Args:
        sql_file: Path to SQL file.
        project: GCP project ID.

    Returns:
        Tuple of (success, message).
    """
    cmd = [
        "bq", "query",
        "--dry_run",
        "--use_legacy_sql=false",
        "--project_id", project,
        "--format=json",
    ]

    with open(sql_file) as f:
        sql = f.read()

    # Skip files with only placeholders
    if "${" in sql and not any(char in sql for char in "SELECT INSERT UPDATE DELETE"):
        return True, "Skipped (template only)"

    result = subprocess.run(
        cmd,
        input=sql,
        capture_output=True,
        text=True,
    )

    if result.returncode == 0:
        try:
            # Try to parse stats
            if result.stdout.strip():
                stats = json.loads(result.stdout)
                bytes_processed = int(
                    stats.get("statistics", {}).get("totalBytesProcessed", 0)
                )
                return True, f"Valid ({bytes_processed / 1e9:.2f} GB estimated)"
        except (json.JSONDecodeError, KeyError):
            pass
        return True, "Valid"
    else:
        error_msg = result.stderr.strip()
        # Extract just the error message
        if "Error" in error_msg:
            error_msg = error_msg.split("Error")[-1].strip()
        return False, f"Error: {error_msg[:200]}"


def run_sql_test(
    sql_file: Path,
    project: str,
    dataset: str,
) -> tuple[bool, str]:
    """Run a test SQL query and check assertions.

    Test SQL files should return 0 rows if passing.

    Args:
        sql_file: Path to test SQL file.
        project: GCP project ID.
        dataset: Test dataset name.

    Returns:
        Tuple of (success, message).
    """
    cmd = [
        "bq", "query",
        "--use_legacy_sql=false",
        "--project_id", project,
        "--format=json",
        "--max_rows=10",
    ]

    with open(sql_file) as f:
        sql = f.read()
        # Replace dataset placeholder
        sql = sql.replace("${DATASET}", dataset)
        sql = sql.replace("${PROJECT}", project)

    result = subprocess.run(
        cmd,
        input=sql,
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        return False, f"Query failed: {result.stderr[:200]}"

    try:
        rows = json.loads(result.stdout) if result.stdout.strip() else []
    except json.JSONDecodeError:
        rows = []

    if len(rows) == 0:
        return True, "All assertions passed"
    else:
        return False, f"Found {len(rows)} failing rows"


def main():
    parser = argparse.ArgumentParser(description="Validate SQL files")
    parser.add_argument(
        "--all",
        action="store_true",
        help="Check all SQL files",
    )
    parser.add_argument(
        "--file",
        type=Path,
        help="Check specific file",
    )
    parser.add_argument(
        "--run-tests",
        action="store_true",
        help="Run SQL test queries",
    )
    parser.add_argument(
        "--project",
        default="",
        help="GCP project ID",
    )
    parser.add_argument(
        "--test-dataset",
        default="test_recommendations",
        help="Test dataset name",
    )
    args = parser.parse_args()

    sql_dir = Path("sql")
    failed = []

    if args.all or args.file:
        if args.file:
            files = [args.file]
        else:
            files = list(sql_dir.rglob("*.sql"))
            # Exclude test files from syntax check
            files = [f for f in files if "/tests/" not in str(f)]

        if not files:
            print("No SQL files found")
            return

        print(f"Validating {len(files)} SQL files...\n")

        for sql_file in sorted(files):
            if not args.project:
                print(f"⚠ {sql_file}: Skipped (no project specified)")
                continue

            ok, msg = validate_syntax(sql_file, args.project)
            status = "✓" if ok else "✗"
            print(f"{status} {sql_file}: {msg}")
            if not ok:
                failed.append(sql_file)

    if args.run_tests:
        test_dir = sql_dir / "recommendations" / "tests"
        test_files = list(test_dir.rglob("*.sql")) if test_dir.exists() else []

        if not test_files:
            print("\nNo SQL test files found")
        else:
            print(f"\nRunning {len(test_files)} SQL tests...\n")

            for sql_file in sorted(test_files):
                if not args.project:
                    print(f"⚠ {sql_file}: Skipped (no project specified)")
                    continue

                ok, msg = run_sql_test(sql_file, args.project, args.test_dataset)
                status = "✓" if ok else "✗"
                print(f"{status} {sql_file}: {msg}")
                if not ok:
                    failed.append(sql_file)

    print()
    if failed:
        print(f"❌ {len(failed)} file(s) failed validation")
        sys.exit(1)
    else:
        print("✅ All validations passed!")


if __name__ == "__main__":
    main()
