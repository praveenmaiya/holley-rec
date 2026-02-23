"""CLI entry point for the recommendation engine.

Validates config and plugin, then logs readiness. Actual data loading and
execution is handled by client runners (Layer 1) that call mode_train() etc.

Usage:
    python -m rec_engine.run --config configs/holley_gnn.yaml --mode train
"""

from __future__ import annotations

import argparse
import importlib
import logging
from typing import Any

import pandas as pd
import yaml

from rec_engine import CONTRACT_VERSION, is_valid_scalar
from rec_engine.contracts import check_contract_version
from rec_engine.plugins import RecEnginePlugin, validate_plugin
from rec_engine.topology import create_strategy

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)


_is_valid_scalar = is_valid_scalar  # Local alias for brevity in lambdas


def load_config(path: str) -> dict[str, Any]:
    """Load and validate config YAML."""
    with open(path) as f:
        config = yaml.safe_load(f)

    config_version = config.get("contract_version", CONTRACT_VERSION)
    check_contract_version(config_version)

    return config


def load_plugin(config: dict[str, Any]) -> RecEnginePlugin:
    """Dynamically load plugin class from config.

    Config should have: plugin: "module.path.ClassName"
    """
    plugin_path = config.get("plugin")
    if not plugin_path:
        from plugins.defaults import DefaultPlugin
        logger.info("No plugin specified, using DefaultPlugin")
        return DefaultPlugin()

    module_path, class_name = plugin_path.rsplit(".", 1)
    module = importlib.import_module(module_path)
    plugin_cls = getattr(module, class_name)

    errors = validate_plugin(plugin_cls)
    if errors:
        raise ValueError(
            f"Plugin validation failed for {plugin_path}:\n"
            + "\n".join(f"  - {e}" for e in errors)
        )

    return plugin_cls()


def build_model(
    n_users: int,
    n_products: int,
    n_entities: int,
    n_categories: int,
    edge_types: list[tuple[str, str, str]],
    config: dict[str, Any],
    entity_type_name: str = "entity",
    product_num_features: int = 3,
    entity_num_features: int = 0,
):
    """Instantiate HeteroGAT."""
    from rec_engine.core.model import HeteroGAT

    return HeteroGAT(
        n_users=n_users,
        n_products=n_products,
        n_entities=n_entities,
        n_categories=n_categories,
        edge_types=edge_types,
        config=config,
        entity_type_name=entity_type_name,
        product_num_features=product_num_features,
        entity_num_features=entity_num_features,
    )


def preprocess_dataframes(
    dataframes: dict[str, pd.DataFrame],
    plugin: RecEnginePlugin,
    config: dict[str, Any] | None = None,
) -> dict[str, pd.DataFrame]:
    """Apply plugin normalization hooks to raw DataFrames.

    Must be called BEFORE contract validation and ID mapping.
    Applies: normalize_user_id, normalize_product_id, map_interaction_weight.
    Returns a new dict with transformed DataFrames (originals are not mutated).

    Args:
        config: Unused, kept for backward compatibility.
    """
    result = {k: df.copy() for k, df in dataframes.items()}

    # Normalize user IDs in all tables that have them
    for table in ("users", "interactions", "ownership", "test_interactions"):
        if table in result and "user_id" in result[table].columns:
            col = result[table]["user_id"]
            result[table]["user_id"] = col.map(
                lambda uid: plugin.normalize_user_id(str(uid)) if _is_valid_scalar(uid) else None
            )

    # Normalize product IDs in all tables that have them
    for table in ("products", "interactions", "fitment"):
        if table in result and "product_id" in result[table].columns:
            col = result[table]["product_id"]
            result[table]["product_id"] = col.map(
                lambda pid: plugin.normalize_product_id(str(pid)) if _is_valid_scalar(pid) else None
            )

    # Normalize product IDs in copurchase (uses product_a / product_b)
    if "copurchase" in result:
        cp = result["copurchase"]
        for col_name in ("product_a", "product_b"):
            if col_name in cp.columns:
                cp[col_name] = cp[col_name].map(
                    lambda pid: plugin.normalize_product_id(str(pid)) if _is_valid_scalar(pid) else None
                )

    # Apply interaction weight mapping
    if "interactions" in result and "interaction_type" in result["interactions"].columns:
        interactions = result["interactions"]
        mapped_weights = interactions["interaction_type"].map(
            plugin.map_interaction_weight
        )
        # Plugin returns non-None → override weight; None → keep existing
        has_override = mapped_weights.notna()
        if has_override.any():
            if "weight" not in interactions.columns:
                interactions["weight"] = 1.0
            interactions.loc[has_override, "weight"] = mapped_weights[has_override].astype(float)
            logger.info(
                "Plugin weight mapping: %d/%d interactions overridden",
                has_override.sum(), len(interactions),
            )

    # Normalize product_id in test_interactions
    if "test_interactions" in result and "product_id" in result["test_interactions"].columns:
        col = result["test_interactions"]["product_id"]
        result["test_interactions"]["product_id"] = col.map(
            lambda pid: plugin.normalize_product_id(str(pid)) if _is_valid_scalar(pid) else None
        )

    return result


