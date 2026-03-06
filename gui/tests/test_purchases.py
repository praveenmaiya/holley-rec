from unittest.mock import patch

import pandas as pd
from services.purchases import get_purchase_history


def test_get_purchase_history_returns_orders():
    mock_df = pd.DataFrame(
        {
            "sku": ["SKU1", "SKU2"],
            "order_date": [pd.Timestamp("2024-01-10"), pd.Timestamp("2024-03-15")],
            "part_type": ["Fuel System", "Ignition"],
        }
    )
    with patch("services.purchases.run_query", return_value=mock_df):
        purchases = get_purchase_history("john@test.com")
        assert len(purchases) == 2
        assert purchases.iloc[0]["sku"] == "SKU1"


def test_get_purchase_history_excludes_service_skus():
    mock_df = pd.DataFrame(
        {
            "sku": ["SKU1"],
            "order_date": [pd.Timestamp("2024-01-10")],
            "part_type": ["Fuel System"],
        }
    )
    with patch("services.purchases.run_query", return_value=mock_df) as mock_run:
        get_purchase_history("john@test.com")
        query = mock_run.call_args[0][0]
        assert "EXT-%" in query
        assert "GIFT-%" in query
        assert "WARRANTY-%" in query
        assert "SERVICE-%" in query
        assert "PREAUTH-%" in query


def test_get_purchase_history_empty():
    with patch("services.purchases.run_query", return_value=pd.DataFrame()):
        purchases = get_purchase_history("noone@test.com")
        assert len(purchases) == 0
