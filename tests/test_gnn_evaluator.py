"""Tests for GNN evaluator."""

import pandas as pd
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
def eval_setup(sample_nodes, sample_edges, sample_id_mappings, gnn_config):  # noqa: F811
    from src.gnn.graph_builder import build_hetero_graph
    from src.gnn.model import HolleyGAT

    gnn_config["training"] = {
        "lr_embedding": 0.001, "lr_gnn": 0.01, "weight_decay": 0.01,
        "max_epochs": 3, "patience": 2, "grad_clip": 1.0,
        "negative_mix": {"in_batch": 0.5, "fitment_hard": 0.3, "random": 0.2},
    }
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

    # Create test DataFrame
    test_df = pd.DataFrame({
        "email_lower": ["user0@test.com", "user1@test.com", "user7@test.com"],
        "base_sku": ["P003", "P005", "P010"],
        "interaction_type": ["view", "cart", "order"],
    })

    # SQL baseline
    sql_baseline_df = pd.DataFrame({
        "email_lower": ["user0@test.com", "user0@test.com", "user1@test.com", "user1@test.com"],
        "sku": ["P001", "P002", "P001", "P005"],
        "rank": [1, 2, 1, 2],
    })

    return model, data, masks, sample_id_mappings, sample_nodes, test_df, sql_baseline_df, gnn_config


