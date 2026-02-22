"""Tests for GNN trainer."""

import math

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
def training_setup(sample_nodes, sample_edges, sample_id_mappings, gnn_config, mocker):  # noqa: F811
    from src.gnn.graph_builder import build_hetero_graph
    from src.gnn.model import HolleyGAT

    # Add training config
    gnn_config["training"] = {
        "lr_embedding": 0.001,
        "lr_gnn": 0.01,
        "weight_decay": 0.01,
        "max_epochs": 5,
        "patience": 3,
        "grad_clip": 1.0,
        "negative_mix": {"in_batch": 0.5, "fitment_hard": 0.3, "random": 0.2},
    }
    gnn_config["eval"]["k_values"] = [4]
    gnn_config["eval"]["bootstrap_samples"] = 10

    data, masks, meta = build_hetero_graph(
        sample_nodes, sample_edges, sample_id_mappings, gnn_config
    )

    model = HolleyGAT(
        n_users=data["user"].num_nodes,
        n_products=data["product"].num_nodes,
        n_vehicles=data["vehicle"].num_nodes,
        n_part_types=meta["n_part_types"],
        config=gnn_config,
    )

    # Mock test interactions: some users interacted with some products
    test_interactions = {0: {2, 3}, 1: {5}, 7: {10}}

    # Mock W&B
    mocker.patch("src.gnn.trainer.log_metrics")

    return model, data, masks, test_interactions, gnn_config


