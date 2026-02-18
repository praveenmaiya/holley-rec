"""Shared recommendation business rules for GNN evaluation and scoring."""

from __future__ import annotations

from collections.abc import Iterable
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from torch_geometric.data import HeteroData


def apply_slot_reservation_with_diversity(
    ranked_products: Iterable[int],
    fitment_set: set[int],
    universal_set: set[int],
    part_type_by_product: dict[int, str],
    *,
    fitment_slots: int = 2,
    universal_slots: int = 2,
    total_slots: int = 4,
    max_per_part_type: int = 2,
    excluded_products: set[int] | None = None,
) -> list[int]:
    """Select final recommendations with slot reservation + part-type cap.

    The selection policy is:
    1. Fill up to `fitment_slots` from ranked fitment products.
    2. Fill up to `universal_slots` from ranked universal products.
    3. Backfill from the global ranked list until `total_slots` is reached.
    4. Enforce `max_per_part_type` across all phases.
    5. Skip products in `excluded_products` (e.g. recently purchased).
    """
    result: list[int] = []
    seen_products: set[int] = set(excluded_products) if excluded_products else set()
    part_type_counts: dict[str, int] = {}

    ranked = list(ranked_products)

    def try_add(product_id: int) -> bool:
        if product_id in seen_products:
            return False
        part_type = part_type_by_product.get(product_id, "")
        if part_type_counts.get(part_type, 0) >= max_per_part_type:
            return False
        result.append(product_id)
        seen_products.add(product_id)
        part_type_counts[part_type] = part_type_counts.get(part_type, 0) + 1
        return True

    fitment_added = 0
    for pid in ranked:
        if fitment_added >= fitment_slots or len(result) >= total_slots:
            break
        if pid in fitment_set and try_add(pid):
            fitment_added += 1

    universal_added = 0
    for pid in ranked:
        if universal_added >= universal_slots or len(result) >= total_slots:
            break
        if pid in universal_set and pid not in fitment_set and try_add(pid):
            universal_added += 1

    for pid in ranked:
        if len(result) >= total_slots:
            break
        try_add(pid)

    return result[:total_slots]


def build_fitment_index(data: HeteroData) -> dict[int, list[int]]:
    """Build user -> fitment product mapping from graph ownership and fitment edges.

    Shared across trainer (hard negative sampling) and evaluator (candidate pool).
    The scorer uses its own ``_build_vehicle_groups()`` because it needs
    vehicle→user and vehicle→product mappings (different structure).
    """
    result: dict[int, list[int]] = {}

    own_type = ("user", "owns", "vehicle")
    fits_type = ("vehicle", "rev_fits", "product")

    if own_type not in data.edge_types or fits_type not in data.edge_types:
        return result

    own_ei = data[own_type].edge_index
    fits_ei = data[fits_type].edge_index

    vehicle_products: dict[int, set[int]] = {}
    for v, p in zip(fits_ei[0].cpu().numpy(), fits_ei[1].cpu().numpy()):
        vehicle_products.setdefault(int(v), set()).add(int(p))

    for u, v in zip(own_ei[0].cpu().numpy(), own_ei[1].cpu().numpy()):
        prods = vehicle_products.get(int(v), set())
        result.setdefault(int(u), []).extend(prods)

    # Deduplicate while preserving insertion order
    return {u: list(dict.fromkeys(prods)) for u, prods in result.items()}