class TestGNNEvaluator:
    def test_evaluate_returns_complete_report(self, eval_setup):
        from src.gnn.evaluator import GNNEvaluator

        model, data, masks, id_map, nodes, test_df, sql_df, config = eval_setup

        evaluator = GNNEvaluator(
            model=model, data=data, split_masks=masks,
            id_mappings=id_map, nodes=nodes, test_df=test_df,
            sql_baseline_df=sql_df, config=config,
        )

        report = evaluator.evaluate()

        assert "gnn_pre_rules" in report
        assert "gnn_post_rules" in report
        assert "sql_baseline" in report
        assert "go_no_go" in report
        assert "n_evaluable" in report

    def test_go_no_go_thresholds(self, eval_setup):
        from src.gnn.evaluator import GNNEvaluator

        model, data, masks, id_map, nodes, test_df, sql_df, config = eval_setup

        evaluator = GNNEvaluator(
            model=model, data=data, split_masks=masks,
            id_mappings=id_map, nodes=nodes, test_df=test_df,
            sql_baseline_df=sql_df, config=config,
        )

        # Test different delta scenarios
        # GO: delta >= +3%
        result = evaluator._go_no_go(
            {"hit_rate_at_4": 0.10}, {"hit_rate_at_4": 0.05}
        )
        assert result["decision"] == "GO"

        # MAYBE: +1% to +3%
        result = evaluator._go_no_go(
            {"hit_rate_at_4": 0.06}, {"hit_rate_at_4": 0.04}
        )
        assert result["decision"] == "MAYBE"

        # SKIP: -1% to +1%
        result = evaluator._go_no_go(
            {"hit_rate_at_4": 0.049}, {"hit_rate_at_4": 0.04}
        )
        assert result["decision"] == "SKIP"

        # INVESTIGATE: < -1%
        result = evaluator._go_no_go(
            {"hit_rate_at_4": 0.02}, {"hit_rate_at_4": 0.05}
        )
        assert result["decision"] == "INVESTIGATE"

    def test_business_rules_produce_max_4(self, eval_setup):
        from src.gnn.evaluator import GNNEvaluator

        model, data, masks, id_map, nodes, test_df, sql_df, config = eval_setup

        evaluator = GNNEvaluator(
            model=model, data=data, split_masks=masks,
            id_mappings=id_map, nodes=nodes, test_df=test_df,
            sql_baseline_df=sql_df, config=config,
        )

        ranked = list(range(20))
        result = evaluator._apply_business_rules(0, ranked)

        assert len(result) <= 4

    def test_business_rules_fitment_only_no_universals(self, eval_setup):
        """v5.18: all 4 slots filled from fitment, no universal products selected."""
        from src.gnn.evaluator import GNNEvaluator

        model, data, masks, id_map, nodes, test_df, sql_df, config = eval_setup

        evaluator = GNNEvaluator(
            model=model, data=data, split_masks=masks,
            id_mappings=id_map, nodes=nodes, test_df=test_df,
            sql_baseline_df=sql_df, config=config,
        )

        # Pass fitment-only candidates (0-9 are fitment in sample fixture)
        ranked = [0, 1, 2, 3, 5, 6, 7, 8]
        result = evaluator._apply_business_rules(0, ranked)

        assert len(result) <= 4
        assert len(result) > 0
        # All selected products should NOT be universal
        for pid in result:
            assert pid not in evaluator.universal_product_ids

    def test_bootstrap_ci_returns_tuples(self, eval_setup):
        from src.gnn.evaluator import GNNEvaluator

        model, data, masks, id_map, nodes, test_df, sql_df, config = eval_setup

        evaluator = GNNEvaluator(
            model=model, data=data, split_masks=masks,
            id_mappings=id_map, nodes=nodes, test_df=test_df,
            sql_baseline_df=sql_df, config=config,
        )

        preds = {0: [3, 5, 10, 15]}
        cis = evaluator._bootstrap_ci(preds, [4], n_samples=10)

        if cis:
            for _, (lo, hi) in cis.items():
                assert lo <= hi

    def test_init_raises_on_missing_test_df_columns(self, eval_setup):
        from src.gnn.evaluator import GNNEvaluator

        model, data, masks, id_map, nodes, _, sql_df, config = eval_setup
        bad_test_df = pd.DataFrame({"email_lower": ["user0@test.com"]})

        with pytest.raises(ValueError, match="test_df missing required columns"):
            GNNEvaluator(
                model=model, data=data, split_masks=masks,
                id_mappings=id_map, nodes=nodes, test_df=bad_test_df,
                sql_baseline_df=sql_df, config=config,
            )

    def test_sql_baseline_normalizes_variants_and_dedupes(self, eval_setup):
        from src.gnn.evaluator import GNNEvaluator

        model, data, masks, id_map, nodes, test_df, _, config = eval_setup
        sql_df = pd.DataFrame({
            "email_lower": ["user0@test.com", "user0@test.com", "user0@test.com"],
            "sku": ["P001B", "P001", "P002"],
            "rank": [1, 2, 3],
        })

        evaluator = GNNEvaluator(
            model=model, data=data, split_masks=masks,
            id_mappings=id_map, nodes=nodes, test_df=test_df,
            sql_baseline_df=sql_df, config=config,
        )

        uid = id_map["user_to_id"]["user0@test.com"]
        p001 = id_map["product_to_id"]["P001"]
        p002 = id_map["product_to_id"]["P002"]
        assert evaluator.sql_baseline[uid] == [p001, p002]

    def test_evaluate_uses_cold_tier_metrics_for_go_no_go(self, eval_setup, mocker):
        from src.gnn.evaluator import GNNEvaluator

        model, data, masks, id_map, nodes, test_df, sql_df, config = eval_setup

        evaluator = GNNEvaluator(
            model=model, data=data, split_masks=masks,
            id_mappings=id_map, nodes=nodes, test_df=test_df,
            sql_baseline_df=sql_df, config=config,
        )

        mocker.patch.object(
            evaluator,
            "_compute_metrics",
            side_effect=[
                {"hit_rate_at_4": 0.90, "mrr": 0.20, "n_users": 3},
                {"hit_rate_at_4": 0.88, "mrr": 0.18, "n_users": 3},
                {"hit_rate_at_4": 0.20, "mrr": 0.05, "n_users": 3},
            ],
        )
        mocker.patch.object(
            evaluator,
            "_compute_stratified",
            return_value={
                "cold": {
                    "gnn_pre_rules": {"hit_rate_at_4": 0.01},
                    "sql_baseline": {"hit_rate_at_4": 0.05},
                },
                "warm": {"n_users": 1},
                "hot": {"n_users": 1},
            },
        )
        mocker.patch.object(evaluator, "_bootstrap_ci", return_value={})
        go_no_go_spy = mocker.spy(evaluator, "_go_no_go")

        report = evaluator.evaluate()

        assert go_no_go_spy.call_args.args[0]["hit_rate_at_4"] == 0.01
        assert go_no_go_spy.call_args.args[1]["hit_rate_at_4"] == 0.05
        assert report["go_no_go"]["decision"] == "INVESTIGATE"

    def test_evaluate_adds_unfair_delta_notes_for_k_above_4(self, eval_setup):
        from src.gnn.evaluator import GNNEvaluator

        model, data, masks, id_map, nodes, test_df, sql_df, config = eval_setup

        evaluator = GNNEvaluator(
            model=model, data=data, split_masks=masks,
            id_mappings=id_map, nodes=nodes, test_df=test_df,
            sql_baseline_df=sql_df, config=config,
        )
        report = evaluator.evaluate()

        assert "pre_rules_hit_rate_at_10_delta_NOTE" in report["deltas"]
        assert "post_rules_hit_rate_at_20_delta_NOTE" in report["deltas"]

    def test_generate_report_calls_evaluate(self, eval_setup, mocker):
        from src.gnn.evaluator import GNNEvaluator

        model, data, masks, id_map, nodes, test_df, sql_df, config = eval_setup

        evaluator = GNNEvaluator(
            model=model, data=data, split_masks=masks,
            id_mappings=id_map, nodes=nodes, test_df=test_df,
            sql_baseline_df=sql_df, config=config,
        )
        expected = {
            "gnn_pre_rules": {},
            "gnn_post_rules": {},
            "sql_baseline": {},
            "go_no_go": {},
            "n_evaluable": 0,
        }
        mocker.patch.object(evaluator, "evaluate", return_value=expected)

        report = evaluator.generate_report()

        assert report == expected
        evaluator.evaluate.assert_called_once()

    def test_universal_products_not_in_eval_candidates(self, eval_setup):
        """v5.18: universal products are excluded from eval candidate pools."""
        from src.gnn.evaluator import GNNEvaluator

        model, data, masks, id_map, nodes, test_df, sql_df, config = eval_setup

        evaluator = GNNEvaluator(
            model=model, data=data, split_masks=masks,
            id_mappings=id_map, nodes=nodes, test_df=test_df,
            sql_baseline_df=sql_df, config=config,
        )

        assert len(evaluator.universal_product_ids) > 0
        # Verify universal products are identified as frozenset
        assert isinstance(evaluator.universal_product_ids, frozenset)

    def test_universal_labels_filtered_from_test_interactions(self, eval_setup):
        """C3: universal products removed from test labels (impossible positives)."""
        from src.gnn.evaluator import GNNEvaluator

        model, data, masks, id_map, nodes, _, sql_df, config = eval_setup

        # Create test_df where one interaction is with a universal product (P015)
        test_df = pd.DataFrame({
            "email_lower": ["user0@test.com", "user0@test.com"],
            "base_sku": ["P003", "P015"],  # P015 is universal
            "interaction_type": ["view", "order"],
        })

        evaluator = GNNEvaluator(
            model=model, data=data, split_masks=masks,
            id_mappings=id_map, nodes=nodes, test_df=test_df,
            sql_baseline_df=sql_df, config=config,
        )

        uid = id_map["user_to_id"]["user0@test.com"]
        universal_pid = id_map["product_to_id"]["P015"]

        if uid in evaluator.test_interactions:
            # P015 (universal) should be filtered out
            assert universal_pid not in evaluator.test_interactions[uid]
