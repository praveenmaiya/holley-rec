"""Build PyG HeteroData graph from DataFrames."""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any

import numpy as np
import pandas as pd
import torch
from sklearn.preprocessing import LabelEncoder

if TYPE_CHECKING:
    from torch_geometric.data import HeteroData

logger = logging.getLogger(__name__)


def build_hetero_graph(
    nodes: dict[str, pd.DataFrame],
    edges: dict[str, pd.DataFrame],
    id_mappings: dict[str, dict],
    config: dict[str, Any],
) -> tuple[HeteroData, dict[str, torch.Tensor], dict[str, Any]]:
    """Build heterogeneous graph from node/edge DataFrames.

    Args:
        nodes: Dict with 'users', 'products', 'vehicles' DataFrames.
        edges: Dict with 'interactions', 'fitment', 'ownership', 'copurchase' DataFrames.
        id_mappings: Dict with 'user_to_id', 'product_to_id', 'vehicle_to_id' mappings.
        config: GNN configuration dict.

    Returns:
        Tuple of (HeteroData, split_masks, metadata).
        split_masks: dict with 'train_mask', 'val_mask', 'test_mask' boolean tensors over users.
        metadata: dict with label encoders and normalization stats.
    """
    from torch_geometric.data import HeteroData

    user_to_id = id_mappings["user_to_id"]
    product_to_id = id_mappings["product_to_id"]
    vehicle_to_id = id_mappings["vehicle_to_id"]

    users_df = nodes["users"]
    products_df = nodes["products"]
    vehicles_df = nodes["vehicles"]

    n_users = len(user_to_id)
    n_products = len(product_to_id)
    n_vehicles = len(vehicle_to_id)

    # Canonical entity order is defined by ID mappings.
    ordered_user_emails = [e for e, _ in sorted(user_to_id.items(), key=lambda x: x[1])]
    ordered_product_skus = [s for s, _ in sorted(product_to_id.items(), key=lambda x: x[1])]
    ordered_vehicle_keys = [k for k, _ in sorted(vehicle_to_id.items(), key=lambda x: x[1])]

    users_lookup = (
        users_df.drop_duplicates(subset=["email_lower"])
        .set_index("email_lower", drop=False)
    )
    products_lookup = (
        products_df.drop_duplicates(subset=["base_sku"])
        .set_index("base_sku", drop=False)
    )
    vehicles_lookup = (
        vehicles_df.assign(vehicle_key=vehicles_df["make"] + "|" + vehicles_df["model"])
        .drop_duplicates(subset=["vehicle_key"])
        .set_index("vehicle_key", drop=False)
    )

    # Fail fast on mapping/table drift to prevent silent embedding-feature misalignment.
    missing_users = [email for email in ordered_user_emails if email not in users_lookup.index]
    missing_products = [sku for sku in ordered_product_skus if sku not in products_lookup.index]
    missing_vehicles = [key for key in ordered_vehicle_keys if key not in vehicles_lookup.index]
    if missing_users or missing_products or missing_vehicles:
        problems = []
        if missing_users:
            problems.append(f"users={len(missing_users)}")
        if missing_products:
            problems.append(f"products={len(missing_products)}")
        if missing_vehicles:
            problems.append(f"vehicles={len(missing_vehicles)}")
        raise ValueError(
            "ID mapping mismatch with node tables; refresh exports or use matching checkpoint data "
            f"({', '.join(problems)})"
        )

    ordered_products = products_lookup.reindex(ordered_product_skus)
    ordered_vehicles = vehicles_lookup.reindex(ordered_vehicle_keys)

    # --- Node Features ---

    # Part type encoding
    part_type_encoder = LabelEncoder()
    part_type_encoder.fit(products_lookup["part_type"].fillna("UNKNOWN").astype(str).values)
    part_type_ids = part_type_encoder.transform(
        ordered_products["part_type"].fillna("UNKNOWN").astype(str).values
    )
    n_part_types = len(part_type_encoder.classes_)

    # Product numerical features (normalized)
    price_vals = ordered_products["price"].fillna(0).values.astype(np.float32)
    log_pop_vals = ordered_products["log_popularity"].fillna(0).values.astype(np.float32)
    fitment_breadth_vals = ordered_products["fitment_breadth"].fillna(0).values.astype(np.float32)
    is_universal_vals = ordered_products["is_universal"].fillna(False).values.astype(bool)

    price_mean, price_std = price_vals.mean(), price_vals.std() + 1e-8
    log_pop_mean, log_pop_std = log_pop_vals.mean(), log_pop_vals.std() + 1e-8
    fb_mean, fb_std = fitment_breadth_vals.mean(), fitment_breadth_vals.std() + 1e-8

    price_norm = (price_vals - price_mean) / price_std
    log_pop_norm = (log_pop_vals - log_pop_mean) / log_pop_std
    fb_norm = (fitment_breadth_vals - fb_mean) / fb_std

    # Vehicle features (normalized)
    user_count_vals = ordered_vehicles["user_count"].fillna(0).values.astype(np.float32)
    prod_count_vals = ordered_vehicles["product_count"].fillna(0).values.astype(np.float32)

    uc_mean, uc_std = user_count_vals.mean(), user_count_vals.std() + 1e-8
    pc_mean, pc_std = prod_count_vals.mean(), prod_count_vals.std() + 1e-8

    vehicle_features = np.stack([
        (user_count_vals - uc_mean) / uc_std,
        (prod_count_vals - pc_mean) / pc_std,
    ], axis=1)

    # --- User Split (80/10/10 stratified by engagement tier) ---
    if "engagement_tier" in users_lookup.columns:
        engagement_by_user = users_lookup["engagement_tier"].astype(str).str.lower()
    else:
        engagement_by_user = pd.Series(dtype=str)

    train_mask = np.zeros(n_users, dtype=bool)
    val_mask = np.zeros(n_users, dtype=bool)
    test_mask = np.zeros(n_users, dtype=bool)

    split_ratios = config["eval"]["user_split"]
    rng = np.random.RandomState(42)

    for tier in ["cold", "warm", "hot"]:
        tier_indices = [
            uid
            for uid, email in enumerate(ordered_user_emails)
            if engagement_by_user.get(email, "cold") == tier
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

    # Node stores (embeddings are learned, we store feature indices/values)
    data["user"].num_nodes = n_users
    data["product"].num_nodes = n_products
    data["product"].part_type_id = torch.tensor(part_type_ids, dtype=torch.long)
    data["product"].x_num = torch.tensor(
        np.stack([price_norm, log_pop_norm, fb_norm], axis=1), dtype=torch.float
    )
    data["product"].is_universal = torch.tensor(is_universal_vals, dtype=torch.bool)
    data["vehicle"].num_nodes = n_vehicles
    data["vehicle"].x = torch.tensor(vehicle_features, dtype=torch.float)

    # --- Edge Indices ---

    # 1. User -> Product (interacts)
    interactions_df = edges["interactions"]
    if len(interactions_df) > 0:
        train_user_emails = {
            ordered_user_emails[idx]
            for idx, is_train in enumerate(train_mask)
            if is_train
        }
        train_interactions = interactions_df[
            interactions_df["email_lower"].isin(train_user_emails)
            & interactions_df["base_sku"].isin(product_to_id)
        ].copy()

        if len(train_interactions) > 0:
            src = torch.tensor(
                train_interactions["email_lower"].map(user_to_id).values,
                dtype=torch.long,
            )
            dst = torch.tensor(
                train_interactions["base_sku"].map(product_to_id).values,
                dtype=torch.long,
            )
            data["user", "interacts", "product"].edge_index = torch.stack([src, dst])
            weights = torch.tensor(
                train_interactions["weight"].fillna(0).values.astype(np.float32),
                dtype=torch.float,
            )
            data["user", "interacts", "product"].edge_weight = weights
            # Reverse
            data["product", "rev_interacts", "user"].edge_index = torch.stack([dst, src])
            data["product", "rev_interacts", "user"].edge_weight = weights

    # 2. Product -> Vehicle (fits)
    fitment_df = edges["fitment"]
    if len(fitment_df) > 0:
        fitment = fitment_df.copy()
        fitment["vehicle_key"] = fitment["make"] + "|" + fitment["model"]
        fitment = fitment[
            fitment["base_sku"].isin(product_to_id)
            & fitment["vehicle_key"].isin(vehicle_to_id)
        ]

        if len(fitment) > 0:
            fit_src_t = torch.tensor(
                fitment["base_sku"].map(product_to_id).values,
                dtype=torch.long,
            )
            fit_dst_t = torch.tensor(
                fitment["vehicle_key"].map(vehicle_to_id).values,
                dtype=torch.long,
            )
            data["product", "fits", "vehicle"].edge_index = torch.stack([fit_src_t, fit_dst_t])
            data["vehicle", "rev_fits", "product"].edge_index = torch.stack([fit_dst_t, fit_src_t])

    # 3. User -> Vehicle (owns)
    ownership_df = edges["ownership"]
    if len(ownership_df) > 0:
        ownership = ownership_df.copy()
        ownership["vehicle_key"] = ownership["make"] + "|" + ownership["model"]
        ownership = ownership[
            ownership["email_lower"].isin(user_to_id)
            & ownership["vehicle_key"].isin(vehicle_to_id)
        ]

        if len(ownership) > 0:
            own_src_t = torch.tensor(
                ownership["email_lower"].map(user_to_id).values,
                dtype=torch.long,
            )
            own_dst_t = torch.tensor(
                ownership["vehicle_key"].map(vehicle_to_id).values,
                dtype=torch.long,
            )
            data["user", "owns", "vehicle"].edge_index = torch.stack([own_src_t, own_dst_t])
            data["vehicle", "rev_owns", "user"].edge_index = torch.stack([own_dst_t, own_src_t])

    # 4. Product <-> Product (co_purchased, symmetric)
    copurchase_df = edges["copurchase"]
    if len(copurchase_df) > 0:
        copurchase = copurchase_df[
            copurchase_df["sku_a"].isin(product_to_id)
            & copurchase_df["sku_b"].isin(product_to_id)
        ]
        if len(copurchase) > 0:
            cp_src_t = torch.tensor(
                copurchase["sku_a"].map(product_to_id).values,
                dtype=torch.long,
            )
            cp_dst_t = torch.tensor(
                copurchase["sku_b"].map(product_to_id).values,
                dtype=torch.long,
            )
            cp_w_t = torch.tensor(
                copurchase["weight"].fillna(0).values.astype(np.float32),
                dtype=torch.float,
            )
            # Symmetric: add both directions
            both_src = torch.cat([cp_src_t, cp_dst_t])
            both_dst = torch.cat([cp_dst_t, cp_src_t])
            both_w = torch.cat([cp_w_t, cp_w_t])
            data["product", "co_purchased", "product"].edge_index = torch.stack([both_src, both_dst])
            data["product", "co_purchased", "product"].edge_weight = both_w

    split_masks = {
        "train_mask": torch.tensor(train_mask, dtype=torch.bool),
        "val_mask": torch.tensor(val_mask, dtype=torch.bool),
        "test_mask": torch.tensor(test_mask, dtype=torch.bool),
    }

    metadata = {
        "part_type_encoder": part_type_encoder,
        "n_part_types": n_part_types,
        "norm_stats": {
            "price": (price_mean, price_std),
            "log_popularity": (log_pop_mean, log_pop_std),
            "fitment_breadth": (fb_mean, fb_std),
            "user_count": (uc_mean, uc_std),
            "product_count": (pc_mean, pc_std),
        },
    }

    _log_graph_stats(data, split_masks)

    return data, split_masks, metadata


def _log_graph_stats(data: HeteroData, split_masks: dict) -> None:
    """Log graph construction statistics."""
    logger.info("=== Graph Construction Complete ===")
    for node_type in data.node_types:
        logger.info(f"  {node_type}: {data[node_type].num_nodes} nodes")
    for edge_type in data.edge_types:
        ei = data[edge_type].edge_index
        logger.info(f"  {edge_type}: {ei.shape[1]} edges")
    logger.info(
        f"  User split: train={split_masks['train_mask'].sum().item()}, "
        f"val={split_masks['val_mask'].sum().item()}, "
        f"test={split_masks['test_mask'].sum().item()}"
    )
