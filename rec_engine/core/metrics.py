"""Recommendation evaluation metrics.

Extracted from holley-rec src/metrics.py for the generic engine.
"""

from __future__ import annotations

from typing import Any

import numpy as np


def precision_at_k(predictions: list[int], actuals: set[int], k: int = 10) -> float:
    """Compute precision@k."""
    if not predictions or not actuals:
        return 0.0
    top_k = predictions[:k]
    hits = sum(1 for item in top_k if item in actuals)
    return hits / k


def recall_at_k(predictions: list[int], actuals: set[int], k: int = 10) -> float:
    """Compute recall@k."""
    if not predictions or not actuals:
        return 0.0
    top_k = predictions[:k]
    hits = sum(1 for item in top_k if item in actuals)
    return hits / len(actuals)


def ndcg_at_k(predictions: list[int], actuals: set[int], k: int = 10) -> float:
    """Compute NDCG@k (Normalized Discounted Cumulative Gain)."""
    if not predictions or not actuals:
        return 0.0
    top_k = predictions[:k]
    dcg = sum(
        1.0 / np.log2(i + 2) for i, item in enumerate(top_k) if item in actuals
    )
    ideal_hits = min(len(actuals), k)
    idcg = sum(1.0 / np.log2(i + 2) for i in range(ideal_hits))
    if idcg == 0:
        return 0.0
    return dcg / idcg


def hit_rate_at_k(predictions: list[int], actuals: set[int], k: int = 4) -> float:
    """Compute Hit Rate@k (binary: 1 if any top-k prediction is relevant)."""
    if not predictions or not actuals:
        return 0.0
    top_k = predictions[:k]
    return 1.0 if any(item in actuals for item in top_k) else 0.0


def mrr(predictions: list[int], actuals: set[int]) -> float:
    """Compute Mean Reciprocal Rank."""
    if not predictions or not actuals:
        return 0.0
    for i, item in enumerate(predictions):
        if item in actuals:
            return 1.0 / (i + 1)
    return 0.0


def mean_average_precision(predictions: list[int], actuals: set[int]) -> float:
    """Compute Mean Average Precision."""
    if not predictions or not actuals:
        return 0.0
    score = 0.0
    hits = 0
    for i, item in enumerate(predictions):
        if item in actuals:
            hits += 1
            score += hits / (i + 1)
    return score / len(actuals) if actuals else 0.0


def catalog_coverage(
    all_predictions: list[list[int]], catalog_size: int, k: int = 10
) -> float:
    """Compute fraction of catalog items that appear in recommendations."""
    if not all_predictions or catalog_size == 0:
        return 0.0
    recommended_items: set[int] = set()
    for preds in all_predictions:
        recommended_items.update(preds[:k])
    return len(recommended_items) / catalog_size


def compute_all_metrics(
    user_predictions: dict[int, list[int]],
    user_actuals: dict[int, set[int]],
    k_values: list[int] | None = None,
    catalog_size: int | None = None,
) -> dict[str, Any]:
    """Compute all metrics for a set of users."""
    if k_values is None:
        k_values = [5, 10, 20]

    results: dict[str, Any] = {}
    precisions = {k: [] for k in k_values}
    recalls = {k: [] for k in k_values}
    ndcgs = {k: [] for k in k_values}
    hit_rates = {k: [] for k in k_values}
    maps: list[float] = []
    mrrs: list[float] = []

    for user_id in user_predictions:
        preds = user_predictions[user_id]
        actuals = user_actuals.get(user_id, set())
        if not actuals:
            continue
        for k in k_values:
            precisions[k].append(precision_at_k(preds, actuals, k))
            recalls[k].append(recall_at_k(preds, actuals, k))
            ndcgs[k].append(ndcg_at_k(preds, actuals, k))
            hit_rates[k].append(hit_rate_at_k(preds, actuals, k))
        maps.append(mean_average_precision(preds, actuals))
        mrrs.append(mrr(preds, actuals))

    for k in k_values:
        results[f"precision_at_{k}"] = float(np.mean(precisions[k])) if precisions[k] else 0.0
        results[f"recall_at_{k}"] = float(np.mean(recalls[k])) if recalls[k] else 0.0
        results[f"ndcg_at_{k}"] = float(np.mean(ndcgs[k])) if ndcgs[k] else 0.0
        results[f"hit_rate_at_{k}"] = float(np.mean(hit_rates[k])) if hit_rates[k] else 0.0

    results["map"] = float(np.mean(maps)) if maps else 0.0
    results["mrr"] = float(np.mean(mrrs)) if mrrs else 0.0
    results["num_users_evaluated"] = len(maps)

    if catalog_size:
        results["catalog_coverage"] = catalog_coverage(
            list(user_predictions.values()), catalog_size, k=max(k_values)
        )

    return results
