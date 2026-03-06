from unittest.mock import patch

import pandas as pd
from services.recommendations import get_user_recommendations


def test_get_user_recommendations_returns_4_slots():
    mock_df = pd.DataFrame(
        {
            "email_lower": ["john@test.com"],
            "rec_part_1": ["SKU1"],
            "rec1_price": [849.95],
            "rec1_score": [47.0],
            "rec1_image": ["https://cdn/img1.jpg"],
            "rec1_pop_source": ["segment"],
            "rec_part_2": ["SKU2"],
            "rec2_price": [599.99],
            "rec2_score": [38.0],
            "rec2_image": ["https://cdn/img2.jpg"],
            "rec2_pop_source": ["segment"],
            "rec_part_3": ["SKU3"],
            "rec3_price": [329.95],
            "rec3_score": [24.0],
            "rec3_image": ["https://cdn/img3.jpg"],
            "rec3_pop_source": ["make"],
            "rec_part_4": ["SKU4"],
            "rec4_price": [449.95],
            "rec4_score": [19.0],
            "rec4_image": ["https://cdn/img4.jpg"],
            "rec4_pop_source": ["make"],
        }
    )
    with patch("services.recommendations.run_query", return_value=mock_df):
        recs = get_user_recommendations("john@test.com")
        assert len(recs) == 4
        assert recs[0]["sku"] == "SKU1"
        assert recs[0]["price"] == 849.95
        assert recs[0]["image"] == "https://cdn/img1.jpg"
        assert recs[0]["score_tier"] == "segment"


def test_get_user_recommendations_handles_3_slots():
    mock_df = pd.DataFrame(
        {
            "email_lower": ["john@test.com"],
            "rec_part_1": ["SKU1"],
            "rec1_price": [100.0],
            "rec1_score": [10.0],
            "rec1_image": ["https://cdn/1.jpg"],
            "rec1_pop_source": ["segment"],
            "rec_part_2": ["SKU2"],
            "rec2_price": [90.0],
            "rec2_score": [8.0],
            "rec2_image": ["https://cdn/2.jpg"],
            "rec2_pop_source": ["make"],
            "rec_part_3": ["SKU3"],
            "rec3_price": [80.0],
            "rec3_score": [6.0],
            "rec3_image": ["https://cdn/3.jpg"],
            "rec3_pop_source": ["make"],
            "rec_part_4": [None],
            "rec4_price": [None],
            "rec4_score": [None],
            "rec4_image": [None],
            "rec4_pop_source": [None],
        }
    )
    with patch("services.recommendations.run_query", return_value=mock_df):
        recs = get_user_recommendations("john@test.com")
        assert len(recs) == 3


def test_get_user_recommendations_empty():
    with patch("services.recommendations.run_query", return_value=pd.DataFrame()):
        recs = get_user_recommendations("noone@test.com")
        assert recs == []
