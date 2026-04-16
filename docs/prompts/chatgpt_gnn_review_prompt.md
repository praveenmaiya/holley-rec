# ChatGPT Peer Review Prompt: GNN Option A Implementation

You are reviewing a complete GNN recommendation system implementation for an automotive parts e-commerce company (Holley). The system uses a heterogeneous Graph Attention Network (HeteroGAT) to generate personalized product recommendations for email campaigns.

## Context

- **Company**: Holley (automotive aftermarket parts)
- **Problem**: 504K users with vehicle fitment data, 98% cold (no browsing/purchase history). Current SQL pipeline uses segment-based popularity ranking. The GNN hypothesis: can graph structure (User→Vehicle→Product message passing + co-purchase similarity) beat SQL popularity for cold users?
- **Architecture**: Two-tower HeteroGAT with 3 node types (User, Product, Vehicle), 4 edge types (7 message-passing directions), BPR loss, dual optimizer
- **Primary metric**: Hit Rate@4 (matches 4 email slots)
- **Honest assessment**: The GNN likely WON'T beat SQL for cold users — this is designed as a clean hypothesis test. A null result leads to Option A+ (semantic enrichment).

## What I Need You To Review

Please review the following for:

1. **Architectural correctness** — Does the HeteroGAT architecture make sense for this graph? Are the edge types and message-passing directions correct?
2. **Data leakage risks** — Is the temporal split (train: Sep 1 2025 to T-30, test: last 30 days) correctly enforced across all components? Are val/test user interaction edges properly excluded from training?
3. **Evaluation methodology** — Is the evaluation fair? Are GNN and SQL baseline compared on the same users with the same candidate sets? Is the go/no-go threshold reasonable?
4. **Training stability** — Is the dual optimizer setup sound? Is the negative sampling strategy (50% in-batch, 30% fitment-hard, 20% random) appropriate? Is BPR the right loss?
5. **Business rule implementation** — Is the 2+2 fitment/universal slot reservation correct in both scorer and evaluator? Does the PartType diversity cap work?
6. **SQL correctness** — Do the export queries correctly join across BigQuery tables? Are variant dedup regexes correct? Is the co-purchase PMI filtering sound?
7. **Production readiness** — Would you trust this code to run in production? What's missing?
8. **Test coverage** — Are the tests adequate? What edge cases are missing?
9. **Potential bugs** — Anything that looks like it would fail at runtime with real data?

---

## FILE 1: Design Spec (docs/plans/2026-02-16-gnn-option-a-design.md)

```markdown
# GNN Option A: Clean Hypothesis Test — Design Spec

**Date**: 2026-02-16
**Status**: Draft (v3 — final review fixes)
**Author**: Praveen Maiya
**Linear**: AUX-12314

---

## 1. Problem Statement

The v5.17 SQL pipeline serves 258K fitment+email users. 98% are cold (no browsing/purchase history) and get identical popularity-ranked recommendations per vehicle segment. The pipeline uses 8 hand-tuned weights and a 3-tier segment fallback (`segment -> make -> global`), which means every user with the same vehicle segment sees the same top-4 products ranked by popularity.

**The GNN hypothesis**: Can graph structure (User->Vehicle->Product message passing + Product co-purchase similarity) produce more relevant recommendations than SQL popularity for cold users?

This is a clean hypothesis test. If it fails, we skip to Option A+ (semantic enrichment with LLM-generated product embeddings). If it succeeds, we justify GNN infrastructure investment.

**Why A before A+**: The approach comparison doc recommends A+ as the most promising option. We run A first because: (1) it isolates whether graph structure alone adds value — if topology is useless, semantic enrichment on a useless graph is wasted effort; (2) A is simpler to implement and debug; (3) A's infrastructure (data export, evaluation harness, scoring pipeline) is fully reusable for A+.

### Hard Prerequisites

Before GNN implementation begins:

1. **Deploy Phase 1 SQL fixes (Q1, Q2, S3)** — fitment slot reservation, PartType diversity cap, universal scoring discount. These affect 51% of users today and are independent of GNN. The GNN SQL baseline must be evaluated against the post-Phase-1 pipeline, not the current broken v5.17.
2. **Confirm GPU access** — T4 on gke-metaflow-dev (open question with Sumeet).
3. **Resolve or mitigate I1/I3** — ESP rate limiting (67% drops) and interaction tracking gap must be addressed before online A/B launch. Offline implementation can proceed without this.

GNN offline evaluation should compare against the Phase-1-fixed SQL baseline. Comparing against unfixed v5.17 would overstate GNN's improvement.

---

## 2. Corrected User Funnel

| Label | Count | Definition |
|-------|------:|------------|
| **All-system** | 3,031,468 | All users in unified attributes |
| **Fitment users** | 504,092 | Users with v1_year + v1_make + v1_model populated |
| **Target users** | 258,185 | Fitment users WITH email marketing consent |
| **Non-email fitment** | 245,907 | Fitment users WITHOUT email consent — in graph for density |
| **Email recipients** | 19,711 | Users who actually received email Dec-Feb 2026 |

### Engagement Tiers (of 504K fitment users)

| Tier | Users | % | Definition |
|------|------:|--:|------------|
| Cold | ~494K | 98% | No interactions in training window |
| Warm | ~7.5K | 1.5% | Views only, no cart/purchase |
| Hot | ~2.5K | 0.5% | Cart or purchase activity |

---

## 3. Graph Structure

### Nodes (3 types)

| Type | Count | Features |
|------|------:|----------|
| User | ~504K | engagement_tier, email_lower |
| Product | ~25K | part_type (categorical), price, log_popularity, fitment_breadth |
| Vehicle | ~2K | user_count, product_count |

### Edges (4 types, all bidirectional)

| Type | ~Count | Weight | Temporal constraint |
|------|-------:|--------|---------------------|
| User -> Product (interacts) | ~90K | base x time_decay | Sep 1, 2025 to T-30 |
| Product -> Vehicle (fits) | ~500K | Binary | Full catalog (atemporal) |
| User -> Vehicle (owns) | ~504K | Binary (1 per user) | Full data (atemporal) |
| Product -> Product (co_purchased) | ~200K | log(1 + count) | Sep 1, 2025 to T-30 |

**Total**: ~1.3M edges across 4 types, 7 message-passing directions.

### Key Structural Property

For training-cold users, the only path to product embeddings is:
```
User -> (owns) -> Vehicle -> (rev_fits) -> Products
```

This 2-hop path IS the GNN's entire value proposition.

---

## 4. Model Architecture

```
Input:
  User:    learned embedding (504K x 128)
  Product: learned embedding (25K x 128) + FeatureMLP(part_type_emb_32 + price + log_pop + fitment_breadth)
  Vehicle: learned embedding (2K x 128)

GNN (2 layers):
  HeteroConv with GATConv per edge type (7 directions)
  Layer 1: 128 -> 256 (4 heads x 64), ELU, dropout=0.1
  Layer 2: 256 -> 256 (4 heads x 64), ELU

Projection:
  User tower:    256 -> 256 -> ReLU -> dropout -> 128 -> L2-norm
  Product tower: 256 -> 256 -> ReLU -> dropout -> 128 -> L2-norm

Score: dot(user_emb, product_emb)
```

### Overfitting Risk

~68M learnable embedding parameters but only ~90K interaction edges. Mitigations: L2 regularization, dropout, early stopping on val HR@4.

### Training Configuration

- Loss: BPR (pairwise)
- Negatives: 50% in-batch, 30% within-fitment hard, 20% random
- Optimizer: Dual Adam (emb lr=0.001, GNN lr=0.01)
- Weight decay: 0.01 (embeddings only)
- Gradient clipping: max_norm=1.0
- Early stopping: patience=10 epochs on val Hit Rate@4
- Full-batch training (~2 GB fits on T4)

---

## 5. Evaluation

### Go/No-Go Thresholds (training-cold user HR@4 delta vs SQL):

| Delta | Decision |
|-------|----------|
| >= +3% | GO — proceed to online A/B |
| +1% to +3% | MAYBE — try A+ first |
| -1% to +1% | SKIP — go directly to A+ |
| < -1% | INVESTIGATE — possible overfitting |
```

---

## FILE 2: Config (configs/gnn.yaml)

```yaml
# GNN Option A: HeteroGAT Vehicle Fitment Recommendations
bigquery:
  project_id: ${PROJECT_ID:-auxia-reporting}
  source_project: ${SOURCE_PROJECT:-auxia-gcp}
  dataset: ${GNN_DATASET:-temp_holley_gnn}
  company_id: 1950

graph:
  min_price: 25
  intent_start: "2025-09-01"
  co_purchase_threshold: 2
  co_purchase_top_k: 50
  time_decay_halflife_days: 30
  interaction_weights:
    view: 1
    cart: 3
    order: 5

model:
  embedding_dim: 128
  hidden_dim: 256
  num_heads: 4
  num_layers: 2
  dropout: 0.1
  proj_dropout: 0.2

training:
  lr_embedding: 0.001
  lr_gnn: 0.01
  weight_decay: 0.01
  max_epochs: 100
  patience: 10
  grad_clip: 1.0
  negative_mix:
    in_batch: 0.5
    fitment_hard: 0.3
    random: 0.2

eval:
  k_values: [4, 10, 20]
  test_window_days: 30
  bootstrap_samples: 1000
  user_split: [0.8, 0.1, 0.1]

output:
  shadow_table: "auxia-reporting.temp_holley_gnn.gnn_recommendations"
  model_gcs: "gs://auxia-models/holley/gnn/"
```

