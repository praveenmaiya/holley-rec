"""Pytest configuration and fixtures."""

import pandas as pd
import pytest


@pytest.fixture
def sample_interactions():
    """Sample interaction data for testing."""
    return pd.DataFrame({
        "user_id": [1, 1, 1, 2, 2, 3, 3, 3, 3],
        "item_id": [10, 20, 30, 10, 40, 20, 30, 40, 50],
        "timestamp": pd.date_range("2024-01-01", periods=9, freq="D"),
        "interaction_type": ["view"] * 5 + ["purchase"] * 4,
    })


@pytest.fixture
def sample_predictions():
    """Sample predictions for evaluation testing."""
    return {
        1: [10, 20, 30, 40, 50],  # User 1 predictions
        2: [40, 10, 20, 30, 50],  # User 2 predictions
        3: [50, 40, 30, 20, 10],  # User 3 predictions
    }


@pytest.fixture
def sample_actuals():
    """Sample ground truth for evaluation testing."""
    return {
        1: {10, 20, 30},  # User 1 actual items
        2: {10, 40},       # User 2 actual items
        3: {20, 30, 40, 50},  # User 3 actual items
    }


@pytest.fixture
def mock_config():
    """Mock configuration for testing."""
    return {
        "project_id": "test-project",
        "dataset": "test_dataset",
        "model": {
            "factors": 32,
            "iterations": 5,
        },
        "limits": {
            "max_users": 100,
            "max_items": 50,
        },
        "wandb": {
            "project": "test-project",
        },
    }


@pytest.fixture
def mock_bq_client(mocker):
    """Mock BigQuery client."""
    client = mocker.Mock()
    client.run_query.return_value = pd.DataFrame({
        "user_id": [1, 2, 3],
        "item_id": [10, 20, 30],
        "score": [0.9, 0.8, 0.7],
    })
    client.project = "test-project"
    client.dataset = "test_dataset"
    return client