class TestGNNTrainer:
    def test_train_epoch_returns_loss(self, training_setup):
        from src.gnn.trainer import GNNTrainer

        model, data, masks, test_interactions, config = training_setup
        trainer = GNNTrainer(
            model=model, data=data, split_masks=masks,
            test_interactions=test_interactions, config=config,
            device=torch.device("cpu"),
        )

        loss = trainer.train_epoch()
        assert isinstance(loss, float)
        assert loss > 0
        assert math.isfinite(loss)

    def test_loss_decreases_over_epochs(self, training_setup):
        from src.gnn.trainer import GNNTrainer

        model, data, masks, test_interactions, config = training_setup
        trainer = GNNTrainer(
            model=model, data=data, split_masks=masks,
            test_interactions=test_interactions, config=config,
            device=torch.device("cpu"),
        )

        losses = [trainer.train_epoch() for _ in range(5)]
        # Loss should generally decrease (allow some noise)
        assert losses[-1] < losses[0]

    def test_validate_returns_metrics(self, training_setup):
        from src.gnn.trainer import GNNTrainer

        model, data, masks, test_interactions, config = training_setup
        trainer = GNNTrainer(
            model=model, data=data, split_masks=masks,
            test_interactions=test_interactions, config=config,
            device=torch.device("cpu"),
        )

        metrics = trainer.validate("val")
        assert "hit_rate_at_4" in metrics
        assert "n_evaluated" in metrics

    def test_eval_candidates_fitment_only_no_universals(self, training_setup):
        """v5.18: eval candidates are fitment-only (no universals)."""
        from src.gnn.trainer import GNNTrainer

        model, data, masks, test_interactions, config = training_setup
        trainer = GNNTrainer(
            model=model, data=data, split_masks=masks,
            test_interactions=test_interactions, config=config,
            device=torch.device("cpu"),
        )

        candidates = trainer._get_eval_candidates(0)
        assert 15 not in candidates  # universal product excluded
        assert 1 in candidates  # fitment product for FORD|MUSTANG users

    def test_eval_candidates_fallback_excludes_universals(self, training_setup):
        """Fallback to all products also excludes universals."""
        from src.gnn.trainer import GNNTrainer

        model, data, masks, test_interactions, config = training_setup
        trainer = GNNTrainer(
            model=model, data=data, split_masks=masks,
            test_interactions=test_interactions, config=config,
            device=torch.device("cpu"),
        )

        # user8 belongs to DODGE|CHARGER, which has no fitment edges in sample fixture
        candidates = trainer._get_eval_candidates(8)
        # All products minus universals
        n_universal = len(trainer.universal_product_ids)
        assert len(candidates) == data["product"].num_nodes - n_universal
        for pid in candidates:
            assert pid not in trainer.universal_product_ids

    def test_test_interactions_filtered_for_universals(self, training_setup):
        """C3: universal products removed from test_interactions during init."""
        from src.gnn.trainer import GNNTrainer

        model, data, masks, test_interactions, config = training_setup
        # Add a universal product (P015 = id 15) to test interactions
        test_interactions_with_universal = {
            0: {2, 3, 15},  # 15 is universal
            1: {5},
            7: {10},
        }
        trainer = GNNTrainer(
            model=model, data=data, split_masks=masks,
            test_interactions=test_interactions_with_universal, config=config,
            device=torch.device("cpu"),
        )

        # Universal product 15 should be filtered out
        if 0 in trainer.test_interactions:
            assert 15 not in trainer.test_interactions[0]

    def test_full_training_loop(self, training_setup):
        from src.gnn.trainer import GNNTrainer

        model, data, masks, test_interactions, config = training_setup
        trainer = GNNTrainer(
            model=model, data=data, split_masks=masks,
            test_interactions=test_interactions, config=config,
            device=torch.device("cpu"),
        )

        results = trainer.train()
        assert "best_epoch" in results
        assert "best_val_hit_rate_at_4" in results
        assert "total_epochs" in results
        assert results["total_epochs"] <= 5

    def test_save_checkpoint(self, training_setup, tmp_path):
        from src.gnn.trainer import GNNTrainer

        model, data, masks, test_interactions, config = training_setup
        trainer = GNNTrainer(
            model=model, data=data, split_masks=masks,
            test_interactions=test_interactions, config=config,
            device=torch.device("cpu"),
        )

        path = str(tmp_path / "model.pt")
        trainer.save_checkpoint(path)

        checkpoint = torch.load(path, weights_only=False)
        assert "model_state_dict" in checkpoint
        assert "config" in checkpoint

    def test_rejects_invalid_negative_mix(self, training_setup):
        from src.gnn.trainer import GNNTrainer

        model, data, masks, test_interactions, config = training_setup
        bad_config = {
            **config,
            "training": {
                **config["training"],
                "negative_mix": {"in_batch": 0.7, "fitment_hard": 0.3, "random": 0.3},
            },
        }

        with pytest.raises(ValueError, match="must sum to 1.0"):
            GNNTrainer(
                model=model, data=data, split_masks=masks,
                test_interactions=test_interactions, config=bad_config,
                device=torch.device("cpu"),
            )

    def test_save_checkpoint_persists_id_mappings(self, training_setup, tmp_path):
        from src.gnn.trainer import GNNTrainer

        model, data, masks, test_interactions, config = training_setup
        trainer = GNNTrainer(
            model=model, data=data, split_masks=masks,
            test_interactions=test_interactions, config=config,
            device=torch.device("cpu"),
        )

        id_mappings = {
            "user_to_id": {"u@test.com": 0},
            "product_to_id": {"P001": 0},
            "vehicle_to_id": {"FORD|MUSTANG": 0},
        }

        path = str(tmp_path / "model_with_ids.pt")
        trainer.save_checkpoint(path, id_mappings=id_mappings)

        checkpoint = torch.load(path, weights_only=False)
        assert checkpoint["id_mappings"] == id_mappings

    def test_sample_negatives_respects_mix_segments(self, training_setup, mocker):
        from src.gnn.trainer import GNNTrainer

        model, data, masks, test_interactions, config = training_setup
        trainer = GNNTrainer(
            model=model, data=data, split_masks=masks,
            test_interactions=test_interactions, config=config,
            device=torch.device("cpu"),
        )

        user_ids = torch.arange(10, dtype=torch.long, device=trainer.device)
        pos_product_ids = torch.arange(10, dtype=torch.long, device=trainer.device)
        trainer.user_fitment_products = {uid: [17, 18] for uid in range(10)}

        def fake_randint(high, size, device=None):
            if tuple(size) == (1,):
                return torch.tensor([0], dtype=torch.long, device=device)
            if tuple(size) == (2,):
                return torch.tensor([19, 18], dtype=torch.long, device=device)
            raise AssertionError(f"unexpected randint shape: {size}")

        mocker.patch(
            "src.gnn.trainer.torch.randperm",
            return_value=torch.arange(10, dtype=torch.long, device=trainer.device),
        )
        mocker.patch("src.gnn.trainer.torch.randint", side_effect=fake_randint)

        neg = trainer._sample_negatives(user_ids, pos_product_ids).cpu().tolist()

        # First 50% from in-batch shuffled positives.
        assert neg[:5] == [0, 1, 2, 3, 4]
        # Next 30% from fitment-hard pool.
        assert neg[5:8] == [17, 17, 17]
        # Final 20% from random branch.
        assert neg[8:] == [19, 18]
