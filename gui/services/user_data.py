"""User lookup from final_vehicle_recommendations (VFU users only)."""

import pandas as pd

from services.bq_client import run_query

_RECS_TABLE = "auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations"

# Resolve email → user_id (one per email, needed for email events lookup)
_USER_ID_SQL = """
SELECT
  ANY_VALUE(u.user_id) AS user_id,
  LOWER(TRIM(p.string_value)) AS email_lower
FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental` u,
  UNNEST(user_properties) AS p
WHERE LOWER(p.property_name) = 'email'
  AND p.string_value IS NOT NULL
GROUP BY email_lower
"""

# Columns to select from recs table (includes images for list view thumbnails)
_REC_COLS = """
  r.email_lower,
  r.v1_year,
  UPPER(r.v1_make) AS v1_make,
  UPPER(r.v1_model) AS v1_model,
  r.rec_part_1, r.rec1_price, r.rec1_image,
  r.rec_part_2, r.rec2_price, r.rec2_image,
  r.rec_part_3, r.rec3_price, r.rec3_image,
  r.rec_part_4, r.rec4_price, r.rec4_image
"""


def search_users(
    email: str | None = None,
    year: str | None = None,
    make: str | None = None,
    model: str | None = None,
    limit: int = 25,
) -> pd.DataFrame:
    """Search VFU users by email or vehicle. Queries recs table directly."""
    conditions = []
    if email:
        conditions.append(f"r.email_lower LIKE '%{email.lower().replace(chr(39), '')}%'")
    if year:
        conditions.append(f"r.v1_year = '{year}'")
    if make:
        conditions.append(f"UPPER(r.v1_make) = '{make.upper()}'")
    if model:
        conditions.append(f"UPPER(r.v1_model) LIKE '%{model.upper()}%'")

    where = " AND ".join(conditions) if conditions else "TRUE"

    query = f"""
    WITH uid AS ({_USER_ID_SQL})
    SELECT
      uid.user_id,
      {_REC_COLS}
    FROM `{_RECS_TABLE}` r
    LEFT JOIN uid ON r.email_lower = uid.email_lower
    WHERE {where}
    LIMIT {limit}
    """
    return run_query(query)


def get_random_users(n: int = 25, buyers_only: bool = False) -> pd.DataFrame:
    """Get random VFU users, optionally filtered to buyers."""
    buyer_join = ""
    if buyers_only:
        buyer_join = """
        INNER JOIN (
          SELECT DISTINCT LOWER(TRIM(SHIP_TO_EMAIL)) AS email_lower
          FROM `auxia-gcp.data_company_1950.import_orders`
          WHERE ITEM IS NOT NULL
        ) buyers ON r.email_lower = buyers.email_lower
        """

    query = f"""
    WITH uid AS ({_USER_ID_SQL})
    SELECT
      uid.user_id,
      {_REC_COLS}
    FROM `{_RECS_TABLE}` r
    LEFT JOIN uid ON r.email_lower = uid.email_lower
    {buyer_join}
    ORDER BY RAND()
    LIMIT {n}
    """
    return run_query(query)
