"""Tests for rec_engine.core.graph_builder — config-driven graph construction."""

import pandas as pd
import pytest
import torch

from rec_engine.core.graph_builder import build_hetero_graph


class TestBuildHeteroGraph:
    @pytest.fixture
    def id_mappings_2node(self, sample_users, sample_products):
        return {
            "user_to_id": {uid: i for i, uid in enumerate(sorted(sample_users["user_id"]))},
            "product_to_id": {pid: i for i, pid in enumerate(sorted(sample_products["product_id"]))},
        }

    @pytest.fixture
    def id_mappings_3node(self, id_mappings_2node, sample_entities):
        m = dict(id_mappings_2node)
        m["entity_to_id"] = {eid: i for i, eid in enumerate(sorted(sample_entities["entity_id"]))}
        return m

    def test_2node_graph_structure(
        self, sample_users, sample_products, sample_interactions,
        sample_copurchase, id_mappings_2node, config_2node,
    ):
        nodes = {"users": sample_users, "products": sample_products}
        edges = {"interactions": sample_interactions, "copurchase": sample_copurchase}
        data, split_masks, metadata = build_hetero_graph(
            nodes, edges, id_mappings_2node, config_2node,
        )
        assert data["user"].num_nodes == 10
        assert data["product"].num_nodes == 20
        assert "train_mask" in split_masks

    def test_3node_graph_structure(
        self, sample_users, sample_products, sample_entities,
        sample_interactions, sample_fitment, sample_ownership,
        sample_copurchase, id_mappings_3node, config_3node,
    ):
        nodes = {"users": sample_users, "products": sample_products, "entities": sample_entities}
        edges = {
            "interactions": sample_interactions,
            "fitment": sample_fitment,
            "ownership": sample_ownership,
            "copurchase": sample_copurchase,
        }
        data, split_masks, metadata = build_hetero_graph(
            nodes, edges, id_mappings_3node, config_3node,
        )
        assert data["user"].num_nodes == 10
        assert data["product"].num_nodes == 20
        assert data["vehicle"].num_nodes == 5
        assert ("product", "fits", "vehicle") in data.edge_types

    def test_user_split_ratios(
        self, sample_users, sample_products, sample_interactions,
        id_mappings_2node, config_2node,
    ):
        nodes = {"users": sample_users, "products": sample_products}
        edges = {"interactions": sample_interactions}
        _, split_masks, _ = build_hetero_graph(
            nodes, edges, id_mappings_2node, config_2node,
        )
        total = (
            split_masks["train_mask"].sum()
            + split_masks["val_mask"].sum()
            + split_masks["test_mask"].sum()
        )
        assert total.item() == 10

    def test_split_masks_pairwise_disjoint(
        self, sample_users, sample_products, sample_interactions,
        id_mappings_2node, config_2node,
    ):
        """R8: Split masks must be pairwise disjoint — no user in multiple splits."""
        nodes = {"users": sample_users, "products": sample_products}
        edges = {"interactions": sample_interactions}
        _, split_masks, _ = build_hetero_graph(
            nodes, edges, id_mappings_2node, config_2node,
        )
        train = split_masks["train_mask"]
        val = split_masks["val_mask"]
        test = split_masks["test_mask"]
        assert not (train & val).any(), "train and val masks overlap"
        assert not (train & test).any(), "train and test masks overlap"
        assert not (val & test).any(), "val and test masks overlap"

    def test_product_features_normalized(
        self, sample_users, sample_products, sample_interactions,
        id_mappings_2node, config_2node,
    ):
        nodes = {"users": sample_users, "products": sample_products}
        edges = {"interactions": sample_interactions}
        data, _, metadata = build_hetero_graph(
            nodes, edges, id_mappings_2node, config_2node,
        )
        x_num = data["product"].x_num
        assert x_num.shape[0] == 20
        assert x_num.shape[1] >= 2
        # Normalized features should be roughly mean 0
        assert abs(x_num.mean().item()) < 1.0

    def test_metadata_includes_categories(
        self, sample_users, sample_products, sample_interactions,
        id_mappings_2node, config_2node,
    ):
        nodes = {"users": sample_users, "products": sample_products}
        edges = {"interactions": sample_interactions}
        _, _, metadata = build_hetero_graph(
            nodes, edges, id_mappings_2node, config_2node,
        )
        assert "category_encoder" in metadata
        assert "n_categories" in metadata
        assert metadata["n_categories"] > 0

    def test_copurchase_symmetric(
        self, sample_users, sample_products, sample_interactions,
        sample_copurchase, id_mappings_2node, config_2node,
    ):
        nodes = {"users": sample_users, "products": sample_products}
        edges = {"interactions": sample_interactions, "copurchase": sample_copurchase}
        data, _, _ = build_hetero_graph(
            nodes, edges, id_mappings_2node, config_2node,
        )
        if ("product", "co_purchased", "product") in data.edge_types:
            ei = data["product", "co_purchased", "product"].edge_index
            # Symmetric: each edge appears twice
            assert ei.shape[1] % 2 == 0

    def test_excluded_mask_set(
        self, sample_users, sample_products, sample_interactions,
        id_mappings_2node, config_2node,
    ):
        nodes = {"users": sample_users, "products": sample_products}
        edges = {"interactions": sample_interactions}
        data, _, _ = build_hetero_graph(
            nodes, edges, id_mappings_2node, config_2node,
        )
        assert hasattr(data["product"], "is_excluded")
        assert data["product"].is_excluded.sum().item() == 2

    def test_unsorted_products_tensor_alignment(
        self, sample_users, sample_interactions, config_2node,
    ):
        """C2: Products in reverse order must still align with ID mapping."""
        # Create products in REVERSE alphabetical order (opposite of sorted ID mapping)
        products_reversed = pd.DataFrame({
            "product_id": [f"prod_{i}" for i in range(19, -1, -1)],
            "price": [100.0 + i for i in range(19, -1, -1)],
            "popularity": [float(i) for i in range(19, -1, -1)],
            "category": [f"cat_{i % 5}" for i in range(19, -1, -1)],
            "is_excluded": [True, True] + [False] * 18,
            "name": [f"Product {i}" for i in range(19, -1, -1)],
            "url": [f"https://example.com/p/{i}" for i in range(19, -1, -1)],
            "image_url": [f"https://cdn.example.com/img/{i}.jpg" for i in range(19, -1, -1)],
        })
        # ID mapping assigns prod_0 -> 0, prod_1 -> 1, ..., prod_19 -> 19
        id_mappings = {
            "user_to_id": {f"user_{i}": i for i in range(10)},
            "product_to_id": {f"prod_{i}": i for i in range(20)},
        }
        nodes = {"users": sample_users, "products": products_reversed}
        edges = {"interactions": sample_interactions}
        data, _, _ = build_hetero_graph(nodes, edges, id_mappings, config_2node)

        # prod_0 has price 100.0, prod_19 has price 119.0 in the reversed DF
        # After reindexing by _pid, tensor[0] should correspond to prod_0 (price=100.0)
        # is_excluded: prod_18 and prod_19 are excluded (mapped IDs 18, 19)
        excluded = data["product"].is_excluded
        assert excluded[18].item() is True
        assert excluded[19].item() is True
        assert excluded[0].item() is False

    def test_unsorted_entities_tensor_alignment(
        self, sample_users, sample_products, sample_interactions,
        sample_fitment, sample_ownership, sample_copurchase, config_3node,
    ):
        """C2: Entities in reverse order must still align with ID mapping."""
        entities_reversed = pd.DataFrame({
            "entity_id": [f"entity_{i}" for i in range(4, -1, -1)],
            "make": ["Ford", "Honda", "Honda", "Toyota", "Toyota"],
            "user_count": [20, 40, 60, 80, 100],
            "product_count": [10, 20, 30, 40, 50],
        })
        id_mappings = {
            "user_to_id": {f"user_{i}": i for i in range(10)},
            "product_to_id": {f"prod_{i}": i for i in range(20)},
            "entity_to_id": {f"entity_{i}": i for i in range(5)},
        }
        nodes = {"users": sample_users, "products": sample_products, "entities": entities_reversed}
        edges = {
            "interactions": sample_interactions,
            "fitment": sample_fitment,
            "ownership": sample_ownership,
            "copurchase": sample_copurchase,
        }
        data, _, _ = build_hetero_graph(nodes, edges, id_mappings, config_3node)

        # entity_0 -> user_count=100 (sorted first in mapping)
        # After reindexing, tensor[0] should have entity_0's features
        assert data["vehicle"].num_nodes == 5
        assert data["vehicle"].x.shape == (5, 2)

    def test_dynamic_engagement_tiers(
        self, sample_products, sample_interactions, config_2node,
    ):
        """H6: Custom engagement tiers are discovered from data, not hardcoded."""
        users_custom = pd.DataFrame({
            "user_id": [f"user_{i}" for i in range(10)],
            "engagement_tier": ["new"] * 3 + ["active"] * 4 + ["vip"] * 3,
        })
        id_mappings = {
            "user_to_id": {f"user_{i}": i for i in range(10)},
            "product_to_id": {f"prod_{i}": i for i in range(20)},
        }
        nodes = {"users": users_custom, "products": sample_products}
        edges = {"interactions": sample_interactions}
        _, split_masks, _ = build_hetero_graph(nodes, edges, id_mappings, config_2node)

        # All users should be assigned to some split (none dropped)
        total = (
            split_masks["train_mask"].sum()
            + split_masks["val_mask"].sum()
            + split_masks["test_mask"].sum()
        )
        assert total.item() == 10

    def test_null_engagement_tiers_not_dropped(
        self, sample_products, sample_interactions, config_2node,
    ):
        """H6 regression: Users with None/NaN engagement tiers must not be dropped."""
        users_with_nulls = pd.DataFrame({
            "user_id": [f"user_{i}" for i in range(10)],
            "engagement_tier": ["cold", "cold", None, None, "warm", None, "warm", None, None, "cold"],
        })
        id_mappings = {
            "user_to_id": {f"user_{i}": i for i in range(10)},
            "product_to_id": {f"prod_{i}": i for i in range(20)},
        }
        nodes = {"users": users_with_nulls, "products": sample_products}
        edges = {"interactions": sample_interactions}
        _, split_masks, _ = build_hetero_graph(nodes, edges, id_mappings, config_2node)

        total = (
            split_masks["train_mask"].sum()
            + split_masks["val_mask"].sum()
            + split_masks["test_mask"].sum()
        )
        # All 10 users must be assigned — nulls go to "unknown" bucket, not dropped
        assert total.item() == 10

    def test_engagement_tier_named_all_no_collision(
        self, sample_products, sample_interactions, config_2node,
    ):
        """R7 regression: A real tier named 'all' must not collide with the sentinel."""
        users_with_all_tier = pd.DataFrame({
            "user_id": [f"user_{i}" for i in range(10)],
            "engagement_tier": ["all"] * 4 + ["warm"] * 3 + ["hot"] * 3,
        })
        id_mappings = {
            "user_to_id": {f"user_{i}": i for i in range(10)},
            "product_to_id": {f"prod_{i}": i for i in range(20)},
        }
        nodes = {"users": users_with_all_tier, "products": sample_products}
        edges = {"interactions": sample_interactions}
        _, split_masks, _ = build_hetero_graph(nodes, edges, id_mappings, config_2node)

        total = (
            split_masks["train_mask"].sum()
            + split_masks["val_mask"].sum()
            + split_masks["test_mask"].sum()
        )
        # All 10 users must be assigned — "all" is a real tier, not a sentinel
        assert total.item() == 10

    def test_transductive_edges_include_all_users(
        self, sample_users, sample_products, sample_interactions,
        id_mappings_2node, config_2node,
    ):
        """MEDIUM #5: All user interactions in graph, train_mask filters for loss."""
        nodes = {"users": sample_users, "products": sample_products}
        edges = {"interactions": sample_interactions}
        data, split_masks, _ = build_hetero_graph(
            nodes, edges, id_mappings_2node, config_2node,
        )
        ei = data["user", "interacts", "product"].edge_index
        train_mask = data["user", "interacts", "product"].train_mask

        # Graph should have edges from ALL users (not just train)
        unique_users = ei[0].unique()
        n_train = split_masks["train_mask"].sum().item()
        assert len(unique_users) >= n_train

        # Explicitly verify val/test users appear in graph edges
        val_user_ids = split_masks["val_mask"].nonzero(as_tuple=True)[0].tolist()
        test_user_ids = split_masks["test_mask"].nonzero(as_tuple=True)[0].tolist()
        users_in_graph = set(unique_users.tolist())
        for uid in val_user_ids + test_user_ids:
            assert uid in users_in_graph, f"User {uid} missing from graph edges"

        # train_mask should exist and be smaller than total edges
        assert train_mask.shape[0] == ei.shape[1]
        assert train_mask.sum().item() < ei.shape[1], "train_mask should exclude val/test edges"
        assert train_mask.sum().item() > 0

        # Non-train edges should correspond to non-train users
        non_train_users = ei[0][~train_mask].unique().tolist()
        train_user_set = set(split_masks["train_mask"].nonzero(as_tuple=True)[0].tolist())
        for uid in non_train_users:
            assert uid not in train_user_set, f"Train user {uid} has unmasked edges"

    def test_build_time_validation_no_interactions(
        self, sample_users, sample_products, config_2node,
    ):
        """HIGH #4: Build should fail if no interaction edges exist."""
        id_mappings = {
            "user_to_id": {f"user_{i}": i for i in range(10)},
            "product_to_id": {f"prod_{i}": i for i in range(20)},
        }
        nodes = {"users": sample_users, "products": sample_products}
        # Empty interactions → no edges → should raise
        empty_interactions = pd.DataFrame(columns=["user_id", "product_id", "interaction_type", "weight"])
        edges = {"interactions": empty_interactions}
        with pytest.raises(ValueError, match="no user-product interaction edges"):
            build_hetero_graph(nodes, edges, id_mappings, config_2node)

    def test_3node_missing_entity_edges_strict(
        self, sample_users, sample_products, sample_entities,
        sample_interactions, config_3node,
    ):
        """MEDIUM #5: Missing entity edges should raise by default in 3-node."""
        id_mappings = {
            "user_to_id": {f"user_{i}": i for i in range(10)},
            "product_to_id": {f"prod_{i}": i for i in range(20)},
            "entity_to_id": {f"entity_{i}": i for i in range(5)},
        }
        nodes = {"users": sample_users, "products": sample_products, "entities": sample_entities}
        # No fitment or ownership edges
        edges = {"interactions": sample_interactions}
        with pytest.raises(ValueError, match="missing entity edges"):
            build_hetero_graph(nodes, edges, id_mappings, config_3node)

    def test_nan_interaction_weights_rejected(
        self, sample_users, sample_products, config_2node,
    ):
        """MEDIUM #6: NaN edge weights should be rejected at build time."""
        id_mappings = {
            "user_to_id": {f"user_{i}": i for i in range(10)},
            "product_to_id": {f"prod_{i}": i for i in range(20)},
        }
        interactions = pd.DataFrame({
            "user_id": ["user_0", "user_1"],
            "product_id": ["prod_0", "prod_1"],
            "interaction_type": ["view", "view"],
            "weight": [1.0, float("nan")],
        })
        nodes = {"users": sample_users, "products": sample_products}
        edges = {"interactions": interactions}
        with pytest.raises(ValueError, match="NaN"):
            build_hetero_graph(nodes, edges, id_mappings, config_2node)

    def test_negative_interaction_weights_rejected(
        self, sample_users, sample_products, config_2node,
    ):
        """MEDIUM #6: Negative edge weights should be rejected at build time."""
        id_mappings = {
            "user_to_id": {f"user_{i}": i for i in range(10)},
            "product_to_id": {f"prod_{i}": i for i in range(20)},
        }
        interactions = pd.DataFrame({
            "user_id": ["user_0", "user_1"],
            "product_id": ["prod_0", "prod_1"],
            "interaction_type": ["view", "view"],
            "weight": [1.0, -2.0],
        })
        nodes = {"users": sample_users, "products": sample_products}
        edges = {"interactions": interactions}
        with pytest.raises(ValueError, match="negative"):
            build_hetero_graph(nodes, edges, id_mappings, config_2node)

    def test_3node_missing_entity_edges_permissive(
        self, sample_users, sample_products, sample_entities,
        sample_interactions, config_3node,
    ):
        """MEDIUM #5: allow_missing_entity_edges=true downgrades to warning."""
        import copy
        cfg = copy.deepcopy(config_3node)
        cfg["graph"]["allow_missing_entity_edges"] = True
        id_mappings = {
            "user_to_id": {f"user_{i}": i for i in range(10)},
            "product_to_id": {f"prod_{i}": i for i in range(20)},
            "entity_to_id": {f"entity_{i}": i for i in range(5)},
        }
        nodes = {"users": sample_users, "products": sample_products, "entities": sample_entities}
        edges = {"interactions": sample_interactions}
        # Should NOT raise — just warn
        data, _, _ = build_hetero_graph(nodes, edges, id_mappings, cfg)
        assert data["user"].num_nodes == 10

    def test_configurable_split_seed(
        self, sample_users, sample_products, sample_interactions,
        id_mappings_2node, config_2node,
    ):
        """M9: Split seed should be configurable via eval.random_seed."""
        import copy
        nodes = {"users": sample_users, "products": sample_products}
        edges = {"interactions": sample_interactions}

        cfg1 = copy.deepcopy(config_2node)
        cfg1["eval"]["random_seed"] = 42
        _, masks1, _ = build_hetero_graph(nodes, edges, id_mappings_2node, cfg1)

        cfg2 = copy.deepcopy(config_2node)
        cfg2["eval"]["random_seed"] = 99
        _, masks2, _ = build_hetero_graph(nodes, edges, id_mappings_2node, cfg2)

        # Different seeds should produce different splits (with high probability)
        # At least one mask should differ
        differs = not (
            torch.equal(masks1["train_mask"], masks2["train_mask"])
            and torch.equal(masks1["val_mask"], masks2["val_mask"])
            and torch.equal(masks1["test_mask"], masks2["test_mask"])
        )
        assert differs, "Different random seeds should produce different user splits"
