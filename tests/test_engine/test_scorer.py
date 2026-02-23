"""Tests for rec_engine.core.scorer — production scoring pipeline."""

import pandas as pd
import pytest

from plugins.defaults import DefaultPlugin
from rec_engine.core.model import HeteroGAT
from rec_engine.core.scorer import GNNScorer, QAFailedError
from rec_engine.topology import create_strategy


def _make_scorer(data, id_mappings, metadata, config, *, user_purchases=None):
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

    products_data = []
    for i in range(20):
        products_data.append({
            "product_id": f"prod_{i}",
            "price": 50.0 + i * 10,
            "popularity": float(20 - i),
            "category": f"cat_{i % 5}",
            "is_excluded": i >= 18,
            "name": f"Product {i}",
            "url": f"https://example.com/p/{i}",
            "image_url": f"https://cdn.example.com/img/{i}.jpg",
        })
    products_df = pd.DataFrame(products_data)

    entities_data = []
    if "entity_to_id" in id_mappings:
        for i in range(5):
            entities_data.append({
                "entity_id": f"entity_{i}",
                "make": ["Toyota", "Toyota", "Honda", "Honda", "Ford"][i],
            })

    nodes = {"products": products_df}
    if entities_data:
        nodes["entities"] = pd.DataFrame(entities_data)

    return GNNScorer(
        model=model,
        data=data,
        id_mappings=id_mappings,
        nodes=nodes,
        config=config,
        strategy=strategy,
        plugin=plugin,
        user_purchases=user_purchases,
    )


class TestGNNScorer:
    @pytest.fixture(params=["user-product", "user-entity-product"])
    def scorer(self, request, small_graph_2node, small_graph_3node, config_2node, config_3node):
        if request.param == "user-product":
            data, _, mappings, meta = small_graph_2node
            return _make_scorer(data, mappings, meta, config_2node)
        data, _, mappings, meta = small_graph_3node
        return _make_scorer(data, mappings, meta, config_3node)

    def test_initialization(self, scorer):
        assert scorer.model is not None
        assert len(scorer.product_meta) > 0

    def test_score_all_users(self, scorer):
        target = {f"user_{i}" for i in range(10)}
        df = scorer.score_all_users(target_user_ids=target)
        assert isinstance(df, pd.DataFrame)
        assert len(df) > 0
        assert "user_id" in df.columns
        assert "rec1_product_id" in df.columns

    def test_output_columns(self, scorer):
        cols = scorer._output_columns()
        assert "user_id" in cols
        assert "rec1_product_id" in cols
        assert "rec1_score" in cols
        assert "is_fallback" in cols
        assert "model_version" in cols

    def test_format_row(self, scorer):
        recs = [(0, 0.9, False), (1, 0.8, False), (2, 0.1, True)]
        row = scorer._format_row("user_0", recs)
        assert row["user_id"] == "user_0"
        assert row["rec1_score"] == 0.9
        assert row["is_fallback"] is True
        assert row["fallback_start_idx"] == 2  # 0-based index of first fallback

    def test_format_row_no_fallback(self, scorer):
        recs = [(0, 0.9, False), (1, 0.8, False)]
        row = scorer._format_row("user_0", recs)
        assert row["is_fallback"] is False
        assert row["fallback_start_idx"] == len(recs)

    def test_min_recs_validation(self, small_graph_2node, config_2node):
        data, _, mappings, meta = small_graph_2node
        bad_config = dict(config_2node)
        bad_config["scoring"] = dict(bad_config["scoring"])
        bad_config["scoring"]["min_recs"] = 10  # > total_slots
        with pytest.raises(ValueError, match="min_recs"):
            _make_scorer(data, mappings, meta, bad_config)


