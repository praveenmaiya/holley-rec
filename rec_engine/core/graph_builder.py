"""Build PyG HeteroData graph from canonical DataFrames.

Config-driven: node types, edge types, and features are determined by
topology config and column mappings. No client-specific hardcoding.
"""

from __future__ import annotations

import logging
from typing import Any

import numpy as np
import pandas as pd
import torch
from sklearn.preprocessing import LabelEncoder

logger = logging.getLogger(__name__)

# Sentinel object for "all users" tier — cannot collide with any real string tier.
_ALL_USERS_TIER = object()


def build_hetero_graph(
    nodes: dict[str, pd.DataFrame],
    edges: dict[str, pd.DataFrame],
    id_mappings: dict[str, dict],
    config: dict[str, Any],
) -> tuple[Any, dict[str, torch.Tensor], dict[str, Any]]:
    """Build heterogeneous graph from canonical DataFrames.

    Args:
        nodes: Dict with 'users', 'products' DataFrames. Optional: 'entities'.
        edges: Dict with 'interactions' DataFrame. Optional: 'fitment', 'ownership', 'copurchase'.
        id_mappings: Dict with 'user_to_id', 'product_to_id'. Optional: 'entity_to_id'.
        config: Engine configuration dict.

    Returns:
        Tuple of (HeteroData, split_masks, metadata).
    """
    from torch_geometric.data import HeteroData

    topology = config.get("topology", "user-product")
    is_3node = topology == "user-entity-product"
    entity_type_name = config.get("entity", {}).get("type_name", "entity")

    user_to_id = id_mappings["user_to_id"]
    product_to_id = id_mappings["product_to_id"]
    entity_to_id = id_mappings.get("entity_to_id", {})

    users_df = nodes["users"]
    products_df = nodes["products"]
    entities_df = nodes.get("entities")

    n_users = len(user_to_id)
    n_products = len(product_to_id)
    n_entities = len(entity_to_id)

    # --- Reindex products/entities by mapped ID to ensure tensor alignment ---
    # CRITICAL: Features must be ordered by mapped integer ID, not DataFrame row order.
    products_df = products_df.drop_duplicates(subset=["product_id"]).copy()
    products_df["_pid"] = products_df["product_id"].map(product_to_id)
    products_df = products_df.dropna(subset=["_pid"])
    products_df["_pid"] = products_df["_pid"].astype(int)
    products_df = products_df.sort_values("_pid").reset_index(drop=True)

    if entities_df is not None and entity_to_id:
        entities_df = entities_df.drop_duplicates(subset=["entity_id"]).copy()
        entities_df["_eid"] = entities_df["entity_id"].map(entity_to_id)
        entities_df = entities_df.dropna(subset=["_eid"])
        entities_df["_eid"] = entities_df["_eid"].astype(int)
        entities_df = entities_df.sort_values("_eid").reset_index(drop=True)

    # --- Node Features ---

    # Product category encoding
    category_col = config.get("columns", {}).get("category", "category")
    category_encoder = LabelEncoder()
    if category_col in products_df.columns:
        category_encoder.fit(products_df[category_col].fillna("UNKNOWN").astype(str).values)
        category_ids = category_encoder.transform(
            products_df[category_col].fillna("UNKNOWN").astype(str).values
        )
    else:
        category_encoder.fit(["UNKNOWN"])
        category_ids = np.zeros(n_products, dtype=int)
    n_categories = len(category_encoder.classes_)

    # Product numerical features (normalized)
    price_col = config.get("columns", {}).get("price", "price")
    popularity_col = config.get("columns", {}).get("popularity", "popularity")

    price_vals = products_df[price_col].fillna(0).values.astype(np.float32) if price_col in products_df.columns else np.zeros(n_products, dtype=np.float32)
    pop_vals = products_df[popularity_col].fillna(0).values.astype(np.float32) if popularity_col in products_df.columns else np.zeros(n_products, dtype=np.float32)

    # Optional features
    num_features = [price_vals, pop_vals]
    feature_names = [price_col, popularity_col]

    # Check for additional product numeric features from config
    extra_product_features = config.get("columns", {}).get("product_features", [])
    for feat_name in extra_product_features:
        if feat_name in products_df.columns:
            feat_vals = products_df[feat_name].fillna(0).values.astype(np.float32)
            num_features.append(feat_vals)
            feature_names.append(feat_name)

    # Normalize all features
    norm_stats: dict[str, tuple[float, float]] = {}
    normalized_features = []
    for vals, name in zip(num_features, feature_names):
        mean, std = float(vals.mean()), float(vals.std() + 1e-8)
        normalized_features.append((vals - mean) / std)
        norm_stats[name] = (mean, std)

    product_x_num = np.stack(normalized_features, axis=1)

    # Excluded product mask (optional)
    exclude_col = config.get("columns", {}).get("is_excluded")
    excluded_mask = None
    if exclude_col and exclude_col in products_df.columns:
        excluded_mask = products_df[exclude_col].fillna(False).values.astype(bool)

    # --- User Split ---
    train_mask = np.zeros(n_users, dtype=bool)
    val_mask = np.zeros(n_users, dtype=bool)
    test_mask = np.zeros(n_users, dtype=bool)

    split_ratios = config.get("eval", {}).get("user_split", [0.8, 0.1, 0.1])
    split_seed = config.get("eval", {}).get("random_seed", 42)
    rng = np.random.RandomState(split_seed)

    # Stratified split by engagement tier if available
    ordered_user_ids = [uid for uid, _ in sorted(user_to_id.items(), key=lambda x: x[1])]

    engagement_col = config.get("columns", {}).get("engagement_tier", "engagement_tier")
    if engagement_col in users_df.columns:
        users_indexed_raw = users_df.set_index("user_id")[engagement_col].to_dict()
        # Normalize: null/missing tiers get "unknown" bucket
        from rec_engine import is_valid_scalar

        users_indexed = {
            uid: str(v).lower() if is_valid_scalar(v) else "unknown"
            for uid, v in users_indexed_raw.items()
        }
        # Discover actual tiers from normalized data
        actual_tiers = sorted(set(users_indexed.values()))
        tiers = actual_tiers if actual_tiers else [_ALL_USERS_TIER]
        logger.info("Engagement tiers found: %s", actual_tiers)
    else:
        users_indexed = {}
        tiers = [_ALL_USERS_TIER]

    for tier in tiers:
        if tier is _ALL_USERS_TIER:
            tier_indices = list(range(n_users))
        else:
            tier_indices = [
                idx for idx, uid in enumerate(ordered_user_ids)
                if users_indexed.get(uid, "unknown") == tier
            ]

        rng.shuffle(tier_indices)
        n = len(tier_indices)
        n_train = int(n * split_ratios[0])
        n_val = int(n * split_ratios[1])

        for idx in tier_indices[:n_train]:
            train_mask[idx] = True
        for idx in tier_indices[n_train:n_train + n_val]:
            val_mask[idx] = True
        for idx in tier_indices[n_train + n_val:]:
            test_mask[idx] = True

    # --- Build HeteroData ---
    data = HeteroData()

    data["user"].num_nodes = n_users
    data["product"].num_nodes = n_products
    data["product"].category_id = torch.tensor(category_ids, dtype=torch.long)
    data["product"].x_num = torch.tensor(product_x_num, dtype=torch.float)
    if excluded_mask is not None:
        data["product"].is_excluded = torch.tensor(excluded_mask, dtype=torch.bool)

    if is_3node and n_entities > 0:
        data[entity_type_name].num_nodes = n_entities
        # Entity features (if configured)
        entity_features_cfg = config.get("entity", {}).get("features", [])
        if entities_df is not None and entity_features_cfg:
            entity_feat_arrays = []
            for feat_name in entity_features_cfg:
                if feat_name in entities_df.columns:
                    vals = entities_df[feat_name].fillna(0).values.astype(np.float32)
                    mean, std = float(vals.mean()), float(vals.std() + 1e-8)
                    entity_feat_arrays.append((vals - mean) / std)
                    norm_stats[f"entity_{feat_name}"] = (mean, std)
            if entity_feat_arrays:
                data[entity_type_name].x = torch.tensor(
                    np.stack(entity_feat_arrays, axis=1), dtype=torch.float
                )

    # --- Edge Indices ---

    # 1. User -> Product (interacts)
    interactions_df = edges.get("interactions", pd.DataFrame())
    user_id_col = config.get("columns", {}).get("user_id", "user_id")
    product_id_col = config.get("columns", {}).get("product_id", "product_id")

    if len(interactions_df) > 0:
        train_user_ids = {
            ordered_user_ids[idx] for idx, is_train in enumerate(train_mask) if is_train
        }
        # Use config-driven column names for filtering, warn on fallback
        int_user_col = user_id_col if user_id_col in interactions_df.columns else "user_id"
        int_prod_col = product_id_col if product_id_col in interactions_df.columns else "product_id"
        if int_user_col != user_id_col:
            logger.warning(
                "Config column '%s' not in interactions; falling back to 'user_id'",
                user_id_col,
            )
        if int_prod_col != product_id_col:
            logger.warning(
                "Config column '%s' not in interactions; falling back to 'product_id'",
                product_id_col,
            )
        # Transductive setup: ALL user interactions (train/val/test) are included
        # in the graph for message passing, so GNN embeddings benefit from the
        # full neighbourhood structure. However, only train-user edges are used
        # for BPR loss computation (via train_mask). Held-out *labels*
        # (test_interactions) come from a separate future time window and are
        # never stored as graph edges, so there is no information leakage.
        all_interactions = interactions_df[
            interactions_df[int_user_col].isin(user_to_id)
            & interactions_df[int_prod_col].isin(product_to_id)
        ].copy()

        if len(all_interactions) > 0:
            src = torch.tensor(
                all_interactions[int_user_col].map(user_to_id).values, dtype=torch.long
            )
            dst = torch.tensor(
                all_interactions[int_prod_col].map(product_to_id).values, dtype=torch.long
            )
            data["user", "interacts", "product"].edge_index = torch.stack([src, dst])
            if "weight" in all_interactions.columns:
                raw_weights = all_interactions["weight"].values.astype(np.float64)
                n_nan = int(np.isnan(raw_weights).sum())
                n_inf = int(np.isinf(raw_weights).sum())
                if n_nan > 0 or n_inf > 0:
                    raise ValueError(
                        f"interaction edge weights contain {n_nan} NaN and "
                        f"{n_inf} Inf values. Check input data."
                    )
                if (raw_weights < 0).any():
                    n_neg = int((raw_weights < 0).sum())
                    raise ValueError(
                        f"interaction edge weights contain {n_neg} negative "
                        "values. Weights must be non-negative."
                    )
                weights = torch.tensor(raw_weights.astype(np.float32), dtype=torch.float)
            else:
                weights = torch.ones(len(all_interactions), dtype=torch.float)
            data["user", "interacts", "product"].edge_weight = weights
            data["product", "rev_interacts", "user"].edge_index = torch.stack([dst, src])
            data["product", "rev_interacts", "user"].edge_weight = weights

            # Train edge mask: only train-user edges used for BPR loss
            train_edge_mask = torch.tensor(
                all_interactions[int_user_col].isin(train_user_ids).values,
                dtype=torch.bool,
            )
            data["user", "interacts", "product"].train_mask = train_edge_mask

    # 2. Product -> Entity (fits) — 3-node only
    if is_3node:
        fitment_df = edges.get("fitment", pd.DataFrame())
        if len(fitment_df) > 0:
            fitment = fitment_df[
                fitment_df["product_id"].isin(product_to_id)
                & fitment_df["entity_id"].isin(entity_to_id)
            ]
            if len(fitment) > 0:
                fit_src = torch.tensor(
                    fitment["product_id"].map(product_to_id).values, dtype=torch.long
                )
                fit_dst = torch.tensor(
                    fitment["entity_id"].map(entity_to_id).values, dtype=torch.long
                )
                data["product", "fits", entity_type_name].edge_index = torch.stack([fit_src, fit_dst])
                data[entity_type_name, "rev_fits", "product"].edge_index = torch.stack([fit_dst, fit_src])

        # 3. User -> Entity (owns) — 3-node only
        ownership_df = edges.get("ownership", pd.DataFrame())
        if len(ownership_df) > 0:
            ownership = ownership_df[
                ownership_df["user_id"].isin(user_to_id)
                & ownership_df["entity_id"].isin(entity_to_id)
            ]
            if len(ownership) > 0:
                own_src = torch.tensor(
                    ownership["user_id"].map(user_to_id).values, dtype=torch.long
                )
                own_dst = torch.tensor(
                    ownership["entity_id"].map(entity_to_id).values, dtype=torch.long
                )
                data["user", "owns", entity_type_name].edge_index = torch.stack([own_src, own_dst])
                data[entity_type_name, "rev_owns", "user"].edge_index = torch.stack([own_dst, own_src])

    # 4. Product <-> Product (co_purchased, symmetric)
    copurchase_df = edges.get("copurchase", pd.DataFrame())
    if len(copurchase_df) > 0:
        copurchase = copurchase_df[
            copurchase_df["product_a"].isin(product_to_id)
            & copurchase_df["product_b"].isin(product_to_id)
        ]
        if len(copurchase) > 0:
            cp_src = torch.tensor(
                copurchase["product_a"].map(product_to_id).values, dtype=torch.long
            )
            cp_dst = torch.tensor(
                copurchase["product_b"].map(product_to_id).values, dtype=torch.long
            )
            if "weight" in copurchase.columns:
                cp_w = torch.tensor(
                    copurchase["weight"].fillna(0).values.astype(np.float32),
                    dtype=torch.float,
                )
            else:
                cp_w = torch.ones(len(copurchase), dtype=torch.float)
            _validate_edge_weights(cp_w, "co-purchase")
            # Symmetric
            both_src = torch.cat([cp_src, cp_dst])
            both_dst = torch.cat([cp_dst, cp_src])
            both_w = torch.cat([cp_w, cp_w])
            data["product", "co_purchased", "product"].edge_index = torch.stack([both_src, both_dst])
            data["product", "co_purchased", "product"].edge_weight = both_w

    split_masks = {
        "train_mask": torch.tensor(train_mask, dtype=torch.bool),
        "val_mask": torch.tensor(val_mask, dtype=torch.bool),
        "test_mask": torch.tensor(test_mask, dtype=torch.bool),
    }

    entity_features_cfg = config.get("entity", {}).get("features", [])
    entity_num_features = 0
    if is_3node and entity_type_name in data.node_types:
        if hasattr(data[entity_type_name], "x"):
            entity_num_features = data[entity_type_name].x.shape[1]

    metadata = {
        "category_encoder": category_encoder,
        "n_categories": n_categories,
        "norm_stats": norm_stats,
        "product_num_features": len(num_features),
        "entity_num_features": entity_num_features,
    }

    allow_missing = config.get("graph", {}).get("allow_missing_entity_edges", False)
    _validate_graph(data, topology, entity_type_name, strict=not allow_missing)
    _log_graph_stats(data, split_masks)

    return data, split_masks, metadata


