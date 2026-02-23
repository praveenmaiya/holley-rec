"""Topology strategy: encapsulates 2-node vs 3-node behavior.

Core modules call strategy methods — they never check topology mode directly.
"""

from __future__ import annotations

import logging
from abc import ABC, abstractmethod
from typing import TYPE_CHECKING, Any

import torch

from rec_engine.plugins import FallbackTier, RecEnginePlugin

if TYPE_CHECKING:
    from torch_geometric.data import HeteroData

logger = logging.getLogger(__name__)


class TopologyStrategy(ABC):
    """Base class for topology-specific behavior."""

    @property
    @abstractmethod
    def is_entity_topology(self) -> bool:
        """Whether this topology has a secondary entity node type."""
        ...

    @abstractmethod
    def get_edge_types(self, config: dict[str, Any]) -> list[tuple[str, str, str]]:
        """Return the list of edge types for this topology."""
        ...

    @abstractmethod
    def build_negative_samples(
        self,
        user_ids: torch.Tensor,
        pos_product_ids: torch.Tensor,
        data: HeteroData,
        plugin: RecEnginePlugin,
        config: dict[str, Any],
        *,
        user_fitment_products: dict[int, list[int]] | None = None,
    ) -> torch.Tensor:
        """Sample negative products for BPR training."""
        ...

    @abstractmethod
    def generate_candidates(
        self,
        user_id: int,
        data: HeteroData,
        *,
        user_fitment_products: dict[int, list[int]] | None = None,
        excluded_product_ids: frozenset[int] | None = None,
    ) -> list[int]:
        """Generate candidate product IDs for a user."""
        ...

    @abstractmethod
    def get_fallback_tiers(
        self,
        plugin: RecEnginePlugin,
        user_context: dict[str, Any],
    ) -> list[FallbackTier]:
        """Get fallback tier order from plugin."""
        ...

    @abstractmethod
    def build_fitment_index(
        self,
        data: HeteroData,
    ) -> dict[int, list[int]]:
        """Build user_id → fitment product mapping from graph edges."""
        ...


class UserProductStrategy(TopologyStrategy):
    """2-node topology: user ↔ product only."""

    @property
    def is_entity_topology(self) -> bool:
        return False

    def get_edge_types(self, config: dict[str, Any]) -> list[tuple[str, str, str]]:
        return [
            ("user", "interacts", "product"),
            ("product", "rev_interacts", "user"),
            ("product", "co_purchased", "product"),
        ]

    def build_negative_samples(
        self,
        user_ids: torch.Tensor,
        pos_product_ids: torch.Tensor,
        data: HeteroData,
        plugin: RecEnginePlugin,
        config: dict[str, Any],
        *,
        user_fitment_products: dict[int, list[int]] | None = None,
    ) -> torch.Tensor:
        """Random-only negative sampling (no entity-aware hard negatives)."""
        n = len(user_ids)
        n_products = data["product"].num_nodes
        device = user_ids.device

        neg_mix = config.get("training", {}).get("negative_mix", {})
        n_inbatch = int(n * neg_mix.get("in_batch", 0.5))
        n_random = n - n_inbatch

        neg_products = torch.zeros(n, dtype=torch.long, device=device)

        # In-batch negatives
        perm = torch.randperm(n, device=device)
        neg_products[:n_inbatch] = pos_product_ids[perm[:n_inbatch]]

        # Random negatives (no fitment-hard for 2-node)
        neg_products[n_inbatch:] = torch.randint(
            n_products, (n_random,), device=device
        )

        return neg_products

    def generate_candidates(
        self,
        user_id: int,
        data: HeteroData,
        *,
        user_fitment_products: dict[int, list[int]] | None = None,
        excluded_product_ids: frozenset[int] | None = None,
    ) -> list[int]:
        """All products are candidates (no entity filtering)."""
        excluded = excluded_product_ids or frozenset()
        return [
            p for p in range(data["product"].num_nodes)
            if p not in excluded
        ]

    def get_fallback_tiers(
        self,
        plugin: RecEnginePlugin,
        user_context: dict[str, Any],
    ) -> list[FallbackTier]:
        ctx = {**user_context, "topology": "user-product"}
        return plugin.fallback_tiers(ctx)

    def build_fitment_index(self, data: HeteroData) -> dict[int, list[int]]:
        """No fitment in 2-node topology."""
        return {}


