"""HolleyGAT: Two-tower HeteroGAT for vehicle fitment recommendations."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

import torch
import torch.nn as nn
import torch.nn.functional as F  # noqa: N812
from torch_geometric.nn import GATConv, HeteroConv

if TYPE_CHECKING:
    from torch_geometric.data import HeteroData


class HolleyGAT(nn.Module):
    """Two-tower heterogeneous GAT model.

    Architecture (from design spec Section 4):
        Input: learned embeddings per node type + product FeatureMLP
        GNN: 2x HeteroConv with GATConv per edge type (7 directions)
        Projection: separate user/product towers -> L2-normalized 128-dim embeddings
        Score: dot product
    """

    def __init__(
        self,
        n_users: int,
        n_products: int,
        n_vehicles: int,
        n_part_types: int,
        config: dict[str, Any],
    ):
        super().__init__()
        model_cfg = config["model"]
        emb_dim = model_cfg["embedding_dim"]  # 128
        hidden_dim = model_cfg["hidden_dim"]  # 256
        num_heads = model_cfg["num_heads"]  # 4
        dropout = model_cfg["dropout"]  # 0.1
        proj_dropout = model_cfg["proj_dropout"]  # 0.2
        head_dim = hidden_dim // num_heads  # 64

        # Learned embeddings
        self.user_embedding = nn.Embedding(n_users, emb_dim)
        self.product_embedding = nn.Embedding(n_products, emb_dim)
        self.vehicle_embedding = nn.Embedding(n_vehicles, emb_dim)

        # Product feature MLP: part_type_emb(32) + price + log_pop + fitment_breadth -> emb_dim
        self.part_type_embedding = nn.Embedding(n_part_types, 32)
        self.product_feature_mlp = nn.Sequential(
            nn.Linear(32 + 3, emb_dim),
            nn.ReLU(),
        )

        # HeteroConv layers (7 message-passing directions)
        self.conv1 = HeteroConv({
            ("user", "interacts", "product"): GATConv(
                emb_dim, head_dim, heads=num_heads, dropout=dropout, add_self_loops=False
            ),
            ("product", "rev_interacts", "user"): GATConv(
                emb_dim, head_dim, heads=num_heads, dropout=dropout, add_self_loops=False
            ),
            ("product", "fits", "vehicle"): GATConv(
                emb_dim, head_dim, heads=num_heads, dropout=dropout, add_self_loops=False
            ),
            ("vehicle", "rev_fits", "product"): GATConv(
                emb_dim, head_dim, heads=num_heads, dropout=dropout, add_self_loops=False
            ),
            ("user", "owns", "vehicle"): GATConv(
                emb_dim, head_dim, heads=num_heads, dropout=dropout, add_self_loops=False
            ),
            ("vehicle", "rev_owns", "user"): GATConv(
                emb_dim, head_dim, heads=num_heads, dropout=dropout, add_self_loops=False
            ),
            ("product", "co_purchased", "product"): GATConv(
                emb_dim, head_dim, heads=num_heads, dropout=dropout, add_self_loops=False
            ),
        }, aggr="sum")

        self.conv2 = HeteroConv({
            ("user", "interacts", "product"): GATConv(
                hidden_dim, head_dim, heads=num_heads, dropout=dropout, add_self_loops=False
            ),
            ("product", "rev_interacts", "user"): GATConv(
                hidden_dim, head_dim, heads=num_heads, dropout=dropout, add_self_loops=False
            ),
            ("product", "fits", "vehicle"): GATConv(
                hidden_dim, head_dim, heads=num_heads, dropout=dropout, add_self_loops=False
            ),
            ("vehicle", "rev_fits", "product"): GATConv(
                hidden_dim, head_dim, heads=num_heads, dropout=dropout, add_self_loops=False
            ),
            ("user", "owns", "vehicle"): GATConv(
                hidden_dim, head_dim, heads=num_heads, dropout=dropout, add_self_loops=False
            ),
            ("vehicle", "rev_owns", "user"): GATConv(
                hidden_dim, head_dim, heads=num_heads, dropout=dropout, add_self_loops=False
            ),
            ("product", "co_purchased", "product"): GATConv(
                hidden_dim, head_dim, heads=num_heads, dropout=dropout, add_self_loops=False
            ),
        }, aggr="sum")

        self.dropout = nn.Dropout(dropout)

        # Projection heads
        self.user_proj = nn.Sequential(
            nn.Linear(hidden_dim, hidden_dim),
            nn.ReLU(),
            nn.Dropout(proj_dropout),
            nn.Linear(hidden_dim, emb_dim),
        )
        self.product_proj = nn.Sequential(
            nn.Linear(hidden_dim, hidden_dim),
            nn.ReLU(),
            nn.Dropout(proj_dropout),
            nn.Linear(hidden_dim, emb_dim),
        )

        self._init_weights()

    def _init_weights(self):
        """Xavier initialization for embeddings."""
        nn.init.xavier_uniform_(self.user_embedding.weight)
        nn.init.xavier_uniform_(self.product_embedding.weight)
        nn.init.xavier_uniform_(self.vehicle_embedding.weight)
        nn.init.xavier_uniform_(self.part_type_embedding.weight)

    def get_initial_embeddings(self, data: HeteroData) -> dict[str, torch.Tensor]:
        """Compute initial node embeddings before GNN layers."""
        # User: learned embedding only
        user_x = self.user_embedding.weight

        # Product: learned embedding + feature MLP
        pt_emb = self.part_type_embedding(data["product"].part_type_id)
        feat_input = torch.cat([pt_emb, data["product"].x_num], dim=1)
        product_x = self.product_embedding.weight + self.product_feature_mlp(feat_input)

        # Vehicle: learned embedding (vehicle features are structural, not learned)
        vehicle_x = self.vehicle_embedding.weight

        return {"user": user_x, "product": product_x, "vehicle": vehicle_x}

    def forward(
        self, data: HeteroData
    ) -> tuple[torch.Tensor, torch.Tensor]:
        """Forward pass producing L2-normalized user and product embeddings.

        Returns:
            (user_embs, product_embs) both of shape (N, embedding_dim), L2-normalized.
        """
        x_dict = self.get_initial_embeddings(data)

        # Build edge_index dict for HeteroConv
        edge_index_dict = {}
        for edge_type in data.edge_types:
            if hasattr(data[edge_type], "edge_index"):
                edge_index_dict[edge_type] = data[edge_type].edge_index

        # Layer 1
        x_dict = self.conv1(x_dict, edge_index_dict)
        x_dict = {key: F.elu(self.dropout(x)) for key, x in x_dict.items()}

        # Layer 2
        x_dict = self.conv2(x_dict, edge_index_dict)
        x_dict = {key: F.elu(x) for key, x in x_dict.items()}

        # Project and normalize
        user_embs = F.normalize(self.user_proj(x_dict["user"]), dim=1)
        product_embs = F.normalize(self.product_proj(x_dict["product"]), dim=1)

        return user_embs, product_embs

    @staticmethod
    def score(user_embs: torch.Tensor, product_embs: torch.Tensor) -> torch.Tensor:
        """Compute dot product scores between user and product embeddings."""
        return torch.mm(user_embs, product_embs.t())

    @staticmethod
    def bpr_loss(pos_scores: torch.Tensor, neg_scores: torch.Tensor) -> torch.Tensor:
        """BPR pairwise ranking loss.

        Args:
            pos_scores: Scores for positive (user, product) pairs.
            neg_scores: Scores for negative (user, product) pairs.

        Returns:
            Scalar loss value.
        """
        return -F.logsigmoid(pos_scores - neg_scores).mean()
