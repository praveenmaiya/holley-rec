"""Fetch user purchase history from import_orders + import_items."""

import pandas as pd

from services.bq_client import run_query


def get_purchase_history(email_lower: str) -> pd.DataFrame:
    """Get all purchases for a user, enriched with product catalog data."""
    query = f"""
    WITH orders AS (
      SELECT
        REGEXP_REPLACE(UPPER(TRIM(o.ITEM)), r'([0-9])[BRGP]$', r'\\1') AS sku,
        SAFE.PARSE_DATE('%A, %B %d, %Y', o.ORDER_DATE) AS order_date
      FROM `auxia-gcp.data_company_1950.import_orders` o
      WHERE LOWER(TRIM(o.SHIP_TO_EMAIL)) = '{email_lower.replace(chr(39), "")}'
        AND o.ITEM IS NOT NULL
        AND NOT (o.ITEM LIKE 'EXT-%' OR o.ITEM LIKE 'GIFT-%'
                 OR o.ITEM LIKE 'WARRANTY-%' OR o.ITEM LIKE 'SERVICE-%'
                 OR o.ITEM LIKE 'PREAUTH-%')
    ),
    products AS (
      SELECT
        UPPER(TRIM(PartNumber)) AS sku,
        MAX(PartType) AS part_type
      FROM `auxia-gcp.data_company_1950.import_items`
      GROUP BY 1
    )
    SELECT DISTINCT
      o.sku,
      o.order_date,
      p.part_type
    FROM orders o
    LEFT JOIN products p ON o.sku = p.sku
    WHERE o.order_date IS NOT NULL
    ORDER BY o.order_date
    """
    return run_query(query)
