"""User lookup and vehicle data from BigQuery."""

import pandas as pd

from services.bq_client import run_query

_USER_VEHICLE_SQL = """
SELECT
  u.user_id,
  MAX(IF(LOWER(p.property_name) = 'email', LOWER(TRIM(p.string_value)), NULL)) AS email_lower,
  MAX(IF(LOWER(p.property_name) = 'v1_year',
    COALESCE(TRIM(p.string_value), CAST(p.long_value AS STRING)), NULL)) AS v1_year,
  MAX(IF(LOWER(p.property_name) = 'v1_make', UPPER(TRIM(p.string_value)), NULL)) AS v1_make,
  MAX(IF(LOWER(p.property_name) = 'v1_model', UPPER(TRIM(p.string_value)), NULL)) AS v1_model
FROM `auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental` u,
  UNNEST(user_properties) AS p
WHERE LOWER(p.property_name) IN ('email', 'v1_year', 'v1_make', 'v1_model')
GROUP BY u.user_id
HAVING email_lower IS NOT NULL
"""


def search_users(
    email: str | None = None,
    year: str | None = None,
    make: str | None = None,
    model: str | None = None,
    limit: int = 50,
) -> pd.DataFrame:
    """Search users by email or vehicle. Returns DataFrame of matches."""
    conditions = []
    if email:
        conditions.append(f"email_lower LIKE '%{email.lower().replace(chr(39), '')}%'")
    if year:
        conditions.append(f"v1_year = '{year}'")
    if make:
        conditions.append(f"v1_make = '{make.upper()}'")
    if model:
        conditions.append(f"v1_model LIKE '%{model.upper()}%'")

    where = " AND ".join(conditions) if conditions else "TRUE"

    query = f"""
    WITH users AS ({_USER_VEHICLE_SQL})
    SELECT * FROM users
    WHERE {where}
    LIMIT {limit}
    """
    return run_query(query)


def get_user_vehicle(email_lower: str) -> dict:
    """Get single user's vehicle info + user_id."""
    query = f"""
    WITH users AS ({_USER_VEHICLE_SQL})
    SELECT * FROM users
    WHERE email_lower = '{email_lower.lower().replace(chr(39), "")}'
    LIMIT 1
    """
    df = run_query(query)
    if df.empty:
        return {}
    return df.iloc[0].to_dict()


def get_random_users(n: int = 10, buyers_only: bool = False) -> pd.DataFrame:
    """Get random sample of users, optionally filtered to buyers."""
    buyer_join = ""
    if buyers_only:
        buyer_join = """
        INNER JOIN (
          SELECT DISTINCT LOWER(TRIM(SHIP_TO_EMAIL)) AS email_lower
          FROM `auxia-gcp.data_company_1950.import_orders`
          WHERE ITEM IS NOT NULL
        ) buyers USING (email_lower)
        """

    query = f"""
    WITH users AS ({_USER_VEHICLE_SQL})
    SELECT u.* FROM users u
    {buyer_join}
    ORDER BY RAND()
    LIMIT {n}
    """
    return run_query(query)
