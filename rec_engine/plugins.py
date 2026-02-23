"""Plugin hook interfaces for client-specific behavior.

Clients implement RecEnginePlugin to customize normalization, deduplication,
interaction weighting, post-rank filtering, fallback strategies, and
evaluation thresholds. All hooks have sensible defaults.
"""

from __future__ import annotations

import enum
from abc import ABC, abstractmethod
from typing import Any


class FallbackTier(enum.Enum):
    """Typed fallback tier identifiers."""

    ENTITY = "entity"
    ENTITY_GROUP = "entity_group"
    GLOBAL = "global"


class RecEnginePlugin(ABC):
    """Client-specific behavioral hooks. All have sensible defaults except normalization."""

    @abstractmethod
    def normalize_user_id(self, raw_id: str) -> str:
        """Normalize and anonymize user identifier.

        MUST return an opaque, irreversible key (e.g., salted hash).
        Raw PII (email, phone) must NOT pass through to the engine.
        """
        ...

    @abstractmethod
    def normalize_product_id(self, raw_id: str) -> str:
        """Normalize product identifier."""
        ...

    def dedup_variant(self, product_id: str) -> str:
        """Strip variant suffixes for dedup. Default: identity (no dedup)."""
        return product_id

    def map_interaction_weight(self, interaction_type: str) -> float | None:
        """Map raw event type to numeric weight.

        Return None to use weight from InteractionContract.weight column.
        Precedence: plugin return value > contract weight column > config default (1.0).
        Only ONE source of truth per interaction row.
        """
        return None

    def post_rank_filter(self, product_id: int, context: dict[str, Any]) -> bool:
        """Filter products after ranking. Default: True (keep all).

        Args:
            product_id: Internal integer product ID.
            context: Dict with:
                - scorer (bool): True when called from scorer
                - user_id (str | None): User being scored
                - product_str_id (str): Original string product ID
                - category (str): Product category label
        """
        return True

    def fallback_tiers(self, user_context: dict[str, Any]) -> list[FallbackTier]:
        """Define fallback tier order.

        Default for 3-node: [ENTITY, ENTITY_GROUP, GLOBAL]
        Default for 2-node: [GLOBAL] only.

        Args:
            user_context: Dict with topology, user_id, entity_ids, etc.
        """
        topology = user_context.get("topology", "user-product")
        if topology == "user-entity-product":
            return [FallbackTier.ENTITY, FallbackTier.ENTITY_GROUP, FallbackTier.GLOBAL]
        return [FallbackTier.GLOBAL]

    def get_go_no_go_thresholds(self) -> dict[str, float] | None:
        """Client-specific evaluation thresholds.

        Returns None to use thresholds from config eval.go_no_go.
        Precedence: plugin override > config eval.go_no_go.
        Returned thresholds are persisted in run metadata for auditability.
        """
        return None


def validate_plugin(plugin_cls: type[RecEnginePlugin]) -> list[str]:
    """Validate that a plugin class implements required hooks correctly.

    Returns list of error messages (empty = valid).
    """
    errors: list[str] = []

    if not issubclass(plugin_cls, RecEnginePlugin):
        errors.append(
            f"{plugin_cls.__name__} must be a subclass of RecEnginePlugin"
        )
        return errors

    # Check abstract methods are implemented
    abstract_methods = {"normalize_user_id", "normalize_product_id"}
    for method_name in abstract_methods:
        method = getattr(plugin_cls, method_name, None)
        if method is None:
            errors.append(f"Missing required method: {method_name}")
        elif getattr(method, "__isabstractmethod__", False):
            errors.append(f"Abstract method not implemented: {method_name}")

    # Try instantiation (catches __init__ issues)
    if not errors:
        try:
            instance = plugin_cls()
            # Smoke-test optional hooks
            instance.dedup_variant("TEST123")
            instance.map_interaction_weight("view")
            instance.post_rank_filter(0, {})
            instance.fallback_tiers({"topology": "user-product"})
            instance.fallback_tiers({"topology": "user-entity-product"})
            instance.get_go_no_go_thresholds()
        except TypeError as exc:
            errors.append(f"Plugin instantiation failed: {exc}")
        except Exception as exc:
            errors.append(f"Plugin smoke test failed: {exc}")

    return errors
