"""Tests for rec_engine.core.rules — business rules."""

from rec_engine.core.rules import apply_slot_reservation_with_diversity, select_popularity_fallback


class TestSlotReservation:
    def test_basic_fitment_fill(self):
        ranked = [0, 1, 2, 3, 4, 5]
        fitment = {0, 1, 2, 3}
        cat_map = {i: f"cat_{i % 3}" for i in range(6)}
        result = apply_slot_reservation_with_diversity(
            ranked, fitment, None, cat_map,
            fitment_slots=4, total_slots=4, max_per_category=2,
        )
        assert len(result) <= 4
        assert all(r in fitment for r in result)

    def test_max_per_category_enforced(self):
        ranked = [0, 1, 2, 3]
        fitment = {0, 1, 2, 3}
        # All same category
        cat_map = {0: "A", 1: "A", 2: "A", 3: "B"}
        result = apply_slot_reservation_with_diversity(
            ranked, fitment, None, cat_map,
            fitment_slots=4, total_slots=4, max_per_category=2,
        )
        a_count = sum(1 for r in result if cat_map[r] == "A")
        assert a_count <= 2

    def test_excluded_products_skipped(self):
        ranked = [0, 1, 2, 3]
        fitment = {0, 1, 2, 3}
        cat_map = {i: f"cat_{i}" for i in range(4)}
        result = apply_slot_reservation_with_diversity(
            ranked, fitment, None, cat_map,
            fitment_slots=4, total_slots=4, max_per_category=2,
            excluded_products={0, 1},
        )
        assert 0 not in result
        assert 1 not in result

    def test_backfill_from_global(self):
        ranked = [10, 11, 0, 1, 2]
        fitment = {0, 1, 2}
        cat_map = {i: f"cat_{i}" for i in range(20)}
        result = apply_slot_reservation_with_diversity(
            ranked, fitment, None, cat_map,
            fitment_slots=2, total_slots=4, max_per_category=2,
        )
        assert len(result) == 4

    def test_empty_ranked(self):
        result = apply_slot_reservation_with_diversity(
            [], set(), None, {}, fitment_slots=4, total_slots=4,
        )
        assert result == []


class TestSelectPopularityFallback:
    def test_basic_selection(self):
        pool = [0, 1, 2, 3, 4]
        cat_map = {i: f"cat_{i}" for i in range(5)}
        counts: dict[str, int] = {}
        result = select_popularity_fallback(
            pool, set(), set(), cat_map, counts, slots_needed=3,
        )
        assert len(result) == 3

    def test_skips_already_selected(self):
        pool = [0, 1, 2, 3]
        cat_map = {i: f"cat_{i}" for i in range(4)}
        counts: dict[str, int] = {}
        result = select_popularity_fallback(
            pool, {0, 1}, set(), cat_map, counts, slots_needed=2,
        )
        assert 0 not in result
        assert 1 not in result

    def test_skips_excluded(self):
        pool = [0, 1, 2, 3]
        cat_map = {i: f"cat_{i}" for i in range(4)}
        counts: dict[str, int] = {}
        result = select_popularity_fallback(
            pool, set(), {0, 1}, cat_map, counts, slots_needed=2,
        )
        assert 0 not in result

    def test_respects_category_cap(self):
        pool = [0, 1, 2, 3]
        cat_map = {0: "A", 1: "A", 2: "A", 3: "B"}
        counts: dict[str, int] = {}
        result = select_popularity_fallback(
            pool, set(), set(), cat_map, counts,
            max_per_category=1, slots_needed=4,
        )
        a_count = sum(1 for r in result if cat_map[r] == "A")
        assert a_count <= 1

    def test_skips_additional_excluded(self):
        pool = [0, 1, 2, 3]
        cat_map = {i: f"cat_{i}" for i in range(4)}
        counts: dict[str, int] = {}
        result = select_popularity_fallback(
            pool, set(), set(), cat_map, counts,
            slots_needed=3, additional_excluded_ids=frozenset({0, 1}),
        )
        assert 0 not in result
        assert 1 not in result
