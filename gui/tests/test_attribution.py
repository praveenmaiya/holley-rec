import pandas as pd
from services.attribution import build_timeline


def test_purchase_before_email_is_history():
    purchases = pd.DataFrame(
        {
            "sku": ["SKU1"],
            "order_date": [pd.Timestamp("2024-06-15")],
            "part_type": ["Engine"],
        }
    )
    emails = pd.DataFrame(
        {
            "treatment_id": [16150700],
            "sent_date": [pd.Timestamp("2026-02-12")],
            "opened": [True],
            "clicked": [False],
            "treatment_tracking_id": ["TT-001"],
        }
    )
    recs = [
        {
            "slot": 1,
            "sku": "SKU-A",
            "price": 100,
            "score": 10,
            "image": "https://cdn/a.jpg",
            "score_tier": "segment",
        },
    ]

    timeline = build_timeline(purchases, emails, recs)
    history_events = [e for e in timeline if e.event_type == "purchase_before"]
    assert len(history_events) == 1
    assert history_events[0].sku == "SKU1"


def test_purchase_after_email_is_hit():
    purchases = pd.DataFrame(
        {
            "sku": ["SKU-A"],
            "order_date": [pd.Timestamp("2026-02-15")],
            "part_type": ["Engine"],
        }
    )
    emails = pd.DataFrame(
        {
            "treatment_id": [16150700],
            "sent_date": [pd.Timestamp("2026-02-12")],
            "opened": [True],
            "clicked": [True],
            "treatment_tracking_id": ["TT-001"],
        }
    )
    recs = [
        {
            "slot": 1,
            "sku": "SKU-A",
            "price": 849.95,
            "score": 47,
            "image": "https://cdn/a.jpg",
            "score_tier": "segment",
        },
    ]

    timeline = build_timeline(purchases, emails, recs)
    after_events = [e for e in timeline if e.event_type == "purchase_after"]
    assert len(after_events) == 1
    assert after_events[0].is_hit is True
    assert after_events[0].matched_slot == 1


def test_purchase_after_email_miss():
    purchases = pd.DataFrame(
        {
            "sku": ["UNRELATED-SKU"],
            "order_date": [pd.Timestamp("2026-02-20")],
            "part_type": ["Wheels"],
        }
    )
    emails = pd.DataFrame(
        {
            "treatment_id": [16150700],
            "sent_date": [pd.Timestamp("2026-02-12")],
            "opened": [True],
            "clicked": [False],
            "treatment_tracking_id": ["TT-001"],
        }
    )
    recs = [
        {
            "slot": 1,
            "sku": "SKU-A",
            "price": 100,
            "score": 10,
            "image": "https://cdn/a.jpg",
            "score_tier": "segment",
        },
    ]

    timeline = build_timeline(purchases, emails, recs)
    after_events = [e for e in timeline if e.event_type == "purchase_after"]
    assert len(after_events) == 1
    assert after_events[0].is_hit is False


def test_multi_email_attribution():
    purchases = pd.DataFrame(
        {
            "sku": ["SKU-B"],
            "order_date": [pd.Timestamp("2026-03-01")],
            "part_type": ["Exhaust"],
        }
    )
    emails = pd.DataFrame(
        {
            "treatment_id": [16150700, 16490932],
            "sent_date": [pd.Timestamp("2026-01-15"), pd.Timestamp("2026-02-20")],
            "opened": [True, True],
            "clicked": [False, False],
            "treatment_tracking_id": ["TT-001", "TT-002"],
        }
    )
    recs = [
        {
            "slot": 1,
            "sku": "SKU-A",
            "price": 100,
            "score": 10,
            "image": "https://cdn/a.jpg",
            "score_tier": "segment",
        },
    ]

    timeline = build_timeline(purchases, emails, recs)
    after_events = [e for e in timeline if e.event_type == "purchase_after"]
    assert len(after_events) == 1
    assert after_events[0].attributed_to_treatment == 16490932


def test_no_emails_all_purchases_are_before():
    purchases = pd.DataFrame(
        {
            "sku": ["SKU1", "SKU2"],
            "order_date": [pd.Timestamp("2024-01-10"), pd.Timestamp("2024-06-15")],
            "part_type": ["Engine", "Exhaust"],
        }
    )
    emails = pd.DataFrame(
        columns=["treatment_id", "sent_date", "opened", "clicked", "treatment_tracking_id"]
    )
    recs = []

    timeline = build_timeline(purchases, emails, recs)
    assert all(e.event_type == "purchase_before" for e in timeline)
    assert len(timeline) == 2


def test_timeline_is_chronologically_sorted():
    purchases = pd.DataFrame(
        {
            "sku": ["SKU1", "SKU2"],
            "order_date": [pd.Timestamp("2024-01-10"), pd.Timestamp("2026-03-01")],
            "part_type": ["Engine", "Exhaust"],
        }
    )
    emails = pd.DataFrame(
        {
            "treatment_id": [16150700],
            "sent_date": [pd.Timestamp("2026-02-12")],
            "opened": [True],
            "clicked": [False],
            "treatment_tracking_id": ["TT-001"],
        }
    )
    recs = []

    timeline = build_timeline(purchases, emails, recs)
    dates = [e.date for e in timeline]
    assert dates == sorted(dates)
