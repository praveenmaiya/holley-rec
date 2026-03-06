from unittest.mock import patch

import pandas as pd
from services.user_data import get_random_users, search_users


def _mock_user_df():
    return pd.DataFrame(
        {
            "user_id": ["U123"],
            "email_lower": ["john@test.com"],
            "v1_year": ["2019"],
            "v1_make": ["FORD"],
            "v1_model": ["MUSTANG"],
            "rec_part_1": ["SKU1"],
            "rec1_price": [199.95],
            "rec1_image": ["https://images.holley.com/test1.jpg"],
            "rec_part_2": ["SKU2"],
            "rec2_price": [299.95],
            "rec2_image": ["https://images.holley.com/test2.jpg"],
            "rec_part_3": [None],
            "rec3_price": [None],
            "rec3_image": [None],
            "rec_part_4": [None],
            "rec4_price": [None],
            "rec4_image": [None],
        }
    )


def test_search_users_by_email():
    with patch("services.user_data.run_query", return_value=_mock_user_df()):
        result = search_users(email="john@test.com")
        assert len(result) == 1
        assert result.iloc[0]["v1_make"] == "FORD"
        assert result.iloc[0]["rec_part_1"] == "SKU1"


def test_search_users_by_vehicle():
    mock_df = pd.concat([_mock_user_df(), _mock_user_df()], ignore_index=True)
    mock_df.loc[1, "email_lower"] = "jane@test.com"
    with patch("services.user_data.run_query", return_value=mock_df):
        result = search_users(year="2019", make="FORD", model="MUSTANG")
        assert len(result) == 2


def test_get_random_users():
    with patch("services.user_data.run_query", return_value=_mock_user_df()):
        result = get_random_users(25)
        assert len(result) == 1
        assert "rec1_image" in result.columns