def _validate_edge_weights(weights: torch.Tensor, edge_name: str) -> None:
    """Check edge weights are finite and non-negative."""
    if not torch.isfinite(weights).all():
        n_bad = (~torch.isfinite(weights)).sum().item()
        raise ValueError(
            f"{edge_name} edge weights contain {n_bad} non-finite values "
            "(NaN or Inf). Check input data."
        )
    if (weights < 0).any():
        n_neg = (weights < 0).sum().item()
        raise ValueError(
            f"{edge_name} edge weights contain {n_neg} negative values. "
            "Weights must be non-negative."
        )


def _validate_graph(
    data: Any,
    topology: str,
    entity_type_name: str,
    *,
    strict: bool = True,
) -> None:
    """Validate required edge types exist after construction.

    Args:
        strict: If True (default), missing entity edges in 3-node topology
            raise ValueError. Set to False (via config
            ``graph.allow_missing_entity_edges: true``) to downgrade to warning.
    """
    # Interaction edges are always required
    if ("user", "interacts", "product") not in data.edge_types:
        raise ValueError(
            "Graph has no user-product interaction edges. "
            "Check that interaction data is non-empty and user/product IDs match."
        )

    if topology == "user-entity-product":
        missing = []
        if ("product", "fits", entity_type_name) not in data.edge_types:
            missing.append(f"fitment (product->{entity_type_name})")
        if ("user", "owns", entity_type_name) not in data.edge_types:
            missing.append(f"ownership (user->{entity_type_name})")

        if missing:
            msg = (
                f"3-node graph missing entity edges: {', '.join(missing)}. "
                "Entity-aware features will be limited."
            )
            if strict:
                raise ValueError(
                    f"{msg} Set graph.allow_missing_entity_edges=true to "
                    "downgrade to a warning."
                )
            logger.warning(msg)


def _log_graph_stats(data: Any, split_masks: dict) -> None:
    """Log graph construction statistics."""
    logger.info("=== Graph Construction Complete ===")
    for node_type in data.node_types:
        logger.info("  %s: %d nodes", node_type, data[node_type].num_nodes)
    for edge_type in data.edge_types:
        ei = data[edge_type].edge_index
        logger.info("  %s: %d edges", edge_type, ei.shape[1])
    logger.info(
        "  User split: train=%d, val=%d, test=%d",
        split_masks["train_mask"].sum().item(),
        split_masks["val_mask"].sum().item(),
        split_masks["test_mask"].sum().item(),
    )
