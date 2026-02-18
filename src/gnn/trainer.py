"""GNN training loop with dual optimizer, early stopping, and W&B logging."""

from __future__ import annotations

import logging
from pathlib import Path
from typing import TYPE_CHECKING, Any

import numpy as np
import torch
import torch.nn as nn

from src.gnn.model import HolleyGAT
from src.metrics import hit_rate_at_k
from src.wandb_utils import log_metrics

if TYPE_CHECKING:
    from torch_geometric.data import HeteroData

logger = logging.getLogger(__name__)


class GNNTrainer:
    """Train HolleyGAT with BPR loss and early stopping."""

    def __init__(
        self,
        model: HolleyGAT,
        data: HeteroData,
        split_masks: dict[str, torch.Tensor],
        test_interactions: dict[int, set[int]],
        config: dict[str, Any],
        device: torch.device = None,
    ):
        self.model = model
        self.data = data
        self.split_masks = split_masks
        self.test_interactions = test_interactions  # user_id -> set of product_ids
        self.config = config
        self.device = device or torch.device("cuda" if torch.cuda.is_available() else "cpu")

        train_cfg = config["training"]
        self.max_epochs = train_cfg["max_epochs"]
        self.patience = train_cfg["patience"]
        self.grad_clip = train_cfg["grad_clip"]
        self.neg_mix = train_cfg["negative_mix"]
        mix_keys = ("in_batch", "fitment_hard", "random")
        mix_total = sum(float(self.neg_mix.get(k, 0.0)) for k in mix_keys)
        if any(float(self.neg_mix.get(k, 0.0)) < 0 for k in mix_keys):
            raise ValueError(f"negative_mix values must be non-negative: {self.neg_mix}")
        if not np.isclose(mix_total, 1.0, atol=1e-6):
            raise ValueError(f"negative_mix must sum to 1.0, got {mix_total:.6f}: {self.neg_mix}")

        # Dual optimizer: slower LR for embeddings, faster for GNN
        embedding_params = [
            model.user_embedding.weight,
            model.product_embedding.weight,
            model.vehicle_embedding.weight,
            model.part_type_embedding.weight,
        ]
        embedding_ids = {id(p) for p in embedding_params}
        gnn_params = [p for p in model.parameters() if id(p) not in embedding_ids]

        self.opt_emb = torch.optim.Adam(
            embedding_params,
            lr=train_cfg["lr_embedding"],
            weight_decay=train_cfg["weight_decay"],
        )
        self.opt_gnn = torch.optim.Adam(
            gnn_params,
            lr=train_cfg["lr_gnn"],
        )

        # Move to device
        self.model = self.model.to(self.device)
        self.data = self.data.to(self.device)

        # Precompute training edges
        self._prepare_training_edges()

        # Build fitment index for hard negative sampling
        self._build_fitment_index()

        # Universal pool for validation-time candidate parity with evaluator.
        universal_mask = getattr(self.data["product"], "is_universal", None)
        if universal_mask is not None:
            self.universal_product_ids = (
                universal_mask.nonzero(as_tuple=True)[0].detach().cpu().tolist()
            )
        else:
            self.universal_product_ids = []
        self.all_product_ids = list(range(self.data["product"].num_nodes))
        self._eval_candidate_cache: dict[int, list[int]] = {}

    def _prepare_training_edges(self):
        """Extract positive training edges as (user_id, product_id) pairs."""
        edge_type = ("user", "interacts", "product")
        if edge_type in self.data.edge_types and hasattr(self.data[edge_type], "edge_index"):
            ei = self.data[edge_type].edge_index
            self.pos_users = ei[0]
            self.pos_products = ei[1]
        else:
            self.pos_users = torch.tensor([], dtype=torch.long, device=self.device)
            self.pos_products = torch.tensor([], dtype=torch.long, device=self.device)

        logger.info(f"Training edges: {len(self.pos_users)} positive pairs")

    def _build_fitment_index(self):
        """Build user -> set of fitment products for hard negative sampling."""
        self.user_fitment_products: dict[int, list[int]] = {}

        # User -> Vehicle via ownership edges
        own_type = ("user", "owns", "vehicle")
        fits_type = ("vehicle", "rev_fits", "product")

        if own_type in self.data.edge_types and fits_type in self.data.edge_types:
            own_ei = self.data[own_type].edge_index
            fits_ei = self.data[fits_type].edge_index

            # Vehicle -> products
            vehicle_products: dict[int, set[int]] = {}
            for v, p in zip(fits_ei[0].cpu().numpy(), fits_ei[1].cpu().numpy()):
                vehicle_products.setdefault(int(v), set()).add(int(p))

            # User -> vehicle -> products
            for u, v in zip(own_ei[0].cpu().numpy(), own_ei[1].cpu().numpy()):
                products = vehicle_products.get(int(v), set())
                self.user_fitment_products[int(u)] = list(products)

    def _get_eval_candidates(self, user_id: int) -> list[int]:
        """Return validation candidate pool: fitment + universal, deduplicated."""
        if user_id in self._eval_candidate_cache:
            return self._eval_candidate_cache[user_id]

        fitment = self.user_fitment_products.get(user_id, [])
        eligible = list(dict.fromkeys(fitment + self.universal_product_ids))
        if not eligible:
            eligible = self.all_product_ids

        self._eval_candidate_cache[user_id] = eligible
        return eligible

    def _sample_negatives(
        self,
        user_ids: torch.Tensor,
        pos_product_ids: torch.Tensor,
    ) -> torch.Tensor:
        """Sample negatives using mixed strategy (in-batch + fitment-hard + random)."""
        n = len(user_ids)
        n_products = self.data["product"].num_nodes

        neg_products = torch.zeros(n, dtype=torch.long, device=self.device)

        n_inbatch = int(n * self.neg_mix["in_batch"])
        n_fitment = int(n * self.neg_mix["fitment_hard"])
        n_random = n - n_inbatch - n_fitment

        # In-batch negatives: shuffle positive products
        perm = torch.randperm(n, device=self.device)
        neg_products[:n_inbatch] = pos_product_ids[perm[:n_inbatch]]

        # Fitment-hard negatives: sample from user's fitment catalog (excluding positive)
        for i in range(n_inbatch, n_inbatch + n_fitment):
            uid = user_ids[i].item()
            fitment_prods = self.user_fitment_products.get(uid, [])
            pos_pid = pos_product_ids[i].item()

            if not fitment_prods:
                neg_products[i] = torch.randint(n_products, (1,), device=self.device)
                continue

            # Rejection sampling avoids per-example list allocations.
            if len(fitment_prods) == 1 and fitment_prods[0] == pos_pid:
                neg_products[i] = torch.randint(n_products, (1,), device=self.device)
                continue

            candidate = pos_pid
            for _ in range(4):
                sampled_idx = torch.randint(len(fitment_prods), (1,), device=self.device).item()
                candidate = fitment_prods[sampled_idx]
                if candidate != pos_pid:
                    break

            if candidate == pos_pid:
                fallback = next((p for p in fitment_prods if p != pos_pid), None)
                if fallback is None:
                    neg_products[i] = torch.randint(n_products, (1,), device=self.device)
                else:
                    neg_products[i] = fallback
            else:
                neg_products[i] = candidate

        # Random negatives
        neg_products[n_inbatch + n_fitment:] = torch.randint(
            n_products, (n_random,), device=self.device
        )

        return neg_products

    def train_epoch(self) -> float:
        """Run one training epoch. Returns average loss."""
        self.model.train()

        if len(self.pos_users) == 0:
            return 0.0

        # Shuffle training edges
        perm = torch.randperm(len(self.pos_users), device=self.device)
        pos_u = self.pos_users[perm]
        pos_p = self.pos_products[perm]

        # Forward pass
        user_embs, product_embs = self.model(self.data)

        # Positive scores
        pos_scores = (user_embs[pos_u] * product_embs[pos_p]).sum(dim=1)

        # Negative sampling
        neg_p = self._sample_negatives(pos_u, pos_p)
        neg_scores = (user_embs[pos_u] * product_embs[neg_p]).sum(dim=1)

        # BPR loss
        loss = HolleyGAT.bpr_loss(pos_scores, neg_scores)

        # Backward
        self.opt_emb.zero_grad()
        self.opt_gnn.zero_grad()
        loss.backward()

        # Gradient clipping
        nn.utils.clip_grad_norm_(self.model.parameters(), self.grad_clip)

        self.opt_emb.step()
        self.opt_gnn.step()

        return loss.item()

    @torch.no_grad()
    def validate(self, split: str = "val") -> dict[str, float]:
        """Compute validation metrics on val or test split.

        Returns dict with hit_rate_at_4, hit_rate_at_10, etc.
        """
        self.model.eval()
        user_embs, product_embs = self.model(self.data)

        mask = self.split_masks[f"{split}_mask"]
        k_values = self.config["eval"]["k_values"]

        metrics = {f"hit_rate_at_{k}": [] for k in k_values}
        n_evaluated = 0

        for uid in mask.nonzero(as_tuple=True)[0]:
            uid_int = uid.item()
            actuals = self.test_interactions.get(uid_int, set())
            if not actuals:
                continue

            # Keep validation candidate semantics aligned with evaluator/scorer.
            eligible = self._get_eval_candidates(uid_int)

            eligible_t = torch.tensor(eligible, dtype=torch.long, device=self.device)
            scores = torch.mv(product_embs[eligible_t], user_embs[uid])
            _, top_indices = scores.topk(min(max(k_values), len(eligible)))
            predictions = [eligible[idx.item()] for idx in top_indices]

            for k in k_values:
                metrics[f"hit_rate_at_{k}"].append(
                    hit_rate_at_k(predictions, actuals, k)
                )
            n_evaluated += 1

        result = {}
        for key, values in metrics.items():
            result[key] = float(np.mean(values)) if values else 0.0
        result["n_evaluated"] = n_evaluated

        return result

    def train(self) -> dict[str, Any]:
        """Full training loop with early stopping.

        Returns dict with final metrics and best epoch.
        """
        best_val_hr4 = -1.0
        best_epoch = 0
        patience_counter = 0
        best_state = None

        logger.info(f"Starting training: max_epochs={self.max_epochs}, patience={self.patience}")

        for epoch in range(self.max_epochs):
            loss = self.train_epoch()
            val_metrics = self.validate("val")

            val_hr4 = val_metrics.get("hit_rate_at_4", 0.0)

            # Log to W&B
            log_metrics({
                "train/loss": loss,
                "train/epoch": epoch,
                **{f"val/{k}": v for k, v in val_metrics.items()},
            }, step=epoch)

            logger.info(
                f"Epoch {epoch}: loss={loss:.4f}, val_hr@4={val_hr4:.4f} "
                f"(n_eval={val_metrics.get('n_evaluated', 0)})"
            )

            if val_hr4 > best_val_hr4:
                best_val_hr4 = val_hr4
                best_epoch = epoch
                patience_counter = 0
                best_state = {k: v.cpu().clone() for k, v in self.model.state_dict().items()}
            else:
                patience_counter += 1

            if patience_counter >= self.patience:
                logger.info(f"Early stopping at epoch {epoch} (best epoch: {best_epoch})")
                break

        # Restore best model
        if best_state is not None:
            self.model.load_state_dict(best_state)
            self.model = self.model.to(self.device)

        return {
            "best_epoch": best_epoch,
            "best_val_hit_rate_at_4": best_val_hr4,
            "total_epochs": epoch + 1,
        }

    def save_checkpoint(self, path: str, id_mappings: dict = None) -> str:
        """Save model checkpoint with ID mappings to local path.

        ID mappings must be saved alongside weights to ensure correct
        entity-to-embedding alignment when loading checkpoints.
        """
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        checkpoint = {
            "model_state_dict": self.model.state_dict(),
            "config": self.config,
        }
        if id_mappings is not None:
            checkpoint["id_mappings"] = id_mappings
        torch.save(checkpoint, path)
        logger.info(f"Saved checkpoint to {path}")
        return path
