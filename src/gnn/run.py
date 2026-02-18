"""GNN Option A entry point: train, evaluate, or score.

Usage:
    python src/gnn/run.py --config configs/gnn.yaml --mode train
    python src/gnn/run.py --config configs/gnn.yaml --mode evaluate
    python src/gnn/run.py --config configs/gnn.yaml --mode score

Via Metaflow:
    ./flows/run.sh src/gnn/run.py "--config configs/gnn.yaml --mode train"
"""

import argparse
import json
import logging
import tempfile
from typing import Any

from src.config import load_config
from src.gcs_utils import download_model, upload_model
from src.gnn.checkpoint_utils import restore_id_mappings_from_checkpoint
from src.gnn.data_loader import GNNDataLoader
from src.wandb_utils import finish_run, init_wandb, log_artifact, log_metrics

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)


def _load_torch_checkpoint(checkpoint_path: str) -> dict[str, Any]:
    """Load checkpoint file using torch without importing torch at module import time."""
    import torch

    return torch.load(checkpoint_path, weights_only=False)


def _build_model(
    n_users: int,
    n_products: int,
    n_vehicles: int,
    n_part_types: int,
    config: dict[str, Any],
):
    """Instantiate HolleyGAT lazily to keep run.py import-light for testability."""
    from src.gnn.model import HolleyGAT

    return HolleyGAT(
        n_users=n_users,
        n_products=n_products,
        n_vehicles=n_vehicles,
        n_part_types=n_part_types,
        config=config,
    )


def _get_trainer_cls():
    from src.gnn.trainer import GNNTrainer

    return GNNTrainer


def _get_evaluator_cls():
    from src.gnn.evaluator import GNNEvaluator

    return GNNEvaluator


def _get_scorer_cls():
    from src.gnn.scorer import GNNScorer

    return GNNScorer


def _restore_checkpoint_mappings(loader, checkpoint: dict[str, Any]) -> None:
    """Restore loader ID mappings from checkpoint metadata.

    Raises ValueError when checkpoint metadata is present but malformed.
    """
    if restore_id_mappings_from_checkpoint(loader, checkpoint):
        logger.info("Loaded ID mappings from checkpoint")


def load_data(config, run_exports: bool = True):
    """Load data from BigQuery, optionally refreshing export tables."""
    loader = GNNDataLoader(config)

    if run_exports:
        logger.info("Running SQL exports...")
        loader.run_exports()
    else:
        logger.info("Skipping SQL exports; using existing tables")

    logger.info("Loading nodes...")
    nodes = loader.load_nodes()

    logger.info("Loading edges...")
    edges = loader.load_edges()

    return loader, nodes, edges


def build_graph(loader, nodes, edges, config):
    """Build PyG HeteroData graph."""
    from src.gnn.graph_builder import build_hetero_graph

    logger.info("Building heterogeneous graph...")
    data, split_masks, metadata = build_hetero_graph(
        nodes, edges, loader.get_id_mappings(), config
    )
    return data, split_masks, metadata


def build_test_interactions(loader, test_df):
    """Convert test DataFrame to user_id -> set of product_ids."""
    user_to_id = loader.user_to_id
    product_to_id = loader.product_to_id
    interactions = {}

    pairs = test_df.assign(
        user_id=test_df["email_lower"].map(user_to_id),
        product_id=test_df["base_sku"].map(product_to_id),
    ).dropna(subset=["user_id", "product_id"])

    if not pairs.empty:
        pairs["user_id"] = pairs["user_id"].astype(int)
        pairs["product_id"] = pairs["product_id"].astype(int)
        for uid, group in pairs.groupby("user_id"):
            interactions[int(uid)] = set(group["product_id"].tolist())
    return interactions


def build_engagement_tiers(nodes, user_to_id):
    """Build user_id -> engagement tier mapping."""
    users = nodes["users"][["email_lower", "engagement_tier"]].copy()
    users["user_id"] = users["email_lower"].map(user_to_id)
    users = users.dropna(subset=["user_id"])
    if users.empty:
        return {}
    users["user_id"] = users["user_id"].astype(int)
    users["engagement_tier"] = users["engagement_tier"].fillna("cold")
    return dict(zip(users["user_id"], users["engagement_tier"]))


