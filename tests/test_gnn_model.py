"""Tests for HolleyGAT model."""

import pytest

torch = pytest.importorskip("torch")
pytest.importorskip("torch_geometric")

from tests.test_gnn_graph_builder import (  # noqa: E402, F401
    gnn_config,
    sample_edges,
    sample_id_mappings,
    sample_nodes,
)


@pytest.fixture
def small_graph(sample_nodes, sample_edges, sample_id_mappings, gnn_config):  # noqa: F811
    from src.gnn.graph_builder import build_hetero_graph

    data, masks, meta = build_hetero_graph(
        sample_nodes, sample_edges, sample_id_mappings, gnn_config
    )
    return data, masks, meta


@pytest.fixture
def model(small_graph, gnn_config):  # noqa: F811
    from src.gnn.model import HolleyGAT

    data, _, meta = small_graph
    return HolleyGAT(
        n_users=data["user"].num_nodes,
        n_products=data["product"].num_nodes,
        n_vehicles=data["vehicle"].num_nodes,
        n_part_types=meta["n_part_types"],
        config=gnn_config,
    )


class TestHolleyGAT:
    def test_forward_output_shapes(self, model, small_graph):
        data, _, _ = small_graph
        user_embs, prod_embs = model(data)

        assert user_embs.shape == (10, 128)  # n_users x embedding_dim
        assert prod_embs.shape == (20, 128)  # n_products x embedding_dim

    def test_embeddings_are_normalized(self, model, small_graph):
        data, _, _ = small_graph
        user_embs, prod_embs = model(data)

        user_norms = torch.norm(user_embs, dim=1)
        prod_norms = torch.norm(prod_embs, dim=1)

        assert torch.allclose(user_norms, torch.ones_like(user_norms), atol=1e-5)
        assert torch.allclose(prod_norms, torch.ones_like(prod_norms), atol=1e-5)

    def test_score_shape(self, model, small_graph):
        data, _, _ = small_graph
        user_embs, prod_embs = model(data)

        scores = model.score(user_embs[:3], prod_embs)
        assert scores.shape == (3, 20)

    def test_bpr_loss_positive(self, model):
        pos_scores = torch.tensor([0.8, 0.7, 0.6])
        neg_scores = torch.tensor([0.2, 0.3, 0.1])
        loss = model.bpr_loss(pos_scores, neg_scores)

        assert loss.item() > 0

    def test_bpr_loss_decreases_with_wider_margin(self, model):
        pos = torch.tensor([0.9, 0.8])
        neg_close = torch.tensor([0.8, 0.7])
        neg_far = torch.tensor([0.1, 0.0])

        loss_close = model.bpr_loss(pos, neg_close)
        loss_far = model.bpr_loss(pos, neg_far)

        assert loss_far.item() < loss_close.item()

    def test_model_parameter_count(self, model):
        total = sum(p.numel() for p in model.parameters())
        assert total > 10_000

    def test_initial_embeddings(self, model, small_graph):
        data, _, _ = small_graph
        embs = model.get_initial_embeddings(data)

        assert "user" in embs
        assert "product" in embs
        assert "vehicle" in embs
        assert embs["user"].shape == (10, 128)
        assert embs["product"].shape == (20, 128)
        assert embs["vehicle"].shape == (3, 128)