class TestBatchedScoring:
    """C2: Verify batched scoring produces consistent results."""

    def test_batch_size_respected(self, small_graph_2node, config_2node):
        """C2: Scorer should use configurable batch_size for matrix multiply."""
        config_2node["scoring"]["batch_size"] = 2
        data, _, mappings, meta = small_graph_2node
        scorer = _make_scorer(data, mappings, meta, config_2node)
        target = {f"user_{i}" for i in range(10)}
        df = scorer.score_all_users(target_user_ids=target)
        assert len(df) > 0

    def test_batched_vs_default_same_results(self, small_graph_2node, config_2node):
        """C2: Small batch should produce same recs as large batch."""
        data, _, mappings, meta = small_graph_2node

        # Large batch (default 512 → all at once)
        scorer1 = _make_scorer(data, mappings, meta, config_2node)
        target = {f"user_{i}" for i in range(10)}
        df1 = scorer1.score_all_users(target_user_ids=target)

        # Small batch
        config_2node["scoring"]["batch_size"] = 2
        scorer2 = _make_scorer(data, mappings, meta, config_2node)
        df2 = scorer2.score_all_users(target_user_ids=target)

        # Same users, same recs
        assert set(df1["user_id"]) == set(df2["user_id"])


class TestPostRankFilterContext:
    def test_post_rank_filter_receives_enriched_context(self, small_graph_2node, config_2node):
        """M8: post_rank_filter context must include product_str_id and category."""
        captured_contexts: list[dict] = []

        class ContextCapturingPlugin(DefaultPlugin):
            def post_rank_filter(self, product_id: int, context: dict) -> bool:
                captured_contexts.append(dict(context))
                return True

        data, _, mappings, meta = small_graph_2node
        strategy = create_strategy(config_2node)
        entity_type_name = config_2node.get("entity", {}).get("type_name", "entity")
        n_entities = len(mappings.get("entity_to_id", {}))
        edge_types = strategy.get_edge_types(config_2node)
        from rec_engine.core.model import HeteroGAT

        model = HeteroGAT(
            n_users=data["user"].num_nodes,
            n_products=data["product"].num_nodes,
            n_entities=n_entities,
            n_categories=meta["n_categories"],
            edge_types=edge_types,
            config=config_2node,
            entity_type_name=entity_type_name,
            product_num_features=meta["product_num_features"],
            entity_num_features=meta.get("entity_num_features", 0),
        )

        products_data = []
        for i in range(20):
            products_data.append({
                "product_id": f"prod_{i}",
                "price": 50.0 + i * 10,
                "popularity": float(20 - i),
                "category": f"cat_{i % 5}",
                "is_excluded": i >= 18,
                "name": f"Product {i}",
                "url": f"https://example.com/p/{i}",
                "image_url": f"https://cdn.example.com/img/{i}.jpg",
            })

        scorer = GNNScorer(
            model=model, data=data, id_mappings=mappings,
            nodes={"products": pd.DataFrame(products_data)},
            config=config_2node, strategy=strategy,
            plugin=ContextCapturingPlugin(salt="test"),
        )
        scorer.score_all_users(target_user_ids={"user_0"})

        assert len(captured_contexts) > 0
        for ctx in captured_contexts:
            assert "scorer" in ctx
            assert ctx["scorer"] is True
            assert "user_id" in ctx
            assert ctx["user_id"] == "user_0"
            # M8: Enriched context fields
            assert "product_str_id" in ctx
            assert "category" in ctx


class TestGNNScorerWithPurchaseExclusion:
    def test_purchase_exclusion(self, small_graph_2node, config_2node):
        data, _, mappings, meta = small_graph_2node
        purchases = {"user_0": {"prod_0", "prod_1"}}
        scorer = _make_scorer(data, mappings, meta, config_2node, user_purchases=purchases)
        assert "user_0" in scorer.user_excluded_products
        assert len(scorer.user_excluded_products["user_0"]) > 0


class TestQAChecks:
    def test_qa_passes_on_valid_data(self, small_graph_2node, config_2node):
        data, _, mappings, meta = small_graph_2node
        scorer = _make_scorer(data, mappings, meta, config_2node)
        target = {f"user_{i}" for i in range(10)}
        # Should not raise
        df = scorer.score_all_users(target_user_ids=target)
        assert len(df) > 0

    def test_qa_fails_on_duplicates(self, small_graph_2node, config_2node):
        data, _, mappings, meta = small_graph_2node
        scorer = _make_scorer(data, mappings, meta, config_2node)
        # Create a DataFrame with duplicates
        cols = scorer._output_columns()
        row = {c: None for c in cols}
        row["user_id"] = "user_0"
        row["rec1_product_id"] = "prod_0"
        df = pd.DataFrame([row, row], columns=cols)
        with pytest.raises(QAFailedError, match="duplicate"):
            scorer._qa_checks(df)
