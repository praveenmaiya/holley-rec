"""Training loop with Faire-style tricks.

Key techniques:
1. Edge-weighted BCE loss (orders > carts > views)
2. Time-decay already in edge weights (from SQL export)
3. Dual optimizer (embedding params vs GNN/MLP params)
4. Mixed negative sampling (in-batch + fitment-aware + global random)
5. Gradient clipping
6. Warm-start from previous checkpoint
"""

import logging
from dataclasses import dataclass
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch_geometric.data import HeteroData

from src.gnn.model import HolleyGAT

logger = logging.getLogger(__name__)


@dataclass
class TrainConfig:
    """Training hyperparameters."""
    epochs: int = 100
    emb_lr: float = 0.001
    emb_weight_decay: float = 1e-5
    gnn_lr: float = 0.01
    gnn_weight_decay: float = 1e-4
    max_grad_norm: float = 1.0
    neg_ratio_inbatch: float = 0.5
    neg_ratio_fitment: float = 0.3
    neg_ratio_random: float = 0.2
    patience: int = 10
    checkpoint_dir: str = "checkpoints/gnn"


class GNNTrainer:
    """Train HolleyGAT with Faire-style techniques."""

    def __init__(
        self,
        model: HolleyGAT,
        data: HeteroData,
        config: TrainConfig | None = None,
        device: str = "cpu",
    ):
        self.model = model.to(device)
        self.data = data.to(device)
        self.config = config or TrainConfig()
        self.device = device

        # Dual optimizer: separate LR for embeddings vs GNN layers
        emb_params = list(model.user_emb.parameters()) + \
                     list(model.product_emb.parameters()) + \
                     list(model.vehicle_emb.parameters())
        emb_param_ids = {id(p) for p in emb_params}
        gnn_params = [p for p in model.parameters() if id(p) not in emb_param_ids]

        self.optimizer = torch.optim.Adam([
            {"params": emb_params, "lr": self.config.emb_lr, "weight_decay": self.config.emb_weight_decay},
            {"params": gnn_params, "lr": self.config.gnn_lr, "weight_decay": self.config.gnn_weight_decay},
        ])

        self.best_val_loss = float("inf")
        self.patience_counter = 0

    def train(self) -> dict[str, list[float]]:
        """Run full training loop.

        Returns:
            Dictionary of metric histories.
        """
        history = {"train_loss": [], "val_loss": []}
        checkpoint_dir = Path(self.config.checkpoint_dir)
        checkpoint_dir.mkdir(parents=True, exist_ok=True)

        for epoch in range(self.config.epochs):
            train_loss = self._train_epoch()
            val_loss = self._validate()

            history["train_loss"].append(train_loss)
            history["val_loss"].append(val_loss)

            logger.info(
                f"Epoch {epoch+1}/{self.config.epochs} — "
                f"train_loss={train_loss:.4f}, val_loss={val_loss:.4f}"
            )

            # Early stopping
            if val_loss < self.best_val_loss:
                self.best_val_loss = val_loss
                self.patience_counter = 0
                self.save_checkpoint(checkpoint_dir / "best_model.pt")
            else:
                self.patience_counter += 1
                if self.patience_counter >= self.config.patience:
                    logger.info(f"Early stopping at epoch {epoch+1}")
                    break

        # Load best model
        self.load_checkpoint(checkpoint_dir / "best_model.pt")
        return history

    def _train_epoch(self) -> float:
        """Single training epoch."""
        self.model.train()
        self.optimizer.zero_grad()

        user_emb, product_emb = self.model(self.data)

        # Get positive edges (user→product interactions)
        edge_key = ("user", "interacts", "product")
        if edge_key not in self.data.edge_index_dict:
            return 0.0

        pos_edge_index = self.data[edge_key].edge_index
        pos_weights = self.data[edge_key].edge_weight

        train_mask = self.data["user"].train_mask
        # Filter to training users
        mask = train_mask[pos_edge_index[0]]
        pos_src = pos_edge_index[0][mask]
        pos_dst = pos_edge_index[1][mask]
        pos_w = pos_weights[mask]

        if len(pos_src) == 0:
            return 0.0

        # Positive scores
        pos_scores = self.model.score(user_emb[pos_src], product_emb[pos_dst])

        # Negative sampling (mixed strategy)
        num_neg = len(pos_src)
        neg_dst = self._sample_negatives(pos_src, pos_dst, num_neg, product_emb.size(0))
        neg_scores = self.model.score(user_emb[pos_src], product_emb[neg_dst])

        # Edge-weighted BCE loss
        pos_loss = -F.logsigmoid(pos_scores) * pos_w
        neg_loss = -F.logsigmoid(-neg_scores)
        loss = (pos_loss.mean() + neg_loss.mean()) / 2

        loss.backward()
        nn.utils.clip_grad_norm_(self.model.parameters(), self.config.max_grad_norm)
        self.optimizer.step()

        return loss.item()

    def _validate(self) -> float:
        """Compute validation loss."""
        self.model.eval()
        with torch.no_grad():
            user_emb, product_emb = self.model(self.data)

            edge_key = ("user", "interacts", "product")
            if edge_key not in self.data.edge_index_dict:
                return 0.0

            pos_edge_index = self.data[edge_key].edge_index
            pos_weights = self.data[edge_key].edge_weight

            val_mask = self.data["user"].val_mask
            mask = val_mask[pos_edge_index[0]]
            pos_src = pos_edge_index[0][mask]
            pos_dst = pos_edge_index[1][mask]
            pos_w = pos_weights[mask]

            if len(pos_src) == 0:
                return 0.0

            pos_scores = self.model.score(user_emb[pos_src], product_emb[pos_dst])
            num_neg = len(pos_src)
            neg_dst = self._sample_negatives(pos_src, pos_dst, num_neg, product_emb.size(0))
            neg_scores = self.model.score(user_emb[pos_src], product_emb[neg_dst])

            pos_loss = -F.logsigmoid(pos_scores) * pos_w
            neg_loss = -F.logsigmoid(-neg_scores)
            loss = (pos_loss.mean() + neg_loss.mean()) / 2

        return loss.item()

    def _sample_negatives(
        self,
        pos_src: torch.Tensor,
        pos_dst: torch.Tensor,
        num_neg: int,
        num_products: int,
    ) -> torch.Tensor:
        """Mixed negative sampling: in-batch + global random.

        Fitment-aware negatives require product→vehicle edges at runtime,
        which adds complexity. For now, use 50% in-batch + 50% random.
        Fitment-aware negatives can be added as a refinement.
        """
        n_inbatch = int(num_neg * self.config.neg_ratio_inbatch)
        n_random = num_neg - n_inbatch

        # In-batch: shuffle positive destinations
        inbatch_neg = pos_dst[torch.randperm(len(pos_dst))[:n_inbatch]]

        # Global random
        random_neg = torch.randint(0, num_products, (n_random,), device=pos_src.device)

        return torch.cat([inbatch_neg, random_neg])

    def save_checkpoint(self, path: str | Path) -> None:
        """Save model checkpoint."""
        torch.save({
            "model_state_dict": self.model.state_dict(),
            "optimizer_state_dict": self.optimizer.state_dict(),
            "best_val_loss": self.best_val_loss,
        }, path)
        logger.info(f"Saved checkpoint → {path}")

    def load_checkpoint(self, path: str | Path) -> None:
        """Load model checkpoint (warm-start)."""
        path = Path(path)
        if not path.exists():
            logger.warning(f"No checkpoint found at {path}")
            return
        checkpoint = torch.load(path, map_location=self.device, weights_only=False)
        self.model.load_state_dict(checkpoint["model_state_dict"])
        if "optimizer_state_dict" in checkpoint:
            self.optimizer.load_state_dict(checkpoint["optimizer_state_dict"])
        self.best_val_loss = checkpoint.get("best_val_loss", float("inf"))
        logger.info(f"Loaded checkpoint ← {path}")
