"""Tests for rec_engine.core.metrics — evaluation metrics."""

from rec_engine.core.metrics import (
    catalog_coverage,
    hit_rate_at_k,
    mean_average_precision,
    mrr,
    ndcg_at_k,
    precision_at_k,
    recall_at_k,
)


class TestHitRateAtK:
    def test_hit(self):
        assert hit_rate_at_k([1, 2, 3], {2}, k=4) == 1.0

    def test_miss(self):
        assert hit_rate_at_k([1, 2, 3], {5}, k=4) == 0.0

    def test_empty_predictions(self):
        assert hit_rate_at_k([], {1}, k=4) == 0.0

    def test_empty_actuals(self):
        assert hit_rate_at_k([1, 2], set(), k=4) == 0.0


class TestMRR:
    def test_first_position(self):
        assert mrr([1, 2, 3], {1}) == 1.0

    def test_second_position(self):
        assert mrr([1, 2, 3], {2}) == 0.5

    def test_no_match(self):
        assert mrr([1, 2, 3], {5}) == 0.0


class TestRecall:
    def test_full_recall(self):
        assert recall_at_k([1, 2, 3], {1, 2}, k=3) == 1.0

    def test_partial_recall(self):
        assert recall_at_k([1, 2, 3], {1, 5}, k=3) == 0.5


class TestNDCG:
    def test_perfect_ndcg(self):
        # First position hit gives NDCG of 1.0
        assert ndcg_at_k([1], {1}, k=1) == 1.0

    def test_zero_ndcg(self):
        assert ndcg_at_k([1, 2], {5}, k=2) == 0.0

    def test_empty(self):
        assert ndcg_at_k([], set(), k=5) == 0.0


class TestPrecision:
    def test_precision(self):
        assert precision_at_k([1, 2, 3], {1, 2}, k=3) == 2 / 3

    def test_no_hits(self):
        assert precision_at_k([1, 2, 3], {5}, k=3) == 0.0


class TestMAP:
    def test_map(self):
        result = mean_average_precision([1, 5, 2], {1, 2})
        assert result > 0

    def test_empty(self):
        assert mean_average_precision([], {1}) == 0.0


class TestCatalogCoverage:
    def test_full_coverage(self):
        preds = [[1, 2], [3, 4], [5]]
        # k=2: takes [1,2], [3,4], [5] → {1,2,3,4,5} = 5/5
        assert catalog_coverage(preds, 5, k=2) == 1.0

    def test_partial_coverage(self):
        preds = [[1, 2, 10], [3, 4, 11]]
        # k=2: takes [1,2], [3,4] → {1,2,3,4} = 4/10
        assert catalog_coverage(preds, 10, k=2) == 4 / 10

    def test_zero_catalog(self):
        assert catalog_coverage([[1]], 0, k=1) == 0.0
