"""Holley-specific plugin for the recommendation engine.

Implements all behavioral hooks for the automotive parts domain:
- User ID hashing (PII → opaque key)
- Variant suffix deduplication (140061B → 140061)
- Interaction weight mapping (view/cart/order)
- 3-tier fallback (vehicle → make → global)
"""

from __future__ import annotations

import hashlib
import os
import re

from rec_engine.plugins import FallbackTier, RecEnginePlugin


class HolleyPlugin(RecEnginePlugin):
    """Holley automotive parts recommendation plugin."""

    VARIANT_RE = re.compile(r"([0-9])[BRGP]$")

    def __init__(self, salt: str | None = None):
        self._salt = salt or os.environ.get("HOLLEY_USER_SALT", "holley-default-salt")

    def normalize_user_id(self, raw_id: str) -> str:
        """Hash email → opaque key. Raw email stays in client Layer 1 only."""
        email = raw_id.strip().lower()
        return hashlib.sha256(
            f"{self._salt}:{email}".encode()
        ).hexdigest()[:16]

    def normalize_product_id(self, raw_id: str) -> str:
        """Strip whitespace from product ID (SKU)."""
        return raw_id.strip()

    def dedup_variant(self, product_id: str) -> str:
        """Strip BRGP variant suffixes: 140061B → 140061.

        Only strips when preceded by a digit (e.g., 140061B → 140061).
        """
        return self.VARIANT_RE.sub(r"\1", product_id)

    def map_interaction_weight(self, interaction_type: str) -> float | None:
        """Map Holley event types to numeric weights.

        Returns None for unknown types (falls back to contract weight column).
        """
        weights = {
            "Viewed Product": 1.0,
            "Added to Cart": 3.0,
            "Placed Order": 5.0,
        }
        return weights.get(interaction_type)

    def fallback_tiers(self, user_context: dict) -> list[FallbackTier]:
        """Holley uses vehicle → make → global (3-tier) for entity topology."""
        if user_context.get("topology") == "user-product":
            return [FallbackTier.GLOBAL]
        return [FallbackTier.ENTITY, FallbackTier.ENTITY_GROUP, FallbackTier.GLOBAL]

    def get_go_no_go_thresholds(self) -> dict[str, float]:
        """Holley-specific evaluation thresholds.

        Uses delta-based schema matching evaluator's _go_no_go() expectations:
        - go_delta: minimum delta to proceed to online A/B
        - maybe_delta: minimum delta to consider (below go_delta)
        - investigate_delta: below this suggests overfitting
        - metric: which metric to compare
        """
        return {
            "go_delta": 0.05,
            "maybe_delta": 0.02,
            "investigate_delta": -0.01,
            "metric": "hit_rate_at_4",
        }