def mode_train(
    config: dict[str, Any],
    dataframes: dict[str, Any],
    plugin: RecEnginePlugin,
) -> dict[str, Any]:
    """Full training pipeline: preprocess -> validate -> build -> train -> evaluate."""
    from rec_engine.contracts import validate
    from rec_engine.core.graph_builder import build_hetero_graph

    strategy = create_strategy(config)

    # Preprocess: apply plugin normalization and weight mapping
    dataframes = preprocess_dataframes(dataframes, plugin, config)

    # Validate contracts
    validate(dataframes, config)

    # Build ID mappings
    id_mappings = _build_id_mappings(dataframes, config)

    # Build graph
    nodes, edges = _prepare_graph_inputs(dataframes)
    data, split_masks, metadata = build_hetero_graph(nodes, edges, id_mappings, config)

    # Build test interactions
    test_df = dataframes.get("test_interactions")
    test_interactions = _build_test_interactions(test_df, id_mappings) if test_df is not None else {}

    # Build model
    entity_type_name = config.get("entity", {}).get("type_name", "entity")
    n_entities = len(id_mappings.get("entity_to_id", {}))
    edge_types = strategy.get_edge_types(config)

    model = build_model(
        n_users=data["user"].num_nodes,
        n_products=data["product"].num_nodes,
        n_entities=n_entities,
        n_categories=metadata["n_categories"],
        edge_types=edge_types,
        config=config,
        entity_type_name=entity_type_name,
        product_num_features=metadata["product_num_features"],
        entity_num_features=metadata.get("entity_num_features", 0),
    )
    logger.info("Model parameters: %s", f"{sum(p.numel() for p in model.parameters()):,}")

    # Train
    from rec_engine.core.trainer import GNNTrainer

    trainer = GNNTrainer(
        model=model,
        data=data,
        split_masks=split_masks,
        test_interactions=test_interactions,
        config=config,
        strategy=strategy,
        plugin=plugin,
    )
    train_results = trainer.train()
    logger.info("Training complete: %s", train_results)

    return {
        "train_results": train_results,
        "model": model,
        "data": data,
        "split_masks": split_masks,
        "id_mappings": id_mappings,
        "metadata": metadata,
        "nodes": nodes,
        "strategy": strategy,
    }


