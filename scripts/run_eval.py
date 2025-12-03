#!/usr/bin/env python3
"""Run model evaluation.

Usage:
    python scripts/run_eval.py --config configs/dev.yaml
    python scripts/run_eval.py --config configs/dev.yaml --model-path artifacts/model.pkl
"""

import argparse
import json
import logging
from datetime import datetime
from pathlib import Path

from src.utils.config import load_config, load_eval_thresholds
from src.evaluation.reporters import generate_report, compare_reports

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


def main():
    parser = argparse.ArgumentParser(description="Run model evaluation")
    parser.add_argument(
        "--config",
        required=True,
        help="Path to config file",
    )
    parser.add_argument(
        "--model-path",
        help="Path to model file (local or GCS)",
    )
    parser.add_argument(
        "--output",
        help="Output path for eval report",
    )
    parser.add_argument(
        "--baseline",
        help="Baseline report to compare against",
    )
    parser.add_argument(
        "--test-mode",
        action="store_true",
        help="Run with limited data for testing",
    )
    args = parser.parse_args()

    # Load config
    config = load_config(args.config)
    logger.info(f"Loaded config from {args.config}")

    if args.test_mode:
        config["limits"] = config.get("limits", {})
        config["limits"]["max_users"] = 1000
        config["limits"]["max_items"] = 500
        logger.info("Test mode: limiting data")

    # TODO: Implement actual evaluation logic
    # This is a placeholder that would be filled in with actual model loading,
    # prediction generation, and metric computation

    # Placeholder metrics
    metrics = {
        "precision_at_5": 0.0,
        "precision_at_10": 0.0,
        "precision_at_20": 0.0,
        "recall_at_5": 0.0,
        "recall_at_10": 0.0,
        "recall_at_20": 0.0,
        "ndcg_at_5": 0.0,
        "ndcg_at_10": 0.0,
        "ndcg_at_20": 0.0,
        "map": 0.0,
        "num_users_evaluated": 0,
    }

    logger.info("Computed metrics:")
    for metric, value in metrics.items():
        logger.info(f"  {metric}: {value:.4f}")

    # Generate report
    output_path = args.output or f"evals/reports/eval_{datetime.now():%Y%m%d_%H%M%S}.json"
    report = generate_report(
        metrics=metrics,
        config=config,
        model_info={"path": args.model_path} if args.model_path else None,
        output_path=output_path,
    )

    # Save latest symlink
    latest_path = Path("evals/reports/latest.json")
    latest_path.parent.mkdir(parents=True, exist_ok=True)
    with open(latest_path, "w") as f:
        json.dump(report, f, indent=2)

    # Compare to baseline if specified
    if args.baseline:
        thresholds = load_eval_thresholds()
        comparison = compare_reports(
            args.baseline,
            output_path,
            thresholds.get("regression", {}),
        )

        logger.info("\nBaseline comparison:")
        if comparison["passed"]:
            logger.info("✅ All metrics within acceptable range")
        else:
            logger.error("❌ Metrics regressed beyond threshold:")
            for reg in comparison["regressions"]:
                logger.error(
                    f"  {reg['metric']}: dropped {reg['drop_percent']:.1f}% "
                    f"(threshold: {reg['threshold']}%)"
                )

        if comparison["improvements"]:
            logger.info("Improvements:")
            for imp in comparison["improvements"]:
                logger.info(f"  {imp['metric']}: +{imp['gain_percent']:.1f}%")

        if not comparison["passed"]:
            exit(1)

    logger.info(f"\nReport saved to {output_path}")


if __name__ == "__main__":
    main()