---

## FILE 3: Data Loader (src/gnn/data_loader.py)

```python
"""GNN data loader: BigQuery exports to DataFrames with ID mappings."""

import logging
from pathlib import Path
from typing import Any

import pandas as pd

from src.bq_client import BQClient

logger = logging.getLogger(__name__)

SQL_DIR = Path(__file__).resolve().parent.parent.parent / "sql" / "gnn"


class GNNDataLoader:
    """Load GNN graph data from BigQuery exports."""

    def __init__(self, config: dict[str, Any], bq_client: BQClient = None):
        self.config = config
        bq_cfg = config["bigquery"]
        self.bq = bq_client or BQClient(
            project=bq_cfg["project_id"],
            dataset=bq_cfg["dataset"],
        )
        self.project_id = bq_cfg["project_id"]
        self.dataset = bq_cfg["dataset"]

        # Node ID mappings (built during load)
        self.user_to_id: dict[str, int] = {}
        self.product_to_id: dict[str, int] = {}
        self.vehicle_to_id: dict[str, int] = {}

    def run_exports(self) -> None:
        """Run SQL export queries to populate BQ tables."""
        params = {
            "PROJECT_ID": self.project_id,
            "GNN_DATASET": self.dataset,
            "SOURCE_PROJECT": self.config["bigquery"]["source_project"],
        }
        for sql_file in ["export_nodes.sql", "export_edges.sql", "export_test_set.sql",
                         "export_sql_baseline.sql"]:
            path = SQL_DIR / sql_file
            logger.info(f"Running {sql_file}...")
            self.bq.run_query_file(str(path), params=params)
            logger.info(f"Completed {sql_file}")

    def load_nodes(self) -> dict[str, pd.DataFrame]:
        """Load node DataFrames and build ID mappings."""
        table_prefix = f"{self.project_id}.{self.dataset}"

        users = self.bq.run_query(f"SELECT * FROM `{table_prefix}.user_nodes`")
        products = self.bq.run_query(f"SELECT * FROM `{table_prefix}.product_nodes`")
        vehicles = self.bq.run_query(f"SELECT * FROM `{table_prefix}.vehicle_nodes`")

        logger.info(f"Loaded nodes: {len(users)} users, {len(products)} products, {len(vehicles)} vehicles")

        # Build ID mappings
        self.user_to_id = {email: i for i, email in enumerate(users["email_lower"].unique())}
        self.product_to_id = {sku: i for i, sku in enumerate(products["base_sku"].unique())}
        self.vehicle_to_id = {
            f"{row['make']}|{row['model']}": i
            for i, row in vehicles.iterrows()
        }

        return {"users": users, "products": products, "vehicles": vehicles}

    def load_edges(self) -> dict[str, pd.DataFrame]:
        """Load edge DataFrames."""
        table_prefix = f"{self.project_id}.{self.dataset}"

        interactions = self.bq.run_query(f"SELECT * FROM `{table_prefix}.interaction_edges`")
        fitment = self.bq.run_query(f"SELECT * FROM `{table_prefix}.fitment_edges`")
        ownership = self.bq.run_query(f"SELECT * FROM `{table_prefix}.ownership_edges`")
        copurchase = self.bq.run_query(f"SELECT * FROM `{table_prefix}.copurchase_edges`")

        logger.info(
            f"Loaded edges: {len(interactions)} interactions, {len(fitment)} fitment, "
            f"{len(ownership)} ownership, {len(copurchase)} copurchase"
        )

        return {
            "interactions": interactions,
            "fitment": fitment,
            "ownership": ownership,
            "copurchase": copurchase,
        }

    def load_test_set(self) -> pd.DataFrame:
        """Load test set interactions."""
        table_prefix = f"{self.project_id}.{self.dataset}"
        df = self.bq.run_query(f"SELECT * FROM `{table_prefix}.test_interactions`")
        logger.info(f"Loaded {len(df)} test interactions")
        return df

    def load_sql_baseline(self) -> pd.DataFrame:
        """Load SQL baseline recommendations."""
        table_prefix = f"{self.project_id}.{self.dataset}"
        df = self.bq.run_query(f"SELECT * FROM `{table_prefix}.sql_baseline`")
        logger.info(f"Loaded {len(df)} SQL baseline recommendations")
        return df

    def get_id_mappings(self) -> dict[str, dict]:
        """Return all ID mappings."""
        return {
            "user_to_id": self.user_to_id,
            "product_to_id": self.product_to_id,
            "vehicle_to_id": self.vehicle_to_id,
        }
```

---

## FILE 4: Graph Builder (src/gnn/graph_builder.py)

```python
"""Build PyG HeteroData graph from DataFrames."""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any

import numpy as np
import pandas as pd
import torch
from sklearn.preprocessing import LabelEncoder

if TYPE_CHECKING:
    from torch_geometric.data import HeteroData

logger = logging.getLogger(__name__)


def build_hetero_graph(
    nodes: dict[str, pd.DataFrame],
    edges: dict[str, pd.DataFrame],
    id_mappings: dict[str, dict],
    config: dict[str, Any],
) -> tuple[HeteroData, dict[str, torch.Tensor], dict[str, Any]]:
    """Build heterogeneous graph from node/edge DataFrames.

    Returns:
        Tuple of (HeteroData, split_masks, metadata).
    """
    from torch_geometric.data import HeteroData

    user_to_id = id_mappings["user_to_id"]
    product_to_id = id_mappings["product_to_id"]
    vehicle_to_id = id_mappings["vehicle_to_id"]

    users_df = nodes["users"]
    products_df = nodes["products"]
    vehicles_df = nodes["vehicles"]

    n_users = len(user_to_id)
    n_products = len(product_to_id)
    n_vehicles = len(vehicle_to_id)

    # --- Node Features ---

    # Part type encoding
    part_type_encoder = LabelEncoder()
    part_types = products_df["part_type"].fillna("UNKNOWN").values
    part_type_ids = part_type_encoder.fit_transform(part_types)
    n_part_types = len(part_type_encoder.classes_)

    # Product numerical features (z-score normalized)
    price_vals = products_df["price"].fillna(0).values.astype(np.float32)
    log_pop_vals = products_df["log_popularity"].fillna(0).values.astype(np.float32)
    fitment_breadth_vals = products_df["fitment_breadth"].fillna(0).values.astype(np.float32)

    price_mean, price_std = price_vals.mean(), price_vals.std() + 1e-8
    log_pop_mean, log_pop_std = log_pop_vals.mean(), log_pop_vals.std() + 1e-8
    fb_mean, fb_std = fitment_breadth_vals.mean(), fitment_breadth_vals.std() + 1e-8

    price_norm = (price_vals - price_mean) / price_std
    log_pop_norm = (log_pop_vals - log_pop_mean) / log_pop_std
    fb_norm = (fitment_breadth_vals - fb_mean) / fb_std

    # Vehicle features (normalized)
    user_count_vals = vehicles_df["user_count"].fillna(0).values.astype(np.float32)
    prod_count_vals = vehicles_df["product_count"].fillna(0).values.astype(np.float32)

    uc_mean, uc_std = user_count_vals.mean(), user_count_vals.std() + 1e-8
    pc_mean, pc_std = prod_count_vals.mean(), prod_count_vals.std() + 1e-8

    vehicle_features = np.stack([
        (user_count_vals - uc_mean) / uc_std,
        (prod_count_vals - pc_mean) / pc_std,
    ], axis=1)

    # --- User Split (80/10/10 stratified by engagement tier) ---
    engagement_tiers = users_df["engagement_tier"].values
    user_emails = users_df["email_lower"].values

    train_mask = np.zeros(n_users, dtype=bool)
    val_mask = np.zeros(n_users, dtype=bool)
    test_mask = np.zeros(n_users, dtype=bool)

    split_ratios = config["eval"]["user_split"]
    rng = np.random.RandomState(42)

    for tier in ["cold", "warm", "hot"]:
        tier_indices = [user_to_id[e] for e, t in zip(user_emails, engagement_tiers)
                        if t == tier and e in user_to_id]
        rng.shuffle(tier_indices)
        n = len(tier_indices)
        n_train = int(n * split_ratios[0])
        n_val = int(n * split_ratios[1])

        for idx in tier_indices[:n_train]:
            train_mask[idx] = True
        for idx in tier_indices[n_train:n_train + n_val]:
            val_mask[idx] = True
        for idx in tier_indices[n_train + n_val:]:
            test_mask[idx] = True

    # --- Build HeteroData ---
    data = HeteroData()

    data["user"].num_nodes = n_users
    data["product"].num_nodes = n_products
    data["product"].part_type_id = torch.tensor(part_type_ids, dtype=torch.long)
    data["product"].x_num = torch.tensor(
        np.stack([price_norm, log_pop_norm, fb_norm], axis=1), dtype=torch.float
    )
    data["vehicle"].num_nodes = n_vehicles
    data["vehicle"].x = torch.tensor(vehicle_features, dtype=torch.float)

    # --- Edge Indices ---

    # 1. User -> Product (interacts) — train-split users only
    interactions_df = edges["interactions"]
    if len(interactions_df) > 0:
        train_user_set = set(
            email for email, idx in user_to_id.items() if train_mask[idx]
        )
        train_interactions = interactions_df[
            interactions_df["email_lower"].isin(train_user_set)
        ]

        src = torch.tensor(
            [user_to_id[e] for e in train_interactions["email_lower"] if e in user_to_id],
            dtype=torch.long,
        )
        dst = torch.tensor(
            [product_to_id[s] for s in train_interactions["base_sku"] if s in product_to_id],
            dtype=torch.long,
        )
        min_len = min(len(src), len(dst))
        src, dst = src[:min_len], dst[:min_len]

        if min_len > 0:
            data["user", "interacts", "product"].edge_index = torch.stack([src, dst])
            weights = torch.tensor(
                train_interactions["weight"].values[:min_len], dtype=torch.float
            )
            data["user", "interacts", "product"].edge_weight = weights
            data["product", "rev_interacts", "user"].edge_index = torch.stack([dst, src])
            data["product", "rev_interacts", "user"].edge_weight = weights

    # 2. Product -> Vehicle (fits)
    fitment_df = edges["fitment"]
    if len(fitment_df) > 0:
        fit_src, fit_dst = [], []
        for _, row in fitment_df.iterrows():
            sku = row["base_sku"]
            vkey = f"{row['make']}|{row['model']}"
            if sku in product_to_id and vkey in vehicle_to_id:
                fit_src.append(product_to_id[sku])
                fit_dst.append(vehicle_to_id[vkey])

        if fit_src:
            fit_src_t = torch.tensor(fit_src, dtype=torch.long)
            fit_dst_t = torch.tensor(fit_dst, dtype=torch.long)
            data["product", "fits", "vehicle"].edge_index = torch.stack([fit_src_t, fit_dst_t])
            data["vehicle", "rev_fits", "product"].edge_index = torch.stack([fit_dst_t, fit_src_t])

    # 3. User -> Vehicle (owns)
    ownership_df = edges["ownership"]
    if len(ownership_df) > 0:
        own_src, own_dst = [], []
        for _, row in ownership_df.iterrows():
            email = row["email_lower"]
            vkey = f"{row['make']}|{row['model']}"
            if email in user_to_id and vkey in vehicle_to_id:
                own_src.append(user_to_id[email])
                own_dst.append(vehicle_to_id[vkey])

        if own_src:
            own_src_t = torch.tensor(own_src, dtype=torch.long)
            own_dst_t = torch.tensor(own_dst, dtype=torch.long)
            data["user", "owns", "vehicle"].edge_index = torch.stack([own_src_t, own_dst_t])
            data["vehicle", "rev_owns", "user"].edge_index = torch.stack([own_dst_t, own_src_t])

    # 4. Product <-> Product (co_purchased, symmetric)
    copurchase_df = edges["copurchase"]
    if len(copurchase_df) > 0:
        cp_src, cp_dst, cp_w = [], [], []
        for _, row in copurchase_df.iterrows():
            a, b = row["sku_a"], row["sku_b"]
            if a in product_to_id and b in product_to_id:
                cp_src.append(product_to_id[a])
                cp_dst.append(product_to_id[b])
                cp_w.append(row["weight"])

        if cp_src:
            cp_src_t = torch.tensor(cp_src, dtype=torch.long)
            cp_dst_t = torch.tensor(cp_dst, dtype=torch.long)
            cp_w_t = torch.tensor(cp_w, dtype=torch.float)
            both_src = torch.cat([cp_src_t, cp_dst_t])
            both_dst = torch.cat([cp_dst_t, cp_src_t])
            both_w = torch.cat([cp_w_t, cp_w_t])
            data["product", "co_purchased", "product"].edge_index = torch.stack([both_src, both_dst])
            data["product", "co_purchased", "product"].edge_weight = both_w

    split_masks = {
        "train_mask": torch.tensor(train_mask, dtype=torch.bool),
        "val_mask": torch.tensor(val_mask, dtype=torch.bool),
        "test_mask": torch.tensor(test_mask, dtype=torch.bool),
    }

    metadata = {
        "part_type_encoder": part_type_encoder,
        "n_part_types": n_part_types,
        "norm_stats": {
            "price": (price_mean, price_std),
            "log_popularity": (log_pop_mean, log_pop_std),
            "fitment_breadth": (fb_mean, fb_std),
            "user_count": (uc_mean, uc_std),
            "product_count": (pc_mean, pc_std),
        },
    }

    _log_graph_stats(data, split_masks)

    return data, split_masks, metadata


def _log_graph_stats(data: HeteroData, split_masks: dict) -> None:
    """Log graph construction statistics."""
    logger.info("=== Graph Construction Complete ===")
    for node_type in data.node_types:
        logger.info(f"  {node_type}: {data[node_type].num_nodes} nodes")
    for edge_type in data.edge_types:
        ei = data[edge_type].edge_index
        logger.info(f"  {edge_type}: {ei.shape[1]} edges")
    logger.info(
        f"  User split: train={split_masks['train_mask'].sum().item()}, "
        f"val={split_masks['val_mask'].sum().item()}, "
        f"test={split_masks['test_mask'].sum().item()}"
    )
```

