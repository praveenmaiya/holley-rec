"""BigQuery client with Streamlit caching."""

import os

import pandas as pd
from google.cloud import bigquery

BQ_PROJECT = "auxia-reporting"

_TESTING = os.environ.get("TESTING", "").lower() in ("1", "true")


def _cache_resource(func):
    if _TESTING:
        return func
    import streamlit as st

    return st.cache_resource(func)


def _cache_data(ttl=300):
    def decorator(func):
        if _TESTING:
            return func
        import streamlit as st

        return st.cache_data(ttl=ttl)(func)

    return decorator


@_cache_resource
def get_bq_client() -> bigquery.Client:
    """Return a cached BQ client."""
    return bigquery.Client(project=BQ_PROJECT)


@_cache_data(ttl=300)
def run_query(query: str, **params: str) -> pd.DataFrame:
    """Run a BQ query with string substitution, cached 5 min."""
    formatted = query.format(**params) if params else query
    client = get_bq_client()
    return client.query(formatted).to_dataframe()
