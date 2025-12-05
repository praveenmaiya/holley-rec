"""Data splitting strategies for evaluation."""

import pandas as pd
from typing import Tuple
import logging

logger = logging.getLogger(__name__)


def time_split(
    df: pd.DataFrame,
    timestamp_col: str = "timestamp",
    train_ratio: float = 0.8,
    cutoff_date: str = None,
) -> Tuple[pd.DataFrame, pd.DataFrame]:
    """Split data by time.

    Args:
        df: DataFrame with interactions.
        timestamp_col: Name of timestamp column.
        train_ratio: Fraction of data for training (if cutoff_date not specified).
        cutoff_date: Explicit cutoff date string (YYYY-MM-DD).

    Returns:
        Tuple of (train_df, test_df).
    """
    df = df.copy()

    if timestamp_col not in df.columns:
        raise ValueError(f"Column {timestamp_col} not found in DataFrame")

    # Ensure timestamp is datetime
    df[timestamp_col] = pd.to_datetime(df[timestamp_col])
    df = df.sort_values(timestamp_col)

    if cutoff_date:
        cutoff = pd.to_datetime(cutoff_date)
    else:
        # Use quantile-based cutoff
        cutoff = df[timestamp_col].quantile(train_ratio)

    train_df = df[df[timestamp_col] < cutoff]
    test_df = df[df[timestamp_col] >= cutoff]

    logger.info(
        f"Time split: train={len(train_df)} ({len(train_df)/len(df)*100:.1f}%), "
        f"test={len(test_df)} ({len(test_df)/len(df)*100:.1f}%)"
    )

    return train_df, test_df


def user_split(
    df: pd.DataFrame,
    user_col: str = "user_id",
    train_ratio: float = 0.8,
    random_state: int = 42,
) -> Tuple[pd.DataFrame, pd.DataFrame]:
    """Split data by user (holdout users).

    Args:
        df: DataFrame with interactions.
        user_col: Name of user ID column.
        train_ratio: Fraction of users for training.
        random_state: Random seed for reproducibility.

    Returns:
        Tuple of (train_df, test_df).
    """
    if user_col not in df.columns:
        raise ValueError(f"Column {user_col} not found in DataFrame")

    users = df[user_col].unique()
    n_train = int(len(users) * train_ratio)

    rng = pd.np.random.default_rng(random_state)
    shuffled_users = rng.permutation(users)

    train_users = set(shuffled_users[:n_train])
    test_users = set(shuffled_users[n_train:])

    train_df = df[df[user_col].isin(train_users)]
    test_df = df[df[user_col].isin(test_users)]

    logger.info(
        f"User split: train_users={len(train_users)}, test_users={len(test_users)}, "
        f"train_interactions={len(train_df)}, test_interactions={len(test_df)}"
    )

    return train_df, test_df


def leave_one_out_split(
    df: pd.DataFrame,
    user_col: str = "user_id",
    timestamp_col: str = "timestamp",
) -> Tuple[pd.DataFrame, pd.DataFrame]:
    """Leave-one-out split: last interaction per user for test.

    Args:
        df: DataFrame with interactions.
        user_col: Name of user ID column.
        timestamp_col: Name of timestamp column.

    Returns:
        Tuple of (train_df, test_df).
    """
    df = df.copy()
    df[timestamp_col] = pd.to_datetime(df[timestamp_col])

    # Get index of last interaction per user
    idx_last = df.groupby(user_col)[timestamp_col].idxmax()

    test_df = df.loc[idx_last]
    train_df = df.drop(idx_last)

    logger.info(
        f"Leave-one-out split: train={len(train_df)}, test={len(test_df)} (one per user)"
    )

    return train_df, test_df