---

## FILE 5: Model (src/gnn/model.py)

```python
"""HolleyGAT: Two-tower HeteroGAT for vehicle fitment recommendations."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

import torch
import torch.nn as nn
import torch.nn.functional as F
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
        user_x = self.user_embedding.weight
        pt_emb = self.part_type_embedding(data["product"].part_type_id)
        feat_input = torch.cat([pt_emb, data["product"].x_num], dim=1)
        product_x = self.product_embedding.weight + self.product_feature_mlp(feat_input)
        vehicle_x = self.vehicle_embedding.weight

        return {"user": user_x, "product": product_x, "vehicle": vehicle_x}

    def forward(
        self, data: HeteroData
    ) -> tuple[torch.Tensor, torch.Tensor]:
        """Forward pass producing L2-normalized user and product embeddings."""
        x_dict = self.get_initial_embeddings(data)

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
        """Compute dot product scores."""
        return torch.mm(user_embs, product_embs.t())

    @staticmethod
    def bpr_loss(pos_scores: torch.Tensor, neg_scores: torch.Tensor) -> torch.Tensor:
        """BPR pairwise ranking loss."""
        return -F.logsigmoid(pos_scores - neg_scores).mean()
```

---

## FILE 6: Trainer (src/gnn/trainer.py)

```python
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
        self.test_interactions = test_interactions
        self.config = config
        self.device = device or torch.device("cuda" if torch.cuda.is_available() else "cpu")

        train_cfg = config["training"]
        self.max_epochs = train_cfg["max_epochs"]
        self.patience = train_cfg["patience"]
        self.grad_clip = train_cfg["grad_clip"]
        self.neg_mix = train_cfg["negative_mix"]

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

        self.model = self.model.to(self.device)
        self.data = self.data.to(self.device)

        self._prepare_training_edges()
        self._build_fitment_index()

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

        own_type = ("user", "owns", "vehicle")
        fits_type = ("vehicle", "rev_fits", "product")

        if own_type in self.data.edge_types and fits_type in self.data.edge_types:
            own_ei = self.data[own_type].edge_index
            fits_ei = self.data[fits_type].edge_index

            vehicle_products: dict[int, list[int]] = {}
            for v, p in zip(fits_ei[0].cpu().numpy(), fits_ei[1].cpu().numpy()):
                vehicle_products.setdefault(int(v), []).append(int(p))

            for u, v in zip(own_ei[0].cpu().numpy(), own_ei[1].cpu().numpy()):
                self.user_fitment_products[int(u)] = vehicle_products.get(int(v), [])

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
            candidates = [p for p in fitment_prods if p != pos_pid]
            if candidates:
                neg_products[i] = candidates[torch.randint(len(candidates), (1,)).item()]
            else:
                neg_products[i] = torch.randint(n_products, (1,), device=self.device)

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

        perm = torch.randperm(len(self.pos_users), device=self.device)
        pos_u = self.pos_users[perm]
        pos_p = self.pos_products[perm]

        user_embs, product_embs = self.model(self.data)

        pos_scores = (user_embs[pos_u] * product_embs[pos_p]).sum(dim=1)

        neg_p = self._sample_negatives(pos_u, pos_p)
        neg_scores = (user_embs[pos_u] * product_embs[neg_p]).sum(dim=1)

        loss = HolleyGAT.bpr_loss(pos_scores, neg_scores)

        self.opt_emb.zero_grad()
        self.opt_gnn.zero_grad()
        loss.backward()

        nn.utils.clip_grad_norm_(self.model.parameters(), self.grad_clip)

        self.opt_emb.step()
        self.opt_gnn.step()

        return loss.item()

    @torch.no_grad()
    def validate(self, split: str = "val") -> dict[str, float]:
        """Compute validation metrics on val or test split."""
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

            eligible = self.user_fitment_products.get(uid_int)
            if not eligible:
                eligible = list(range(self.data["product"].num_nodes))

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
        """Full training loop with early stopping."""
        best_val_hr4 = -1.0
        best_epoch = 0
        patience_counter = 0
        best_state = None

        logger.info(f"Starting training: max_epochs={self.max_epochs}, patience={self.patience}")

        for epoch in range(self.max_epochs):
            loss = self.train_epoch()
            val_metrics = self.validate("val")

            val_hr4 = val_metrics.get("hit_rate_at_4", 0.0)

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

        if best_state is not None:
            self.model.load_state_dict(best_state)
            self.model = self.model.to(self.device)

        return {
            "best_epoch": best_epoch,
            "best_val_hit_rate_at_4": best_val_hr4,
            "total_epochs": epoch + 1,
        }

    def save_checkpoint(self, path: str) -> str:
        """Save model checkpoint to local path."""
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        torch.save({
            "model_state_dict": self.model.state_dict(),
            "config": self.config,
        }, path)
        logger.info(f"Saved checkpoint to {path}")
        return path
```

---

