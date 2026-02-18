"""Tests for GNN graph builder."""

import numpy as np
import pandas as pd
import pytest

torch = pytest.importorskip("torch")
pytest.importorskip("torch_geometric")


@pytest.fixture
def sample_nodes():
    """10 users, 20 products, 5 vehicles."""
    users = pd.DataFrame({
        "email_lower": [f"user{i}@test.com" for i in range(10)],
        "v1_make": ["FORD"] * 4 + ["CHEVY"] * 3 + ["DODGE"] * 3,
        "v1_model": ["MUSTANG"] * 4 + ["CAMARO"] * 3 + ["CHARGER"] * 3,
        "v1_year": ["2020"] * 10,
        "has_email_consent": [True] * 8 + [False] * 2,
        "engagement_tier": ["cold"] * 7 + ["warm"] * 2 + ["hot"] * 1,
    })
    products = pd.DataFrame({
        "sku": [f"P{i:03d}" for i in range(20)],
        "base_sku": [f"P{i:03d}" for i in range(20)],
        "part_type": ["Ignition"] * 5 + ["Exhaust"] * 5 + ["Brakes"] * 5 + ["Wheels"] * 5,
        "price": np.random.uniform(25, 500, 20).tolist(),
        "log_popularity": np.random.uniform(0, 5, 20).tolist(),
        "fitment_breadth": np.random.randint(0, 20, 20).tolist(),
        "is_universal": [False] * 15 + [True] * 5,
    })
    vehicles = pd.DataFrame({
        "make": ["FORD", "CHEVY", "DODGE"],
        "model": ["MUSTANG", "CAMARO", "CHARGER"],
        "user_count": [4, 3, 3],
        "product_count": [10, 8, 6],
    })
    return {"users": users, "products": products, "vehicles": vehicles}


@pytest.fixture
def sample_edges():
    interactions = pd.DataFrame({
        "email_lower": ["user0@test.com", "user1@test.com", "user7@test.com", "user8@test.com"],
        "base_sku": ["P001", "P002", "P010", "P015"],
        "interaction_type": ["view", "cart", "order", "view"],
        "weight": [1.0, 3.0, 5.0, 1.0],
    })
    fitment = pd.DataFrame({
        "base_sku": [f"P{i:03d}" for i in range(10)] + [f"P{i:03d}" for i in range(5, 15)],
        "make": ["FORD"] * 10 + ["CHEVY"] * 10,
        "model": ["MUSTANG"] * 10 + ["CAMARO"] * 10,
    })
    ownership = pd.DataFrame({
        "email_lower": [f"user{i}@test.com" for i in range(10)],
        "make": ["FORD"] * 4 + ["CHEVY"] * 3 + ["DODGE"] * 3,
        "model": ["MUSTANG"] * 4 + ["CAMARO"] * 3 + ["CHARGER"] * 3,
    })
    copurchase = pd.DataFrame({
        "sku_a": ["P001", "P002", "P005"],
        "sku_b": ["P003", "P004", "P010"],
        "co_count": [5, 3, 2],
        "pmi": [0.5, 0.3, 0.2],
        "weight": [1.79, 1.39, 1.10],
    })
    return {
        "interactions": interactions,
        "fitment": fitment,
        "ownership": ownership,
        "copurchase": copurchase,
    }


@pytest.fixture
def sample_id_mappings(sample_nodes):
    return {
        "user_to_id": {
            email: i for i, email in enumerate(sample_nodes["users"]["email_lower"])
        },
        "product_to_id": {
            sku: i for i, sku in enumerate(sample_nodes["products"]["base_sku"])
        },
        "vehicle_to_id": {
            f"{row['make']}|{row['model']}": i
            for i, row in sample_nodes["vehicles"].iterrows()
        },
    }


@pytest.fixture
def gnn_config():
    return {
        "model": {
            "embedding_dim": 128, "hidden_dim": 256, "num_heads": 4,
            "num_layers": 2, "dropout": 0.1, "proj_dropout": 0.2,
        },
        "eval": {"user_split": [0.8, 0.1, 0.1], "k_values": [4, 10, 20]},
    }


