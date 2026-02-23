"""Tests for rec_engine.core.trainer — training loop."""

import pytest
import torch

from plugins.defaults import DefaultPlugin
from rec_engine.core.model import HeteroGAT
from rec_engine.core.trainer import GNNTrainer
from rec_engine.topology import create_strategy


def _make_trainer(data, split_masks, id_mappings, metadata, config, topology):
    strategy = create_strategy(config)
    plugin = DefaultPlugin(salt="test")

    entity_type_name = config.get("entity", {}).get("type_name", "entity")
    n_entities = len(id_mappings.get("entity_to_id", {}))
    edge_types = strategy.get_edge_types(config)

    model = HeteroGAT(
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

    test_interactions = {8: {0, 1}, 9: {2, 3}}

    return GNNTrainer(
        model=model,
        data=data,
        split_masks=split_masks,
        test_interactions=test_interactions,
        config=config,
        strategy=strategy,
        plugin=plugin,
    )


class TestGNNTrainer:
    @pytest.fixture(params=["user-product", "user-entity-product"])
    def trainer(self, request, small_graph_2node, small_graph_3node, config_2node, config_3node):
        if request.param == "user-product":
            data, masks, mappings, meta = small_graph_2node
            return _make_trainer(data, masks, mappings, meta, config_2node, request.param)
        data, masks, mappings, meta = small_graph_3node
        return _make_trainer(data, masks, mappings, meta, config_3node, request.param)

    def test_initialization(self, trainer):
        assert trainer.model is not None
        assert len(trainer.pos_users) > 0

    def test_train_epoch_returns_loss(self, trainer):
        loss = trainer.train_epoch()
        assert isinstance(loss, float)
        assert loss > 0

    def test_validate_returns_metrics(self, trainer):
        metrics = trainer.validate("val")
        assert "hit_rate_at_4" in metrics
        assert "n_evaluated" in metrics

    def test_train_with_early_stopping(self, trainer):
        result = trainer.train()
        assert "best_epoch" in result
        assert "best_val_hit_rate_at_4" in result
        assert "total_epochs" in result
        assert result["total_epochs"] <= trainer.max_epochs

    def test_save_checkpoint(self, trainer, tmp_path):
        path = str(tmp_path / "checkpoint.pt")
        saved = trainer.save_checkpoint(path, id_mappings={"test": "mapping"})
        assert saved == path
        checkpoint = torch.load(path, weights_only=False)
        assert "model_state_dict" in checkpoint
        assert "config" in checkpoint
        assert "id_mappings" in checkpoint

    def test_negative_mix_validation(self, small_graph_2node, config_2node):
        data, masks, mappings, meta = small_graph_2node
        bad_config = dict(config_2node)
        bad_config["training"] = dict(bad_config["training"])
        bad_config["training"]["negative_mix"] = {"in_batch": 0.5, "random": 0.3}  # sums to 0.8
        with pytest.raises(ValueError, match="sum to 1.0"):
            _make_trainer(data, masks, mappings, meta, bad_config, "user-product")

    def test_excluded_products_filtered(self, trainer):
        # Products 18, 19 are excluded — should not be in test interactions
        for uid, prods in trainer.test_interactions.items():
            for pid in prods:
                assert pid not in trainer.excluded_product_ids

    def test_min_training_edges_fail_fast(self, small_graph_2node, config_2node):
        """H5: Fail fast when training edges below minimum threshold."""
        data, masks, mappings, meta = small_graph_2node
        cfg = dict(config_2node)
        cfg["training"] = dict(cfg["training"])
        cfg["training"]["min_training_edges"] = 9999  # Way more than available
        with pytest.raises(ValueError, match="training edges"):
            _make_trainer(data, masks, mappings, meta, cfg, "user-product")