## FILE 7: Evaluator (src/gnn/evaluator.py)

```python
"""GNN evaluation: stratified metrics, SQL baseline comparison, bootstrap CIs."""

from __future__ import annotations

import logging
import re
from typing import TYPE_CHECKING, Any

import numpy as np
import pandas as pd
import torch

from src.gnn.model import HolleyGAT
from src.metrics import hit_rate_at_k, mrr, ndcg_at_k, recall_at_k

if TYPE_CHECKING:
    from torch_geometric.data import HeteroData

logger = logging.getLogger(__name__)


class GNNEvaluator:
    """Evaluate GNN recommendations vs SQL baseline with stratification and CIs."""

    def __init__(
        self,
        model: HolleyGAT,
        data: HeteroData,
        split_masks: dict[str, torch.Tensor],
        id_mappings: dict[str, dict],
        test_df: pd.DataFrame,
        sql_baseline_df: pd.DataFrame,
        config: dict[str, Any],
        user_engagement_tiers: dict[int, str] = None,
        device: torch.device = None,
    ):
        self.model = model
        self.data = data
        self.split_masks = split_masks
        self.id_mappings = id_mappings
        self.config = config
        self.device = device or torch.device("cuda" if torch.cuda.is_available() else "cpu")

        user_to_id = id_mappings["user_to_id"]
        product_to_id = id_mappings["product_to_id"]

        # Build test set: user_id -> set of product_ids
        self.test_interactions: dict[int, set[int]] = {}
        for _, row in test_df.iterrows():
            uid = user_to_id.get(row["email_lower"])
            pid = product_to_id.get(row["base_sku"])
            if uid is not None and pid is not None:
                self.test_interactions.setdefault(uid, set()).add(pid)

        # Build SQL baseline: user_id -> list of product_ids (ranked)
        self.sql_baseline: dict[int, list[int]] = {}
        for _, row in sql_baseline_df.iterrows():
            uid = user_to_id.get(row["email_lower"])
            sku = row["sku"]
            base_sku = re.sub(r'([0-9])[BRGP]$', r'\1', sku) if sku else None
            pid = product_to_id.get(base_sku)
            if uid is not None and pid is not None:
                self.sql_baseline.setdefault(uid, []).append(pid)

        self.user_tiers = user_engagement_tiers or {}
        self.user_fitment_products = self._build_fitment_index()

    def _build_fitment_index(self) -> dict[int, list[int]]:
        """Build user -> fitment product mapping from graph edges."""
        result: dict[int, list[int]] = {}
        own_type = ("user", "owns", "vehicle")
        fits_type = ("vehicle", "rev_fits", "product")

        if own_type not in self.data.edge_types or fits_type not in self.data.edge_types:
            return result

        own_ei = self.data[own_type].edge_index
        fits_ei = self.data[fits_type].edge_index

        vehicle_products: dict[int, list[int]] = {}
        for v, p in zip(fits_ei[0].cpu().numpy(), fits_ei[1].cpu().numpy()):
            vehicle_products.setdefault(int(v), []).append(int(p))

        for u, v in zip(own_ei[0].cpu().numpy(), own_ei[1].cpu().numpy()):
            result[int(u)] = vehicle_products.get(int(v), [])

        return result

    @torch.no_grad()
    def evaluate(self, split: str = "test") -> dict[str, Any]:
        """Run full evaluation pipeline."""
        self.model.eval()
        self.model = self.model.to(self.device)
        self.data = self.data.to(self.device)

        user_embs, product_embs = self.model(self.data)
        user_embs = user_embs.cpu()
        product_embs = product_embs.cpu()

        mask = self.split_masks[f"{split}_mask"]
        k_values = self.config["eval"]["k_values"]

        gnn_pre_rules_by_user: dict[int, list[int]] = {}
        gnn_post_rules_by_user: dict[int, list[int]] = {}

        evaluable_users = []
        for uid in mask.nonzero(as_tuple=True)[0]:
            uid_int = uid.item()
            if uid_int not in self.test_interactions:
                continue
            evaluable_users.append(uid_int)

        logger.info(f"Evaluable {split} users: {len(evaluable_users)}")

        for uid in evaluable_users:
            eligible = self.user_fitment_products.get(uid)
            if not eligible:
                eligible = list(range(self.data["product"].num_nodes))

            eligible_t = torch.tensor(eligible, dtype=torch.long)
            scores = torch.mv(product_embs[eligible_t], user_embs[uid])
            _, top_indices = scores.topk(min(max(k_values) * 2, len(eligible)))
            pre_rules = [eligible[idx.item()] for idx in top_indices]
            gnn_pre_rules_by_user[uid] = pre_rules

            post_rules = self._apply_business_rules(uid, pre_rules, scores, eligible)
            gnn_post_rules_by_user[uid] = post_rules

        gnn_pre = self._compute_metrics(gnn_pre_rules_by_user, k_values)
        gnn_post = self._compute_metrics(gnn_post_rules_by_user, k_values)

        sql_preds = {uid: self.sql_baseline.get(uid, []) for uid in evaluable_users}
        sql_metrics = self._compute_metrics(sql_preds, k_values)

        by_tier = self._compute_stratified(
            gnn_pre_rules_by_user, gnn_post_rules_by_user, sql_preds, k_values
        )

        n_bootstrap = self.config["eval"]["bootstrap_samples"]
        gnn_pre_ci = self._bootstrap_ci(gnn_pre_rules_by_user, k_values, n_bootstrap)
        gnn_post_ci = self._bootstrap_ci(gnn_post_rules_by_user, k_values, n_bootstrap)
        sql_ci = self._bootstrap_ci(sql_preds, k_values, n_bootstrap)

        deltas = {}
        for key in gnn_pre:
            deltas[f"pre_rules_{key}_delta"] = gnn_pre[key] - sql_metrics.get(key, 0)
            deltas[f"post_rules_{key}_delta"] = gnn_post[key] - sql_metrics.get(key, 0)

        go_no_go = self._go_no_go(gnn_pre, sql_metrics)

        return {
            "gnn_pre_rules": gnn_pre,
            "gnn_post_rules": gnn_post,
            "sql_baseline": sql_metrics,
            "gnn_pre_rules_ci": gnn_pre_ci,
            "gnn_post_rules_ci": gnn_post_ci,
            "sql_baseline_ci": sql_ci,
            "by_tier": by_tier,
            "deltas": deltas,
            "go_no_go": go_no_go,
            "n_evaluable": len(evaluable_users),
        }

    def _apply_business_rules(
        self, user_id, ranked_products, scores, eligible,
    ) -> list[int]:
        """Apply post-GNN business rules (fitment slots, diversity, etc.)."""
        fitment_set = set(self.user_fitment_products.get(user_id, []))
        fitment_recs = [p for p in ranked_products if p in fitment_set]
        universal_recs = [p for p in ranked_products if p not in fitment_set]

        result = []
        for pool, max_slots in [(fitment_recs, 2), (universal_recs, 2)]:
            added = 0
            for pid in pool:
                if added >= max_slots:
                    break
                if len(result) >= 4:
                    break
                result.append(pid)
                added += 1

        for pid in ranked_products:
            if len(result) >= 4:
                break
            if pid not in result:
                result.append(pid)

        return result[:4]

    def _compute_metrics(self, predictions, k_values) -> dict[str, float]:
        """Compute aggregate metrics across all users."""
        metrics_lists: dict[str, list[float]] = {
            f"hit_rate_at_{k}": [] for k in k_values
        }
        for k in k_values:
            metrics_lists[f"recall_at_{k}"] = []
        metrics_lists["mrr"] = []
        metrics_lists["ndcg_at_10"] = []

        for uid, preds in predictions.items():
            actuals = self.test_interactions.get(uid, set())
            if not actuals or not preds:
                continue
            for k in k_values:
                metrics_lists[f"hit_rate_at_{k}"].append(hit_rate_at_k(preds, actuals, k))
                metrics_lists[f"recall_at_{k}"].append(recall_at_k(preds, actuals, k))
            metrics_lists["mrr"].append(mrr(preds, actuals))
            metrics_lists["ndcg_at_10"].append(ndcg_at_k(preds, actuals, 10))

        result = {}
        for key, values in metrics_lists.items():
            result[key] = float(np.mean(values)) if values else 0.0
        result["n_users"] = len([u for u in predictions if self.test_interactions.get(u)])
        return result

    def _compute_stratified(self, gnn_pre, gnn_post, sql_preds, k_values):
        """Compute metrics stratified by engagement tier."""
        tiers = {"cold": {}, "warm": {}, "hot": {}}
        for tier_name in tiers:
            tier_users = [uid for uid in gnn_pre if self.user_tiers.get(uid) == tier_name]
            if not tier_users:
                tiers[tier_name] = {"n_users": 0}
                continue
            tier_gnn_pre = {uid: gnn_pre[uid] for uid in tier_users if uid in gnn_pre}
            tier_gnn_post = {uid: gnn_post[uid] for uid in tier_users if uid in gnn_post}
            tier_sql = {uid: sql_preds[uid] for uid in tier_users if uid in sql_preds}
            tiers[tier_name] = {
                "gnn_pre_rules": self._compute_metrics(tier_gnn_pre, k_values),
                "gnn_post_rules": self._compute_metrics(tier_gnn_post, k_values),
                "sql_baseline": self._compute_metrics(tier_sql, k_values),
            }
        return tiers

    def _bootstrap_ci(self, predictions, k_values, n_samples):
        """Compute 95% bootstrap confidence intervals."""
        rng = np.random.RandomState(42)
        users = [uid for uid in predictions if self.test_interactions.get(uid)]
        if not users:
            return {}
        per_user: dict[str, list[float]] = {f"hit_rate_at_{k}": [] for k in k_values}
        for uid in users:
            preds = predictions[uid]
            actuals = self.test_interactions[uid]
            for k in k_values:
                per_user[f"hit_rate_at_{k}"].append(hit_rate_at_k(preds, actuals, k))
        cis = {}
        for key, values in per_user.items():
            arr = np.array(values)
            boot_means = []
            for _ in range(n_samples):
                sample = rng.choice(arr, size=len(arr), replace=True)
                boot_means.append(sample.mean())
            boot_means = np.array(boot_means)
            cis[key] = (float(np.percentile(boot_means, 2.5)), float(np.percentile(boot_means, 97.5)))
        return cis

    def _go_no_go(self, gnn_metrics, sql_metrics) -> dict[str, str]:
        """Evaluate go/no-go thresholds."""
        delta = gnn_metrics.get("hit_rate_at_4", 0) - sql_metrics.get("hit_rate_at_4", 0)
        if delta >= 0.03:
            decision = "GO"
            rationale = f"Hit Rate@4 delta = {delta:+.4f} (>= +3%): proceed to online A/B"
        elif delta >= 0.01:
            decision = "MAYBE"
            rationale = f"Hit Rate@4 delta = {delta:+.4f} (+1% to +3%): try Option A+ first"
        elif delta >= -0.01:
            decision = "SKIP"
            rationale = f"Hit Rate@4 delta = {delta:+.4f} (-1% to +1%): go directly to Option A+"
        else:
            decision = "INVESTIGATE"
            rationale = f"Hit Rate@4 delta = {delta:+.4f} (< -1%): possible overfitting or data issue"
        return {
            "decision": decision, "rationale": rationale,
            "gnn_hit_rate_at_4": gnn_metrics.get("hit_rate_at_4", 0),
            "sql_hit_rate_at_4": sql_metrics.get("hit_rate_at_4", 0),
            "delta": delta,
        }

    def generate_report(self) -> dict[str, Any]:
        """Run evaluation and return complete report."""
        results = self.evaluate()
        logger.info("=== GNN Evaluation Report ===")
        logger.info(f"Evaluable users: {results['n_evaluable']}")
        logger.info(f"GNN Pre-rules:  {results['gnn_pre_rules']}")
        logger.info(f"GNN Post-rules: {results['gnn_post_rules']}")
        logger.info(f"SQL Baseline:   {results['sql_baseline']}")
        logger.info(f"Go/No-Go:       {results['go_no_go']}")
        return results
```

