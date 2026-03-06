from unittest.mock import patch

import pandas as pd
from services.emails import get_email_events


def test_get_email_events_returns_send_with_interactions():
    mock_df = pd.DataFrame(
        {
            "treatment_id": [16150700],
            "treatment_tracking_id": ["TT-001"],
            "sent_date": [pd.Timestamp("2026-02-12")],
            "opened": [True],
            "clicked": [True],
        }
    )
    with patch("services.emails.run_query", return_value=mock_df):
        events = get_email_events("U123")
        assert len(events) == 1
        assert bool(events.iloc[0]["opened"]) is True
        assert bool(events.iloc[0]["clicked"]) is True


def test_get_email_events_multiple_emails():
    mock_df = pd.DataFrame(
        {
            "treatment_id": [16150700, 16490932],
            "treatment_tracking_id": ["TT-001", "TT-002"],
            "sent_date": [pd.Timestamp("2026-01-15"), pd.Timestamp("2026-02-12")],
            "opened": [True, False],
            "clicked": [False, False],
        }
    )
    with patch("services.emails.run_query", return_value=mock_df):
        events = get_email_events("U123")
        assert len(events) == 2


def test_get_email_events_empty():
    with patch("services.emails.run_query", return_value=pd.DataFrame()):
        events = get_email_events("U999")
        assert len(events) == 0
