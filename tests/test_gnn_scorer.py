"""Tests for GNN scorer."""

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


def _qa_row(
    email: str = "a@test.com",
    *,
    rec1_sku: str = "P001",
    rec1_price: float = 50.0,
    rec1_score: float = 0.9,
    rec1_image_url: str = "https://cdn.example.com/p1.jpg",
    rec2_sku: str | None = None,
    rec2_price: float | None = None,
    rec2_score: float | None = None,
    rec3_sku: str | None = None,
    rec3_price: float | None = None,
    rec3_score: float | None = None,
    rec4_sku: str | None = None,
    rec4_price: float | None = None,
    rec4_score: float | None = None,
    is_fallback: bool = False,
    fallback_start_idx: int = 1,
) -> dict:
    return {
        "email_lower": email,
        "rec1_sku": rec1_sku,
        "rec1_name": "Product 1",
        "rec1_url": "https://example.com/p1",
        "rec1_image_url": rec1_image_url,
        "rec1_price": rec1_price,
        "rec1_score": rec1_score,
        "rec2_sku": rec2_sku,
        "rec2_name": None,
        "rec2_url": None,
        "rec2_image_url": None,
        "rec2_price": rec2_price,
        "rec2_score": rec2_score,
        "rec3_sku": rec3_sku,
        "rec3_name": None,
        "rec3_url": None,
        "rec3_image_url": None,
        "rec3_price": rec3_price,
        "rec3_score": rec3_score,
        "rec4_sku": rec4_sku,
        "rec4_name": None,
        "rec4_url": None,
        "rec4_image_url": None,
        "rec4_price": rec4_price,
        "rec4_score": rec4_score,
        "fitment_count": 1,
        "is_fallback": is_fallback,
        "fallback_start_idx": fallback_start_idx,
        "model_version": "v6.0",
    }


@pytest.fixture
def scorer_setup(sample_nodes, sample_edges, sample_id_mappings, gnn_config, mocker):  # noqa: F811
    from src.gnn.graph_builder import build_hetero_graph
    from src.gnn.model import HolleyGAT

    gnn_config["bigquery"] = {
        "project_id": "test-project",
        "dataset": "test_dataset",
        "source_project": "test-source",
    }
    gnn_config["graph"] = {"min_price": 25}
    gnn_config["output"] = {"shadow_table": "test.table", "qa": {"min_users": 1}}

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

    mock_bq = mocker.Mock()
    return model, data, sample_id_mappings, sample_nodes, gnn_config, mock_bq


