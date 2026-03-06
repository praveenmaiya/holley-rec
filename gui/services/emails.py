"""Fetch email send and interaction events from BigQuery."""

import pandas as pd

from services.bq_client import run_query


def get_email_events(user_id: str) -> pd.DataFrame:
    """Get all email events for a user: sends with open/click status."""
    query = f"""
    WITH sends AS (
      SELECT
        treatment_id,
        treatment_tracking_id,
        DATE(treatment_sent_timestamp) AS sent_date
      FROM `auxia-gcp.company_1950.treatment_history_sent`
      WHERE user_id = '{user_id.replace(chr(39), "")}'
        AND request_source = 'LIVE'
        AND surface_id = 929
    ),
    opens AS (
      SELECT DISTINCT treatment_tracking_id
      FROM `auxia-gcp.company_1950.treatment_interaction`
      WHERE interaction_type = 'VIEWED'
    ),
    clicks AS (
      SELECT DISTINCT treatment_tracking_id
      FROM `auxia-gcp.company_1950.treatment_interaction`
      WHERE interaction_type = 'CLICKED'
    )
    SELECT
      s.treatment_id,
      s.treatment_tracking_id,
      s.sent_date,
      o.treatment_tracking_id IS NOT NULL AS opened,
      c.treatment_tracking_id IS NOT NULL AS clicked
    FROM sends s
    LEFT JOIN opens o USING (treatment_tracking_id)
    LEFT JOIN clicks c USING (treatment_tracking_id)
    ORDER BY s.sent_date
    """
    return run_query(query)
