"""HeteroGAT: Config-driven heterogeneous GAT for recommendations.

Generalized from HolleyGAT — edge types and node types are driven by
topology config rather than hardcoded.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

import torch
import torch.nn as nn
import torch.nn.functional as F  # noqa: N812
from torch_geometric.nn import GATConv, HeteroConv

if TYPE_CHECKING:
    from torch_geometric.data import HeteroData


class HeteroGAT(nn.Module):
    """Two-tower heterogeneous GAT model.

    Architecture:
        Input: learned embeddings per node type + gated feature fusion
        GNN: 2x HeteroConv with GATConv per edge type + skip connections
        Projection: separate user/product towers -> L2-normalized embeddings
        Score: dot product
    """

    def __init__(
        self,
        n_users: int,
        n_products: int,
        n_entities: int,
        n_categories: int,
        edge_types: list[tuple[str, str, str]],
        config: dict[str, Any],
        *,
        entity_type_name: str = "entity",
        product_num_features: int = 3,
        entity_num_features: int = 0,
    ):
        super().__init__()
        model_cfg = config["model"]
        emb_dim = model_cfg["embedding_dim"]
        hidden_dim = model_cfg["hidden_dim"]
        num_heads = model_cfg["num_heads"]
        dropout = model_cfg["dropout"]
        proj_dropout = model_cfg.get("proj_dropout", 0.2)

        if hidden_dim % num_heads != 0:
            raise ValueError(
                f"hidden_dim ({hidden_dim}) must be divisible by num_heads ({num_heads})"
            )
        head_dim = hidden_dim // num_heads

        self.entity_type_name = entity_type_name
        self.has_entity = n_entities > 0
        self.emb_dim = emb_dim
        self.hidden_dim = hidden_dim

        # Learned embeddings
        self.user_embedding = nn.Embedding(n_users, emb_dim)
        self.product_embedding = nn.Embedding(n_products, emb_dim)

        if self.has_entity:
            self.entity_embedding = nn.Embedding(n_entities, emb_dim)

        # Product feature MLP: category_emb(32) + num_features -> emb_dim
        category_emb_dim = 32
        self.category_embedding = nn.Embedding(max(n_categories, 1), category_emb_dim)
        self.product_feature_mlp = nn.Sequential(
            nn.Linear(category_emb_dim + product_num_features, emb_dim),
            nn.ReLU(),
        )

        # Gated fusion for products: learned gate blends embedding and feature MLP
        self.product_gate = nn.Linear(emb_dim * 2, emb_dim)

        # Entity feature MLP (mirrors product pattern)
        self.has_entity_features = self.has_entity and entity_num_features > 0
        if self.has_entity_features:
            self.entity_feature_mlp = nn.Sequential(
                nn.Linear(entity_num_features, emb_dim),
                nn.ReLU(),
            )
            self.entity_gate = nn.Linear(emb_dim * 2, emb_dim)

        # Build HeteroConv layers from edge types
        # edge_dim=1 enables edge weight integration in attention
        def _make_conv(in_dim: int) -> HeteroConv:
            convs = {}
            for et in edge_types:
                convs[et] = GATConv(
                    in_dim, head_dim, heads=num_heads,
                    dropout=dropout, add_self_loops=False,
                    edge_dim=1,
                )
            return HeteroConv(convs, aggr="sum")

        self.conv1 = _make_conv(emb_dim)
        self.conv2 = _make_conv(hidden_dim)

        # Skip connections: per-node-type linear projections for dimension matching
        # Ensures nodes with no incoming edges retain their embeddings
        node_types = {"user", "product"}
        if self.has_entity:
            node_types.add(entity_type_name)
        self.skip1 = nn.ModuleDict({
            nt: nn.Linear(emb_dim, hidden_dim) for nt in sorted(node_types)
        })
        self.skip2 = nn.ModuleDict({
            nt: nn.Linear(hidden_dim, hidden_dim) for nt in sorted(node_types)
        })

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
        if self.has_entity:
            nn.init.xavier_uniform_(self.entity_embedding.weight)
        nn.init.xavier_uniform_(self.category_embedding.weight)

    @staticmethod
    def _gated_fusion(
        embedding: torch.Tensor,
        features: torch.Tensor,
        gate_linear: nn.Linear,
    ) -> torch.Tensor:
        """Blend embedding and feature vectors via a learned gate."""
        gate = torch.sigmoid(gate_linear(torch.cat([embedding, features], dim=1)))
        return gate * embedding + (1 - gate) * features

    def get_initial_embeddings(self, data: HeteroData) -> dict[str, torch.Tensor]:
        """Compute initial node embeddings before GNN layers."""
        # User: learned embedding only
        user_x = self.user_embedding.weight

        # Product: gated fusion of learned embedding + feature MLP
        cat_emb = self.category_embedding(data["product"].category_id)
        feat_input = torch.cat([cat_emb, data["product"].x_num], dim=1)
        product_features = self.product_feature_mlp(feat_input)
        product_x = self._gated_fusion(
            self.product_embedding.weight, product_features, self.product_gate,
        )

        x_dict = {"user": user_x, "product": product_x}

        if self.has_entity:
            entity_emb = self.entity_embedding.weight
            if self.has_entity_features and hasattr(data[self.entity_type_name], "x"):
                entity_features = self.entity_feature_mlp(data[self.entity_type_name].x)
                entity_x = self._gated_fusion(entity_emb, entity_features, self.entity_gate)
            else:
                entity_x = entity_emb
            x_dict[self.entity_type_name] = entity_x

        return x_dict

    def forward(self, data: HeteroData) -> tuple[torch.Tensor, torch.Tensor]:
        """Forward pass producing L2-normalized user and product embeddings."""
        x_dict = self.get_initial_embeddings(data)

        edge_index_dict = {}
        edge_attr_dict = {}
        for edge_type in data.edge_types:
            store = data[edge_type]
            if hasattr(store, "edge_index"):
                edge_index_dict[edge_type] = store.edge_index
                if hasattr(store, "edge_weight"):
                    # GATConv expects [num_edges, edge_dim] shape
                    edge_attr_dict[edge_type] = store.edge_weight.unsqueeze(-1)

        conv_kwargs = {}
        if edge_attr_dict:
            conv_kwargs["edge_attr_dict"] = edge_attr_dict

        # Layer 1 with skip connections
        x_in = x_dict
        x_conv = self.conv1(x_in, edge_index_dict, **conv_kwargs)
        x_dict = {}
        for key in x_in:
            conv_out = x_conv.get(key, torch.zeros_like(self.skip1[key](x_in[key])))
            x_dict[key] = F.elu(self.dropout(conv_out + self.skip1[key](x_in[key])))

        # Layer 2 with skip connections
        x_in = x_dict
        x_conv = self.conv2(x_in, edge_index_dict, **conv_kwargs)
        x_dict = {}
        for key in x_in:
            conv_out = x_conv.get(key, torch.zeros_like(self.skip2[key](x_in[key])))
            x_dict[key] = F.elu(conv_out + self.skip2[key](x_in[key]))

        # Project and normalize
        user_embs = F.normalize(self.user_proj(x_dict["user"]), dim=1)
        product_embs = F.normalize(self.product_proj(x_dict["product"]), dim=1)

        return user_embs, product_embs

    @staticmethod
    def score(user_embs: torch.Tensor, product_embs: torch.Tensor) -> torch.Tensor:
        """Compute dot product scores between user and product embeddings."""
        return torch.mm(user_embs, product_embs.t())

    @staticmethod
    def bpr_loss(
        pos_scores: torch.Tensor,
        neg_scores: torch.Tensor,
        weights: torch.Tensor | None = None,
    ) -> torch.Tensor:
        """BPR pairwise ranking loss, optionally weighted by interaction strength.

        When weights are provided, the loss is normalized by the sum of weights
        (not the count of pairs) so that the gradient magnitude is invariant to
        global weight scaling — only *relative* weights matter.
        """
        per_pair = -F.logsigmoid(pos_scores - neg_scores)
        if weights is not None:
            return (per_pair * weights).sum() / weights.sum().clamp(min=1e-8)
        return per_pair.mean()
