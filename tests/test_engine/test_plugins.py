"""Tests for rec_engine.plugins — plugin hooks and validation."""

from plugins.defaults import DefaultPlugin
from rec_engine.plugins import FallbackTier, RecEnginePlugin, validate_plugin
from src.gnn.holley_plugins import HolleyPlugin


class TestDefaultPlugin:
    def test_normalize_user_id(self):
        plugin = DefaultPlugin(salt="test")
        result = plugin.normalize_user_id("  User@Example.COM  ")
        assert len(result) == 16
        assert result.isalnum()

    def test_normalize_user_id_deterministic(self):
        plugin = DefaultPlugin(salt="test")
        assert plugin.normalize_user_id("a@b.com") == plugin.normalize_user_id("a@b.com")

    def test_normalize_user_id_different_salt(self):
        p1 = DefaultPlugin(salt="salt1")
        p2 = DefaultPlugin(salt="salt2")
        assert p1.normalize_user_id("a@b.com") != p2.normalize_user_id("a@b.com")

    def test_normalize_product_id(self):
        plugin = DefaultPlugin()
        assert plugin.normalize_product_id("  SKU123  ") == "SKU123"

    def test_dedup_variant_identity(self):
        plugin = DefaultPlugin()
        assert plugin.dedup_variant("SKU123") == "SKU123"

    def test_map_interaction_weight_returns_none(self):
        plugin = DefaultPlugin()
        assert plugin.map_interaction_weight("view") is None

    def test_post_rank_filter_keeps_all(self):
        plugin = DefaultPlugin()
        assert plugin.post_rank_filter(0, {}) is True

    def test_fallback_tiers_2node(self):
        plugin = DefaultPlugin()
        tiers = plugin.fallback_tiers({"topology": "user-product"})
        assert tiers == [FallbackTier.GLOBAL]

    def test_fallback_tiers_3node(self):
        plugin = DefaultPlugin()
        tiers = plugin.fallback_tiers({"topology": "user-entity-product"})
        assert tiers == [FallbackTier.ENTITY, FallbackTier.ENTITY_GROUP, FallbackTier.GLOBAL]

    def test_go_no_go_thresholds_none(self):
        plugin = DefaultPlugin()
        assert plugin.get_go_no_go_thresholds() is None


class TestHolleyPlugin:
    def test_normalize_user_id(self):
        plugin = HolleyPlugin(salt="test")
        result = plugin.normalize_user_id("John@Example.COM")
        assert len(result) == 16

    def test_dedup_variant_strips_suffix(self):
        plugin = HolleyPlugin()
        assert plugin.dedup_variant("140061B") == "140061"
        assert plugin.dedup_variant("140061R") == "140061"
        assert plugin.dedup_variant("140061G") == "140061"
        assert plugin.dedup_variant("140061P") == "140061"

    def test_dedup_variant_keeps_non_variant(self):
        plugin = HolleyPlugin()
        assert plugin.dedup_variant("140061") == "140061"
        assert plugin.dedup_variant("HOLLEYB") == "HOLLEYB"  # not preceded by digit

    def test_map_interaction_weight(self):
        plugin = HolleyPlugin()
        assert plugin.map_interaction_weight("Viewed Product") == 1.0
        assert plugin.map_interaction_weight("Added to Cart") == 3.0
        assert plugin.map_interaction_weight("Placed Order") == 5.0
        assert plugin.map_interaction_weight("unknown") is None

    def test_fallback_tiers_default(self):
        plugin = HolleyPlugin()
        tiers = plugin.fallback_tiers({})
        assert tiers == [FallbackTier.ENTITY, FallbackTier.ENTITY_GROUP, FallbackTier.GLOBAL]

    def test_fallback_tiers_3node_explicit(self):
        plugin = HolleyPlugin()
        tiers = plugin.fallback_tiers({"topology": "user-entity-product"})
        assert tiers == [FallbackTier.ENTITY, FallbackTier.ENTITY_GROUP, FallbackTier.GLOBAL]

    def test_fallback_tiers_2node(self):
        plugin = HolleyPlugin()
        tiers = plugin.fallback_tiers({"topology": "user-product"})
        assert tiers == [FallbackTier.GLOBAL]

    def test_go_no_go_thresholds(self):
        plugin = HolleyPlugin()
        thresholds = plugin.get_go_no_go_thresholds()
        assert "go_delta" in thresholds
        assert "maybe_delta" in thresholds
        assert "investigate_delta" in thresholds
        assert "metric" in thresholds
        assert thresholds["go_delta"] == 0.05
        assert thresholds["metric"] == "hit_rate_at_4"


class TestValidatePlugin:
    def test_default_plugin_valid(self):
        errors = validate_plugin(DefaultPlugin)
        assert errors == []

    def test_holley_plugin_valid(self):
        errors = validate_plugin(HolleyPlugin)
        assert errors == []

    def test_non_subclass(self):
        class NotAPlugin:
            pass

        errors = validate_plugin(NotAPlugin)
        assert len(errors) > 0
        assert "subclass" in errors[0]

    def test_missing_abstract_method(self):
        # This would fail at instantiation, not at class definition
        class IncompletePlugin(RecEnginePlugin):
            pass

        errors = validate_plugin(IncompletePlugin)
        assert len(errors) > 0
