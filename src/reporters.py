"""Evaluation report generation."""

import json
import logging
from datetime import datetime
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)


def generate_report(
    metrics: dict[str, float],
    config: dict[str, Any],
    model_info: dict[str, Any] = None,
    output_path: str = None,
) -> dict[str, Any]:
    """Generate evaluation report.

    Args:
        metrics: Dictionary of computed metrics.
        config: Configuration used for evaluation.
        model_info: Optional model metadata.
        output_path: Optional path to save JSON report.

    Returns:
        Complete report dictionary.
    """
    report = {
        "timestamp": datetime.utcnow().isoformat(),
        "metrics": metrics,
        "config": {
            "k_values": config.get("k_values", [5, 10, 20]),
            "split_type": config.get("split_type", "time"),
            "train_ratio": config.get("train_ratio", 0.8),
        },
    }

    if model_info:
        report["model"] = model_info

    if output_path:
        path = Path(output_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w") as f:
            json.dump(report, f, indent=2)
        logger.info(f"Report saved to {output_path}")

    return report


def compare_reports(
    baseline_path: str,
    candidate_path: str,
    thresholds: dict[str, float] = None,
) -> dict[str, Any]:
    """Compare candidate metrics against baseline.

    Args:
        baseline_path: Path to baseline JSON report.
        candidate_path: Path to candidate JSON report.
        thresholds: Regression thresholds (max allowed drop %).

    Returns:
        Comparison results with pass/fail status.
    """
    if thresholds is None:
        thresholds = {"max_percent_drop": 5.0}

    with open(baseline_path) as f:
        baseline = json.load(f)
    with open(candidate_path) as f:
        candidate = json.load(f)

    baseline_metrics = baseline["metrics"]
    candidate_metrics = candidate["metrics"]

    comparison = {
        "baseline_timestamp": baseline.get("timestamp"),
        "candidate_timestamp": candidate.get("timestamp"),
        "metrics_comparison": {},
        "regressions": [],
        "improvements": [],
        "passed": True,
    }

    max_drop = thresholds.get("max_percent_drop", 5.0)

    for metric, baseline_value in baseline_metrics.items():
        if metric not in candidate_metrics:
            continue

        candidate_value = candidate_metrics[metric]

        if baseline_value == 0:
            pct_change = 0 if candidate_value == 0 else float("inf")
        else:
            pct_change = ((candidate_value - baseline_value) / baseline_value) * 100

        metric_comparison = {
            "baseline": baseline_value,
            "candidate": candidate_value,
            "change_percent": round(pct_change, 2),
        }

        comparison["metrics_comparison"][metric] = metric_comparison

        # Check for regression
        metric_threshold = thresholds.get(metric, max_drop)
        if pct_change < -metric_threshold:
            comparison["regressions"].append({
                "metric": metric,
                "drop_percent": abs(pct_change),
                "threshold": metric_threshold,
            })
            comparison["passed"] = False
        elif pct_change > 0:
            comparison["improvements"].append({
                "metric": metric,
                "gain_percent": pct_change,
            })

    return comparison


def format_report_markdown(report: dict[str, Any]) -> str:
    """Format report as markdown.

    Args:
        report: Report dictionary.

    Returns:
        Markdown formatted string.
    """
    lines = [
        "# Evaluation Report",
        f"\nGenerated: {report.get('timestamp', 'N/A')}",
        "\n## Metrics\n",
        "| Metric | Value |",
        "|--------|-------|",
    ]

    for metric, value in report.get("metrics", {}).items():
        if isinstance(value, float):
            lines.append(f"| {metric} | {value:.4f} |")
        else:
            lines.append(f"| {metric} | {value} |")

    if "model" in report:
        lines.extend([
            "\n## Model Info\n",
            f"- Version: {report['model'].get('version', 'N/A')}",
            f"- Parameters: {report['model'].get('params', {})}",
        ])

    return "\n".join(lines)
