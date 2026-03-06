from unittest.mock import patch

import pandas as pd
from services.treatments import (
    _pg_cache,
    get_treatment_name,
    get_treatment_type,
)


def test_get_treatment_name_personalized():
    name = get_treatment_name(16150700)
    assert name != "" and name != "Treatment 16150700"


def test_get_treatment_type_personalized():
    assert get_treatment_type(16150700) == "Personalized"


def test_get_treatment_type_static():
    assert get_treatment_type(16490932) == "Static"


def test_get_treatment_type_unknown():
    with patch("services.bq_client.run_query", return_value=pd.DataFrame()):
        _pg_cache.pop(99999999, None)
        assert get_treatment_type(99999999) == "Unknown"


def test_get_treatment_name_unknown():
    with patch("services.bq_client.run_query", return_value=pd.DataFrame()):
        _pg_cache.pop(99999999, None)
        name = get_treatment_name(99999999)
        assert name == "Treatment 99999999"


def test_pg_fallback_personalized():
    """Treatment not in CSV but found in PostgreSQL with 'personalized' in name."""
    mock_df = pd.DataFrame(
        {"treatment_id": [12345678], "name": ["Personalized Vehicle Fitment Recs"]}
    )
    with patch("services.bq_client.run_query", return_value=mock_df):
        _pg_cache.pop(12345678, None)
        assert get_treatment_name(12345678) == "Personalized Vehicle Fitment Recs"
        assert get_treatment_type(12345678) == "Personalized"


def test_pg_fallback_static():
    """Treatment not in CSV, found in PostgreSQL without 'personalized' in name."""
    mock_df = pd.DataFrame({"treatment_id": [87654321], "name": ["Static Weekly Deals"]})
    with patch("services.bq_client.run_query", return_value=mock_df):
        _pg_cache.pop(87654321, None)
        assert get_treatment_name(87654321) == "Static Weekly Deals"
        assert get_treatment_type(87654321) == "Static"
