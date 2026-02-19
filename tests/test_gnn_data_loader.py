"""Tests for GNN data loader with mocked BQ client."""

from pathlib import Path

import pandas as pd
import pytest
from google.api_core.exceptions import NotFound

from src.gnn.data_loader import GNNDataLoader


@pytest.fixture
def gnn_config():
    return {
        "bigquery": {
            "project_id": "test-project",
            "source_project": "test-source",
            "dataset": "test_gnn",
            "company_id": 1950,
        },
        "graph": {"min_price": 25},
        "eval": {"user_split": [0.8, 0.1, 0.1]},
    }


@pytest.fixture
def mock_bq(mocker):
    client = mocker.Mock()
    client.project = "test-project"
    client.dataset = "test_gnn"
    return client


class TestGNNDataLoader:
    def test_load_nodes_builds_id_mappings(self, gnn_config, mock_bq):
        users_df = pd.DataFrame({
            "email_lower": ["a@test.com", "b@test.com", "c@test.com"],
            "v1_make": ["FORD", "CHEVY", "FORD"],
            "v1_model": ["MUSTANG", "CAMARO", "MUSTANG"],
            "v1_year": ["2020", "2019", "2021"],
            "has_email_consent": [True, True, False],
            "engagement_tier": ["cold", "warm", "cold"],
        })
        products_df = pd.DataFrame({
            "sku": ["SKU1", "SKU2"],
            "base_sku": ["SKU1", "SKU2"],
            "part_type": ["Ignition", "Exhaust"],
            "price": [100.0, 200.0],
            "log_popularity": [2.0, 3.0],
            "fitment_breadth": [5, 10],
            "is_universal": [False, True],
        })
        vehicles_df = pd.DataFrame({
            "make": ["FORD", "CHEVY"],
            "model": ["MUSTANG", "CAMARO"],
            "user_count": [2, 1],
            "product_count": [100, 50],
        })

        def mock_run_query(query, *args, **kwargs):
            if "user_nodes" in query:
                return users_df
            elif "product_nodes" in query:
                return products_df
            elif "vehicle_nodes" in query:
                return vehicles_df
            return pd.DataFrame()

        mock_bq.run_query = mock_run_query

        loader = GNNDataLoader(gnn_config, bq_client=mock_bq)
        loader.load_nodes()

        assert len(loader.user_to_id) == 3
        assert len(loader.product_to_id) == 2
        assert len(loader.vehicle_to_id) == 2
        assert "a@test.com" in loader.user_to_id
        assert "SKU1" in loader.product_to_id
        assert "FORD|MUSTANG" in loader.vehicle_to_id

    def test_load_edges(self, gnn_config, mock_bq):
        mock_bq.run_query.return_value = pd.DataFrame({
            "email_lower": ["a@test.com"],
            "base_sku": ["SKU1"],
            "interaction_type": ["view"],
            "weight": [1.0],
        })

        loader = GNNDataLoader(gnn_config, bq_client=mock_bq)
        edges = loader.load_edges()

        assert "interactions" in edges
        assert "fitment" in edges
        assert "ownership" in edges
        assert "copurchase" in edges
        for key in ("interactions", "fitment", "ownership", "copurchase"):
            assert isinstance(edges[key], pd.DataFrame)

    def test_get_id_mappings_empty_before_load(self, gnn_config, mock_bq):
        loader = GNNDataLoader(gnn_config, bq_client=mock_bq)
        mappings = loader.get_id_mappings()
        assert mappings["user_to_id"] == {}

    def test_id_mappings_are_deterministic_sorted_order(self, gnn_config, mock_bq):
        """IDs must be assigned in sorted key order regardless of input order."""
        # Deliberately unsorted input — z before a, SKU9 before SKU1
        users_df = pd.DataFrame({
            "email_lower": ["z@test.com", "a@test.com", "m@test.com"],
            "v1_make": ["FORD", "FORD", "FORD"],
            "v1_model": ["MUSTANG", "MUSTANG", "MUSTANG"],
            "v1_year": ["2020", "2020", "2020"],
            "has_email_consent": [True, True, True],
            "engagement_tier": ["cold", "cold", "cold"],
        })
        products_df = pd.DataFrame({
            "sku": ["SKU9", "SKU1", "SKU5"],
            "base_sku": ["SKU9", "SKU1", "SKU5"],
            "part_type": ["Ignition", "Exhaust", "Brakes"],
            "price": [100.0, 200.0, 150.0],
            "log_popularity": [2.0, 3.0, 1.0],
            "fitment_breadth": [5, 10, 7],
            "is_universal": [False, True, False],
        })
        vehicles_df = pd.DataFrame({
            "make": ["FORD", "CHEVY"],
            "model": ["MUSTANG", "CAMARO"],
            "user_count": [3, 0],
            "product_count": [100, 50],
        })

        def mock_run_query(query, *args, **kwargs):
            if "user_nodes" in query:
                return users_df
            elif "product_nodes" in query:
                return products_df
            elif "vehicle_nodes" in query:
                return vehicles_df
            return pd.DataFrame()

        mock_bq.run_query = mock_run_query

        loader = GNNDataLoader(gnn_config, bq_client=mock_bq)
        loader.load_nodes()

        # Alphabetical: a=0, m=1, z=2
        assert loader.user_to_id["a@test.com"] == 0
        assert loader.user_to_id["m@test.com"] == 1
        assert loader.user_to_id["z@test.com"] == 2

        # Alphabetical: SKU1=0, SKU5=1, SKU9=2
        assert loader.product_to_id["SKU1"] == 0
        assert loader.product_to_id["SKU5"] == 1
        assert loader.product_to_id["SKU9"] == 2

        # Sorted by (make, model): CHEVY|CAMARO=0, FORD|MUSTANG=1
        assert loader.vehicle_to_id["CHEVY|CAMARO"] == 0
        assert loader.vehicle_to_id["FORD|MUSTANG"] == 1

    def test_load_nodes_deduplicates(self, gnn_config, mock_bq):
        """Duplicate rows in BQ output are deduplicated."""
        users_df = pd.DataFrame({
            "email_lower": ["a@test.com", "a@test.com", "b@test.com"],
            "v1_make": ["FORD", "FORD", "CHEVY"],
            "v1_model": ["MUSTANG", "MUSTANG", "CAMARO"],
            "v1_year": ["2020", "2020", "2019"],
            "has_email_consent": [True, True, True],
            "engagement_tier": ["cold", "cold", "warm"],
        })
        products_df = pd.DataFrame({
            "sku": ["SKU1", "SKU1"],
            "base_sku": ["SKU1", "SKU1"],
            "part_type": ["Ignition", "Ignition"],
            "price": [100.0, 100.0],
            "log_popularity": [2.0, 2.0],
            "fitment_breadth": [5, 5],
            "is_universal": [False, False],
        })
        vehicles_df = pd.DataFrame({
            "make": ["FORD", "FORD"],
            "model": ["MUSTANG", "MUSTANG"],
            "user_count": [2, 2],
            "product_count": [100, 100],
        })

        def mock_run_query(query, *args, **kwargs):
            if "user_nodes" in query:
                return users_df
            elif "product_nodes" in query:
                return products_df
            elif "vehicle_nodes" in query:
                return vehicles_df
            return pd.DataFrame()

        mock_bq.run_query = mock_run_query

        loader = GNNDataLoader(gnn_config, bq_client=mock_bq)
        nodes = loader.load_nodes()

        assert len(loader.user_to_id) == 2  # a and b, not 3
        assert len(loader.product_to_id) == 1  # SKU1 once
        assert len(loader.vehicle_to_id) == 1  # FORD|MUSTANG once
        assert len(nodes["users"]) == 2
        assert len(nodes["products"]) == 1
        assert len(nodes["vehicles"]) == 1

    def test_run_exports_uses_eval_baseline_table_precedence(self, gnn_config, mock_bq):
        """run_exports should prefer eval.baseline_table over output/default."""
        config = {
            **gnn_config,
            "eval": {**gnn_config["eval"], "baseline_table": "eval.table"},
            "output": {"baseline_table": "output.table"},
        }
        loader = GNNDataLoader(config, bq_client=mock_bq)
        loader.run_exports()

        called_files = [Path(call.args[0]).name for call in mock_bq.run_query_file.call_args_list]
        assert called_files == [
            "export_nodes.sql",
            "export_edges.sql",
            "export_test_set.sql",
            "export_sql_baseline.sql",
            "export_user_purchases.sql",
        ]
        for call in mock_bq.run_query_file.call_args_list:
            assert call.kwargs["params"]["BASELINE_TABLE"] == "eval.table"

    def test_run_exports_falls_back_to_output_baseline_table(self, gnn_config, mock_bq):
        """run_exports should use output.baseline_table when eval.baseline_table is absent."""
        config = {
            **gnn_config,
            "output": {"baseline_table": "output.table"},
        }
        loader = GNNDataLoader(config, bq_client=mock_bq)
        loader.run_exports()

        for call in mock_bq.run_query_file.call_args_list:
            assert call.kwargs["params"]["BASELINE_TABLE"] == "output.table"

    def test_run_exports_uses_default_baseline_table(self, gnn_config, mock_bq):
        """run_exports should use production default when no baseline table is configured."""
        loader = GNNDataLoader(gnn_config, bq_client=mock_bq)
        loader.run_exports()

        expected = "auxia-reporting.company_1950_jp.final_vehicle_recommendations"
        for call in mock_bq.run_query_file.call_args_list:
            assert call.kwargs["params"]["BASELINE_TABLE"] == expected

    def test_load_test_set_queries_expected_table(self, gnn_config, mock_bq):
        mock_bq.run_query.return_value = pd.DataFrame({"email_lower": ["a@test.com"]})

        loader = GNNDataLoader(gnn_config, bq_client=mock_bq)
        df = loader.load_test_set()

        assert len(df) == 1
        query = mock_bq.run_query.call_args.args[0]
        assert "test_interactions" in query

    def test_load_sql_baseline_queries_expected_table(self, gnn_config, mock_bq):
        mock_bq.run_query.return_value = pd.DataFrame({"email_lower": ["a@test.com"], "sku": ["SKU1"]})

        loader = GNNDataLoader(gnn_config, bq_client=mock_bq)
        df = loader.load_sql_baseline()

        assert len(df) == 1
        query = mock_bq.run_query.call_args.args[0]
        assert "sql_baseline" in query

    def test_load_user_purchases_groups_by_email(self, gnn_config, mock_bq):
        mock_bq.run_query.return_value = pd.DataFrame({
            "email_lower": ["a@test.com", "a@test.com", "b@test.com"],
            "base_sku": ["SKU1", "SKU2", "SKU3"],
        })

        loader = GNNDataLoader(gnn_config, bq_client=mock_bq)
        purchases = loader.load_user_purchases()

        assert purchases == {
            "a@test.com": {"SKU1", "SKU2"},
            "b@test.com": {"SKU3"},
        }
        query = mock_bq.run_query.call_args.args[0]
        assert "user_purchases" in query

    def test_load_user_purchases_returns_empty_on_query_error(self, gnn_config, mock_bq):
        mock_bq.run_query.side_effect = NotFound("table not found")

        loader = GNNDataLoader(gnn_config, bq_client=mock_bq)
        purchases = loader.load_user_purchases()

        assert purchases == {}

    def test_load_user_purchases_raises_on_non_notfound_errors(self, gnn_config, mock_bq):
        mock_bq.run_query.side_effect = RuntimeError("permission denied")

        loader = GNNDataLoader(gnn_config, bq_client=mock_bq)

        with pytest.raises(RuntimeError, match="permission denied"):
            loader.load_user_purchases()

    def test_load_user_purchases_validates_required_columns(self, gnn_config, mock_bq):
        mock_bq.run_query.return_value = pd.DataFrame({
            "email_lower": ["a@test.com"],
            "sku": ["SKU1"],
        })

        loader = GNNDataLoader(gnn_config, bq_client=mock_bq)

        with pytest.raises(ValueError, match="missing required columns"):
            loader.load_user_purchases()
