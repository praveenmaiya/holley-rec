"""Tests for evaluation metrics."""

import pytest
from src.evaluation.metrics import (
    precision_at_k,
    recall_at_k,
    ndcg_at_k,
    mean_average_precision,
    compute_all_metrics,
)


class TestPrecisionAtK:
    """Tests for precision@k metric."""

    def test_perfect_precision(self):
        """All predictions are relevant."""
        predictions = [1, 2, 3, 4, 5]
        actuals = {1, 2, 3, 4, 5}
        assert precision_at_k(predictions, actuals, k=5) == 1.0

    def test_zero_precision(self):
        """No predictions are relevant."""
        predictions = [1, 2, 3, 4, 5]
        actuals = {6, 7, 8, 9, 10}
        assert precision_at_k(predictions, actuals, k=5) == 0.0

    def test_partial_precision(self):
        """Some predictions are relevant."""
        predictions = [1, 2, 3, 4, 5]
        actuals = {1, 3, 5}
        assert precision_at_k(predictions, actuals, k=5) == 0.6

    def test_k_larger_than_predictions(self):
        """K is larger than prediction list."""
        predictions = [1, 2, 3]
        actuals = {1, 2, 3}
        # Should still work, dividing by k
        assert precision_at_k(predictions, actuals, k=5) == 0.6

    def test_empty_predictions(self):
        """Empty predictions list."""
        assert precision_at_k([], {1, 2, 3}, k=5) == 0.0

    def test_empty_actuals(self):
        """Empty actuals set."""
        assert precision_at_k([1, 2, 3], set(), k=5) == 0.0


class TestRecallAtK:
    """Tests for recall@k metric."""

    def test_perfect_recall(self):
        """All actuals are in predictions."""
        predictions = [1, 2, 3, 4, 5]
        actuals = {1, 2, 3}
        assert recall_at_k(predictions, actuals, k=5) == 1.0

    def test_zero_recall(self):
        """No actuals are in predictions."""
        predictions = [1, 2, 3, 4, 5]
        actuals = {6, 7, 8}
        assert recall_at_k(predictions, actuals, k=5) == 0.0

    def test_partial_recall(self):
        """Some actuals are in predictions."""
        predictions = [1, 2, 3, 4, 5]
        actuals = {1, 6, 7, 8}
        assert recall_at_k(predictions, actuals, k=5) == 0.25


class TestNDCGAtK:
    """Tests for NDCG@k metric."""

    def test_perfect_ndcg(self):
        """Ideal ranking."""
        predictions = [1, 2, 3]
        actuals = {1, 2, 3}
        assert ndcg_at_k(predictions, actuals, k=3) == 1.0

    def test_zero_ndcg(self):
        """No relevant items."""
        predictions = [1, 2, 3]
        actuals = {4, 5, 6}
        assert ndcg_at_k(predictions, actuals, k=3) == 0.0

    def test_ndcg_ordering_matters(self):
        """NDCG should prefer relevant items at top."""
        actuals = {1}
        # Item at position 1
        pred1 = [1, 2, 3]
        # Item at position 3
        pred2 = [2, 3, 1]
        assert ndcg_at_k(pred1, actuals, k=3) > ndcg_at_k(pred2, actuals, k=3)


class TestMAP:
    """Tests for Mean Average Precision."""

    def test_perfect_map(self):
        """All predictions relevant in order."""
        predictions = [1, 2, 3]
        actuals = {1, 2, 3}
        assert mean_average_precision(predictions, actuals) == 1.0

    def test_zero_map(self):
        """No relevant predictions."""
        predictions = [1, 2, 3]
        actuals = {4, 5, 6}
        assert mean_average_precision(predictions, actuals) == 0.0


class TestComputeAllMetrics:
    """Tests for compute_all_metrics function."""

    def test_basic_computation(self, sample_predictions, sample_actuals):
        """Test basic metric computation."""
        metrics = compute_all_metrics(
            sample_predictions,
            sample_actuals,
            k_values=[5],
        )

        assert "precision_at_5" in metrics
        assert "recall_at_5" in metrics
        assert "ndcg_at_5" in metrics
        assert "map" in metrics
        assert metrics["num_users_evaluated"] == 3

    def test_empty_input(self):
        """Handle empty input gracefully."""
        metrics = compute_all_metrics({}, {})
        assert metrics["num_users_evaluated"] == 0

    def test_with_catalog_coverage(self, sample_predictions, sample_actuals):
        """Test catalog coverage computation."""
        metrics = compute_all_metrics(
            sample_predictions,
            sample_actuals,
            k_values=[5],
            catalog_size=100,
        )
        assert "catalog_coverage" in metrics
        assert 0 <= metrics["catalog_coverage"] <= 1
