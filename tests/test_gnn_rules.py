"""Tests for shared GNN business rules (slot reservation + diversity)."""

import pytest

from src.gnn.rules import apply_slot_reservation_with_diversity


@pytest.fixture
def part_types():
    """Product ID -> PartType mapping. 20 products, 4 part types."""
    return {
        0: "Ignition", 1: "Ignition", 2: "Ignition",
        3: "Exhaust", 4: "Exhaust", 5: "Exhaust",
        6: "Brakes", 7: "Brakes", 8: "Brakes",
        9: "Wheels", 10: "Wheels", 11: "Wheels",
        12: "Ignition", 13: "Exhaust", 14: "Brakes",
        15: "Wheels", 16: "Ignition", 17: "Exhaust",
        18: "Brakes", 19: "Wheels",
    }


class TestSlotReservation:
    def test_basic_2_fitment_2_universal(self, part_types):
        """Standard case: picks 2 fitment then 2 universal from ranked list."""
        ranked = [0, 1, 10, 11, 2, 3, 12, 13]
        fitment = {0, 1, 2, 3}
        universal = {10, 11, 12, 13}

        result = apply_slot_reservation_with_diversity(
            ranked, fitment, universal, part_types,
        )

        assert len(result) == 4
        # First 2 slots: fitment products (0, 1 are top-ranked fitment)
        assert result[0] in fitment
        assert result[1] in fitment
        # Next 2 slots: universal products
        assert result[2] in universal
        assert result[3] in universal

    def test_empty_fitment_fills_from_universal_and_backfill(self, part_types):
        """No fitment products: universal gets its 2, backfill fills rest."""
        ranked = [10, 11, 3, 6]
        fitment = set()
        universal = {10, 11}

        result = apply_slot_reservation_with_diversity(
            ranked, fitment, universal, part_types,
        )

        assert len(result) == 4
        assert 10 in result
        assert 11 in result

    def test_empty_universal_fills_from_fitment_and_backfill(self, part_types):
        """No universal products: fitment gets its 2, backfill fills rest."""
        ranked = [0, 3, 6, 9]
        fitment = {0, 3, 6, 9}
        universal = set()

        result = apply_slot_reservation_with_diversity(
            ranked, fitment, universal, part_types,
        )

        assert len(result) == 4
        assert result[0] in fitment
        assert result[1] in fitment

    def test_part_type_diversity_cap(self, part_types):
        """Max 2 per PartType: third Ignition product is skipped."""
        # All fitment are Ignition (0, 1, 2), universals are also Ignition (12, 16)
        all_ignition_types = {i: "Ignition" for i in range(20)}
        ranked = [0, 1, 2, 10, 11, 12]
        fitment = {0, 1, 2}
        universal = {10, 11, 12}

        result = apply_slot_reservation_with_diversity(
            ranked, fitment, universal, all_ignition_types,
        )

        # Only 2 can be selected due to PartType cap
        assert len(result) == 2

    def test_product_in_both_fitment_and_universal_counted_as_fitment(self, part_types):
        """Product appearing in both sets is treated as fitment, not double-counted."""
        ranked = [5, 10, 11, 6, 7]
        fitment = {5, 6, 7}
        universal = {5, 10, 11}  # 5 is in both

        result = apply_slot_reservation_with_diversity(
            ranked, fitment, universal, part_types,
        )

        assert len(result) == 4
        # 5 is taken as fitment (phase 1)
        assert result[0] == 5
        # Universal phase skips 5 (already seen), takes 10 and 11
        assert 10 in result
        assert 11 in result
        # Only 1 fitment slot used in phase 1 (product 5), so phase 1 takes 6 too
        assert 6 in result

    def test_fewer_products_than_slots(self, part_types):
        """Fewer products available than total_slots: returns what's available."""
        ranked = [0, 10]
        fitment = {0}
        universal = {10}

        result = apply_slot_reservation_with_diversity(
            ranked, fitment, universal, part_types,
        )

        assert result == [0, 10]

    def test_empty_ranked_list(self, part_types):
        """Empty ranked list returns empty result."""
        result = apply_slot_reservation_with_diversity(
            [], set(), set(), part_types,
        )

        assert result == []

    def test_backfill_respects_diversity_cap(self, part_types):
        """Backfill phase also enforces PartType cap."""
        # Fitment: 0 (Ignition), 1 (Ignition) -> fills 2 fitment slots, 2 Ignition used
        # Universal: 3 (Exhaust), 4 (Exhaust) -> fills 2 universal slots
        # Remaining would be backfill, but we have exactly 4 already
        # Use a case where backfill is needed and cap matters
        ranked = [0, 3, 10, 12, 16]
        fitment = {0, 3}
        universal = {10}
        # 0=Ignition, 3=Exhaust -> 2 fitment
        # 10=Wheels -> 1 universal
        # backfill: 12=Ignition (ok, only 1 Ignition so far), 16=Ignition -> capped at 2
        result = apply_slot_reservation_with_diversity(
            ranked, fitment, universal, part_types,
        )

        assert len(result) == 4
        assert result == [0, 3, 10, 12]

    def test_preserves_ranked_order_within_phases(self, part_types):
        """Within each phase, products are selected in ranked order."""
        ranked = [6, 0, 9, 3, 10, 11, 7, 8]
        fitment = {0, 3, 6, 7, 8, 9}
        universal = {10, 11}

        result = apply_slot_reservation_with_diversity(
            ranked, fitment, universal, part_types,
        )

        assert len(result) == 4
        # Fitment phase: 6 (Brakes), 0 (Ignition) — first 2 fitment in ranked order
        assert result[0] == 6
        assert result[1] == 0
        # Universal phase: 10 (Wheels), 11 (Wheels) — but max_per_part_type=2
        assert result[2] == 10
        assert result[3] == 11

    def test_custom_slot_counts(self, part_types):
        """Non-default slot configuration: 3 fitment + 1 universal = 4 total."""
        ranked = [0, 3, 6, 10, 11]
        fitment = {0, 3, 6}
        universal = {10, 11}

        result = apply_slot_reservation_with_diversity(
            ranked, fitment, universal, part_types,
            fitment_slots=3, universal_slots=1, total_slots=4,
        )

        assert len(result) == 4
        # 3 fitment: 0, 3, 6
        assert result[0] == 0
        assert result[1] == 3
        assert result[2] == 6
        # 1 universal: 10
        assert result[3] == 10

    def test_missing_part_type_treated_as_empty_string(self, part_types):
        """Products not in part_type map get empty string, still counted."""
        ranked = [99, 100, 0, 10]
        fitment = {99, 100}
        universal = {0, 10}
        # 99 and 100 not in part_types -> both get ""
        # max 2 per part type, so both can be selected

        result = apply_slot_reservation_with_diversity(
            ranked, fitment, universal, part_types,
        )

        assert len(result) == 4
        assert result[0] == 99
        assert result[1] == 100
