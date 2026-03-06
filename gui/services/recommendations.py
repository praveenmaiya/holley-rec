"""Fetch user recommendations from final_vehicle_recommendations."""

import pandas as pd

from services.bq_client import run_query

_RECS_TABLE = "auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations"


def get_user_recommendations(email_lower: str) -> list[dict]:
    """Get a user's 4 recommendation slots as a list of dicts."""
    query = f"""
    SELECT *
    FROM `{_RECS_TABLE}`
    WHERE email_lower = '{email_lower.replace(chr(39), "")}'
    LIMIT 1
    """
    df = run_query(query)
    if df.empty:
        return []

    row = df.iloc[0]
    recs = []
    for i in range(1, 5):
        sku = row.get(f"rec_part_{i}")
        if pd.isna(sku):
            continue
        recs.append(
            {
                "slot": i,
                "sku": sku,
                "price": row.get(f"rec{i}_price"),
                "score": row.get(f"rec{i}_score"),
                "image": row.get(f"rec{i}_image"),
                "score_tier": row.get(f"rec{i}_pop_source"),
            }
        )
    return recs
