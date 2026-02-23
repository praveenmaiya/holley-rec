"""Tests for rec_engine.topology — strategy pattern for 2-node vs 3-node."""

import pytest
import torch

from plugins.defaults import DefaultPlugin
from rec_engine.plugins import FallbackTier
from rec_engine.topology import (
    UserEntityProductStrategy,
    UserProductStrategy,
    create_strategy,
)


class TestCreateStrategy:
    def test_user_product(self):
        strategy = create_strategy({"topology": "user-product"})
        assert isinstance(strategy, UserProductStrategy)

    def test_user_entity_product(self):
        strategy = create_strategy({"topology": "user-entity-product"})
        assert isinstance(strategy, UserEntityProductStrategy)

    def test_unknown_topology(self):
        with pytest.raises(ValueError, match="Unknown topology"):
            create_strategy({"topology": "unknown"})

    def test_default_is_user_product(self):
        strategy = create_strategy({})
        assert isinstance(strategy, UserProductStrategy)


class TestUserProductStrategy:
    @pytest.fixture
    def strategy(self):
        return UserProductStrategy()

    def test_is_entity_topology(self, strategy):
        assert strategy.is_entity_topology is False

    def test_edge_types(self, strategy):
        edge_types = strategy.get_edge_types({})
        assert ("user", "interacts", "product") in edge_types
        assert ("product", "co_purchased", "product") in edge_types
        assert len(edge_types) == 3

    def test_generate_candidates_all_products(self, strategy, small_graph_2node):
        data, _, _, _ = small_graph_2node
        candidates = strategy.generate_candidates(0, data)
        assert len(candidates) == data["product"].num_nodes

    def test_generate_candidates_excludes(self, strategy, small_graph_2node):
        data, _, _, _ = small_graph_2node
        excluded = frozenset({0, 1, 2})
        candidates = strategy.generate_candidates(0, data, excluded_product_ids=excluded)
        assert 0 not in candidates
        assert 1 not in candidates
        assert 2 not in candidates

    def test_fallback_tiers_global_only(self, strategy):
        plugin = DefaultPlugin()
        tiers = strategy.get_fallback_tiers(plugin, {})
        assert tiers == [FallbackTier.GLOBAL]

    def test_build_fitment_index_empty(self, strategy, small_graph_2node):
        data, _, _, _ = small_graph_2node
        index = strategy.build_fitment_index(data)
        assert index == {}

    def test_negative_samples_shape(self, strategy, small_graph_2node):
        data, _, _, _ = small_graph_2node
        plugin = DefaultPlugin()
        config = {"training": {"negative_mix": {"in_batch": 0.5, "random": 0.5}}}
        user_ids = torch.tensor([0, 1, 2, 3], dtype=torch.long)
        pos_ids = torch.tensor([0, 1, 2, 3], dtype=torch.long)
        neg = strategy.build_negative_samples(user_ids, pos_ids, data, plugin, config)
        assert neg.shape == (4,)


class TestUserEntityProductStrategy:
    @pytest.fixture
    def strategy(self):
        return UserEntityProductStrategy()

    def test_is_entity_topology(self, strategy):
        assert strategy.is_entity_topology is True

    def test_edge_types(self, strategy):
        config = {"entity": {"type_name": "vehicle"}}
        edge_types = strategy.get_edge_types(config)
        assert ("product", "fits", "vehicle") in edge_types
        assert ("user", "owns", "vehicle") in edge_types
        assert len(edge_types) == 7

    def test_generate_candidates_fitment(self, strategy, small_graph_3node):
        data, _, id_mappings, _ = small_graph_3node
        fitment = strategy.build_fitment_index(data)
        candidates = strategy.generate_candidates(
            0, data, user_fitment_products=fitment
        )
        # User 0 has fitment products via vehicle ownership
        assert len(candidates) > 0

    def test_generate_candidates_fallback(self, strategy, small_graph_3node):
        data, _, _, _ = small_graph_3node
        # User with no fitment → fallback to all
        candidates = strategy.generate_candidates(
            99, data, user_fitment_products={}
        )
        assert len(candidates) == data["product"].num_nodes

    def test_build_fitment_index(self, strategy, small_graph_3node):
        data, _, _, _ = small_graph_3node
        index = strategy.build_fitment_index(data)
        assert len(index) > 0
        # Check deterministic ordering
        for prods in index.values():
            assert prods == sorted(prods)

    def test_fallback_tiers_3tier(self, strategy):
        plugin = DefaultPlugin()
        tiers = strategy.get_fallback_tiers(plugin, {})
        assert FallbackTier.ENTITY in tiers
        assert FallbackTier.ENTITY_GROUP in tiers
        assert FallbackTier.GLOBAL in tiers

    def test_negative_samples_shape(self, strategy, small_graph_3node):
        data, _, _, _ = small_graph_3node
        plugin = DefaultPlugin()
        config = {"training": {"negative_mix": {"in_batch": 0.5, "fitment_hard": 0.3, "random": 0.2}}}
        fitment = strategy.build_fitment_index(data)
        user_ids = torch.tensor([0, 1, 2, 3], dtype=torch.long)
        pos_ids = torch.tensor([0, 1, 2, 3], dtype=torch.long)
        neg = strategy.build_negative_samples(
            user_ids, pos_ids, data, plugin, config,
            user_fitment_products=fitment,
        )
        assert neg.shape == (4,)