def mode_evaluate(
    config: dict[str, Any],
    dataframes: dict[str, Any],
    plugin: RecEnginePlugin,
    *,
    model_checkpoint: str | None = None,
    train_result: dict[str, Any] | None = None,
    baseline_df: pd.DataFrame | None = None,
) -> dict[str, Any]:
    """Full evaluation pipeline: preprocess -> validate -> build -> evaluate.

    Can use either a pre-trained model (from train_result) or load from checkpoint.
    """
    from rec_engine.contracts import validate
    from rec_engine.core.evaluator import GNNEvaluator
    from rec_engine.core.graph_builder import build_hetero_graph

    strategy = create_strategy(config)
    dataframes = preprocess_dataframes(dataframes, plugin, config)
    validate(dataframes, config)

    if train_result is not None:
        # Use in-memory model from training
        model = train_result["model"]
        data = train_result["data"]
        split_masks = train_result["split_masks"]
        id_mappings = train_result["id_mappings"]
        nodes = train_result["nodes"]
        metadata = train_result["metadata"]
    else:
        if not model_checkpoint:
            raise ValueError(
                "mode_evaluate requires either train_result or model_checkpoint. "
                "Evaluating with an untrained model would produce meaningless metrics."
            )
        # Build fresh from dataframes
        id_mappings = _build_id_mappings(dataframes, config)
        nodes, edges = _prepare_graph_inputs(dataframes)
        data, split_masks, metadata = build_hetero_graph(nodes, edges, id_mappings, config)

        model = _load_model_from_checkpoint(
            model_checkpoint, data, id_mappings, metadata, strategy, config,
        )

    test_df = dataframes.get("test_interactions", pd.DataFrame())

    evaluator = GNNEvaluator(
        model=model,
        data=data,
        split_masks=split_masks,
        id_mappings=id_mappings,
        nodes=nodes,
        test_df=test_df,
        config=config,
        strategy=strategy,
        plugin=plugin,
        baseline_df=baseline_df,
    )
    results = evaluator.generate_report()
    logger.info("Evaluation complete: go/no-go=%s", results["go_no_go"]["decision"])

    return results


