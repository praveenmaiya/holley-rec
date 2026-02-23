"""GNN training loop with dual optimizer, early stopping.

Uses TopologyStrategy for negative sampling and candidate generation.
Uses RecEnginePlugin for client-specific behavior.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import TYPE_CHECKING, Any

import numpy as np
import torch
import torch.nn as nn

from rec_engine.core.metrics import hit_rate_at_k
from rec_engine.core.model import HeteroGAT
from rec_engine.plugins import RecEnginePlugin
from rec_engine.topology import TopologyStrategy

if TYPE_CHECKING:
    from torch_geometric.data import HeteroData

logger = logging.getLogger(__name__)


class GNNTrainer:
    """Train HeteroGAT with BPR loss and early stopping."""

    def __init__(
        self,
        model: HeteroGAT,
        data: HeteroData,
        split_masks: dict[str, torch.Tensor],
        test_interactions: dict[int, set[int]],
        config: dict[str, Any],
        strategy: TopologyStrategy,
        plugin: RecEnginePlugin,
        device: torch.device | None = None,
    ):
        self.model = model
        self.data = data
        self.split_masks = split_masks
        self.test_interactions = test_interactions
        self.config = config
        self.strategy = strategy
        self.plugin = plugin
        self.device = device or torch.device("cuda" if torch.cuda.is_available() else "cpu")

        train_cfg = config["training"]
        self.max_epochs = train_cfg["max_epochs"]
        self.patience = train_cfg["patience"]
        self.grad_clip = train_cfg.get("grad_clip", 1.0)
        self.neg_mix = train_cfg.get("negative_mix", {"in_batch": 0.5, "random": 0.5})

        # Validate negative_mix
        mix_keys = ("in_batch", "fitment_hard", "random")
        mix_total = sum(float(self.neg_mix.get(k, 0.0)) for k in mix_keys)
        if any(float(self.neg_mix.get(k, 0.0)) < 0 for k in mix_keys):
            raise ValueError(f"negative_mix values must be non-negative: {self.neg_mix}")
        if not np.isclose(mix_total, 1.0, atol=1e-6):
            raise ValueError(f"negative_mix must sum to 1.0, got {mix_total:.6f}: {self.neg_mix}")

        # Dual optimizer
        embedding_params = [model.user_embedding.weight, model.product_embedding.weight]
        if model.has_entity:
            embedding_params.append(model.entity_embedding.weight)
        embedding_params.append(model.category_embedding.weight)

        embedding_ids = {id(p) for p in embedding_params}
        gnn_params = [p for p in model.parameters() if id(p) not in embedding_ids]

        self.opt_emb = torch.optim.Adam(
            embedding_params,
            lr=train_cfg["lr_embedding"],
            weight_decay=train_cfg.get("weight_decay", 0.01),
        )
        self.opt_gnn = torch.optim.Adam(gnn_params, lr=train_cfg["lr_gnn"])

        self.model = self.model.to(self.device)
        self.data = self.data.to(self.device)

        self._prepare_training_edges()

        # Build fitment index via strategy
        self.user_fitment_products = strategy.build_fitment_index(self.data)

        # Excluded product IDs (excluded from eval candidates)
        excluded_mask = getattr(self.data["product"], "is_excluded", None)
        if excluded_mask is not None:
            self.excluded_product_ids: frozenset[int] = frozenset(
                excluded_mask.nonzero(as_tuple=True)[0].detach().cpu().tolist()
            )
        else:
            self.excluded_product_ids = frozenset()

        # Filter excluded products from test labels
        self.test_interactions = {
            uid: prods - self.excluded_product_ids
            for uid, prods in self.test_interactions.items()
            if prods - self.excluded_product_ids
        }

        self.all_product_ids = [
            p for p in range(self.data["product"].num_nodes)
            if p not in self.excluded_product_ids
        ]
        self._eval_candidate_cache: dict[int, list[int]] = {}
        self._fallback_warned = False

        # H5: Fail-fast minimum data thresholds
        min_training_edges = config.get("training", {}).get("min_training_edges", 0)
        if min_training_edges > 0 and len(self.pos_users) < min_training_edges:
            raise ValueError(
                f"Only {len(self.pos_users)} training edges "
                f"(minimum: {min_training_edges}). Check input data."
            )

    def _prepare_training_edges(self):
        """Extract positive training edges and their weights.

        Transductive setup: all edges (train/val/test users) are in the graph
        for message passing so GNN embeddings see the full neighbourhood.
        Only train-user edges (identified by ``train_mask``) are used for BPR
        loss. Held-out evaluation labels (``test_interactions``) come from a
        separate future time window and are **never** stored as graph edges,
        so there is no information leakage.
        """
        edge_type = ("user", "interacts", "product")
        if edge_type in self.data.edge_types and hasattr(self.data[edge_type], "edge_index"):
            ei = self.data[edge_type].edge_index
            # Transductive: filter to train edges only for loss computation
            train_mask = getattr(self.data[edge_type], "train_mask", None)
            if train_mask is not None:
                self.pos_users = ei[0][train_mask]
                self.pos_products = ei[1][train_mask]
                if hasattr(self.data[edge_type], "edge_weight"):
                    self.edge_weights = self.data[edge_type].edge_weight[train_mask]
                else:
                    self.edge_weights = torch.ones(len(self.pos_users), device=self.device)
            else:
                logger.warning(
                    "No train_mask on interaction edges — using ALL edges for "
                    "BPR loss. This may cause evaluation leakage if val/test "
                    "user edges are in the graph. Set train_mask in graph_builder."
                )
                self.pos_users = ei[0]
                self.pos_products = ei[1]
                if hasattr(self.data[edge_type], "edge_weight"):
                    self.edge_weights = self.data[edge_type].edge_weight
                else:
                    self.edge_weights = torch.ones(len(self.pos_users), device=self.device)
        else:
            self.pos_users = torch.tensor([], dtype=torch.long, device=self.device)
            self.pos_products = torch.tensor([], dtype=torch.long, device=self.device)
            self.edge_weights = torch.tensor([], dtype=torch.float, device=self.device)
        logger.info("Training edges: %d positive pairs", len(self.pos_users))

    def _get_eval_candidates(self, user_id: int) -> list[int]:
        """Return validation candidate pool via strategy."""
        if user_id in self._eval_candidate_cache:
            return self._eval_candidate_cache[user_id]

        candidates = self.strategy.generate_candidates(
            user_id, self.data,
            user_fitment_products=self.user_fitment_products,
            excluded_product_ids=self.excluded_product_ids,
        )
        if not candidates:
            candidates = self.all_product_ids
            if not self._fallback_warned:
                logger.warning(
                    "Eval candidate fallback: user %d has no candidates, "
                    "using all %d non-excluded products",
                    user_id, len(candidates),
                )
                self._fallback_warned = True

        self._eval_candidate_cache[user_id] = candidates
        return candidates

    def train_epoch(self) -> float:
        """Run one training epoch. Returns average loss."""
        self.model.train()
        if len(self.pos_users) == 0:
            return 0.0

        perm = torch.randperm(len(self.pos_users), device=self.device)
        pos_u = self.pos_users[perm]
        pos_p = self.pos_products[perm]
        weights = self.edge_weights[perm]

        user_embs, product_embs = self.model(self.data)
        pos_scores = (user_embs[pos_u] * product_embs[pos_p]).sum(dim=1)

        neg_p = self.strategy.build_negative_samples(
            pos_u, pos_p, self.data, self.plugin, self.config,
            user_fitment_products=self.user_fitment_products,
        )
        neg_scores = (user_embs[pos_u] * product_embs[neg_p]).sum(dim=1)

        loss = HeteroGAT.bpr_loss(pos_scores, neg_scores, weights=weights)

        self.opt_emb.zero_grad()
        self.opt_gnn.zero_grad()
        loss.backward()
        nn.utils.clip_grad_norm_(self.model.parameters(), self.grad_clip)
        self.opt_emb.step()
        self.opt_gnn.step()

        return loss.item()

    @torch.no_grad()
    def validate(self, split: str = "val") -> dict[str, float]:
        """Compute validation metrics on val or test split.

        Uses batched scoring when all users share the same candidate pool
        (2-node topology). Falls back to per-user scoring otherwise.
        """
        self.model.eval()
        user_embs, product_embs = self.model(self.data)

        mask = self.split_masks[f"{split}_mask"]
        k_values = self.config["eval"]["k_values"]
        max_k = max(k_values)

        metrics = {f"hit_rate_at_{k}": [] for k in k_values}
        n_evaluated = 0

        # Collect evaluable users
        eval_users = []
        for uid in mask.nonzero(as_tuple=True)[0]:
            uid_int = uid.item()
            actuals = self.test_interactions.get(uid_int, set())
            if actuals:
                eval_users.append((uid_int, actuals))

        if not eval_users:
            result = {f"hit_rate_at_{k}": 0.0 for k in k_values}
            result["n_evaluated"] = 0
            return result

        # Check if all users share the same candidate pool.
        # 2-node topology: always uniform by definition (all non-excluded products).
        # 3-node topology: varies per user (entity-specific candidates).
        # NOTE: If a custom 2-node strategy adds per-user candidate filtering,
        # this assumption must be revisited (consider a strategy capability flag).
        if not self.strategy.is_entity_topology:
            uniform_candidates = True
            first_candidates = self._get_eval_candidates(eval_users[0][0])
        else:
            first_candidates = self._get_eval_candidates(eval_users[0][0])
            uniform_candidates = all(
                self._get_eval_candidates(uid) == first_candidates
                for uid, _ in eval_users
            ) if len(eval_users) > 1 else True

        if uniform_candidates and len(first_candidates) > 0:
            # Batched scoring: all users share same candidates
            eligible_t = torch.tensor(first_candidates, dtype=torch.long, device=self.device)
            candidate_embs = product_embs[eligible_t]
            user_ids_t = torch.tensor(
                [uid for uid, _ in eval_users], dtype=torch.long, device=self.device,
            )
            # [n_users, n_candidates]
            all_scores = torch.mm(user_embs[user_ids_t], candidate_embs.t())
            for i, (uid_int, actuals) in enumerate(eval_users):
                _, top_indices = all_scores[i].topk(min(max_k, len(first_candidates)))
                predictions = [first_candidates[idx.item()] for idx in top_indices]
                for k in k_values:
                    metrics[f"hit_rate_at_{k}"].append(hit_rate_at_k(predictions, actuals, k))
                n_evaluated += 1
        else:
            # Per-user scoring (3-node: different candidates per user)
            for uid_int, actuals in eval_users:
                eligible = self._get_eval_candidates(uid_int)
                eligible_t = torch.tensor(eligible, dtype=torch.long, device=self.device)
                scores = torch.mv(product_embs[eligible_t], user_embs[uid_int])
                _, top_indices = scores.topk(min(max_k, len(eligible)))
                predictions = [eligible[idx.item()] for idx in top_indices]
                for k in k_values:
                    metrics[f"hit_rate_at_{k}"].append(hit_rate_at_k(predictions, actuals, k))
                n_evaluated += 1

        result = {}
        for key, values in metrics.items():
            result[key] = float(np.mean(values)) if values else 0.0
        result["n_evaluated"] = n_evaluated
        return result

    def train(self) -> dict[str, Any]:
        """Full training loop with early stopping."""
        best_val_hr4 = -1.0
        best_epoch = 0
        patience_counter = 0
        best_state = None

        logger.info("Starting training: max_epochs=%d, patience=%d", self.max_epochs, self.patience)

        epoch = 0
        for epoch in range(self.max_epochs):
            loss = self.train_epoch()
            val_metrics = self.validate("val")
            val_hr4 = val_metrics.get("hit_rate_at_4", 0.0)

            logger.info(
                "Epoch %d: loss=%.4f, val_hr@4=%.4f (n_eval=%d)",
                epoch, loss, val_hr4, val_metrics.get("n_evaluated", 0),
            )

            if val_hr4 > best_val_hr4:
                best_val_hr4 = val_hr4
                best_epoch = epoch
                patience_counter = 0
                best_state = {k: v.cpu().clone() for k, v in self.model.state_dict().items()}
            else:
                patience_counter += 1

            if patience_counter >= self.patience:
                logger.info("Early stopping at epoch %d (best: %d)", epoch, best_epoch)
                break

        if best_state is not None:
            self.model.load_state_dict(best_state)
            self.model = self.model.to(self.device)

        return {
            "best_epoch": best_epoch,
            "best_val_hit_rate_at_4": best_val_hr4,
            "total_epochs": epoch + 1,
        }

    def save_checkpoint(self, path: str, id_mappings: dict | None = None) -> str:
        """Save model checkpoint with ID mappings."""
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        checkpoint = {
            "model_state_dict": self.model.state_dict(),
            "config": self.config,
        }
        if id_mappings is not None:
            checkpoint["id_mappings"] = id_mappings
        torch.save(checkpoint, path)
        logger.info("Saved checkpoint to %s", path)
        return path
