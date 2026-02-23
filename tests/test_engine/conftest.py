"""Shared fixtures for engine tests.

Provides synthetic data for both 2-node and 3-node topologies.
"""

from __future__ import annotations

import numpy as np
import pandas as pd
import pytest
import torch
from torch_geometric.data import HeteroData

from plugins.defaults import DefaultPlugin

# ── Configs ──────────────────────────────────────────────────────────────────


def _base_config(topology: str = "user-entity-product") -> dict:
    return {
        "contract_version": "1.0",
        "topology": topology,
        "client": {"id": "test", "company_id": 0, "env": "test"},
        "columns": {
            "user_id": "user_id",
            "product_id": "product_id",
            "price": "price",
            "popularity": "popularity",
            "category": "category",
            "is_excluded": "is_excluded",
            "engagement_tier": "engagement_tier",
            "product_features": [],
        },
        "entity": {
            "type_name": "vehicle",
            "group_column": "make",
            "features": ["user_count", "product_count"],
        },
        "graph": {"min_price": 10, "co_purchase_threshold": 2, "co_purchase_top_k": 50},
        "model": {
            "embedding_dim": 16,
            "hidden_dim": 16,
            "num_heads": 2,
            "num_layers": 2,
            "dropout": 0.0,
            "proj_dropout": 0.0,
        },
        "training": {
            "lr_embedding": 0.01,
            "lr_gnn": 0.01,
            "weight_decay": 0.0,
            "max_epochs": 3,
            "patience": 2,
            "grad_clip": 1.0,
            "negative_mix": {"in_batch": 0.5, "fitment_hard": 0.3, "random": 0.2},
        },
        "eval": {
            "k_values": [4],
            "test_window_days": 30,
            "bootstrap_samples": 10,
            "user_split": [0.6, 0.2, 0.2],
            "go_no_go": {
                "go_delta": 0.03,
                "maybe_delta": 0.01,
                "investigate_delta": -0.01,
                "metric": "hit_rate_at_4",
            },
        },
        "scoring": {"total_slots": 4, "max_per_category": 2, "min_recs": 2},
        "fallback": {"enabled": True, "score_sentinel": 0.0},
        "output": {"model_version": "test-v1", "qa": {"min_users": 0, "min_coverage": 0.0}},
    }


@pytest.fixture(params=["user-product", "user-entity-product"])
def config_both_topologies(request):
    """Config fixture parameterized for both topologies."""
    cfg = _base_config(request.param)
    if request.param == "user-product":
        cfg["training"]["negative_mix"] = {"in_batch": 0.5, "fitment_hard": 0.0, "random": 0.5}
    return cfg


@pytest.fixture
def config_3node():
    return _base_config("user-entity-product")


@pytest.fixture
def config_2node():
    cfg = _base_config("user-product")
    cfg["training"]["negative_mix"] = {"in_batch": 0.5, "fitment_hard": 0.0, "random": 0.5}
    return cfg


# ── DataFrames ───────────────────────────────────────────────────────────────


@pytest.fixture
def sample_users():
    return pd.DataFrame({
        "user_id": [f"user_{i}" for i in range(10)],
        "engagement_tier": ["cold"] * 4 + ["warm"] * 3 + ["hot"] * 3,
    })


@pytest.fixture
def sample_products():
    return pd.DataFrame({
        "product_id": [f"prod_{i}" for i in range(20)],
        "price": np.random.uniform(20, 200, 20).tolist(),
        "popularity": np.random.uniform(0, 5, 20).tolist(),
        "category": [f"cat_{i % 5}" for i in range(20)],
        "is_excluded": [False] * 18 + [True] * 2,
        "name": [f"Product {i}" for i in range(20)],
        "url": [f"https://example.com/p/{i}" for i in range(20)],
        "image_url": [f"https://cdn.example.com/img/{i}.jpg" for i in range(20)],
    })


@pytest.fixture
def sample_entities():
    return pd.DataFrame({
        "entity_id": [f"entity_{i}" for i in range(5)],
        "make": ["Toyota", "Toyota", "Honda", "Honda", "Ford"],
        "user_count": [100, 80, 60, 40, 20],
        "product_count": [50, 40, 30, 20, 10],
    })


@pytest.fixture
def sample_interactions(sample_users, sample_products):
    rows = []
    for i in range(50):
        uid = f"user_{i % 10}"
        pid = f"prod_{i % 18}"  # avoid excluded products
        rows.append({
            "user_id": uid,
            "product_id": pid,
            "interaction_type": ["view", "cart", "order"][i % 3],
            "weight": [1.0, 3.0, 5.0][i % 3],
        })
    return pd.DataFrame(rows)


@pytest.fixture
def sample_fitment(sample_products, sample_entities):
    rows = []
    for i in range(18):  # exclude the 2 excluded products
        eid = f"entity_{i % 5}"
        rows.append({"product_id": f"prod_{i}", "entity_id": eid})
    return pd.DataFrame(rows)


@pytest.fixture
def sample_ownership(sample_users, sample_entities):
    rows = []
    for i in range(10):
        rows.append({"user_id": f"user_{i}", "entity_id": f"entity_{i % 5}"})
    return pd.DataFrame(rows)


@pytest.fixture
def sample_copurchase():
    rows = [
        {"product_a": "prod_0", "product_b": "prod_1", "weight": 3.0},
        {"product_a": "prod_1", "product_b": "prod_2", "weight": 2.0},
        {"product_a": "prod_3", "product_b": "prod_4", "weight": 5.0},
    ]
    return pd.DataFrame(rows)