---

## FILE 8: Scorer (src/gnn/scorer.py)

```python
"""GNN production scorer: generate shadow recommendations table."""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any

import pandas as pd
import torch

from src.bq_client import BQClient
from src.gnn.model import HolleyGAT

if TYPE_CHECKING:
    from torch_geometric.data import HeteroData

logger = logging.getLogger(__name__)


class GNNScorer:
    """Score all target users and write to shadow table."""

    def __init__(
        self,
        model: HolleyGAT,
        data: HeteroData,
        id_mappings: dict[str, dict],
        nodes: dict[str, pd.DataFrame],
        config: dict[str, Any],
        bq_client: BQClient = None,
        device: torch.device = None,
    ):
        self.model = model
        self.data = data
        self.id_mappings = id_mappings
        self.nodes = nodes
        self.config = config
        self.device = device or torch.device("cuda" if torch.cuda.is_available() else "cpu")

        bq_cfg = config["bigquery"]
        self.bq = bq_client or BQClient(
            project=bq_cfg["project_id"],
            dataset=bq_cfg["dataset"],
        )

        self.id_to_user = {v: k for k, v in id_mappings["user_to_id"].items()}
        self.id_to_product = {v: k for k, v in id_mappings["product_to_id"].items()}
        self.id_to_vehicle = {v: k for k, v in id_mappings["vehicle_to_id"].items()}

        self._build_product_metadata()
        self._build_vehicle_groups()

    def _build_product_metadata(self):
        """Build sku -> metadata from product nodes."""
        products_df = self.nodes["products"]
        self.product_meta: dict[str, dict] = {}
        for _, row in products_df.iterrows():
            sku = row["base_sku"]
            self.product_meta[sku] = {
                "sku": row.get("sku", sku),
                "price": row.get("price", 0),
                "part_type": row.get("part_type", ""),
                "is_universal": row.get("is_universal", False),
            }

    def _build_vehicle_groups(self):
        """Build vehicle -> (user_ids, product_ids) mappings from graph."""
        self.vehicle_users: dict[int, list[int]] = {}
        self.vehicle_products: dict[int, list[int]] = {}

        own_type = ("user", "owns", "vehicle")
        fits_type = ("vehicle", "rev_fits", "product")

        if own_type in self.data.edge_types:
            own_ei = self.data[own_type].edge_index
            for u, v in zip(own_ei[0].cpu().numpy(), own_ei[1].cpu().numpy()):
                self.vehicle_users.setdefault(int(v), []).append(int(u))

        if fits_type in self.data.edge_types:
            fits_ei = self.data[fits_type].edge_index
            for v, p in zip(fits_ei[0].cpu().numpy(), fits_ei[1].cpu().numpy()):
                self.vehicle_products.setdefault(int(v), []).append(int(p))

    @torch.no_grad()
    def score_all_users(self) -> pd.DataFrame:
        """Score all target users using vehicle-grouped strategy."""
        self.model.eval()
        self.model = self.model.to(self.device)
        self.data = self.data.to(self.device)

        user_embs, product_embs = self.model(self.data)
        user_embs = user_embs.cpu()
        product_embs = product_embs.cpu()

        users_df = self.nodes["users"]
        target_emails = set(users_df[users_df["has_email_consent"]]["email_lower"])

        rows = []
        n_vehicles = len(self.vehicle_users)

        for vid_idx, (vid, user_ids) in enumerate(self.vehicle_users.items()):
            if vid_idx % 200 == 0:
                logger.info(f"Scoring vehicle {vid_idx}/{n_vehicles}...")

            product_ids = self.vehicle_products.get(vid, [])
            if not product_ids:
                continue

            prod_ids_t = torch.tensor(product_ids, dtype=torch.long)
            prod_embs_batch = product_embs[prod_ids_t]

            for uid in user_ids:
                email = self.id_to_user.get(uid)
                if email is None or email not in target_emails:
                    continue

                user_emb = user_embs[uid].unsqueeze(0)
                scores = torch.mm(user_emb, prod_embs_batch.t()).squeeze(0)

                recs = self._select_top4(uid, product_ids, scores)
                if recs:
                    rows.append(self._format_row(email, recs))

        df = pd.DataFrame(rows)
        logger.info(f"Scored {len(df)} users across {n_vehicles} vehicles")
        self._qa_checks(df)
        return df

    def _select_top4(self, user_id, product_ids, scores) -> list[tuple[int, float]]:
        """Select top 4 products with business rules applied."""
        scored = list(zip(product_ids, scores.numpy()))
        scored.sort(key=lambda x: -x[1])

        fitment_products = set(self.vehicle_products.get(
            self._get_user_vehicle(user_id), []
        ))

        fitment_ranked = [(pid, s) for pid, s in scored if pid in fitment_products]
        universal_ranked = [(pid, s) for pid, s in scored if pid not in fitment_products]

        result = []
        seen_part_types: dict[str, int] = {}

        # 2 fitment slots
        for pid, s in fitment_ranked:
            if len(result) >= 2:
                break
            sku = self.id_to_product.get(pid, "")
            pt = self.product_meta.get(sku, {}).get("part_type", "")
            if seen_part_types.get(pt, 0) >= 2:
                continue
            result.append((pid, float(s)))
            seen_part_types[pt] = seen_part_types.get(pt, 0) + 1

        # 2 universal slots
        for pid, s in universal_ranked:
            if len(result) >= 4:
                break
            sku = self.id_to_product.get(pid, "")
            pt = self.product_meta.get(sku, {}).get("part_type", "")
            if seen_part_types.get(pt, 0) >= 2:
                continue
            result.append((pid, float(s)))
            seen_part_types[pt] = seen_part_types.get(pt, 0) + 1

        # Backfill
        for pid, s in scored:
            if len(result) >= 4:
                break
            if pid not in {r[0] for r in result}:
                result.append((pid, float(s)))

        return result[:4]

    def _get_user_vehicle(self, user_id: int) -> int:
        """Get vehicle ID for a user."""
        own_type = ("user", "owns", "vehicle")
        if own_type not in self.data.edge_types:
            return -1
        own_ei = self.data[own_type].edge_index.cpu()
        mask = own_ei[0] == user_id
        if mask.any():
            return own_ei[1][mask][0].item()
        return -1

    def _format_row(self, email, recs) -> dict:
        """Format recommendations as wide-format row."""
        row = {"email_lower": email}
        fitment_count = 0
        for i, (pid, score) in enumerate(recs, 1):
            sku = self.id_to_product.get(pid, "")
            meta = self.product_meta.get(sku, {})
            row[f"rec{i}_sku"] = meta.get("sku", sku)
            row[f"rec{i}_price"] = meta.get("price", 0)
            row[f"rec{i}_score"] = score
            if not meta.get("is_universal", True):
                fitment_count += 1
        for i in range(len(recs) + 1, 5):
            row[f"rec{i}_sku"] = None
            row[f"rec{i}_price"] = None
            row[f"rec{i}_score"] = None
        row["fitment_count"] = fitment_count
        row["model_version"] = "gnn_option_a_v1"
        return row

    def _qa_checks(self, df) -> None:
        """Run QA checks before writing to BQ."""
        checks_passed = True
        if len(df) < 250_000:
            logger.warning(f"QA FAIL: Only {len(df)} users (expected >= 250K)")
            checks_passed = False
        n_dupes = df["email_lower"].duplicated().sum()
        if n_dupes > 0:
            logger.warning(f"QA FAIL: {n_dupes} duplicate users")
            checks_passed = False
        null_slot1 = df["rec1_sku"].isna().sum()
        if null_slot1 > 0:
            logger.warning(f"QA FAIL: {null_slot1} users missing rec1")
            checks_passed = False
        min_price = self.config["graph"]["min_price"]
        for i in range(1, 5):
            col = f"rec{i}_price"
            if col in df.columns:
                below = (df[col].dropna() < min_price).sum()
                if below > 0:
                    logger.warning(f"QA FAIL: {below} recs in slot {i} below ${min_price}")
                    checks_passed = False
        for _, row in df.iterrows():
            scores = [row.get(f"rec{i}_score") for i in range(1, 5)]
            scores = [s for s in scores if s is not None]
            if scores != sorted(scores, reverse=True):
                logger.warning("QA FAIL: Score ordering violated")
                checks_passed = False
                break
        if checks_passed:
            logger.info("QA checks PASSED")
        else:
            logger.warning("QA checks FAILED — review warnings above")

    def write_shadow_table(self, df) -> None:
        """Write recommendations to shadow BQ table."""
        table_id = self.config["output"]["shadow_table"]
        logger.info(f"Writing {len(df)} rows to shadow table: {table_id}")
        self.bq.write_table(df, table_id)
        logger.info("Shadow table write complete")
```

