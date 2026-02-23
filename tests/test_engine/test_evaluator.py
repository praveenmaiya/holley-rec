"""Tests for rec_engine.core.evaluator — evaluation pipeline."""

import pandas as pd
import pytest

from plugins.defaults import DefaultPlugin
from rec_engine.core.evaluator import GNNEvaluator
from rec_engine.core.model import HeteroGAT
from rec_engine.topology import create_strategy


def _make_evaluator(data, split_masks, id_mappings, metadata, config):
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

    products_df = pd.DataFrame({
        "product_id": [f"prod_{i}" for i in range(20)],
        "category": [f"cat_{i % 5}" for i in range(20)],
        "is_excluded": [False] * 18 + [True] * 2,
    })
    nodes = {"products": products_df}

    test_df = pd.DataFrame({
        "user_id": ["user_8", "user_8", "user_9", "user_9"],
        "product_id": ["prod_0", "prod_1", "prod_2", "prod_3"],
    })

    baseline_df = pd.DataFrame({
        "user_id": ["user_8", "user_8", "user_9"],
        "product_id": ["prod_0", "prod_5", "prod_2"],
        "rank": [1, 2, 1],
    })

    user_tiers = {8: "cold", 9: "warm"}

    return GNNEvaluator(
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
        user_engagement_tiers=user_tiers,
    )


class TestGNNEvaluator:
    @pytest.fixture(params=["user-product", "user-entity-product"])
    def evaluator(self, request, small_graph_2node, small_graph_3node, config_2node, config_3node):
        if request.param == "user-product":
            data, masks, mappings, meta = small_graph_2node
            return _make_evaluator(data, masks, mappings, meta, config_2node)
        data, masks, mappings, meta = small_graph_3node
        return _make_evaluator(data, masks, mappings, meta, config_3node)

    def test_evaluate_returns_dict(self, evaluator):
        results = evaluator.evaluate()
        assert "gnn_pre_rules" in results
        assert "gnn_post_rules" in results
        assert "baseline" in results
        assert "go_no_go" in results
        assert "n_evaluable" in results

    def test_metrics_keys(self, evaluator):
        results = evaluator.evaluate()
        pre = results["gnn_pre_rules"]
        assert "hit_rate_at_4" in pre
        assert "n_users" in pre

    def test_go_no_go_has_decision(self, evaluator):
        results = evaluator.evaluate()
        gng = results["go_no_go"]
        assert "decision" in gng
        assert gng["decision"] in ("GO", "MAYBE", "SKIP", "INVESTIGATE")
        assert "delta" in gng

    def test_bootstrap_ci_structure(self, evaluator):
        results = evaluator.evaluate()
        ci = results.get("gnn_pre_rules_ci", {})
        for key, val in ci.items():
            assert isinstance(val, tuple)
            assert len(val) == 2
            assert val[0] <= val[1]

    def test_stratified_has_tiers(self, evaluator):
        results = evaluator.evaluate()
        by_tier = results["by_tier"]
        # Tiers are discovered dynamically from user_engagement_tiers data
        # Test fixture provides {8: "cold", 9: "warm"}
        assert "cold" in by_tier
        assert "warm" in by_tier
        assert len(by_tier) >= 2

    def test_generate_report(self, evaluator):
        report = evaluator.generate_report()
        assert "go_no_go" in report

    def test_go_no_go_uses_config_thresholds(
        self, small_graph_2node, config_2node,
    ):
        """H3: Go/no-go should use configured thresholds, not hardcoded."""
        # Set very low thresholds so any non-negative delta → GO
        config_2node["eval"]["go_no_go"] = {
            "go_delta": 0.0001,
            "maybe_delta": 0.00001,
            "investigate_delta": -1.0,
            "metric": "hit_rate_at_4",
        }
        data, masks, mappings, meta = small_graph_2node
        evaluator = _make_evaluator(data, masks, mappings, meta, config_2node)
        results = evaluator.evaluate()
        gng = results["go_no_go"]
        assert "thresholds" in gng
        # Config thresholds should be persisted
        assert gng["thresholds"]["go_delta"] == 0.0001

    def test_go_no_go_decision_boundaries(self, small_graph_2node, config_2node):
        """H3 regression: Verify all 4 decision categories map correctly."""
        data, masks, mappings, meta = small_graph_2node
        evaluator = _make_evaluator(data, masks, mappings, meta, config_2node)

        # Test all 4 decision boundaries via _go_no_go directly
        thresholds = {"go_delta": 0.10, "maybe_delta": 0.05, "investigate_delta": -0.02, "metric": "hit_rate_at_4"}
        evaluator.config["eval"]["go_no_go"] = thresholds
        evaluator.plugin = DefaultPlugin(salt="test")  # ensure None thresholds (uses config)

        # GO: delta >= go_delta
        result = evaluator._go_no_go({"hit_rate_at_4": 0.50}, {"hit_rate_at_4": 0.30})
        assert result["decision"] == "GO"

        # MAYBE: maybe_delta <= delta < go_delta
        # Use 0.36 to avoid fp boundary: 0.35 - 0.30 = 0.049999... < 0.05
        result = evaluator._go_no_go({"hit_rate_at_4": 0.36}, {"hit_rate_at_4": 0.30})
        assert result["decision"] == "MAYBE"

        # SKIP: investigate_delta <= delta < maybe_delta
        result = evaluator._go_no_go({"hit_rate_at_4": 0.30}, {"hit_rate_at_4": 0.30})
        assert result["decision"] == "SKIP"

        # INVESTIGATE: delta < investigate_delta
        result = evaluator._go_no_go({"hit_rate_at_4": 0.20}, {"hit_rate_at_4": 0.30})
        assert result["decision"] == "INVESTIGATE"

    def test_min_evaluable_users_fail_fast(self, small_graph_2node, config_2node):
        """H5: Evaluator should fail fast when evaluable users below minimum."""
        config_2node["eval"]["min_evaluable_users"] = 9999
        data, masks, mappings, meta = small_graph_2node
        evaluator = _make_evaluator(data, masks, mappings, meta, config_2node)
        with pytest.raises(ValueError, match="evaluable users"):
            evaluator.evaluate()

    def test_ndcg_at_all_k_values(self, evaluator):
        """M9: NDCG should be computed for all configured k_values, not hardcoded."""
        results = evaluator.evaluate()
        pre = results["gnn_pre_rules"]
        k_values = evaluator.config["eval"]["k_values"]
        for k in k_values:
            assert f"ndcg_at_{k}" in pre

    def test_excluded_set_from_graph_tensor(self, small_graph_2node, config_2node):
        """H4: Evaluator excluded set should come from graph tensor, not DataFrame."""
        data, masks, mappings, meta = small_graph_2node
        evaluator = _make_evaluator(data, masks, mappings, meta, config_2node)
        # Graph has products 18,19 excluded
        assert 18 in evaluator.excluded_product_ids
        assert 19 in evaluator.excluded_product_ids
        assert 0 not in evaluator.excluded_product_ids