def mode_train(config):
    """Full training pipeline: export -> build -> train -> evaluate -> save."""
    init_wandb(config, job_type="training", tags=["gnn", "option-a"])

    loader, nodes, edges = load_data(config, run_exports=True)
    data, split_masks, metadata = build_graph(loader, nodes, edges, config)

    test_df = loader.load_test_set()
    test_interactions = build_test_interactions(loader, test_df)
    sql_baseline_df = loader.load_sql_baseline()

    # Build model
    model = _build_model(
        n_users=data["user"].num_nodes,
        n_products=data["product"].num_nodes,
        n_vehicles=data["vehicle"].num_nodes,
        n_part_types=metadata["n_part_types"],
        config=config,
    )
    logger.info(f"Model parameters: {sum(p.numel() for p in model.parameters()):,}")

    # Train
    trainer_cls = _get_trainer_cls()
    trainer = trainer_cls(
        model=model,
        data=data,
        split_masks=split_masks,
        test_interactions=test_interactions,
        config=config,
    )
    train_results = trainer.train()
    logger.info(f"Training complete: {train_results}")

    # Save checkpoint with ID mappings for reproducible loading
    with tempfile.NamedTemporaryFile(suffix=".pt", delete=False) as f:
        checkpoint_path = f.name
    trainer.save_checkpoint(checkpoint_path, id_mappings=loader.get_id_mappings())

    gcs_path = config["output"]["model_gcs"] + "latest.pt"
    upload_model(checkpoint_path, gcs_path)
    log_artifact(checkpoint_path, "holley-gnn-model", "model")

    # Evaluate
    engagement_tiers = build_engagement_tiers(nodes, loader.user_to_id)

    evaluator_cls = _get_evaluator_cls()
    evaluator = evaluator_cls(
        model=model,
        data=data,
        split_masks=split_masks,
        id_mappings=loader.get_id_mappings(),
        nodes=nodes,
        test_df=test_df,
        sql_baseline_df=sql_baseline_df,
        config=config,
        user_engagement_tiers=engagement_tiers,
    )
    report = evaluator.generate_report()

    # Log evaluation metrics
    flat_metrics = {}
    for section in ["gnn_pre_rules", "gnn_post_rules", "sql_baseline"]:
        for k, v in report.get(section, {}).items():
            flat_metrics[f"eval/{section}/{k}"] = v
    for k, v in report.get("go_no_go", {}).items():
        if isinstance(v, (int, float)):
            flat_metrics[f"eval/go_no_go/{k}"] = v

    log_metrics(flat_metrics)

    logger.info(f"\n=== GO/NO-GO ===\n{json.dumps(report['go_no_go'], indent=2)}")

    finish_run()
    return report


def mode_evaluate(config):
    """Load existing model and evaluate against SQL baseline."""
    init_wandb(config, job_type="evaluation", tags=["gnn", "option-a"])

    refresh_exports = config.get("eval", {}).get("refresh_exports", False)
    loader, nodes, edges = load_data(config, run_exports=refresh_exports)

    # Load model from GCS
    gcs_path = config["output"]["model_gcs"] + "latest.pt"
    with tempfile.NamedTemporaryFile(suffix=".pt", delete=False) as f:
        local_path = f.name
    download_model(gcs_path, local_path)

    checkpoint = _load_torch_checkpoint(local_path)
    _restore_checkpoint_mappings(loader, checkpoint)

    data, split_masks, metadata = build_graph(loader, nodes, edges, config)

    model = _build_model(
        n_users=data["user"].num_nodes,
        n_products=data["product"].num_nodes,
        n_vehicles=data["vehicle"].num_nodes,
        n_part_types=metadata["n_part_types"],
        config=config,
    )
    model.load_state_dict(checkpoint["model_state_dict"])

    test_df = loader.load_test_set()
    sql_baseline_df = loader.load_sql_baseline()
    engagement_tiers = build_engagement_tiers(nodes, loader.user_to_id)

    evaluator_cls = _get_evaluator_cls()
    evaluator = evaluator_cls(
        model=model,
        data=data,
        split_masks=split_masks,
        id_mappings=loader.get_id_mappings(),
        nodes=nodes,
        test_df=test_df,
        sql_baseline_df=sql_baseline_df,
        config=config,
        user_engagement_tiers=engagement_tiers,
    )
    report = evaluator.generate_report()

    logger.info(f"\n=== GO/NO-GO ===\n{json.dumps(report['go_no_go'], indent=2)}")

    finish_run()
    return report


def mode_score(config):
    """Load model, score all users, write shadow table."""
    init_wandb(config, job_type="scoring", tags=["gnn", "option-a"])

    refresh_exports = config.get("output", {}).get("refresh_exports", False)
    loader, nodes, edges = load_data(config, run_exports=refresh_exports)

    # Load model from GCS
    gcs_path = config["output"]["model_gcs"] + "latest.pt"
    with tempfile.NamedTemporaryFile(suffix=".pt", delete=False) as f:
        local_path = f.name
    download_model(gcs_path, local_path)

    checkpoint = _load_torch_checkpoint(local_path)
    _restore_checkpoint_mappings(loader, checkpoint)

    data, split_masks, metadata = build_graph(loader, nodes, edges, config)

    model = _build_model(
        n_users=data["user"].num_nodes,
        n_products=data["product"].num_nodes,
        n_vehicles=data["vehicle"].num_nodes,
        n_part_types=metadata["n_part_types"],
        config=config,
    )
    model.load_state_dict(checkpoint["model_state_dict"])

    # Load purchase history for exclusion (365-day lookback)
    user_purchases = loader.load_user_purchases()

    scorer_cls = _get_scorer_cls()
    scorer = scorer_cls(
        model=model,
        data=data,
        id_mappings=loader.get_id_mappings(),
        nodes=nodes,
        config=config,
        user_purchases=user_purchases,
    )

    df = scorer.score_all_users()
    scorer.write_shadow_table(df)

    log_metrics({"scoring/n_users": len(df)})
    finish_run()

    logger.info(f"Scoring complete: {len(df)} users written to shadow table")
    return df


def main():
    parser = argparse.ArgumentParser(description="GNN Option A: HeteroGAT Recommendations")
    parser.add_argument("--config", required=True, help="Path to config YAML")
    parser.add_argument(
        "--mode",
        required=True,
        choices=["train", "evaluate", "score"],
        help="Run mode: train (full pipeline), evaluate (load model + eval), score (write shadow table)",
    )
    args = parser.parse_args()

    config = load_config(args.config)
    logger.info(f"Mode: {args.mode}, Config: {args.config}")

    if args.mode == "train":
        mode_train(config)
    elif args.mode == "evaluate":
        mode_evaluate(config)
    elif args.mode == "score":
        mode_score(config)


if __name__ == "__main__":
    main()
