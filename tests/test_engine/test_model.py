"""Tests for rec_engine.core.model — HeteroGAT model."""

import pytest
import torch

from rec_engine.core.model import HeteroGAT


class TestHeteroGAT:
    @pytest.fixture(params=["2node", "3node"])
    def model_and_data(self, request, small_graph_2node, small_graph_3node):
        if request.param == "2node":
            data, _, _, metadata = small_graph_2node
            edge_types = [
                ("user", "interacts", "product"),
                ("product", "rev_interacts", "user"),
                ("product", "co_purchased", "product"),
            ]
            model = HeteroGAT(
                n_users=10, n_products=20, n_entities=0,
                n_categories=metadata["n_categories"],
                edge_types=edge_types,
                config={"model": {"embedding_dim": 16, "hidden_dim": 16, "num_heads": 2, "dropout": 0.0}},
                product_num_features=metadata["product_num_features"],
            )
        else:
            data, _, _, metadata = small_graph_3node
            edge_types = [
                ("user", "interacts", "product"),
                ("product", "rev_interacts", "user"),
                ("product", "fits", "vehicle"),
                ("vehicle", "rev_fits", "product"),
                ("user", "owns", "vehicle"),
                ("vehicle", "rev_owns", "user"),
                ("product", "co_purchased", "product"),
            ]
            model = HeteroGAT(
                n_users=10, n_products=20, n_entities=5,
                n_categories=metadata["n_categories"],
                edge_types=edge_types,
                config={"model": {"embedding_dim": 16, "hidden_dim": 16, "num_heads": 2, "dropout": 0.0}},
                entity_type_name="vehicle",
                product_num_features=metadata["product_num_features"],
                entity_num_features=metadata["entity_num_features"],
            )
        return model, data

    def test_forward_output_shapes(self, model_and_data):
        model, data = model_and_data
        user_embs, product_embs = model(data)
        assert user_embs.shape == (10, 16)
        assert product_embs.shape == (20, 16)

    def test_embeddings_are_normalized(self, model_and_data):
        model, data = model_and_data
        user_embs, product_embs = model(data)
        user_norms = torch.norm(user_embs, dim=1)
        product_norms = torch.norm(product_embs, dim=1)
        torch.testing.assert_close(user_norms, torch.ones(10), atol=1e-5, rtol=1e-5)
        torch.testing.assert_close(product_norms, torch.ones(20), atol=1e-5, rtol=1e-5)

    def test_score_shape(self, model_and_data):
        model, data = model_and_data
        user_embs, product_embs = model(data)
        scores = HeteroGAT.score(user_embs[:3], product_embs)
        assert scores.shape == (3, 20)

    def test_bpr_loss_positive(self):
        pos = torch.randn(100)
        neg = torch.randn(100)
        loss = HeteroGAT.bpr_loss(pos, neg)
        assert loss.item() > 0

    def test_bpr_loss_decreases_with_margin(self):
        pos = torch.ones(100) * 2.0
        neg_close = torch.ones(100) * 1.5
        neg_far = torch.ones(100) * 0.0
        loss_close = HeteroGAT.bpr_loss(pos, neg_close)
        loss_far = HeteroGAT.bpr_loss(pos, neg_far)
        assert loss_close > loss_far

    def test_parameter_count(self, model_and_data):
        model, _ = model_and_data
        n_params = sum(p.numel() for p in model.parameters())
        assert n_params > 1000

    def test_initial_embeddings(self, model_and_data):
        model, data = model_and_data
        x_dict = model.get_initial_embeddings(data)
        assert "user" in x_dict
        assert "product" in x_dict
        assert x_dict["user"].shape == (10, 16)
        assert x_dict["product"].shape == (20, 16)

    def test_hidden_dim_not_divisible_by_num_heads(self):
        """M10: hidden_dim must be divisible by num_heads."""
        with pytest.raises(ValueError, match="must be divisible"):
            HeteroGAT(
                n_users=10, n_products=20, n_entities=0,
                n_categories=5,
                edge_types=[("user", "interacts", "product")],
                config={"model": {
                    "embedding_dim": 16, "hidden_dim": 17,
                    "num_heads": 2, "dropout": 0.0,
                }},
            )

    def test_skip_connections_preserve_isolated_nodes(self, small_graph_2node):
        """CRITICAL #1: Nodes with no incoming edges must retain embeddings."""
        from torch_geometric.data import HeteroData

        data, _, _, metadata = small_graph_2node
        # Create a graph where user 9 has NO edges at all
        sparse_data = HeteroData()
        sparse_data["user"].num_nodes = 10
        sparse_data["product"].num_nodes = 20
        sparse_data["product"].category_id = data["product"].category_id
        sparse_data["product"].x_num = data["product"].x_num
        # Only one edge: user_0 -> product_0
        sparse_data["user", "interacts", "product"].edge_index = torch.tensor([[0], [0]])
        sparse_data["product", "rev_interacts", "user"].edge_index = torch.tensor([[0], [0]])

        edge_types = [
            ("user", "interacts", "product"),
            ("product", "rev_interacts", "user"),
        ]
        model = HeteroGAT(
            n_users=10, n_products=20, n_entities=0,
            n_categories=metadata["n_categories"],
            edge_types=edge_types,
            config={"model": {"embedding_dim": 16, "hidden_dim": 16, "num_heads": 2, "dropout": 0.0}},
            product_num_features=metadata["product_num_features"],
        )
        model.eval()
        user_embs, product_embs = model(sparse_data)

        # User 9 has no edges but should still have non-zero embedding (via skip)
        assert user_embs[9].norm().item() > 0
        # All users should have valid normalized embeddings
        norms = torch.norm(user_embs, dim=1)
        torch.testing.assert_close(norms, torch.ones(10), atol=1e-5, rtol=1e-5)

        # User 0 (has edge) should differ from user 9 (no edges) — skip provides
        # the baseline, but conv output for user 0 adds information
        assert not torch.allclose(user_embs[0], user_embs[9], atol=1e-4)

    def test_skip_connections_exist(self, model_and_data):
        """Verify skip connection modules are present."""
        model, _ = model_and_data
        assert hasattr(model, "skip1")
        assert hasattr(model, "skip2")
        assert "user" in model.skip1
        assert "product" in model.skip1

    def test_gated_fusion_product(self, model_and_data):
        """MEDIUM #6: Product fusion uses learned gate, not additive."""
        model, data = model_and_data
        assert hasattr(model, "product_gate")
        x_dict = model.get_initial_embeddings(data)
        # Product embeddings should differ from pure embedding weight
        pure_emb = model.product_embedding.weight
        assert not torch.allclose(x_dict["product"], pure_emb)

    def test_entity_feature_fusion_3node(self, small_graph_3node):
        """HIGH #3: Entity features from data should be used in embeddings."""
        data, _, _, metadata = small_graph_3node
        edge_types = [
            ("user", "interacts", "product"),
            ("product", "rev_interacts", "user"),
            ("product", "fits", "vehicle"),
            ("vehicle", "rev_fits", "product"),
            ("user", "owns", "vehicle"),
            ("vehicle", "rev_owns", "user"),
            ("product", "co_purchased", "product"),
        ]
        model = HeteroGAT(
            n_users=10, n_products=20, n_entities=5,
            n_categories=metadata["n_categories"],
            edge_types=edge_types,
            config={"model": {"embedding_dim": 16, "hidden_dim": 16, "num_heads": 2, "dropout": 0.0}},
            entity_type_name="vehicle",
            product_num_features=metadata["product_num_features"],
            entity_num_features=metadata["entity_num_features"],
        )
        assert model.has_entity_features
        assert hasattr(model, "entity_feature_mlp")
        assert hasattr(model, "entity_gate")

        x_dict = model.get_initial_embeddings(data)
        # Entity embedding should differ from pure embedding (features fused)
        pure_emb = model.entity_embedding.weight
        assert not torch.allclose(x_dict["vehicle"], pure_emb)

    def test_entity_without_features_uses_embedding_only(self, small_graph_3node):
        """Entity with entity_num_features=0 should use embedding only."""
        data, _, _, metadata = small_graph_3node
        edge_types = [
            ("user", "interacts", "product"),
            ("product", "rev_interacts", "user"),
            ("product", "fits", "vehicle"),
            ("vehicle", "rev_fits", "product"),
            ("user", "owns", "vehicle"),
            ("vehicle", "rev_owns", "user"),
            ("product", "co_purchased", "product"),
        ]
        model = HeteroGAT(
            n_users=10, n_products=20, n_entities=5,
            n_categories=metadata["n_categories"],
            edge_types=edge_types,
            config={"model": {"embedding_dim": 16, "hidden_dim": 16, "num_heads": 2, "dropout": 0.0}},
            entity_type_name="vehicle",
            product_num_features=metadata["product_num_features"],
            entity_num_features=0,
        )
        assert not model.has_entity_features
        x_dict = model.get_initial_embeddings(data)
        # Without entity features, should be pure embedding
        torch.testing.assert_close(x_dict["vehicle"], model.entity_embedding.weight)

    def test_edge_weights_used_in_forward(self, model_and_data):
        """HIGH #2: Edge weights should influence message passing via GATConv edge_dim."""
        model, data = model_and_data
        model.eval()

        # Save original weights and forward
        originals = {}
        try:
            with torch.no_grad():
                for edge_type in data.edge_types:
                    if hasattr(data[edge_type], "edge_weight"):
                        originals[edge_type] = data[edge_type].edge_weight.clone()
                user_embs_1, product_embs_1 = model(data)

            # HETEROGENEOUS weight perturbation: alternate 0.1 and 10.0
            # Uniform scaling doesn't change softmax attention distribution,
            # but varying weights across edges does.
            with torch.no_grad():
                for edge_type in data.edge_types:
                    if hasattr(data[edge_type], "edge_weight"):
                        w = data[edge_type].edge_weight
                        mask = torch.arange(len(w)) % 2 == 0
                        new_w = torch.where(mask, w * 10.0, w * 0.1)
                        data[edge_type].edge_weight = new_w
                user_embs_2, product_embs_2 = model(data)

            # Both user and product embeddings should differ
            assert not torch.allclose(user_embs_1, user_embs_2, atol=1e-4)
            assert not torch.allclose(product_embs_1, product_embs_2, atol=1e-4)
        finally:
            # Restore original weights even if assertions fail
            for edge_type, w in originals.items():
                data[edge_type].edge_weight = w

    def test_forward_without_edge_weights(self, small_graph_2node):
        """Forward should work gracefully when no edge_weight attributes exist."""
        from torch_geometric.data import HeteroData

        data, _, _, metadata = small_graph_2node
        # Build graph without edge_weight
        no_weight_data = HeteroData()
        no_weight_data["user"].num_nodes = 10
        no_weight_data["product"].num_nodes = 20
        no_weight_data["product"].category_id = data["product"].category_id
        no_weight_data["product"].x_num = data["product"].x_num
        no_weight_data["user", "interacts", "product"].edge_index = (
            data["user", "interacts", "product"].edge_index
        )
        no_weight_data["product", "rev_interacts", "user"].edge_index = (
            data["product", "rev_interacts", "user"].edge_index
        )

        edge_types = [
            ("user", "interacts", "product"),
            ("product", "rev_interacts", "user"),
        ]
        model = HeteroGAT(
            n_users=10, n_products=20, n_entities=0,
            n_categories=metadata["n_categories"],
            edge_types=edge_types,
            config={"model": {"embedding_dim": 16, "hidden_dim": 16, "num_heads": 2, "dropout": 0.0}},
            product_num_features=metadata["product_num_features"],
        )
        # Should not raise — edge_attr_dict is simply empty
        user_embs, product_embs = model(no_weight_data)
        assert user_embs.shape == (10, 16)
        assert product_embs.shape == (20, 16)

    def test_weighted_bpr_loss(self):
        """HIGH #2: Weighted BPR uses normalized weighted mean."""
        pos = torch.ones(100)
        neg = torch.zeros(100)

        # Uniform weights = standard BPR
        loss_unweighted = HeteroGAT.bpr_loss(pos, neg)
        loss_weighted_1 = HeteroGAT.bpr_loss(pos, neg, weights=torch.ones(100))
        torch.testing.assert_close(loss_unweighted, loss_weighted_1, atol=1e-6, rtol=1e-6)

        # Scale invariance: global scaling should NOT change the loss
        loss_weighted_5 = HeteroGAT.bpr_loss(pos, neg, weights=torch.ones(100) * 5.0)
        torch.testing.assert_close(loss_weighted_1, loss_weighted_5, atol=1e-6, rtol=1e-6)

        # Relative weights matter: upweight first half, downweight second
        mixed_weights = torch.cat([torch.ones(50) * 3.0, torch.ones(50) * 1.0])
        loss_mixed = HeteroGAT.bpr_loss(pos, neg, weights=mixed_weights)
        # Mixed weights with uniform scores should still equal uniform (since all pairs identical)
        torch.testing.assert_close(loss_unweighted, loss_mixed, atol=1e-6, rtol=1e-6)

    def test_weighted_bpr_relative_importance(self):
        """Relative weights should shift loss toward higher-weighted pairs."""
        # Different scores for two halves
        pos = torch.cat([torch.ones(50) * 2.0, torch.ones(50) * 0.5])
        neg = torch.zeros(100)

        # Upweight the "easy" half (high margin) → lower loss
        weights_easy = torch.cat([torch.ones(50) * 10.0, torch.ones(50) * 1.0])
        loss_easy = HeteroGAT.bpr_loss(pos, neg, weights=weights_easy)

        # Upweight the "hard" half (low margin) → higher loss
        weights_hard = torch.cat([torch.ones(50) * 1.0, torch.ones(50) * 10.0])
        loss_hard = HeteroGAT.bpr_loss(pos, neg, weights=weights_hard)

        assert loss_hard > loss_easy