---

## FILE 9: Metrics (added to src/metrics.py)

```python
def hit_rate_at_k(
    predictions: list[int],
    actuals: set[int],
    k: int = 4
) -> float:
    """Compute Hit Rate@k (binary: 1 if any top-k prediction is relevant)."""
    if not predictions or not actuals:
        return 0.0
    top_k = predictions[:k]
    return 1.0 if any(item in actuals for item in top_k) else 0.0


def mrr(
    predictions: list[int],
    actuals: set[int],
) -> float:
    """Compute Mean Reciprocal Rank."""
    if not predictions or not actuals:
        return 0.0
    for i, item in enumerate(predictions):
        if item in actuals:
            return 1.0 / (i + 1)
    return 0.0
```

---

## FILE 10: SQL — export_nodes.sql

```sql
-- GNN Option A: Node Export
-- Exports user, product, and vehicle nodes from BigQuery to temp_holley_gnn

DECLARE target_project STRING DEFAULT '${PROJECT_ID}';
DECLARE target_dataset STRING DEFAULT '${GNN_DATASET}';
DECLARE source_project STRING DEFAULT '${SOURCE_PROJECT}';
DECLARE min_price FLOAT64 DEFAULT 25.0;
DECLARE intent_start DATE DEFAULT DATE '2025-09-01';

-- 1. User Nodes (~504K fitment users)
CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.user_nodes` AS
WITH users_raw AS (
  SELECT
    LOWER(TRIM(a.string_value)) AS email_lower,
    MAX(CASE WHEN b.key = 'v1_make' THEN UPPER(TRIM(COALESCE(b.string_value, CAST(b.long_value AS STRING)))) END) AS v1_make,
    MAX(CASE WHEN b.key = 'v1_model' THEN UPPER(TRIM(COALESCE(b.string_value, CAST(b.long_value AS STRING)))) END) AS v1_model,
    MAX(CASE WHEN b.key = 'v1_year' THEN COALESCE(b.string_value, CAST(b.long_value AS STRING)) END) AS v1_year,
    MAX(CASE WHEN b.key = 'email_marketing_consent' THEN COALESCE(b.string_value, CAST(b.long_value AS STRING)) END) AS email_consent
  FROM `${SOURCE_PROJECT}.company_1950.ingestion_unified_attributes_schema_incremental` a,
    UNNEST(a.attributes) AS b
  WHERE a.key = 'email'
    AND a.string_value IS NOT NULL
    AND TRIM(a.string_value) != ''
  GROUP BY 1
)
SELECT
  email_lower, v1_make, v1_model, v1_year,
  CASE WHEN LOWER(email_consent) IN ('subscribed', 'true', '1') THEN TRUE ELSE FALSE END AS has_email_consent,
  'cold' AS engagement_tier  -- Updated in export_edges.sql
FROM users_raw
WHERE v1_year IS NOT NULL AND v1_make IS NOT NULL AND v1_model IS NOT NULL
  AND TRIM(v1_make) != '' AND TRIM(v1_model) != '';

-- 2. Product Nodes (~25K eligible products)
CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.product_nodes` AS
WITH sku_prices AS (
  SELECT
    REGEXP_REPLACE(sku, r'([0-9])[BRGP]$', r'\1') AS base_sku,
    MIN(sku) AS canonical_sku,
    MAX(price) AS price
  FROM (
    SELECT ii.ExternalID AS sku, SAFE_CAST(ii.Price AS FLOAT64) AS price
    FROM `${SOURCE_PROJECT}.data_company_1950.import_items` ii
    WHERE ii.Price IS NOT NULL AND SAFE_CAST(ii.Price AS FLOAT64) >= min_price
  )
  GROUP BY 1
),
order_counts AS (
  SELECT REGEXP_REPLACE(ProductID, r'([0-9])[BRGP]$', r'\1') AS base_sku, COUNT(*) AS order_count
  FROM `${SOURCE_PROJECT}.data_company_1950.import_orders`
  WHERE ORDER_DATE >= CAST(intent_start AS STRING)
  GROUP BY 1
),
fitment_breadth AS (
  SELECT REGEXP_REPLACE(sku, r'([0-9])[BRGP]$', r'\1') AS base_sku,
    COUNT(DISTINCT CONCAT(make, '|', model)) AS fitment_breadth
  FROM `${SOURCE_PROJECT}.data_company_1950.vehicle_product_fitment_data`
  GROUP BY 1
),
excluded_skus AS (
  SELECT DISTINCT ExternalID AS sku
  FROM `${SOURCE_PROJECT}.data_company_1950.import_items_tags`
  WHERE LOWER(tags) LIKE '%refurbished%'
),
product_categories AS (
  SELECT ExternalID AS sku, PartType,
    CASE WHEN SAFE_CAST(UniversalPart AS INT64) = 1 THEN TRUE ELSE FALSE END AS is_universal
  FROM `${SOURCE_PROJECT}.data_company_1950.import_items`
)
SELECT
  sp.canonical_sku AS sku, sp.base_sku, pc.PartType AS part_type, sp.price,
  LOG(1 + COALESCE(oc.order_count, 0)) AS log_popularity,
  COALESCE(fb.fitment_breadth, 0) AS fitment_breadth,
  COALESCE(pc.is_universal, FALSE) AS is_universal
FROM sku_prices sp
LEFT JOIN order_counts oc ON sp.base_sku = oc.base_sku
LEFT JOIN fitment_breadth fb ON sp.base_sku = fb.base_sku
LEFT JOIN excluded_skus es ON sp.canonical_sku = es.sku
LEFT JOIN product_categories pc ON sp.canonical_sku = pc.sku
WHERE es.sku IS NULL AND COALESCE(pc.PartType, '') NOT IN ('Service', 'Commodity');

-- 3. Vehicle Nodes (~2K unique make/model)
CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.vehicle_nodes` AS
WITH user_vehicles AS (
  SELECT v1_make, v1_model, COUNT(*) AS user_count
  FROM `${PROJECT_ID}.${GNN_DATASET}.user_nodes` GROUP BY 1, 2
),
fitment_products AS (
  SELECT UPPER(TRIM(make)) AS v_make, UPPER(TRIM(model)) AS v_model,
    COUNT(DISTINCT REGEXP_REPLACE(sku, r'([0-9])[BRGP]$', r'\1')) AS product_count
  FROM `${SOURCE_PROJECT}.data_company_1950.vehicle_product_fitment_data` GROUP BY 1, 2
)
SELECT uv.v1_make AS make, uv.v1_model AS model, uv.user_count,
  COALESCE(fp.product_count, 0) AS product_count
FROM user_vehicles uv
LEFT JOIN fitment_products fp ON uv.v1_make = fp.v_make AND uv.v1_model = fp.v_model;
```

---

## FILE 11: SQL — export_edges.sql

```sql
-- GNN Option A: Edge Export
DECLARE intent_start DATE DEFAULT DATE '2025-09-01';
DECLARE test_window_days INT64 DEFAULT 30;
DECLARE time_decay_halflife FLOAT64 DEFAULT 30.0;
DECLARE co_purchase_threshold INT64 DEFAULT 2;
DECLARE co_purchase_top_k INT64 DEFAULT 50;
DECLARE train_cutoff DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL test_window_days DAY);

