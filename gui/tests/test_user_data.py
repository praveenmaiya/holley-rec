from unittest.mock import patch

import pandas as pd
from services.user_data import get_random_users, get_user_vehicle, search_users


def test_search_users_by_email():
    mock_df = pd.DataFrame(
        {
            "user_id": ["U123"],
            "email_lower": ["john@test.com"],
            "v1_year": ["2019"],
            "v1_make": ["FORD"],
            "v1_model": ["MUSTANG"],
        }
    )
    with patch("services.user_data.run_query", return_value=mock_df):
        result = search_users(email="john@test.com")
        assert len(result) == 1
        assert result.iloc[0]["v1_make"] == "FORD"


def test_search_users_by_vehicle():
    mock_df = pd.DataFrame(
        {
            "user_id": ["U1", "U2"],
            "email_lower": ["a@test.com", "b@test.com"],
            "v1_year": ["2019", "2019"],
            "v1_make": ["FORD", "FORD"],
            "v1_model": ["MUSTANG", "MUSTANG"],
        }
    )
    with patch("services.user_data.run_query", return_value=mock_df):
        result = search_users(year="2019", make="FORD", model="MUSTANG")
        assert len(result) == 2


def test_get_user_vehicle():
    mock_df = pd.DataFrame(
        {
            "user_id": ["U123"],
            "email_lower": ["john@test.com"],
            "v1_year": ["2019"],
            "v1_make": ["FORD"],
            "v1_model": ["MUSTANG GT"],
        }
    )
    with patch("services.user_data.run_query", return_value=mock_df):
        result = get_user_vehicle("john@test.com")
        assert result["user_id"] == "U123"
        assert result["v1_model"] == "MUSTANG GT"


def test_get_user_vehicle_not_found():
    with patch("services.user_data.run_query", return_value=pd.DataFrame()):
        result = get_user_vehicle("noone@test.com")
        assert result == {}


def test_get_random_users():
    mock_df = pd.DataFrame(
        {
            "user_id": ["U1"],
            "email_lower": ["a@test.com"],
            "v1_year": ["2020"],
            "v1_make": ["CHEVROLET"],
            "v1_model": ["CAMARO"],
        }
    )
    with patch("services.user_data.run_query", return_value=mock_df):
        result = get_random_users(10)
        assert len(result) == 1