class UserEntityProductStrategy(TopologyStrategy):
    """3-node topology: user ↔ entity ↔ product."""

    @property
    def is_entity_topology(self) -> bool:
        return True

    def get_edge_types(self, config: dict[str, Any]) -> list[tuple[str, str, str]]:
        entity_type = config.get("entity", {}).get("type_name", "entity")
        return [
            ("user", "interacts", "product"),
            ("product", "rev_interacts", "user"),
            ("product", "fits", entity_type),
            (entity_type, "rev_fits", "product"),
            ("user", "owns", entity_type),
            (entity_type, "rev_owns", "user"),
            ("product", "co_purchased", "product"),
        ]

    def build_negative_samples(
        self,
        user_ids: torch.Tensor,
        pos_product_ids: torch.Tensor,
        data: HeteroData,
        plugin: RecEnginePlugin,
        config: dict[str, Any],
        *,
        user_fitment_products: dict[int, list[int]] | None = None,
    ) -> torch.Tensor:
        """Mixed negative sampling: in-batch + fitment-hard + random."""
        n = len(user_ids)
        n_products = data["product"].num_nodes
        device = user_ids.device

        neg_mix = config.get("training", {}).get("negative_mix", {})
        n_inbatch = int(n * neg_mix.get("in_batch", 0.5))
        n_fitment = int(n * neg_mix.get("fitment_hard", 0.3))
        n_random = n - n_inbatch - n_fitment

        neg_products = torch.zeros(n, dtype=torch.long, device=device)

        # In-batch negatives
        perm = torch.randperm(n, device=device)
        neg_products[:n_inbatch] = pos_product_ids[perm[:n_inbatch]]

        # Fitment-hard negatives (entity-aware)
        fitment_map = user_fitment_products or {}
        for i in range(n_inbatch, n_inbatch + n_fitment):
            uid = user_ids[i].item()
            fitment_prods = fitment_map.get(uid, [])
            pos_pid = pos_product_ids[i].item()

            if not fitment_prods:
                neg_products[i] = torch.randint(n_products, (1,), device=device)
                continue

            if len(fitment_prods) == 1 and fitment_prods[0] == pos_pid:
                neg_products[i] = torch.randint(n_products, (1,), device=device)
                continue

            # Rejection sampling
            candidate = pos_pid
            for _ in range(4):
                sampled_idx = torch.randint(
                    len(fitment_prods), (1,), device=device
                ).item()
                candidate = fitment_prods[sampled_idx]
                if candidate != pos_pid:
                    break

            if candidate == pos_pid:
                fallback = next((p for p in fitment_prods if p != pos_pid), None)
                if fallback is None:
                    neg_products[i] = torch.randint(n_products, (1,), device=device)
                else:
                    neg_products[i] = fallback
            else:
                neg_products[i] = candidate

        # Random negatives
        neg_products[n_inbatch + n_fitment:] = torch.randint(
            n_products, (n_random,), device=device
        )

        return neg_products

    def generate_candidates(
        self,
        user_id: int,
        data: HeteroData,
        *,
        user_fitment_products: dict[int, list[int]] | None = None,
        excluded_product_ids: frozenset[int] | None = None,
    ) -> list[int]:
        """Entity-aware candidates: fitment products, fallback to all."""
        excluded = excluded_product_ids or frozenset()
        fitment_map = user_fitment_products or {}
        fitment = fitment_map.get(user_id, [])
        eligible = [p for p in fitment if p not in excluded]
        if eligible:
            return eligible
        # Fallback to all non-excluded products
        return [
            p for p in range(data["product"].num_nodes)
            if p not in excluded
        ]

    def get_fallback_tiers(
        self,
        plugin: RecEnginePlugin,
        user_context: dict[str, Any],
    ) -> list[FallbackTier]:
        ctx = {**user_context, "topology": "user-entity-product"}
        return plugin.fallback_tiers(ctx)

    def build_fitment_index(self, data: HeteroData) -> dict[int, list[int]]:
        """Build user → fitment product mapping from ownership + fitment edges."""
        user_products: dict[int, set[int]] = {}

        # Find entity type name from edge types
        entity_type = None
        for et in data.edge_types:
            if et[1] == "owns" and et[0] == "user":
                entity_type = et[2]
                break

        if entity_type is None:
            return {}

        own_type = ("user", "owns", entity_type)
        fits_type = (entity_type, "rev_fits", "product")

        if own_type not in data.edge_types or fits_type not in data.edge_types:
            return {}

        own_ei = data[own_type].edge_index
        fits_ei = data[fits_type].edge_index

        entity_products: dict[int, set[int]] = {}
        for e, p in zip(fits_ei[0].cpu().numpy(), fits_ei[1].cpu().numpy()):
            entity_products.setdefault(int(e), set()).add(int(p))

        for u, e in zip(own_ei[0].cpu().numpy(), own_ei[1].cpu().numpy()):
            user_products.setdefault(int(u), set()).update(
                entity_products.get(int(e), set())
            )

        return {u: sorted(prods) for u, prods in user_products.items()}


def create_strategy(config: dict[str, Any]) -> TopologyStrategy:
    """Factory: create the right strategy based on config topology."""
    topology = config.get("topology", "user-product")
    if topology == "user-entity-product":
        return UserEntityProductStrategy()
    if topology == "user-product":
        return UserProductStrategy()
    raise ValueError(
        f"Unknown topology: {topology!r}. "
        f"Supported: 'user-product', 'user-entity-product'"
    )