class TestGNNScorer:
    def test_universal_set_excludes_from_output(self, scorer_setup):
        """Universal products are identified but excluded from candidate pools."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        # Products P015-P019 are universal (is_universal=True)
        assert len(scorer.universal_product_ids) == 5
        assert isinstance(scorer.universal_product_ids, frozenset)

    def test_select_top4_fitment_only(self, scorer_setup):
        """v5.18: all 4 slots are fitment (no universal slots)."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        # Use diverse part types: 0=Ignition, 3=Exhaust, 6=Brakes, 9=Wheels, 1=Ignition
        fitment_ids = [0, 3, 6, 9, 1]
        fitment_scores = torch.tensor([5.0, 4.0, 3.0, 2.0, 1.0])

        result = scorer._select_top4(fitment_ids, fitment_scores)

        assert len(result) == 4
        pids = [pid for pid, _, _ in result]
        for pid in pids:
            assert pid in fitment_ids
        # Finding 2: all GNN recs have is_fallback=False
        for _, _, from_fb in result:
            assert from_fb is False

    def test_select_top4_max_4_results(self, scorer_setup):
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        result = scorer._select_top4(
            list(range(100)), torch.randn(100),
        )

        assert len(result) <= 4

    def test_select_top4_respects_excluded_products(self, scorer_setup):
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        fitment_ids = [0, 1, 2, 3, 4]
        fitment_scores = torch.tensor([5.0, 4.0, 3.0, 2.0, 1.0])

        excluded = {0, 1}
        result = scorer._select_top4(
            fitment_ids, fitment_scores,
            excluded_products=excluded,
        )

        pids = [pid for pid, _, _ in result]
        assert 0 not in pids
        assert 1 not in pids

    def test_format_row_has_expected_columns(self, scorer_setup):
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        recs = [(0, 0.95, False), (1, 0.90, False), (2, 0.85, False), (3, 0.80, False)]
        row = scorer._format_row("test@example.com", recs)

        assert row["email_lower"] == "test@example.com"
        assert "rec1_sku" in row
        assert "rec1_name" in row
        assert "rec1_url" in row
        assert "rec1_image_url" in row
        assert "rec4_sku" in row
        assert "fitment_count" in row
        assert "is_fallback" in row
        assert "fallback_start_idx" in row
        assert "model_version" in row
        assert row["fitment_count"] == 4  # all recs are fitment (v5.18)
        assert row["is_fallback"] is False
        assert row["fallback_start_idx"] == 4  # no fallback, all GNN

    def test_qa_raises_on_too_few_users(self, scorer_setup):
        from src.gnn.scorer import GNNScorer, QAFailedError

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )
        scorer.min_users = 250_000

        # Small DataFrame should fail the 250K check
        df = pd.DataFrame([_qa_row()])

        with pytest.raises(QAFailedError, match="expected >= 250000"):
            scorer._qa_checks(df)

    def test_qa_raises_on_duplicates(self, scorer_setup):
        from src.gnn.scorer import GNNScorer, QAFailedError

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        # DataFrame with duplicate emails.
        df = pd.DataFrame([_qa_row(), _qa_row()])

        with pytest.raises(QAFailedError, match="duplicate"):
            scorer._qa_checks(df)

    def test_score_all_users_end_to_end_offline(self, scorer_setup, mocker):
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )
        mocker.patch.object(scorer, "_qa_checks", return_value=None)

        df = scorer.score_all_users()

        assert not df.empty
        expected_cols = {
            "email_lower",
            "rec1_sku", "rec2_sku", "rec3_sku", "rec4_sku",
            "rec1_name", "rec2_name", "rec3_name", "rec4_name",
            "rec1_url", "rec2_url", "rec3_url", "rec4_url",
            "rec1_image_url", "rec2_image_url", "rec3_image_url", "rec4_image_url",
            "rec1_price", "rec2_price", "rec3_price", "rec4_price",
            "rec1_score", "rec2_score", "rec3_score", "rec4_score",
            "fitment_count", "is_fallback", "fallback_start_idx", "model_version",
        }
        assert expected_cols.issubset(df.columns)
        consented = set(nodes["users"].loc[nodes["users"]["has_email_consent"], "email_lower"])
        assert set(df["email_lower"]).issubset(consented)
        # v5.18: no universal products in output
        universal_skus = set(
            nodes["products"].loc[nodes["products"]["is_universal"], "sku"]
        )
        for i in range(1, 5):
            col = f"rec{i}_sku"
            non_null = df[col].dropna()
            assert not non_null.isin(universal_skus).any(), f"Universal product found in {col}"

    def test_score_all_users_fallback_when_no_fitment(self, scorer_setup, mocker):
        """Users with no fitment get fallback recs (not dropped)."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )
        scorer.vehicle_products = {}  # Force no-fitment scenario
        mocker.patch.object(scorer, "_qa_checks", return_value=None)

        df = scorer.score_all_users()

        # With fallback enabled, users should still get recs from global popularity
        if not scorer.global_fitment_by_popularity:
            assert df.empty  # no fallback products available
        else:
            assert not df.empty
            assert (df["is_fallback"]).all()

    def test_qa_raises_on_price_floor_violation(self, scorer_setup):
        from src.gnn.scorer import GNNScorer, QAFailedError

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        df = pd.DataFrame([_qa_row(rec1_price=10.0)])  # below min_price=25

        with pytest.raises(QAFailedError, match="below"):
            scorer._qa_checks(df)

    def test_qa_raises_on_score_ordering_violation(self, scorer_setup):
        from src.gnn.scorer import GNNScorer, QAFailedError

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        df = pd.DataFrame([
            _qa_row(
                rec1_score=0.1,
                rec2_sku="P002",
                rec2_price=60.0,
                rec2_score=0.9,  # higher than rec1 -> ordering violation
            )
        ])

        with pytest.raises(QAFailedError, match="Score ordering violated"):
            scorer._qa_checks(df)

    def test_write_shadow_table_calls_bq_client(self, scorer_setup):
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        df = pd.DataFrame({"email_lower": ["a@test.com"]})
        scorer.write_shadow_table(df)

        mock_bq.write_table.assert_called_once_with(df, "test.table")

    def test_score_all_users_raises_when_no_recs_at_all(self, scorer_setup):
        from src.gnn.scorer import GNNScorer, QAFailedError

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )
        scorer.vehicle_users = {}
        scorer.global_fitment_by_popularity = []  # no fallback candidates either
        scorer.vehicle_fitment_by_popularity = {}
        scorer.make_fitment_by_popularity = {}

        with pytest.raises(QAFailedError, match="expected >= 1"):
            scorer.score_all_users()

    def test_purchase_exclusion_filters_bought_products(self, scorer_setup):
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        # Get a sku that exists in the product catalog
        products_df = nodes["products"]
        excluded_sku = products_df["base_sku"].iloc[0]

        user_purchases = {"user_1@test.com": {excluded_sku}}

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
            user_purchases=user_purchases,
        )

        # Verify the exclusion was built
        assert "user_1@test.com" in scorer.user_excluded_products
        pid = id_map["product_to_id"][excluded_sku]
        assert pid in scorer.user_excluded_products["user_1@test.com"]

    def test_purchase_exclusion_merges_colliding_normalized_emails(self, scorer_setup):
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        products_df = nodes["products"]
        sku_a = products_df["base_sku"].iloc[0]
        sku_b = products_df["base_sku"].iloc[1]

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
            user_purchases={
                "User_1@Test.com": {sku_a},
                " user_1@test.com ": {sku_b},
            },
        )

        merged = scorer.user_excluded_products["user_1@test.com"]
        assert id_map["product_to_id"][sku_a] in merged
        assert id_map["product_to_id"][sku_b] in merged

    def test_purchase_exclusion_empty_by_default(self, scorer_setup):
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        assert scorer.user_excluded_products == {}

    def test_qa_raises_on_non_https_image_url(self, scorer_setup):
        """HTTPS image URL validation catches protocol-relative and http URLs."""
        from src.gnn.scorer import GNNScorer, QAFailedError

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        df = pd.DataFrame([_qa_row(rec1_image_url="http://cdn.example.com/p1.jpg")])

        with pytest.raises(QAFailedError, match="non-HTTPS"):
            scorer._qa_checks(df)

    def test_qa_passes_with_empty_image_urls(self, scorer_setup):
        """Empty/None image URLs should not trigger HTTPS validation failure."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        df = pd.DataFrame([_qa_row(rec1_image_url="")])
        # Should not raise — empty strings are skipped
        scorer._qa_checks(df)

    def test_purchase_exclusion_normalizes_email_and_sku(self, scorer_setup):
        """Purchase exclusion normalizes email (lowercase/trim) and SKU (variant strip)."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        products_df = nodes["products"]
        base_sku = products_df["base_sku"].iloc[0]
        # Add variant suffix that should be stripped
        variant_sku = base_sku + "B" if base_sku[-1].isdigit() else base_sku

        user_purchases = {"  User_1@Test.COM  ": {variant_sku}}

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
            user_purchases=user_purchases,
        )

        # Email should be normalized to lowercase/trimmed
        assert "user_1@test.com" in scorer.user_excluded_products
        pid = id_map["product_to_id"][base_sku]
        assert pid in scorer.user_excluded_products["user_1@test.com"]

    def test_format_row_is_fallback_true_from_provenance(self, scorer_setup):
        """Finding 2: is_fallback=True when any rec has from_fallback=True provenance."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        # Second rec is fallback (provenance flag, not score value)
        recs = [(0, 0.95, False), (1, 0.0, True)]
        row = scorer._format_row("test@example.com", recs)

        assert row["is_fallback"] is True
        assert row["fallback_start_idx"] == 1  # slot 2 (0-based idx 1) is first fallback

    def test_format_row_is_fallback_false_for_gnn_scores(self, scorer_setup):
        """is_fallback=False when all recs have from_fallback=False provenance."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        recs = [(0, 0.95, False), (1, 0.90, False)]
        row = scorer._format_row("test@example.com", recs)

        assert row["is_fallback"] is False

    def test_format_row_gnn_score_zero_not_misdetected_as_fallback(self, scorer_setup):
        """Finding 2: GNN score of exactly 0.0 should NOT trigger is_fallback=True."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        # Score is 0.0 but from_fallback is False — should NOT be detected as fallback
        recs = [(0, 0.0, False)]
        row = scorer._format_row("test@example.com", recs)

        assert row["is_fallback"] is False

    def test_popularity_index_built_correctly(self, scorer_setup):
        """Popularity index has vehicle, make, and global tiers."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        # Vehicle tier: at least one vehicle has fitment products
        assert len(scorer.vehicle_fitment_by_popularity) > 0
        # No universals in any vehicle popularity list
        for vid, pids in scorer.vehicle_fitment_by_popularity.items():
            for pid in pids:
                assert pid not in scorer.universal_product_ids

        # Make tier
        assert len(scorer.make_fitment_by_popularity) > 0
        for make, pids in scorer.make_fitment_by_popularity.items():
            for pid in pids:
                assert pid not in scorer.universal_product_ids

        # Global tier
        assert len(scorer.global_fitment_by_popularity) > 0
        for pid in scorer.global_fitment_by_popularity:
            assert pid not in scorer.universal_product_ids

    def test_apply_fallback_vehicle_tier(self, scorer_setup):
        """Fallback fills from vehicle-specific popularity when available."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        # Pick a vehicle that has fitment products
        vid = next(iter(scorer.vehicle_fitment_by_popularity))
        fallback = scorer._apply_fallback(
            vehicle_ids=[vid], makes=None,
            existing_recs=[], excluded_products=None,
            part_type_counts={},
        )

        assert len(fallback) > 0
        assert len(fallback) <= scorer.min_recs
        for pid, score, from_fb in fallback:
            assert score == scorer.score_sentinel
            assert from_fb is True
            assert pid not in scorer.universal_product_ids

    def test_apply_fallback_global_tier(self, scorer_setup):
        """Fallback falls through to global tier when no vehicle/make."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        fallback = scorer._apply_fallback(
            vehicle_ids=None, makes=None,
            existing_recs=[], excluded_products=None,
            part_type_counts={},
        )

        assert len(fallback) > 0
        for pid, score, from_fb in fallback:
            assert score == scorer.score_sentinel
            assert from_fb is True

    def test_apply_fallback_respects_exclusion(self, scorer_setup):
        """Fallback skips excluded (purchased) products."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        # Exclude all global fallback products except a few
        excluded = set(scorer.global_fitment_by_popularity[:-2])

        fallback = scorer._apply_fallback(
            vehicle_ids=None, makes=None,
            existing_recs=[], excluded_products=excluded,
            part_type_counts={},
        )

        for pid, _, _ in fallback:
            assert pid not in excluded

    def test_apply_fallback_multi_vehicle(self, scorer_setup):
        """Finding 1: fallback tries multiple vehicles for multi-vehicle users."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        # Get two vehicles with fitment products
        vids = list(scorer.vehicle_fitment_by_popularity.keys())[:2]
        if len(vids) < 2:
            pytest.skip("Need at least 2 vehicles with fitment products")

        fallback = scorer._apply_fallback(
            vehicle_ids=vids, makes=None,
            existing_recs=[], excluded_products=None,
            part_type_counts={},
        )

        assert len(fallback) > 0
        for _, _, from_fb in fallback:
            assert from_fb is True

    def test_zero_row_user_gets_global_fallback(self, scorer_setup, mocker):
        """User with no vehicle in graph gets recs via global popularity fallback."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )
        # Clear vehicle mappings so no user gets GNN recs
        scorer.vehicle_users = {}
        mocker.patch.object(scorer, "_qa_checks", return_value=None)

        df = scorer.score_all_users()

        # All target users should have recs via fallback
        consented = set(nodes["users"].loc[nodes["users"]["has_email_consent"], "email_lower"])
        if scorer.global_fitment_by_popularity:
            assert len(df) > 0
            for _, row in df.iterrows():
                assert row["email_lower"] in consented
                assert row["is_fallback"] is True

    def test_min_recs_validation_rejects_above_4(self, scorer_setup):
        """Finding 6: min_recs > 4 raises ValueError (4-slot output schema)."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup
        config["fallback"] = {"enabled": True, "min_recs": 5}

        with pytest.raises(ValueError, match="must be 0-4"):
            GNNScorer(
                model=model, data=data, id_mappings=id_map,
                nodes=nodes, config=config, bq_client=mock_bq,
            )

    def test_min_recs_validation_rejects_negative(self, scorer_setup):
        """Finding 6: min_recs < 0 raises ValueError."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup
        config["fallback"] = {"enabled": True, "min_recs": -1}

        with pytest.raises(ValueError, match="must be 0-4"):
            GNNScorer(
                model=model, data=data, id_mappings=id_map,
                nodes=nodes, config=config, bq_client=mock_bq,
            )

    def test_qa_coverage_check_fails_on_low_coverage(self, scorer_setup):
        """Finding 4: QA fails when output covers <95% of target users."""
        from src.gnn.scorer import GNNScorer, QAFailedError

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        # 1 row but target_count=100 → 1% coverage
        df = pd.DataFrame([_qa_row()])

        with pytest.raises(QAFailedError, match="Low target coverage"):
            scorer._qa_checks(df, target_count=100)

    def test_qa_score_ordering_skips_fallback_rows(self, scorer_setup):
        """Finding 3: QA ordering check ignores fallback rows."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        # Fallback row: rec1 has negative GNN score, rec2 has 0.0 sentinel.
        # This would violate ordering but is valid for fallback rows.
        df = pd.DataFrame([{
            "email_lower": "a@test.com",
            "rec1_sku": "P001", "rec1_name": "A", "rec1_url": "https://a",
            "rec1_image_url": "https://cdn.example.com/a.jpg",
            "rec1_price": 50.0, "rec1_score": -0.1,
            "rec2_sku": "P002", "rec2_name": "B", "rec2_url": "https://b",
            "rec2_image_url": "https://cdn.example.com/b.jpg",
            "rec2_price": 60.0, "rec2_score": 0.0,
            "rec3_sku": None, "rec3_name": None, "rec3_url": None,
            "rec3_image_url": None, "rec3_price": None, "rec3_score": None,
            "rec4_sku": None, "rec4_name": None, "rec4_url": None,
            "rec4_image_url": None, "rec4_price": None, "rec4_score": None,
            "fitment_count": 2, "is_fallback": True, "fallback_start_idx": 1,
            "model_version": "v6.0",
        }])

        # Should NOT raise — fallback rows skip ordering check
        scorer._qa_checks(df, target_count=1)

    def test_qa_score_ordering_enforced_on_non_fallback(self, scorer_setup):
        """Finding 3: ordering check still catches violations on non-fallback rows."""
        from src.gnn.scorer import GNNScorer, QAFailedError

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        # Non-fallback row with ordering violation
        df = pd.DataFrame([_qa_row(
            rec1_score=0.1,
            rec2_sku="P002", rec2_price=60.0, rec2_score=0.9,
            is_fallback=False, fallback_start_idx=1,
        )])

        with pytest.raises(QAFailedError, match="Score ordering violated"):
            scorer._qa_checks(df, target_count=1)

    def test_score_sentinel_read_from_config(self, scorer_setup):
        """Finding 2: score_sentinel is read from config, not hardcoded."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup
        config["fallback"] = {"enabled": True, "min_recs": 3, "score_sentinel": -999.0}

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        assert scorer.score_sentinel == -999.0

    def test_multi_vehicle_merge_unions_candidates(self, scorer_setup, mocker):
        """R3 #4: Multi-vehicle merge through production code path.

        Each vehicle has only 2 fitment products (not enough for 4 slots alone).
        Getting 4 GNN recs from the exact union proves the merge works.
        """
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )
        mocker.patch.object(scorer, "_qa_checks", return_value=None)

        uid_0 = id_map["user_to_id"]["user0@test.com"]
        vid_ford = id_map["vehicle_to_id"]["FORD|MUSTANG"]
        vid_chevy = id_map["vehicle_to_id"]["CHEVY|CAMARO"]

        # Resolve product IDs from id_map (not hardcoded indices)
        pid_p000 = id_map["product_to_id"]["P000"]  # Ignition
        pid_p005 = id_map["product_to_id"]["P005"]  # Exhaust
        pid_p003 = id_map["product_to_id"]["P003"]  # Ignition
        pid_p010 = id_map["product_to_id"]["P010"]  # Brakes

        # Constrain each vehicle to 2 non-overlapping products.
        # Neither vehicle alone can fill 4 slots.
        scorer.vehicle_products = {
            vid_ford: [pid_p000, pid_p005],
            vid_chevy: [pid_p010, pid_p003],
        }
        scorer.vehicle_users = {
            vid_ford: [uid_0],
            vid_chevy: [uid_0],
        }
        scorer._build_popularity_index()

        expected_union = {"P000", "P003", "P005", "P010"}

        df = scorer.score_all_users()
        user0_row = df[df["email_lower"] == "user0@test.com"]
        assert len(user0_row) == 1

        rec_skus = {
            user0_row.iloc[0][f"rec{i}_sku"]
            for i in range(1, 5)
            if pd.notna(user0_row.iloc[0][f"rec{i}_sku"])
        }
        # All 4 recs must come from the constrained union — proves merge, not leak
        assert rec_skus == expected_union
        assert not user0_row.iloc[0]["is_fallback"]  # all GNN-scored, no fallback needed

    def test_format_row_fallback_start_idx_correct(self, scorer_setup):
        """R3 #2: fallback_start_idx reflects exact boundary from provenance."""
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        # 2 GNN recs + 2 fallback recs
        recs = [(0, 0.95, False), (1, 0.85, False), (2, 0.0, True), (3, 0.0, True)]
        row = scorer._format_row("test@example.com", recs)

        assert row["is_fallback"] is True
        assert row["fallback_start_idx"] == 2  # slots 1-2 are GNN, 3-4 are fallback

    def test_qa_ordering_detects_gnn_prefix_violation_with_sentinel_score(self, scorer_setup):
        """R3 #2: QA catches GNN prefix ordering bug even when GNN score == sentinel."""
        from src.gnn.scorer import GNNScorer, QAFailedError

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        # GNN prefix has 2 scores: 0.0 then 0.5 (ordering violation)
        # With old sentinel-based detection, 0.0 would be misidentified as fallback.
        # With fallback_start_idx=2, QA knows the first 2 slots are GNN.
        df = pd.DataFrame([{
            "email_lower": "a@test.com",
            "rec1_sku": "P001", "rec1_name": "A", "rec1_url": "https://a",
            "rec1_image_url": "https://cdn.example.com/a.jpg",
            "rec1_price": 50.0, "rec1_score": 0.0,  # GNN score happens to be 0.0
            "rec2_sku": "P002", "rec2_name": "B", "rec2_url": "https://b",
            "rec2_image_url": "https://cdn.example.com/b.jpg",
            "rec2_price": 60.0, "rec2_score": 0.5,  # higher than rec1 -> violation
            "rec3_sku": "P003", "rec3_name": "C", "rec3_url": "https://c",
            "rec3_image_url": "https://cdn.example.com/c.jpg",
            "rec3_price": 70.0, "rec3_score": 0.0,  # fallback sentinel
            "rec4_sku": None, "rec4_name": None, "rec4_url": None,
            "rec4_image_url": None, "rec4_price": None, "rec4_score": None,
            "fitment_count": 3, "is_fallback": True,
            "fallback_start_idx": 2,  # first 2 slots are GNN
            "model_version": "v6.0",
        }])

        with pytest.raises(QAFailedError, match="Score ordering violated.*GNN prefix"):
            scorer._qa_checks(df, target_count=1)