class TestBuildHeteroGraph:
    def test_builds_correct_node_counts(
        self, sample_nodes, sample_edges, sample_id_mappings, gnn_config
    ):
        from src.gnn.graph_builder import build_hetero_graph

        data, masks, meta = build_hetero_graph(
            sample_nodes, sample_edges, sample_id_mappings, gnn_config
        )

        assert data["user"].num_nodes == 10
        assert data["product"].num_nodes == 20
        assert data["vehicle"].num_nodes == 3

    def test_product_features_correct_shape(
        self, sample_nodes, sample_edges, sample_id_mappings, gnn_config
    ):
        from src.gnn.graph_builder import build_hetero_graph

        data, _, _ = build_hetero_graph(
            sample_nodes, sample_edges, sample_id_mappings, gnn_config
        )

        assert data["product"].part_type_id.shape == (20,)
        assert data["product"].x_num.shape == (20, 3)

    def test_vehicle_features_correct_shape(
        self, sample_nodes, sample_edges, sample_id_mappings, gnn_config
    ):
        from src.gnn.graph_builder import build_hetero_graph

        data, _, _ = build_hetero_graph(
            sample_nodes, sample_edges, sample_id_mappings, gnn_config
        )

        assert data["vehicle"].x.shape == (3, 2)

    def test_user_split_sums_to_total(
        self, sample_nodes, sample_edges, sample_id_mappings, gnn_config
    ):
        from src.gnn.graph_builder import build_hetero_graph

        _, masks, _ = build_hetero_graph(
            sample_nodes, sample_edges, sample_id_mappings, gnn_config
        )

        total = masks["train_mask"].sum() + masks["val_mask"].sum() + masks["test_mask"].sum()
        assert total == 10

    def test_splits_are_disjoint(
        self, sample_nodes, sample_edges, sample_id_mappings, gnn_config
    ):
        from src.gnn.graph_builder import build_hetero_graph

        _, masks, _ = build_hetero_graph(
            sample_nodes, sample_edges, sample_id_mappings, gnn_config
        )

        overlap = (masks["train_mask"] & masks["val_mask"]).sum()
        assert overlap == 0

    def test_fitment_edges_exist(
        self, sample_nodes, sample_edges, sample_id_mappings, gnn_config
    ):
        from src.gnn.graph_builder import build_hetero_graph

        data, _, _ = build_hetero_graph(
            sample_nodes, sample_edges, sample_id_mappings, gnn_config
        )

        assert ("product", "fits", "vehicle") in data.edge_types
        assert data["product", "fits", "vehicle"].edge_index.shape[0] == 2

    def test_copurchase_edges_symmetric(
        self, sample_nodes, sample_edges, sample_id_mappings, gnn_config
    ):
        from src.gnn.graph_builder import build_hetero_graph

        data, _, _ = build_hetero_graph(
            sample_nodes, sample_edges, sample_id_mappings, gnn_config
        )

        if ("product", "co_purchased", "product") in data.edge_types:
            ei = data["product", "co_purchased", "product"].edge_index
            # Symmetric means we doubled the edges
            assert ei.shape[1] == 6  # 3 pairs * 2 directions

    def test_metadata_has_part_type_encoder(
        self, sample_nodes, sample_edges, sample_id_mappings, gnn_config
    ):
        from src.gnn.graph_builder import build_hetero_graph

        _, _, meta = build_hetero_graph(
            sample_nodes, sample_edges, sample_id_mappings, gnn_config
        )

        assert "part_type_encoder" in meta
        assert meta["n_part_types"] == 4  # Ignition, Exhaust, Brakes, Wheels

    def test_drift_detection_raises_on_mismatched_user_mapping(
        self, sample_nodes, sample_edges, gnn_config
    ):
        """Graph builder raises ValueError when ID mapping has users not in node table."""
        from src.gnn.graph_builder import build_hetero_graph

        bad_mappings = {
            "user_to_id": {
                "ghost@nowhere.com": 0,  # not in sample_nodes
                "user0@test.com": 1,
            },
            "product_to_id": {
                sku: i for i, sku in enumerate(sample_nodes["products"]["base_sku"])
            },
            "vehicle_to_id": {
                f"{row['make']}|{row['model']}": i
                for i, row in sample_nodes["vehicles"].iterrows()
            },
        }

        with pytest.raises(ValueError, match="ID mapping mismatch"):
            build_hetero_graph(sample_nodes, sample_edges, bad_mappings, gnn_config)

    def test_drift_detection_raises_on_mismatched_product_mapping(
        self, sample_nodes, sample_edges, sample_id_mappings, gnn_config
    ):
        """Graph builder raises ValueError when ID mapping has products not in node table."""
        from src.gnn.graph_builder import build_hetero_graph

        bad_mappings = {
            **sample_id_mappings,
            "product_to_id": {
                "NONEXISTENT_SKU": 0,
                "P000": 1,
            },
        }

        with pytest.raises(ValueError, match="ID mapping mismatch"):
            build_hetero_graph(sample_nodes, sample_edges, bad_mappings, gnn_config)

    def test_drift_detection_raises_on_mismatched_vehicle_mapping(
        self, sample_nodes, sample_edges, sample_id_mappings, gnn_config
    ):
        """Graph builder raises ValueError when ID mapping has vehicles not in node table."""
        from src.gnn.graph_builder import build_hetero_graph

        bad_mappings = {
            **sample_id_mappings,
            "vehicle_to_id": {
                "TESLA|CYBERTRUCK": 0,
            },
        }

        with pytest.raises(ValueError, match="ID mapping mismatch"):
            build_hetero_graph(sample_nodes, sample_edges, bad_mappings, gnn_config)

    def test_is_universal_stored_on_product_nodes(
        self, sample_nodes, sample_edges, sample_id_mappings, gnn_config
    ):
        """is_universal boolean tensor is stored as product node attribute."""
        from src.gnn.graph_builder import build_hetero_graph

        data, _, _ = build_hetero_graph(
            sample_nodes, sample_edges, sample_id_mappings, gnn_config
        )

        assert hasattr(data["product"], "is_universal")
        assert data["product"].is_universal.dtype == torch.bool
        assert data["product"].is_universal.shape == (20,)
        # Fixture: first 15 products are non-universal, last 5 are universal
        assert data["product"].is_universal.sum().item() == 5

    def test_interaction_edges_include_only_train_users(
        self, sample_nodes, sample_edges, sample_id_mappings, gnn_config
    ):
        """Leakage guard: training interaction edges must come only from train users."""
        from src.gnn.graph_builder import build_hetero_graph

        data, masks, _ = build_hetero_graph(
            sample_nodes, sample_edges, sample_id_mappings, gnn_config
        )

        edge_type = ("user", "interacts", "product")
        if edge_type not in data.edge_types:
            pytest.skip("No training interaction edges in fixture split")

        train_users = set(masks["train_mask"].nonzero(as_tuple=True)[0].tolist())
        src_users = set(data[edge_type].edge_index[0].tolist())
        assert src_users.issubset(train_users)

    def test_reverse_interaction_edge_weights_match_forward(
        self, sample_nodes, sample_edges, sample_id_mappings, gnn_config
    ):
        """Forward and reverse interaction edges should carry identical weights."""
        from src.gnn.graph_builder import build_hetero_graph

        data, _, _ = build_hetero_graph(
            sample_nodes, sample_edges, sample_id_mappings, gnn_config
        )

        fwd = ("user", "interacts", "product")
        rev = ("product", "rev_interacts", "user")
        if fwd not in data.edge_types or rev not in data.edge_types:
            pytest.skip("No interaction edges in fixture split")

        assert torch.equal(data[fwd].edge_weight, data[rev].edge_weight)