@pytest.fixture
def sample_test_interactions():
    return pd.DataFrame({
        "user_id": ["user_8", "user_8", "user_9", "user_9"],
        "product_id": ["prod_0", "prod_1", "prod_2", "prod_3"],
    })


@pytest.fixture
def all_dataframes_3node(
    sample_users, sample_products, sample_entities,
    sample_interactions, sample_fitment, sample_ownership,
    sample_copurchase, sample_test_interactions,
):
    return {
        "users": sample_users,
        "products": sample_products,
        "entities": sample_entities,
        "interactions": sample_interactions,
        "fitment": sample_fitment,
        "ownership": sample_ownership,
        "copurchase": sample_copurchase,
        "test_interactions": sample_test_interactions,
    }


@pytest.fixture
def all_dataframes_2node(
    sample_users, sample_products,
    sample_interactions, sample_copurchase, sample_test_interactions,
):
    return {
        "users": sample_users,
        "products": sample_products,
        "interactions": sample_interactions,
        "copurchase": sample_copurchase,
        "test_interactions": sample_test_interactions,
    }


# ── Plugin ───────────────────────────────────────────────────────────────────


@pytest.fixture
def default_plugin():
    return DefaultPlugin(salt="test-salt")


# ── Pre-built Graph Fixtures ────────────────────────────────────────────────


def _build_small_graph(topology: str) -> tuple[HeteroData, dict, dict, dict]:
    """Build a minimal graph for testing."""
    n_users, n_products, n_entities = 10, 20, 5

    data = HeteroData()
    data["user"].num_nodes = n_users
    data["product"].num_nodes = n_products
    data["product"].category_id = torch.randint(0, 5, (n_products,))
    data["product"].x_num = torch.randn(n_products, 2)
    data["product"].is_excluded = torch.tensor(
        [False] * 18 + [True] * 2, dtype=torch.bool
    )

    # Interactions (transductive: includes val/test users for message passing)
    # Users 0-5 are train, 6-7 val, 8-9 test
    src = torch.tensor([0, 0, 1, 1, 2, 3, 4, 5, 8, 9], dtype=torch.long)
    dst = torch.tensor([0, 1, 2, 3, 4, 5, 6, 7, 0, 2], dtype=torch.long)
    data["user", "interacts", "product"].edge_index = torch.stack([src, dst])
    data["user", "interacts", "product"].edge_weight = torch.ones(len(src))
    # Train edge mask: only train-user edges used for BPR loss
    data["user", "interacts", "product"].train_mask = torch.tensor(
        [True, True, True, True, True, True, True, True, False, False],
        dtype=torch.bool,
    )
    data["product", "rev_interacts", "user"].edge_index = torch.stack([dst, src])
    data["product", "rev_interacts", "user"].edge_weight = torch.ones(len(src))

    # Co-purchase
    cp_src = torch.tensor([0, 1], dtype=torch.long)
    cp_dst = torch.tensor([1, 2], dtype=torch.long)
    data["product", "co_purchased", "product"].edge_index = torch.stack(
        [torch.cat([cp_src, cp_dst]), torch.cat([cp_dst, cp_src])]
    )

    user_to_id = {f"user_{i}": i for i in range(n_users)}
    product_to_id = {f"prod_{i}": i for i in range(n_products)}
    id_mappings = {"user_to_id": user_to_id, "product_to_id": product_to_id}

    if topology == "user-entity-product":
        data["vehicle"].num_nodes = n_entities
        data["vehicle"].x = torch.randn(n_entities, 2)

        # Fitment
        fit_src = torch.tensor([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], dtype=torch.long)
        fit_dst = torch.tensor([0, 0, 1, 1, 2, 2, 3, 3, 4, 4], dtype=torch.long)
        data["product", "fits", "vehicle"].edge_index = torch.stack([fit_src, fit_dst])
        data["vehicle", "rev_fits", "product"].edge_index = torch.stack([fit_dst, fit_src])

        # Ownership
        own_src = torch.tensor([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], dtype=torch.long)
        own_dst = torch.tensor([0, 0, 1, 1, 2, 2, 3, 3, 4, 4], dtype=torch.long)
        data["user", "owns", "vehicle"].edge_index = torch.stack([own_src, own_dst])
        data["vehicle", "rev_owns", "user"].edge_index = torch.stack([own_dst, own_src])

        entity_to_id = {f"entity_{i}": i for i in range(n_entities)}
        id_mappings["entity_to_id"] = entity_to_id

    split_masks = {
        "train_mask": torch.tensor([True] * 6 + [False] * 4, dtype=torch.bool),
        "val_mask": torch.tensor([False] * 6 + [True] * 2 + [False] * 2, dtype=torch.bool),
        "test_mask": torch.tensor([False] * 8 + [True] * 2, dtype=torch.bool),
    }

    entity_num_features = 2 if topology == "user-entity-product" else 0
    return data, split_masks, id_mappings, {
        "n_categories": 5,
        "product_num_features": 2,
        "entity_num_features": entity_num_features,
    }


@pytest.fixture
def small_graph_3node():
    return _build_small_graph("user-entity-product")


@pytest.fixture
def small_graph_2node():
    return _build_small_graph("user-product")
