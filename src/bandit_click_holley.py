#!/usr/bin/env python3
"""
Holley Click Bandit Analysis

Computes Beta-Binomial Thompson Sampling posterior parameters for email treatment optimization.
Adapted from JCOM's Click Bandit Model for Holley (company_1950).

Run via Metaflow:
    ./flows/run.sh src/bandit_click_holley.py
"""

import sys
import numpy as np
import pandas as pd
from google.cloud import bigquery

# Configuration
COMPANY_ID = "1950"
SURFACE_ID = 929
DATA_WINDOW_DAYS = 60
BQ_PROJECT = "auxia-reporting"

# Prior parameters for Beta distribution (uniform prior)
PRIOR_ALPHA = 1.0
PRIOR_BETA = 1.0


def get_treatment_ctr_data(
    company_id: str = COMPANY_ID,
    surface_id: int = SURFACE_ID,
    days: int = DATA_WINDOW_DAYS,
) -> pd.DataFrame:
    """Query BigQuery for treatment CTR data.

    Args:
        company_id: Company identifier
        surface_id: Surface to filter on (email surface)
        days: Number of days to look back

    Returns:
        DataFrame with treatment_id, views (n), clicks, ctr
    """
    query = f"""
    WITH sent AS (
        SELECT treatment_id, treatment_tracking_id
        FROM `auxia-gcp.company_{company_id}.treatment_history_sent`
        WHERE DATE(treatment_sent_timestamp)
            BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL {days} DAY)
            AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY)
        AND request_source = "LIVE"
        AND surface_id = {surface_id}
    ),
    views AS (
        SELECT DISTINCT treatment_tracking_id
        FROM `auxia-gcp.company_{company_id}.treatment_interaction`
        WHERE DATE(interaction_timestamp_micros)
            BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL {days} DAY)
            AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY)
        AND interaction_type = "VIEWED"
    ),
    clicks AS (
        SELECT DISTINCT treatment_tracking_id
        FROM `auxia-gcp.company_{company_id}.treatment_interaction`
        WHERE DATE(interaction_timestamp_micros)
            BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL {days} DAY)
            AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY)
        AND interaction_type = "CLICKED"
    )
    SELECT
        CAST(sent.treatment_id AS STRING) AS treatment_id,
        COUNT(DISTINCT views.treatment_tracking_id) AS n,
        COUNT(DISTINCT clicks.treatment_tracking_id) AS clicks
    FROM sent
    JOIN views ON sent.treatment_tracking_id = views.treatment_tracking_id
    LEFT JOIN clicks ON sent.treatment_tracking_id = clicks.treatment_tracking_id
    GROUP BY 1
    HAVING n > 0
    """

    client = bigquery.Client(project=BQ_PROJECT)
    df = client.query(query).to_dataframe()
    df["ctr"] = df["clicks"] / df["n"]
    return df


def compute_beta_posteriors(df: pd.DataFrame) -> pd.DataFrame:
    """Compute Beta posterior parameters for each treatment.

    Uses conjugate Beta-Binomial model:
    - Prior: Beta(alpha, beta)
    - Likelihood: Binomial(n, p)
    - Posterior: Beta(alpha + clicks, beta + n - clicks)

    Args:
        df: DataFrame with treatment_id, n (views), clicks

    Returns:
        DataFrame with posterior parameters (alpha, beta, mean, stddev)
    """
    results = []
    for _, row in df.iterrows():
        n = int(row["n"])
        clicks = int(row["clicks"])

        # Beta posterior parameters
        alpha_post = PRIOR_ALPHA + clicks
        beta_post = PRIOR_BETA + (n - clicks)

        # Posterior mean and variance for Beta distribution
        posterior_mean = alpha_post / (alpha_post + beta_post)
        posterior_var = (alpha_post * beta_post) / (
            (alpha_post + beta_post) ** 2 * (alpha_post + beta_post + 1)
        )

        results.append({
            "treatment_id": str(row["treatment_id"]),
            "alpha": alpha_post,
            "beta": beta_post,
            "posterior_mean": posterior_mean,
            "posterior_stddev": np.sqrt(posterior_var),
        })

    return pd.DataFrame(results)


def simulate_thompson_sampling(
    posterior_df: pd.DataFrame,
    n_simulations: int = 10000,
    seed: int = 42,
) -> pd.DataFrame:
    """Simulate Thompson Sampling treatment selection.

    For each simulated user:
    1. Sample CTR from Beta posterior for each treatment
    2. Select treatment with highest sampled CTR

    Args:
        posterior_df: DataFrame with alpha, beta per treatment
        n_simulations: Number of users to simulate
        seed: Random seed for reproducibility

    Returns:
        DataFrame with selection counts and percentages
    """
    rng = np.random.default_rng(seed)

    treatment_ids = posterior_df["treatment_id"].values
    alphas = posterior_df["alpha"].values
    betas = posterior_df["beta"].values

    # Sample from Beta posterior for each treatment x simulation
    # Shape: (n_simulations, n_treatments)
    samples = rng.beta(alphas, betas, size=(n_simulations, len(treatment_ids)))

    # Select treatment with max sampled CTR per simulation
    selected_idx = np.argmax(samples, axis=1)
    selected_treatments = treatment_ids[selected_idx]

    # Count selections
    unique, counts = np.unique(selected_treatments, return_counts=True)
    selection_df = pd.DataFrame({
        "treatment_id": unique,
        "selections": counts,
        "selection_pct": counts / n_simulations * 100,
    })

    return selection_df.sort_values("selection_pct", ascending=False)


def main() -> int:
    """Run Holley Click Bandit analysis."""
    print(f"Holley Click Bandit Analysis")
    print(f"Company: {COMPANY_ID} | Surface: {SURFACE_ID} | Window: {DATA_WINDOW_DAYS} days")
    print()

    # Fetch data
    print("Fetching treatment data from BigQuery...")
    try:
        df = get_treatment_ctr_data()
    except Exception as e:
        print(f"ERROR: Failed to fetch data: {e}")
        return 1

    if df.empty:
        print("No treatment data found for the specified criteria.")
        return 1

    total_views = df["n"].sum()
    total_clicks = df["clicks"].sum()
    print(f"Found {len(df)} treatments | {total_views:,} views | {total_clicks:,} clicks | {total_clicks/total_views:.2%} CTR")
    print()

    # Compute posteriors
    print("Computing Beta posteriors...")
    posterior_df = compute_beta_posteriors(df)

    # Merge for display
    full_df = posterior_df.merge(df[["treatment_id", "n", "clicks", "ctr"]], on="treatment_id")
    full_df = full_df.sort_values("posterior_mean", ascending=False)

    print("\nPosterior Parameters (sorted by mean):")
    display_cols = ["treatment_id", "n", "clicks", "ctr", "posterior_mean", "posterior_stddev"]
    print(full_df[display_cols].to_string(index=False))
    print()

    # Simulate selection
    print("Simulating Thompson Sampling (10K users)...")
    selection_df = simulate_thompson_sampling(posterior_df)

    # Merge for comparison
    comparison = selection_df.merge(
        full_df[["treatment_id", "posterior_mean", "ctr", "n"]],
        on="treatment_id"
    )

    print("\nExpected Selection Distribution:")
    print(comparison.to_string(index=False))
    print()

    # Summary
    top = comparison.iloc[0]
    print(f"Top treatment: {top['treatment_id']}")
    print(f"  Expected selection: {top['selection_pct']:.1f}%")
    print(f"  Posterior mean CTR: {top['posterior_mean']:.4f}")
    print(f"  Observed CTR: {top['ctr']:.4f} ({int(top['n']):,} views)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