def mode_score(
    config: dict[str, Any],
    dataframes: dict[str, Any],
    plugin: RecEnginePlugin,
    *,
    model_checkpoint: str | None = None,
    train_result: dict[str, Any] | None = None,
    target_user_ids: set[str] | None = None,
    user_purchases: dict[str, set[str]] | None = None,
) -> pd.DataFrame:
    """Full scoring pipeline: preprocess -> validate -> build -> score.

    Can use either a pre-trained model (from train_result) or load from checkpoint.
    Returns scored recommendations DataFrame.
    """
    from rec_engine.contracts import validate
    from rec_engine.core.graph_builder import build_hetero_graph
    from rec_engine.core.scorer import GNNScorer

    strategy = create_strategy(config)
    dataframes = preprocess_dataframes(dataframes, plugin, config)
    validate(dataframes, config)

    if train_result is not None:
        model = train_result["model"]
        data = train_result["data"]
        id_mappings = train_result["id_mappings"]
        nodes = train_result["nodes"]
    else:
        if not model_checkpoint:
            raise ValueError(
                "mode_score requires either train_result or model_checkpoint. "
                "Scoring with an untrained model would produce meaningless results."
            )
        id_mappings = _build_id_mappings(dataframes, config)
        nodes, edges = _prepare_graph_inputs(dataframes)
        data, _, metadata = build_hetero_graph(nodes, edges, id_mappings, config)

        model = _load_model_from_checkpoint(
            model_checkpoint, data, id_mappings, metadata, strategy, config,
        )

    # Normalize runtime inputs conditionally: keep IDs already in graph,
    # normalize only unknown raw IDs, drop unresolvable ones.
    user_to_id = id_mappings["user_to_id"]

    if target_user_ids is not None:
        # Guard against bare-string (would iterate characters)
        if isinstance(target_user_ids, str):
            target_user_ids = {target_user_ids}
        elif not hasattr(target_user_ids, "__iter__"):
            raise TypeError(
                f"target_user_ids must be an iterable of user IDs or None, "
                f"got {type(target_user_ids).__name__}"
            )

    if target_user_ids is not None:
        normalized_targets: set[str] = set()
        for raw_uid in target_user_ids:
            if not _is_valid_scalar(raw_uid):
                continue
            uid = str(raw_uid)
            if uid in user_to_id:
                normalized_targets.add(uid)
            else:
                canon = plugin.normalize_user_id(uid)
                if canon in user_to_id:
                    normalized_targets.add(canon)
                else:
                    logger.warning("Runtime target user ID %r not in graph, skipping", raw_uid)
        if not normalized_targets:
            logger.warning("All target_user_ids were unresolvable — result will be empty")
        target_user_ids = normalized_targets

    if user_purchases is not None:
        if not hasattr(user_purchases, "items"):
            raise TypeError(
                f"user_purchases must be a dict-like mapping (uid -> product_ids), "
                f"got {type(user_purchases).__name__}"
            )
        # Normalize UID keys and PID values through plugin hooks so
        # purchase exclusion lookups match the canonical product_to_id keys.
        normalized_purchases: dict[str, set[str]] = {}
        for raw_uid, pids in user_purchases.items():
            if not _is_valid_scalar(raw_uid):
                continue
            uid = str(raw_uid)
            if uid in user_to_id:
                canon_uid = uid
            else:
                canon_uid = plugin.normalize_user_id(uid)
                if canon_uid not in user_to_id:
                    continue
            # Guard against bare-string values (would iterate characters)
            # and non-iterable values (None, int, float) that would crash .update()
            if isinstance(pids, str):
                pids = {pids}
            elif not hasattr(pids, "__iter__"):
                logger.warning("user_purchases[%r] is non-iterable (%s), skipping", raw_uid, type(pids).__name__)
                continue
            existing = normalized_purchases.setdefault(canon_uid, set())
            for pid in pids:
                if _is_valid_scalar(pid):
                    existing.add(plugin.normalize_product_id(str(pid)))
                else:
                    logger.warning("user_purchases[%r] contains non-scalar element (%s), skipping element", raw_uid, type(pid).__name__)
        user_purchases = normalized_purchases

    scorer = GNNScorer(
        model=model,
        data=data,
        id_mappings=id_mappings,
        nodes=nodes,
        config=config,
        strategy=strategy,
        plugin=plugin,
        user_purchases=user_purchases,
    )
    df = scorer.score_all_users(target_user_ids)
    logger.info("Scoring complete: %d users scored", len(df))

    return df


def _load_model_from_checkpoint(
    checkpoint_path: str,
    data: Any,
    id_mappings: dict[str, dict],
    metadata: dict[str, Any],
    strategy: Any,
    config: dict[str, Any],
) -> Any:
    """Load a trained HeteroGAT model from a checkpoint file.

    Security note: uses weights_only=False because checkpoints contain both
    model_state_dict (tensors) and config (plain dict). This allows arbitrary
    code execution via pickle — only load checkpoints from trusted sources.
    Revisit for multi-tenant deployment (Phase 4).
    """
    import torch

    entity_type_name = config.get("entity", {}).get("type_name", "entity")
    n_entities = len(id_mappings.get("entity_to_id", {}))
    edge_types = strategy.get_edge_types(config)

    model = build_model(
        n_users=data["user"].num_nodes,
        n_products=data["product"].num_nodes,
        n_entities=n_entities,
        n_categories=metadata["n_categories"],
        edge_types=edge_types,
        config=config,
        entity_type_name=entity_type_name,
        product_num_features=metadata["product_num_features"],
        entity_num_features=metadata.get("entity_num_features", 0),
    )

    checkpoint_data = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
    model.load_state_dict(checkpoint_data["model_state_dict"])
    logger.info("Loaded model from checkpoint: %s", checkpoint_path)
    return model