-- 1. Interaction Edges (User -> Product), Sep 1 2025 to T-30, train-split users
CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.interaction_edges` AS
WITH events AS (
  SELECT
    LOWER(TRIM(a.key_value)) AS email_lower,
    COALESCE(
      MAX(CASE WHEN p.key = 'ProductId' THEN COALESCE(p.string_value, CAST(p.long_value AS STRING)) END),
      MAX(CASE WHEN p.key = 'ProductID' THEN COALESCE(p.string_value, CAST(p.long_value AS STRING)) END)
    ) AS sku,
    a.event_name,
    DATE(a.event_timestamp) AS event_date
  FROM `${SOURCE_PROJECT}.company_1950.ingestion_unified_schema_incremental` a,
    UNNEST(a.properties) AS p
  WHERE a.key_type = 'email'
    AND a.event_name IN ('Viewed Product', 'Added to Cart', 'Placed Order')
    AND DATE(a.event_timestamp) BETWEEN intent_start AND train_cutoff
  GROUP BY 1, a.event_name, DATE(a.event_timestamp), a.event_timestamp
)
SELECT e.email_lower,
  REGEXP_REPLACE(e.sku, r'([0-9])[BRGP]$', r'\1') AS base_sku,
  CASE WHEN e.event_name = 'Viewed Product' THEN 'view'
       WHEN e.event_name = 'Added to Cart' THEN 'cart'
       WHEN e.event_name = 'Placed Order' THEN 'order'
  END AS interaction_type,
  CASE WHEN e.event_name = 'Viewed Product' THEN 1.0
       WHEN e.event_name = 'Added to Cart' THEN 3.0
       WHEN e.event_name = 'Placed Order' THEN 5.0
  END * EXP(-LN(2) * DATE_DIFF(train_cutoff, e.event_date, DAY) / time_decay_halflife) AS weight
FROM events e
INNER JOIN `${PROJECT_ID}.${GNN_DATASET}.user_nodes` u ON e.email_lower = u.email_lower
INNER JOIN `${PROJECT_ID}.${GNN_DATASET}.product_nodes` p ON REGEXP_REPLACE(e.sku, r'([0-9])[BRGP]$', r'\1') = p.base_sku
WHERE e.sku IS NOT NULL;

-- 2. Update engagement tiers
UPDATE `${PROJECT_ID}.${GNN_DATASET}.user_nodes` u
SET engagement_tier = COALESCE(tiers.tier, 'cold')
FROM (
  SELECT email_lower,
    CASE WHEN SUM(CASE WHEN interaction_type IN ('cart', 'order') THEN 1 ELSE 0 END) > 0 THEN 'hot'
         WHEN COUNT(*) > 0 THEN 'warm'
         ELSE 'cold' END AS tier
  FROM `${PROJECT_ID}.${GNN_DATASET}.interaction_edges` GROUP BY 1
) tiers
WHERE u.email_lower = tiers.email_lower;

-- 3. Fitment Edges (Product -> Vehicle), full catalog, atemporal
CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.fitment_edges` AS
SELECT DISTINCT
  REGEXP_REPLACE(f.sku, r'([0-9])[BRGP]$', r'\1') AS base_sku,
  UPPER(TRIM(f.make)) AS make, UPPER(TRIM(f.model)) AS model
FROM `${SOURCE_PROJECT}.data_company_1950.vehicle_product_fitment_data` f
INNER JOIN `${PROJECT_ID}.${GNN_DATASET}.product_nodes` p ON REGEXP_REPLACE(f.sku, r'([0-9])[BRGP]$', r'\1') = p.base_sku
INNER JOIN `${PROJECT_ID}.${GNN_DATASET}.vehicle_nodes` v ON UPPER(TRIM(f.make)) = v.make AND UPPER(TRIM(f.model)) = v.model;

-- 4. Ownership Edges (User -> Vehicle)
CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.ownership_edges` AS
SELECT DISTINCT u.email_lower, u.v1_make AS make, u.v1_model AS model
FROM `${PROJECT_ID}.${GNN_DATASET}.user_nodes` u
INNER JOIN `${PROJECT_ID}.${GNN_DATASET}.vehicle_nodes` v ON u.v1_make = v.make AND u.v1_model = v.model;

-- 5. Co-purchase Edges (Product <-> Product), with PMI filter and top-K
CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.copurchase_edges` AS
WITH order_items AS (
  SELECT CustomerID, OrderID, REGEXP_REPLACE(ProductID, r'([0-9])[BRGP]$', r'\1') AS base_sku
  FROM `${SOURCE_PROJECT}.data_company_1950.import_orders`
  WHERE SAFE.PARSE_DATE('%Y-%m-%d', SUBSTR(ORDER_DATE, 1, 10)) BETWEEN intent_start AND train_cutoff
),
valid_orders AS (
  SELECT oi.* FROM order_items oi
  INNER JOIN `${PROJECT_ID}.${GNN_DATASET}.product_nodes` p ON oi.base_sku = p.base_sku
),
pairs AS (
  SELECT a.base_sku AS sku_a, b.base_sku AS sku_b, COUNT(DISTINCT a.OrderID) AS co_count
  FROM valid_orders a INNER JOIN valid_orders b ON a.OrderID = b.OrderID AND a.base_sku < b.base_sku
  GROUP BY 1, 2 HAVING co_count >= co_purchase_threshold
),
product_freq AS (SELECT base_sku, COUNT(DISTINCT OrderID) AS freq FROM valid_orders GROUP BY 1),
total_orders AS (SELECT COUNT(DISTINCT OrderID) AS total FROM valid_orders),
pmi_pairs AS (
  SELECT p.sku_a, p.sku_b, p.co_count,
    LOG((p.co_count * t.total * 1.0) / (fa.freq * fb.freq)) AS pmi,
    LOG(1 + p.co_count) AS weight
  FROM pairs p CROSS JOIN total_orders t
  INNER JOIN product_freq fa ON p.sku_a = fa.base_sku
  INNER JOIN product_freq fb ON p.sku_b = fb.base_sku
),
ranked AS (
  SELECT sku_a, sku_b, co_count, pmi, weight,
    ROW_NUMBER() OVER (PARTITION BY sku_a ORDER BY weight DESC) AS rank_a,
    ROW_NUMBER() OVER (PARTITION BY sku_b ORDER BY weight DESC) AS rank_b
  FROM pmi_pairs WHERE pmi > 0
)
SELECT sku_a, sku_b, co_count, pmi, weight
FROM ranked WHERE rank_a <= co_purchase_top_k OR rank_b <= co_purchase_top_k;
```

---

## FILE 12: SQL — export_test_set.sql

```sql
-- GNN Option A: Test Set Export
-- Last 30 days of interactions for val/test split users
DECLARE test_window_days INT64 DEFAULT 30;
DECLARE test_start DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL test_window_days DAY);
DECLARE test_end DATE DEFAULT CURRENT_DATE();

CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.test_interactions` AS
WITH events AS (
  SELECT
    LOWER(TRIM(a.key_value)) AS email_lower,
    COALESCE(
      MAX(CASE WHEN p.key = 'ProductId' THEN COALESCE(p.string_value, CAST(p.long_value AS STRING)) END),
      MAX(CASE WHEN p.key = 'ProductID' THEN COALESCE(p.string_value, CAST(p.long_value AS STRING)) END)
    ) AS sku,
    a.event_name, a.event_timestamp
  FROM `${SOURCE_PROJECT}.company_1950.ingestion_unified_schema_incremental` a,
    UNNEST(a.properties) AS p
  WHERE a.key_type = 'email'
    AND a.event_name IN ('Viewed Product', 'Added to Cart', 'Placed Order')
    AND DATE(a.event_timestamp) BETWEEN test_start AND test_end
  GROUP BY 1, a.event_name, a.event_timestamp
)
SELECT e.email_lower,
  REGEXP_REPLACE(e.sku, r'([0-9])[BRGP]$', r'\1') AS base_sku,
  CASE WHEN e.event_name = 'Viewed Product' THEN 'view'
       WHEN e.event_name = 'Added to Cart' THEN 'cart'
       WHEN e.event_name = 'Placed Order' THEN 'order' END AS interaction_type,
  e.event_timestamp
FROM events e
INNER JOIN `${PROJECT_ID}.${GNN_DATASET}.user_nodes` u ON e.email_lower = u.email_lower
INNER JOIN `${PROJECT_ID}.${GNN_DATASET}.product_nodes` p ON REGEXP_REPLACE(e.sku, r'([0-9])[BRGP]$', r'\1') = p.base_sku
WHERE e.sku IS NOT NULL;
```

---

## FILE 13: SQL — export_sql_baseline.sql

```sql
-- GNN Option A: SQL Baseline Export
-- Reshape current SQL recommendations to long format for comparison
DECLARE min_price FLOAT64 DEFAULT 25.0;

CREATE OR REPLACE TABLE `${PROJECT_ID}.${GNN_DATASET}.sql_baseline` AS
WITH wide_recs AS (
  SELECT email_lower, rec1_sku, rec1_price, rec2_sku, rec2_price,
    rec3_sku, rec3_price, rec4_sku, rec4_price
  FROM `auxia-reporting.company_1950_jp.final_vehicle_recommendations`
)
SELECT email_lower, sku, rank
FROM (
  SELECT email_lower, rec1_sku AS sku, 1 AS rank, rec1_price AS price FROM wide_recs
  UNION ALL
  SELECT email_lower, rec2_sku AS sku, 2 AS rank, rec2_price AS price FROM wide_recs
  UNION ALL
  SELECT email_lower, rec3_sku AS sku, 3 AS rank, rec3_price AS price FROM wide_recs
  UNION ALL
  SELECT email_lower, rec4_sku AS sku, 4 AS rank, rec4_price AS price FROM wide_recs
)
WHERE sku IS NOT NULL AND price >= min_price
ORDER BY email_lower, rank;
```

---

## FILE 14: Entry Point (src/gnn/run.py)

