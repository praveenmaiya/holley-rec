"""Weights & Biases integration utilities."""

import logging
from typing import Any, Optional

import wandb

logger = logging.getLogger(__name__)


def init_wandb(
    config: dict[str, Any],
    job_type: str = "training",
    tags: list[str] = None,
    notes: str = None,
) -> wandb.run:
    """Initialize W&B run.

    Args:
        config: Configuration dictionary (should have wandb section).
        job_type: Type of job (training, evaluation, inference).
        tags: Optional tags for the run.
        notes: Optional notes for the run.

    Returns:
        W&B run object.
    """
    wandb_config = config.get("wandb", {})

    project = wandb_config.get("project", "holley-rec")
    entity = wandb_config.get("entity")

    run = wandb.init(
        project=project,
        entity=entity,
        config=config,
        job_type=job_type,
        tags=tags or [],
        notes=notes,
    )

    logger.info(f"Initialized W&B run: {run.url}")

    return run


def log_metrics(
    metrics: dict[str, float],
    step: int = None,
    commit: bool = True,
) -> None:
    """Log metrics to W&B.

    Args:
        metrics: Dictionary of metric names to values.
        step: Optional step number.
        commit: Whether to commit the log.
    """
    if wandb.run is None:
        logger.warning("W&B not initialized, skipping metric logging")
        return

    wandb.log(metrics, step=step, commit=commit)


def log_artifact(
    local_path: str,
    name: str,
    artifact_type: str = "model",
    metadata: dict[str, Any] = None,
) -> Optional[wandb.Artifact]:
    """Log artifact to W&B.

    Args:
        local_path: Local path to artifact.
        name: Artifact name.
        artifact_type: Type of artifact (model, dataset, etc.).
        metadata: Optional metadata dictionary.

    Returns:
        W&B Artifact object or None if not initialized.
    """
    if wandb.run is None:
        logger.warning("W&B not initialized, skipping artifact logging")
        return None

    artifact = wandb.Artifact(
        name=name,
        type=artifact_type,
        metadata=metadata or {},
    )
    artifact.add_file(local_path)

    wandb.log_artifact(artifact)
    logger.info(f"Logged artifact: {name}")

    return artifact


def log_table(
    data: list[list[Any]],
    columns: list[str],
    table_name: str = "results",
) -> None:
    """Log table to W&B.

    Args:
        data: List of rows (each row is a list).
        columns: Column names.
        table_name: Name for the table.
    """
    if wandb.run is None:
        logger.warning("W&B not initialized, skipping table logging")
        return

    table = wandb.Table(columns=columns, data=data)
    wandb.log({table_name: table})


def finish_run() -> None:
    """Finish W&B run."""
    if wandb.run is not None:
        wandb.finish()
        logger.info("W&B run finished")


def log_eval_results(
    metrics: dict[str, float],
    baseline_metrics: dict[str, float] = None,
    config: dict[str, Any] = None,
) -> None:
    """Log evaluation results with optional baseline comparison.

    Args:
        metrics: Current evaluation metrics.
        baseline_metrics: Optional baseline metrics for comparison.
        config: Optional config to log.
    """
    log_metrics(metrics)

    if baseline_metrics:
        comparison = {}
        for key, value in metrics.items():
            if key in baseline_metrics:
                baseline_value = baseline_metrics[key]
                if baseline_value != 0:
                    pct_change = ((value - baseline_value) / baseline_value) * 100
                    comparison[f"{key}_vs_baseline_pct"] = pct_change

        log_metrics(comparison)

    if config:
        wandb.config.update(config, allow_val_change=True)
