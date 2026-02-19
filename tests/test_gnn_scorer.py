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
    def test_universal_pool_not_empty(self, scorer_setup):
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        # Products P015-P019 are universal (is_universal=True)
        assert len(scorer.universal_product_ids) == 5

    def test_select_top4_respects_slot_reservation(self, scorer_setup):
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        fitment_ids = [0, 1, 2, 3, 4]
        fitment_scores = torch.tensor([5.0, 4.0, 3.0, 2.0, 1.0])
        universal_ids = [15, 16, 17, 18, 19]
        universal_scores = torch.tensor([4.5, 3.5, 2.5, 1.5, 0.5])

        result = scorer._select_top4(
            fitment_ids, fitment_scores,
            universal_ids, universal_scores,
        )

        assert len(result) == 4
        # First 2 should be from fitment pool
        pids = [pid for pid, _ in result]
        assert pids[0] in fitment_ids
        assert pids[1] in fitment_ids

    def test_select_top4_max_4_results(self, scorer_setup):
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        result = scorer._select_top4(
            list(range(100)), torch.randn(100),
            list(range(100, 200)), torch.randn(100),
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
        universal_ids = [15, 16, 17, 18, 19]
        universal_scores = torch.tensor([4.5, 3.5, 2.5, 1.5, 0.5])

        excluded = {0, 15}
        result = scorer._select_top4(
            fitment_ids, fitment_scores,
            universal_ids, universal_scores,
            excluded_products=excluded,
        )

        pids = [pid for pid, _ in result]
        assert 0 not in pids
        assert 15 not in pids

    def test_format_row_has_expected_columns(self, scorer_setup):
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )

        recs = [(0, 0.95), (1, 0.90), (15, 0.85), (16, 0.80)]
        row = scorer._format_row("test@example.com", recs)

        assert row["email_lower"] == "test@example.com"
        assert "rec1_sku" in row
        assert "rec1_name" in row
        assert "rec1_url" in row
        assert "rec1_image_url" in row
        assert "rec4_sku" in row
        assert "fitment_count" in row
        assert "model_version" in row
        assert row["fitment_count"] == 2

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
            "fitment_count", "model_version",
        }
        assert expected_cols.issubset(df.columns)
        consented = set(nodes["users"].loc[nodes["users"]["has_email_consent"], "email_lower"])
        assert set(df["email_lower"]).issubset(consented)

    def test_score_all_users_uses_universal_pool_when_fitment_missing(self, scorer_setup, mocker):
        from src.gnn.scorer import GNNScorer

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )
        scorer.vehicle_products = {}  # Force no-fitment scenario for every vehicle group.
        mocker.patch.object(scorer, "_qa_checks", return_value=None)

        df = scorer.score_all_users()

        assert not df.empty
        assert (df["fitment_count"] == 0).all()

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

    def test_score_all_users_raises_when_no_vehicle_groups(self, scorer_setup):
        from src.gnn.scorer import GNNScorer, QAFailedError

        model, data, id_map, nodes, config, mock_bq = scorer_setup

        scorer = GNNScorer(
            model=model, data=data, id_mappings=id_map,
            nodes=nodes, config=config, bq_client=mock_bq,
        )
        scorer.vehicle_users = {}  # force empty scoring path

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
