"""Shared recommendation business rules for evaluation and scoring.

Generic versions of slot reservation, fitment index building, and
popularity-based fallback selection.
"""

from __future__ import annotations

from collections.abc import Iterable


def apply_slot_reservation_with_diversity(
    ranked_products: Iterable[int],
    fitment_set: set[int],
    excluded_set: set[int] | frozenset[int] | None,
    category_by_product: dict[int, str],
    *,
    fitment_slots: int = 4,
    excluded_slots: int = 0,
    total_slots: int = 4,
    max_per_category: int = 2,
    excluded_products: set[int] | None = None,
) -> list[int]:
    """Select final recommendations with slot reservation + category diversity cap.

    The selection policy is:
    1. Fill up to ``fitment_slots`` from ranked fitment products.
    2. Fill up to ``excluded_slots`` from ranked excluded-set products (e.g. universals).
    3. Backfill from the global ranked list until ``total_slots`` is reached.
    4. Enforce ``max_per_category`` across all phases.
    5. Skip products in ``excluded_products`` (e.g. recently purchased).
    """
    if excluded_set is None:
        excluded_set = frozenset()

    result: list[int] = []
    seen_products: set[int] = set(excluded_products) if excluded_products else set()
    category_counts: dict[str, int] = {}

    ranked = list(ranked_products)

    def try_add(product_id: int) -> bool:
        if product_id in seen_products:
            return False
        category = category_by_product.get(product_id, "")
        if category_counts.get(category, 0) >= max_per_category:
            return False
        result.append(product_id)
        seen_products.add(product_id)
        category_counts[category] = category_counts.get(category, 0) + 1
        return True

    # Phase 1: fitment slots
    fitment_added = 0
    for pid in ranked:
        if fitment_added >= fitment_slots or len(result) >= total_slots:
            break
        if pid in fitment_set and try_add(pid):
            fitment_added += 1

    # Phase 2: excluded-set slots (e.g. universal products)
    excluded_added = 0
    for pid in ranked:
        if excluded_added >= excluded_slots or len(result) >= total_slots:
            break
        if pid in excluded_set and pid not in fitment_set and try_add(pid):
            excluded_added += 1

    # Phase 3: backfill
    for pid in ranked:
        if len(result) >= total_slots:
            break
        try_add(pid)

    return result[:total_slots]


def select_popularity_fallback(
    popularity_ranked_ids: list[int],
    already_selected: set[int],
    excluded_products: set[int],
    category_by_product: dict[int, str],
    category_counts: dict[str, int],
    *,
    max_per_category: int = 2,
    slots_needed: int = 4,
    additional_excluded_ids: frozenset[int] | set[int] | None = None,
) -> list[int]:
    """Select popularity-ranked fallback products respecting diversity and exclusions.

    Walks the pre-sorted popularity list and picks products that:
    - Are not already selected or excluded
    - Are not in additional_excluded_ids (e.g. universal products)
    - Respect the category diversity cap
    """
    if additional_excluded_ids is None:
        additional_excluded_ids = frozenset()

    result: list[int] = []
    skip = already_selected | excluded_products

    for pid in popularity_ranked_ids:
        if len(result) >= slots_needed:
            break
        if pid in skip:
            continue
        if pid in additional_excluded_ids:
            continue
        category = category_by_product.get(pid, "")
        if category_counts.get(category, 0) >= max_per_category:
            continue
        result.append(pid)
        skip.add(pid)
        category_counts[category] = category_counts.get(category, 0) + 1

    return result
