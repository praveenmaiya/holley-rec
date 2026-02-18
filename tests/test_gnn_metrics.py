"""Tests for hit_rate_at_k and mrr metrics."""

import math

import pytest

from src.metrics import (
    catalog_coverage,
    compute_all_metrics,
    hit_rate_at_k,
    mean_average_precision,
    mrr,
    ndcg_at_k,
    precision_at_k,
    recall_at_k,
)


class TestHitRateAtK:
    def test_hit_at_top(self):
        assert hit_rate_at_k([1, 2, 3, 4], {1}, k=4) == 1.0

    def test_hit_at_last_position(self):
        assert hit_rate_at_k([1, 2, 3, 4], {4}, k=4) == 1.0

    def test_no_hit(self):
        assert hit_rate_at_k([1, 2, 3, 4], {5}, k=4) == 0.0

    def test_hit_beyond_k(self):
        assert hit_rate_at_k([1, 2, 3, 4, 5], {5}, k=4) == 0.0

    def test_empty_predictions(self):
        assert hit_rate_at_k([], {1, 2}, k=4) == 0.0

    def test_empty_actuals(self):
        assert hit_rate_at_k([1, 2, 3], set(), k=4) == 0.0

    def test_multiple_hits(self):
        assert hit_rate_at_k([1, 2, 3, 4], {1, 2, 3}, k=4) == 1.0


class TestMRR:
    def test_first_position(self):
        assert mrr([1, 2, 3], {1}) == 1.0

    def test_second_position(self):
        assert mrr([1, 2, 3], {2}) == 0.5

    def test_third_position(self):
        assert mrr([1, 2, 3], {3}) == pytest.approx(1 / 3)

    def test_no_match(self):
        assert mrr([1, 2, 3], {4}) == 0.0

    def test_empty(self):
        assert mrr([], {1}) == 0.0
        assert mrr([1], set()) == 0.0

    def test_multiple_relevant(self):
        # MRR only cares about the first relevant item
        assert mrr([1, 2, 3], {2, 3}) == 0.5


class TestComputeAllMetrics:
    def test_includes_hit_rate_and_mrr(self):
        preds = {1: [10, 20, 30, 40, 50]}
        actuals = {1: {10, 30}}
        results = compute_all_metrics(preds, actuals, k_values=[4, 10])

        assert "hit_rate_at_4" in results
        assert "hit_rate_at_10" in results
        assert "mrr" in results
        assert results["hit_rate_at_4"] == 1.0
        assert results["mrr"] == 1.0

    def test_includes_catalog_coverage_when_catalog_size_provided(self):
        preds = {1: [10, 20, 30], 2: [20, 40, 50]}
        actuals = {1: {10}, 2: {20}}
        results = compute_all_metrics(preds, actuals, k_values=[3], catalog_size=100)

        assert "catalog_coverage" in results
        assert results["catalog_coverage"] == pytest.approx(5 / 100)

    def test_empty_inputs_return_zero_metrics(self):
        results = compute_all_metrics({}, {}, k_values=[4, 10])

        assert results["precision_at_4"] == 0.0
        assert results["recall_at_10"] == 0.0
        assert results["hit_rate_at_4"] == 0.0
        assert results["mrr"] == 0.0
        assert results["num_users_evaluated"] == 0


class TestOtherMetricFunctions:
    def test_precision_recall_ndcg_known_values(self):
        preds = [1, 2, 3, 4]
        actuals = {1, 3}

        assert precision_at_k(preds, actuals, k=4) == pytest.approx(0.5)
        assert recall_at_k(preds, actuals, k=4) == pytest.approx(1.0)
        expected_dcg = 1.0 + (1.0 / math.log2(4.0))
        expected_idcg = 1.0 + (1.0 / math.log2(3.0))
        assert ndcg_at_k(preds, actuals, k=4) == pytest.approx(expected_dcg / expected_idcg)

    def test_map_known_value(self):
        preds = [1, 2, 3, 4]
        actuals = {1, 3}
        # AP = (1/1 + 2/3) / 2
        assert mean_average_precision(preds, actuals) == pytest.approx((1.0 + (2.0 / 3.0)) / 2.0)

    def test_catalog_coverage_uses_top_k(self):
        all_preds = [[1, 2, 3], [3, 4, 5], [5, 6, 7]]
        assert catalog_coverage(all_preds, catalog_size=10, k=2) == pytest.approx(6 / 10)
