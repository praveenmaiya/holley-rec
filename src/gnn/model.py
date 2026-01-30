"""Heterogeneous GAT model for vehicle fitment recommendations.

Adapted from Faire's two-tower GNN design:
- Learned embeddings for user/product/vehicle nodes
- Product feature MLP (part_type, price, log_popularity)
- 2-layer HeteroConv with GATConv (separate attention per edge type)
- Two projection towers: User MLP + Product MLP → 128-dim embeddings
- L2-normalized dot product scoring
"""

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch_geometric.data import HeteroData
from torch_geometric.nn import GATConv, HeteroConv


class ProductFeatureMLP(nn.Module):
    """MLP to encode product features (part_type embedding + continuous features)."""

    def __init__(
        self,
        num_part_types: int,
        part_type_dim: int = 32,
        num_continuous: int = 3,  # price, log_popularity, fitment_breadth
        output_dim: int = 128,
    ):
        super().__init__()
        self.part_type_emb = nn.Embedding(num_part_types, part_type_dim)
        self.mlp = nn.Sequential(
            nn.Linear(part_type_dim + num_continuous, output_dim),
            nn.ReLU(),
            nn.Linear(output_dim, output_dim),
        )

    def forward(self, part_type: torch.Tensor, x: torch.Tensor) -> torch.Tensor:
        pt_emb = self.part_type_emb(part_type)
        combined = torch.cat([pt_emb, x], dim=-1)
        return self.mlp(combined)


class HolleyGAT(nn.Module):
    """Heterogeneous GAT for vehicle fitment recommendations."""

    def __init__(
        self,
        num_users: int,
        num_products: int,
        num_vehicles: int,
        num_part_types: int,
        embedding_dim: int = 128,
        hidden_dim: int = 256,
        num_heads: int = 4,
        dropout: float = 0.1,
    ):
        super().__init__()
        self.embedding_dim = embedding_dim
        self.hidden_dim = hidden_dim

        # Node embeddings (learned)
        self.user_emb = nn.Embedding(num_users, embedding_dim)
        self.product_emb = nn.Embedding(num_products, embedding_dim)
        self.vehicle_emb = nn.Embedding(num_vehicles, embedding_dim)

        # Product feature encoder
        self.product_mlp = ProductFeatureMLP(
            num_part_types=num_part_types,
            output_dim=embedding_dim,
        )

        # Layer 1: HeteroConv with GATConv per edge type
        self.conv1 = HeteroConv(
            {
                ("user", "interacts", "product"): GATConv(
                    embedding_dim, hidden_dim // num_heads, heads=num_heads, dropout=dropout,
                ),
                ("product", "rev_interacts", "user"): GATConv(
                    embedding_dim, hidden_dim // num_heads, heads=num_heads, dropout=dropout,
                ),
                ("product", "fits", "vehicle"): GATConv(
                    embedding_dim, hidden_dim // num_heads, heads=num_heads, dropout=dropout,
                ),
                ("vehicle", "rev_fits", "product"): GATConv(
                    embedding_dim, hidden_dim // num_heads, heads=num_heads, dropout=dropout,
                ),
                ("user", "owns", "vehicle"): GATConv(
                    embedding_dim, hidden_dim // num_heads, heads=num_heads, dropout=dropout,
                ),
                ("vehicle", "rev_owns", "user"): GATConv(
                    embedding_dim, hidden_dim // num_heads, heads=num_heads, dropout=dropout,
                ),
                ("product", "co_purchased", "product"): GATConv(
                    embedding_dim, hidden_dim // num_heads, heads=num_heads, dropout=dropout,
                ),
            },
            aggr="sum",
        )

        # Layer 2
        self.conv2 = HeteroConv(
            {
                ("user", "interacts", "product"): GATConv(
                    hidden_dim, hidden_dim // num_heads, heads=num_heads, dropout=dropout,
                ),
                ("product", "rev_interacts", "user"): GATConv(
                    hidden_dim, hidden_dim // num_heads, heads=num_heads, dropout=dropout,
                ),
                ("product", "fits", "vehicle"): GATConv(
                    hidden_dim, hidden_dim // num_heads, heads=num_heads, dropout=dropout,
                ),
                ("vehicle", "rev_fits", "product"): GATConv(
                    hidden_dim, hidden_dim // num_heads, heads=num_heads, dropout=dropout,
                ),
                ("user", "owns", "vehicle"): GATConv(
                    hidden_dim, hidden_dim // num_heads, heads=num_heads, dropout=dropout,
                ),
                ("vehicle", "rev_owns", "user"): GATConv(
                    hidden_dim, hidden_dim // num_heads, heads=num_heads, dropout=dropout,
                ),
                ("product", "co_purchased", "product"): GATConv(
                    hidden_dim, hidden_dim // num_heads, heads=num_heads, dropout=dropout,
                ),
            },
            aggr="sum",
        )

        # Projection towers (user and product → same embedding space)
        self.user_tower = nn.Sequential(
            nn.Linear(hidden_dim, hidden_dim),
            nn.ReLU(),
            nn.Dropout(dropout),
            nn.Linear(hidden_dim, embedding_dim),
        )
        self.product_tower = nn.Sequential(
            nn.Linear(hidden_dim, hidden_dim),
            nn.ReLU(),
            nn.Dropout(dropout),
            nn.Linear(hidden_dim, embedding_dim),
        )

        self.dropout = dropout
        self._init_weights()

    def _init_weights(self):
        nn.init.xavier_uniform_(self.user_emb.weight)
        nn.init.xavier_uniform_(self.product_emb.weight)
        nn.init.xavier_uniform_(self.vehicle_emb.weight)

    def get_initial_embeddings(
        self, data: HeteroData
    ) -> dict[str, torch.Tensor]:
        """Compute initial node embeddings before GNN layers."""
        user_x = self.user_emb(data["user"].node_id)
        product_x = self.product_emb(data["product"].node_id) + self.product_mlp(
            data["product"].part_type, data["product"].x
        )
        vehicle_x = self.vehicle_emb(data["vehicle"].node_id)
        return {"user": user_x, "product": product_x, "vehicle": vehicle_x}

    def forward(
        self, data: HeteroData
    ) -> tuple[torch.Tensor, torch.Tensor]:
        """Forward pass returning L2-normalized user and product embeddings.

        Returns:
            (user_embeddings, product_embeddings) both [N, embedding_dim]
        """
        x_dict = self.get_initial_embeddings(data)

        # Layer 1
        x_dict = self.conv1(x_dict, data.edge_index_dict)
        x_dict = {k: F.elu(v) for k, v in x_dict.items()}
        x_dict = {k: F.dropout(v, p=self.dropout, training=self.training) for k, v in x_dict.items()}

        # Layer 2
        x_dict = self.conv2(x_dict, data.edge_index_dict)
        x_dict = {k: F.elu(v) for k, v in x_dict.items()}

        # Project to shared embedding space
        user_out = self.user_tower(x_dict["user"])
        product_out = self.product_tower(x_dict["product"])

        # L2 normalize for dot product scoring
        user_out = F.normalize(user_out, p=2, dim=-1)
        product_out = F.normalize(product_out, p=2, dim=-1)

        return user_out, product_out

    def score(
        self,
        user_emb: torch.Tensor,
        product_emb: torch.Tensor,
    ) -> torch.Tensor:
        """Dot product similarity score."""
        return (user_emb * product_emb).sum(dim=-1)