```python
"""GNN Option A entry point: train, evaluate, or score.

Usage:
    python src/gnn/run.py --config configs/gnn.yaml --mode train
    python src/gnn/run.py --config configs/gnn.yaml --mode evaluate
    python src/gnn/run.py --config configs/gnn.yaml --mode score
"""

import argparse
import json
import logging
import tempfile

import torch

from src.config import load_config
from src.gcs_utils import download_model, upload_model
from src.gnn.data_loader import GNNDataLoader
from src.gnn.graph_builder import build_hetero_graph
from src.gnn.model import HolleyGAT
from src.wandb_utils import finish_run, init_wandb, log_artifact, log_metrics

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)


def load_data(config):
    """Load and export data from BigQuery."""
    loader = GNNDataLoader(config)
    logger.info("Running SQL exports...")
    loader.run_exports()
    logger.info("Loading nodes...")
    nodes = loader.load_nodes()
    logger.info("Loading edges...")
    edges = loader.load_edges()
    return loader, nodes, edges


def build_graph(loader, nodes, edges, config):
    """Build PyG HeteroData graph."""
    logger.info("Building heterogeneous graph...")
    data, split_masks, metadata = build_hetero_graph(
        nodes, edges, loader.get_id_mappings(), config
    )
    return data, split_masks, metadata


def mode_train(config):
    """Full training pipeline: export -> build -> train -> evaluate -> save."""
    from src.gnn.evaluator import GNNEvaluator
    from src.gnn.trainer import GNNTrainer

    init_wandb(config, job_type="training", tags=["gnn", "option-a"])

    loader, nodes, edges = load_data(config)
    data, split_masks, metadata = build_graph(loader, nodes, edges, config)

    test_df = loader.load_test_set()
    test_interactions = build_test_interactions(loader, test_df)
    sql_baseline_df = loader.load_sql_baseline()

    model = HolleyGAT(
        n_users=data["user"].num_nodes,
        n_products=data["product"].num_nodes,
        n_vehicles=data["vehicle"].num_nodes,
        n_part_types=metadata["n_part_types"],
        config=config,
    )
    logger.info(f"Model parameters: {sum(p.numel() for p in model.parameters()):,}")

    trainer = GNNTrainer(
        model=model, data=data, split_masks=split_masks,
        test_interactions=test_interactions, config=config,
    )
    train_results = trainer.train()
    logger.info(f"Training complete: {train_results}")

    checkpoint_path = tempfile.mktemp(suffix=".pt")
    trainer.save_checkpoint(checkpoint_path)
    gcs_path = config["output"]["model_gcs"] + "latest.pt"
    upload_model(checkpoint_path, gcs_path)
    log_artifact(checkpoint_path, "holley-gnn-model", "model")

    # Evaluate
    engagement_tiers = build_engagement_tiers(nodes, loader.user_to_id)
    evaluator = GNNEvaluator(
        model=model, data=data, split_masks=split_masks,
        id_mappings=loader.get_id_mappings(), test_df=test_df,
        sql_baseline_df=sql_baseline_df, config=config,
        user_engagement_tiers=engagement_tiers,
    )
    report = evaluator.generate_report()

    flat_metrics = {}
    for section in ["gnn_pre_rules", "gnn_post_rules", "sql_baseline"]:
        for k, v in report.get(section, {}).items():
            flat_metrics[f"eval/{section}/{k}"] = v
    log_metrics(flat_metrics)

    logger.info(f"\n=== GO/NO-GO ===\n{json.dumps(report['go_no_go'], indent=2)}")
    finish_run()
    return report


def mode_evaluate(config):
    """Load existing model and evaluate."""
    from src.gnn.evaluator import GNNEvaluator

    init_wandb(config, job_type="evaluation", tags=["gnn", "option-a"])
    loader, nodes, edges = load_data(config)
    data, split_masks, metadata = build_graph(loader, nodes, edges, config)

    gcs_path = config["output"]["model_gcs"] + "latest.pt"
    local_path = tempfile.mktemp(suffix=".pt")
    download_model(gcs_path, local_path)

    checkpoint = torch.load(local_path, weights_only=False)
    model = HolleyGAT(
        n_users=data["user"].num_nodes, n_products=data["product"].num_nodes,
        n_vehicles=data["vehicle"].num_nodes, n_part_types=metadata["n_part_types"],
        config=config,
    )
    model.load_state_dict(checkpoint["model_state_dict"])

    test_df = loader.load_test_set()
    sql_baseline_df = loader.load_sql_baseline()
    engagement_tiers = build_engagement_tiers(nodes, loader.user_to_id)

    evaluator = GNNEvaluator(
        model=model, data=data, split_masks=split_masks,
        id_mappings=loader.get_id_mappings(), test_df=test_df,
        sql_baseline_df=sql_baseline_df, config=config,
        user_engagement_tiers=engagement_tiers,
    )
    report = evaluator.generate_report()
    logger.info(f"\n=== GO/NO-GO ===\n{json.dumps(report['go_no_go'], indent=2)}")
    finish_run()
    return report


def mode_score(config):
    """Load model, score all users, write shadow table."""
    from src.gnn.scorer import GNNScorer

    init_wandb(config, job_type="scoring", tags=["gnn", "option-a"])
    loader, nodes, edges = load_data(config)
    data, split_masks, metadata = build_graph(loader, nodes, edges, config)

    gcs_path = config["output"]["model_gcs"] + "latest.pt"
    local_path = tempfile.mktemp(suffix=".pt")
    download_model(gcs_path, local_path)

    checkpoint = torch.load(local_path, weights_only=False)
    model = HolleyGAT(
        n_users=data["user"].num_nodes, n_products=data["product"].num_nodes,
        n_vehicles=data["vehicle"].num_nodes, n_part_types=metadata["n_part_types"],
        config=config,
    )
    model.load_state_dict(checkpoint["model_state_dict"])

    scorer = GNNScorer(
        model=model, data=data, id_mappings=loader.get_id_mappings(),
        nodes=nodes, config=config,
    )
    df = scorer.score_all_users()
    scorer.write_shadow_table(df)
    log_metrics({"scoring/n_users": len(df)})
    finish_run()
    logger.info(f"Scoring complete: {len(df)} users written to shadow table")
    return df


def build_test_interactions(loader, test_df):
    """Convert test DataFrame to user_id -> set of product_ids."""
    interactions = {}
    for _, row in test_df.iterrows():
        uid = loader.user_to_id.get(row["email_lower"])
        pid = loader.product_to_id.get(row["base_sku"])
        if uid is not None and pid is not None:
            interactions.setdefault(uid, set()).add(pid)
    return interactions


def build_engagement_tiers(nodes, user_to_id):
    """Build user_id -> engagement tier mapping."""
    tiers = {}
    for _, row in nodes["users"].iterrows():
        uid = user_to_id.get(row["email_lower"])
        if uid is not None:
            tiers[uid] = row.get("engagement_tier", "cold")
    return tiers


def main():
    parser = argparse.ArgumentParser(description="GNN Option A: HeteroGAT Recommendations")
    parser.add_argument("--config", required=True, help="Path to config YAML")
    parser.add_argument("--mode", required=True, choices=["train", "evaluate", "score"])
    args = parser.parse_args()

    config = load_config(args.config)
    logger.info(f"Mode: {args.mode}, Config: {args.config}")

    if args.mode == "train":
        mode_train(config)
    elif args.mode == "evaluate":
        mode_evaluate(config)
    elif args.mode == "score":
        mode_score(config)


if __name__ == "__main__":
    main()
```

---

## Specific Review Questions

Please address these specific concerns in your review:

### Architecture
1. The model has ~68M embedding parameters but only ~90K interaction edges. Is weight_decay=0.01 sufficient regularization, or should we reduce embedding dimensions?
2. For 98% cold users, the only signal path is User→Vehicle→Product (2 hops). With only 2 GNN layers, is this enough depth? Too much?
3. The product initial embedding is `learned_emb + FeatureMLP(features)`. Is additive combination correct, or should it be concatenation?

### Data Leakage
4. Co-purchase edges use the same `intent_start to train_cutoff` window as interaction edges. But the SQL baseline was built before this temporal split existed. Is the `export_sql_baseline.sql` leaking future information?
5. The test set includes ALL interaction types (view, cart, order). Should evaluation only count orders/carts as ground truth, or are views valid positives?

### Evaluation
6. The go/no-go uses pre-rules Hit Rate@4. But the SQL baseline IS already post-rules (it has slot reservation). Is this an apples-to-oranges comparison?
7. Bootstrap CIs only cover Hit Rate@k. Should we also bootstrap MRR and NDCG?

### Training
8. In-batch negatives (50%) shuffle positive products — but some shuffled products might actually be positives for that user. Is this a problem at this scale?
9. The fitment-hard negative loop (lines 132-140 in trainer.py) is a Python for-loop over 30% of edges. Will this be a training bottleneck at 90K edges?

### Production
10. The scorer iterates `df.iterrows()` for QA score ordering check — will this be too slow with 258K users?
11. The scorer's `_get_user_vehicle()` does a linear scan of edge_index for each user in `_select_top4`. This is called per-user per-vehicle — is there a performance issue?

### SQL
12. The `export_edges.sql` GROUP BY includes `a.event_timestamp` — does this prevent proper deduplication of events?
13. The `export_sql_baseline.sql` reads from `final_vehicle_recommendations` which may be the unfixed v5.17. Should this point to a specific fixed version?

Please provide:
- **Critical issues** (must fix before running)
- **Important improvements** (should fix for reliability)
- **Minor suggestions** (nice-to-have)
- **Overall assessment** (production-ready? What's the biggest risk?)