def _prepare_graph_inputs(
    dataframes: dict[str, Any],
) -> tuple[dict[str, pd.DataFrame], dict[str, pd.DataFrame]]:
    """Extract node and edge DataFrames from canonical dataframes dict.

    Returns (nodes, edges) ready for build_hetero_graph.
    """
    nodes: dict[str, pd.DataFrame] = {
        "users": dataframes["users"],
        "products": dataframes["products"],
    }
    edges: dict[str, pd.DataFrame] = {
        "interactions": dataframes["interactions"],
    }
    if "entities" in dataframes:
        nodes["entities"] = dataframes["entities"]
    if "fitment" in dataframes:
        edges["fitment"] = dataframes["fitment"]
    if "ownership" in dataframes:
        edges["ownership"] = dataframes["ownership"]
    if "copurchase" in dataframes:
        edges["copurchase"] = dataframes["copurchase"]
    return nodes, edges


def _build_id_mappings(
    dataframes: dict[str, Any],
    config: dict[str, Any],
) -> dict[str, dict]:
    """Build deterministic ID mappings from canonical DataFrames."""
    users_df = dataframes["users"]
    products_df = dataframes["products"]

    user_to_id = {
        uid: i for i, uid in enumerate(
            sorted(users_df["user_id"].drop_duplicates().tolist())
        )
    }
    product_to_id = {
        pid: i for i, pid in enumerate(
            sorted(products_df["product_id"].drop_duplicates().tolist())
        )
    }

    mappings = {
        "user_to_id": user_to_id,
        "product_to_id": product_to_id,
    }

    if "entities" in dataframes:
        entities_df = dataframes["entities"]
        entity_to_id = {
            eid: i for i, eid in enumerate(
                sorted(entities_df["entity_id"].drop_duplicates().tolist())
            )
        }
        mappings["entity_to_id"] = entity_to_id

    return mappings


def _build_test_interactions(
    test_df: Any,
    id_mappings: dict[str, dict],
) -> dict[int, set[int]]:
    """Convert test DataFrame to user_id -> set of product_ids."""
    if test_df is None or test_df.empty:
        return {}

    user_to_id = id_mappings["user_to_id"]
    product_to_id = id_mappings["product_to_id"]

    interactions: dict[int, set[int]] = {}
    pairs = test_df.assign(
        _uid=test_df["user_id"].map(user_to_id),
        _pid=test_df["product_id"].map(product_to_id),
    ).dropna(subset=["_uid", "_pid"])

    if not pairs.empty:
        pairs["_uid"] = pairs["_uid"].astype(int)
        pairs["_pid"] = pairs["_pid"].astype(int)
        for uid, group in pairs.groupby("_uid"):
            interactions[int(uid)] = set(group["_pid"].tolist())

    return interactions


def main():
    """CLI entry point."""
    parser = argparse.ArgumentParser(description="Auxia Recommendation Engine")
    parser.add_argument("--config", required=True, help="Path to config YAML")
    parser.add_argument(
        "--mode",
        required=True,
        choices=["train", "evaluate", "score"],
        help="Run mode",
    )
    args = parser.parse_args()

    config = load_config(args.config)
    plugin = load_plugin(config)
    logger.info("Mode: %s, Config: %s", args.mode, args.config)
    logger.info("Plugin: %s", type(plugin).__name__)
    logger.info("Topology: %s", config.get("topology", "user-product"))
    logger.info("Contract version: %s (engine: %s)", config.get("contract_version", "1.0"), CONTRACT_VERSION)

    # NOTE: mode_train requires dataframes to be loaded by the caller (e.g. client runner).
    # The CLI validates config and plugin but does not load data — that is Layer 1's job.
    # See holley_runner.py for a complete example of wiring data loading → mode_train.
    if args.mode == "train":
        logger.info("Config and plugin validated. Ready for training.")
        logger.info("Provide dataframes via mode_train() in your client runner.")
    elif args.mode == "evaluate":
        logger.info("Config and plugin validated. Ready for evaluation.")
    elif args.mode == "score":
        logger.info("Config and plugin validated. Ready for scoring.")


if __name__ == "__main__":
    main()
