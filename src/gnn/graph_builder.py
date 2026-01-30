"""Build PyTorch Geometric HeteroData from DataFrames."""

import logging

import numpy as np
import pandas as pd
import torch
from sklearn.preprocessing import LabelEncoder
from torch_geometric.data import HeteroData

logger = logging.getLogger(__name__)


class HolleyGraphBuilder:
    """Convert DataFrames into a PyG HeteroData heterogeneous graph."""

    def __init__(self):
        self.user_encoder = LabelEncoder()
        self.product_encoder = LabelEncoder()
        self.vehicle_encoder = LabelEncoder()
        self.part_type_encoder = LabelEncoder()

    def build(self, data: dict[str, pd.DataFrame]) -> HeteroData:
        """Build HeteroData from loaded DataFrames.

        Args:
            data: Dictionary with keys matching GNNDataLoader.TABLES.

        Returns:
            PyG HeteroData with user, product, vehicle nodes and all edge types.
        """
        hetero = HeteroData()

        # --- Encode node IDs ---
        users = data["user_nodes"]
        products = data["product_nodes"]
        vehicles = data["vehicle_nodes"]

        self.user_encoder.fit(users["user_id"])
        self.product_encoder.fit(products["sku"])
        self.vehicle_encoder.fit(vehicles["vehicle_id"])

        # --- User nodes ---
        num_users = len(users)
        hetero["user"].num_nodes = num_users
        # User IDs will be embedded (learned), so just store index
        hetero["user"].node_id = torch.arange(num_users)

        # Engagement tier as feature (0=cold, 1=warm, 2=hot)
        tier_map = {"cold": 0, "warm": 1, "hot": 2}
        hetero["user"].engagement_tier = torch.tensor(
            users["engagement_tier"].map(tier_map).fillna(0).astype(int).values,
            dtype=torch.long,
        )

        # --- Product nodes ---
        num_products = len(products)
        hetero["product"].num_nodes = num_products
        hetero["product"].node_id = torch.arange(num_products)

        # Product features: part_type (categorical), price, log_popularity, fitment_breadth
        self.part_type_encoder.fit(
            products["part_type"].fillna("UNKNOWN").values
        )
        part_type_ids = self.part_type_encoder.transform(
            products["part_type"].fillna("UNKNOWN").values
        )
        hetero["product"].part_type = torch.tensor(part_type_ids, dtype=torch.long)
        hetero["product"].x = torch.tensor(
            np.column_stack([
                products["price"].fillna(0).values,
                products["log_popularity"].fillna(0).values,
                products["fitment_breadth"].fillna(0).values,
            ]),
            dtype=torch.float,
        )

        # --- Vehicle nodes ---
        num_vehicles = len(vehicles)
        hetero["vehicle"].num_nodes = num_vehicles
        hetero["vehicle"].node_id = torch.arange(num_vehicles)
        hetero["vehicle"].x = torch.tensor(
            np.column_stack([
                vehicles["user_count"].fillna(0).values,
                vehicles["product_count"].fillna(0).values,
            ]),
            dtype=torch.float,
        )

        # --- Edges ---
        self._add_user_product_edges(hetero, data["edges_user_product"])
        self._add_product_vehicle_edges(hetero, data["edges_product_vehicle"])
        self._add_user_vehicle_edges(hetero, data["edges_user_vehicle"])
        self._add_product_product_edges(hetero, data["edges_product_product"])

        # --- Train/val/test masks on users ---
        self._add_user_masks(hetero, num_users)

        logger.info(
            f"Built graph: {num_users} users, {num_products} products, "
            f"{num_vehicles} vehicles"
        )
        return hetero

    def _add_user_product_edges(
        self, hetero: HeteroData, df: pd.DataFrame
    ) -> None:
        if df.empty:
            return
        src = self.user_encoder.transform(df["user_id"])
        dst = self.product_encoder.transform(df["sku"])
        edge_index = torch.tensor(np.array([src, dst]), dtype=torch.long)
        weights = torch.tensor(df["weight"].values, dtype=torch.float)

        hetero["user", "interacts", "product"].edge_index = edge_index
        hetero["user", "interacts", "product"].edge_weight = weights
        # Reverse
        hetero["product", "rev_interacts", "user"].edge_index = edge_index.flip(0)
        hetero["product", "rev_interacts", "user"].edge_weight = weights

    def _add_product_vehicle_edges(
        self, hetero: HeteroData, df: pd.DataFrame
    ) -> None:
        if df.empty:
            return
        src = self.product_encoder.transform(df["sku"])
        dst = self.vehicle_encoder.transform(df["vehicle_id"])
        edge_index = torch.tensor(np.array([src, dst]), dtype=torch.long)

        hetero["product", "fits", "vehicle"].edge_index = edge_index
        hetero["vehicle", "rev_fits", "product"].edge_index = edge_index.flip(0)

    def _add_user_vehicle_edges(
        self, hetero: HeteroData, df: pd.DataFrame
    ) -> None:
        if df.empty:
            return
        src = self.user_encoder.transform(df["user_id"])
        dst = self.vehicle_encoder.transform(df["vehicle_id"])
        edge_index = torch.tensor(np.array([src, dst]), dtype=torch.long)

        hetero["user", "owns", "vehicle"].edge_index = edge_index
        hetero["vehicle", "rev_owns", "user"].edge_index = edge_index.flip(0)

    def _add_product_product_edges(
        self, hetero: HeteroData, df: pd.DataFrame
    ) -> None:
        if df.empty:
            return
        src = self.product_encoder.transform(df["sku_a"])
        dst = self.product_encoder.transform(df["sku_b"])
        # Bidirectional
        edge_index = torch.tensor(
            np.array([
                np.concatenate([src, dst]),
                np.concatenate([dst, src]),
            ]),
            dtype=torch.long,
        )
        weights = torch.tensor(
            np.concatenate([df["weight"].values, df["weight"].values]),
            dtype=torch.float,
        )

        hetero["product", "co_purchased", "product"].edge_index = edge_index
        hetero["product", "co_purchased", "product"].edge_weight = weights

    def _add_user_masks(self, hetero: HeteroData, num_users: int) -> None:
        """80/10/10 train/val/test split on users."""
        perm = torch.randperm(num_users)
        n_train = int(0.8 * num_users)
        n_val = int(0.1 * num_users)

        train_mask = torch.zeros(num_users, dtype=torch.bool)
        val_mask = torch.zeros(num_users, dtype=torch.bool)
        test_mask = torch.zeros(num_users, dtype=torch.bool)

        train_mask[perm[:n_train]] = True
        val_mask[perm[n_train : n_train + n_val]] = True
        test_mask[perm[n_train + n_val :]] = True

        hetero["user"].train_mask = train_mask
        hetero["user"].val_mask = val_mask
        hetero["user"].test_mask = test_mask

    @property
    def num_part_types(self) -> int:
        return len(self.part_type_encoder.classes_)
