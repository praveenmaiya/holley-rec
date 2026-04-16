# ChatGPT Test Review Prompt

Copy everything below this line into ChatGPT (GPT-4o or o3).

---

You are a senior test engineer reviewing the test suite for a GNN-based product recommendation system. The system recommends automotive parts to users based on vehicle fitment, purchase history, and collaborative filtering using a Heterogeneous Graph Attention Network (HeteroGAT).

## Your Task

Review all 8 test files against their production code. For each file, evaluate:

1. **Coverage completeness**: Are all public methods tested? Are critical code paths exercised?
2. **Test quality**: Do tests verify behavior (not implementation)? Are assertions specific enough?
3. **Edge cases**: Are boundary conditions, empty inputs, and error paths tested?
4. **Anti-patterns**: Mock abuse, testing implementation details, fragile assertions, tautological tests?
5. **Missing tests**: What specific tests should be added? Write the test signature and a one-line description.

## Output Format

For each file, provide:
- **Grade**: A/B/C/D/F with one-sentence justification
- **Strengths**: 2-3 bullet points
- **Issues**: Numbered list with severity (Critical/Important/Minor)
- **Missing tests**: Concrete test signatures with descriptions

End with:
- **Overall assessment**: Is this test suite production-ready?
- **Top 5 tests to add**: Ordered by impact, with full test code

## Context

- Framework: pytest with pytest-mock
- 5 test files require `torch` + `torch_geometric` (skipped locally, run on K8s GPU)
- 3 test files run without torch (metrics, rules, data_loader)
- Current results: **30 passed, 5 skipped, 0 failed**
- The system processes ~504K users, ~25K products, ~2K vehicles

---

## PRODUCTION CODE

### src/gnn/rules.py (shared business rules)

```python
"""Shared recommendation business rules for GNN evaluation and scoring."""

from __future__ import annotations

from collections.abc import Iterable


def apply_slot_reservation_with_diversity(
    ranked_products: Iterable[int],
    fitment_set: set[int],
    universal_set: set[int],
    part_type_by_product: dict[int, str],
    *,
    fitment_slots: int = 2,
    universal_slots: int = 2,
    total_slots: int = 4,
    max_per_part_type: int = 2,
) -> list[int]:
    """Select final recommendations with slot reservation + part-type cap.

    The selection policy is:
    1. Fill up to `fitment_slots` from ranked fitment products.
    2. Fill up to `universal_slots` from ranked universal products.
    3. Backfill from the global ranked list until `total_slots` is reached.
    4. Enforce `max_per_part_type` across all phases.
    """
    result: list[int] = []
    seen_products: set[int] = set()
    part_type_counts: dict[str, int] = {}

    ranked = list(ranked_products)

    def try_add(product_id: int) -> bool:
        if product_id in seen_products:
            return False
        part_type = part_type_by_product.get(product_id, "")
        if part_type_counts.get(part_type, 0) >= max_per_part_type:
            return False
        result.append(product_id)
        seen_products.add(product_id)
        part_type_counts[part_type] = part_type_counts.get(part_type, 0) + 1
        return True

    fitment_added = 0
    for pid in ranked:
        if fitment_added >= fitment_slots or len(result) >= total_slots:
            break
        if pid in fitment_set and try_add(pid):
            fitment_added += 1

    universal_added = 0
    for pid in ranked:
        if universal_added >= universal_slots or len(result) >= total_slots:
            break
        if pid in universal_set and pid not in fitment_set and try_add(pid):
            universal_added += 1

    for pid in ranked:
        if len(result) >= total_slots:
            break
        try_add(pid)

    return result[:total_slots]
```

### src/gnn/data_loader.py

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
        baseline_table = (
            self.config.get("eval", {}).get("baseline_table")
            or self.config.get("output", {}).get("baseline_table")
            or "auxia-reporting.company_1950_jp.final_vehicle_recommendations"
        )
        params = {
            "PROJECT_ID": self.project_id,
            "GNN_DATASET": self.dataset,
            "SOURCE_PROJECT": self.config["bigquery"]["source_project"],
            "BASELINE_TABLE": baseline_table,
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

        # Canonical ordering and deduplication ensure deterministic ID mapping and
        # stable feature alignment across train/eval/score.
        users = (
            users.drop_duplicates(subset=["email_lower"])
            .sort_values("email_lower")
            .reset_index(drop=True)
        )
        products = (
            products.drop_duplicates(subset=["base_sku"])
            .sort_values("base_sku")
            .reset_index(drop=True)
        )
        vehicles = (
            vehicles.drop_duplicates(subset=["make", "model"])
            .sort_values(["make", "model"])
            .reset_index(drop=True)
        )

        logger.info(f"Loaded nodes: {len(users)} users, {len(products)} products, {len(vehicles)} vehicles")

        # Build deterministic mappings in canonical DataFrame order.
        self.user_to_id = {
            email: i for i, email in enumerate(users["email_lower"].tolist())
        }
        self.product_to_id = {
            sku: i for i, sku in enumerate(products["base_sku"].tolist())
        }
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
        return {"interactions": interactions, "fitment": fitment, "ownership": ownership, "copurchase": copurchase}

    def load_test_set(self) -> pd.DataFrame:
        table_prefix = f"{self.project_id}.{self.dataset}"
        return self.bq.run_query(f"SELECT * FROM `{table_prefix}.test_interactions`")

    def load_sql_baseline(self) -> pd.DataFrame:
        table_prefix = f"{self.project_id}.{self.dataset}"
        return self.bq.run_query(f"SELECT * FROM `{table_prefix}.sql_baseline`")

    def get_id_mappings(self) -> dict[str, dict]:
        return {
            "user_to_id": self.user_to_id,
            "product_to_id": self.product_to_id,
            "vehicle_to_id": self.vehicle_to_id,
        }
```

### src/gnn/graph_builder.py

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

    # Canonical entity order is defined by ID mappings.
    ordered_user_emails = [e for e, _ in sorted(user_to_id.items(), key=lambda x: x[1])]
    ordered_product_skus = [s for s, _ in sorted(product_to_id.items(), key=lambda x: x[1])]
    ordered_vehicle_keys = [k for k, _ in sorted(vehicle_to_id.items(), key=lambda x: x[1])]

    users_lookup = (
        users_df.drop_duplicates(subset=["email_lower"])
        .set_index("email_lower", drop=False)
    )
    products_lookup = (
        products_df.drop_duplicates(subset=["base_sku"])
        .set_index("base_sku", drop=False)
    )
    vehicles_lookup = (
        vehicles_df.assign(vehicle_key=vehicles_df["make"] + "|" + vehicles_df["model"])
        .drop_duplicates(subset=["vehicle_key"])
        .set_index("vehicle_key", drop=False)
    )

    # Fail fast on mapping/table drift to prevent silent embedding-feature misalignment.
    missing_users = [email for email in ordered_user_emails if email not in users_lookup.index]
    missing_products = [sku for sku in ordered_product_skus if sku not in products_lookup.index]
    missing_vehicles = [key for key in ordered_vehicle_keys if key not in vehicles_lookup.index]
    if missing_users or missing_products or missing_vehicles:
        problems = []
        if missing_users:
            problems.append(f"users={len(missing_users)}")
        if missing_products:
            problems.append(f"products={len(missing_products)}")
        if missing_vehicles:
            problems.append(f"vehicles={len(missing_vehicles)}")
        raise ValueError(
            "ID mapping mismatch with node tables; refresh exports or use matching checkpoint data "
            f"({', '.join(problems)})"
        )

    ordered_products = products_lookup.reindex(ordered_product_skus)
    ordered_vehicles = vehicles_lookup.reindex(ordered_vehicle_keys)

    # --- Node Features ---
    part_type_encoder = LabelEncoder()
    part_type_encoder.fit(products_lookup["part_type"].fillna("UNKNOWN").astype(str).values)
    part_type_ids = part_type_encoder.transform(
        ordered_products["part_type"].fillna("UNKNOWN").astype(str).values
    )
    n_part_types = len(part_type_encoder.classes_)

    price_vals = ordered_products["price"].fillna(0).values.astype(np.float32)
    log_pop_vals = ordered_products["log_popularity"].fillna(0).values.astype(np.float32)
    fitment_breadth_vals = ordered_products["fitment_breadth"].fillna(0).values.astype(np.float32)
    is_universal_vals = ordered_products["is_universal"].fillna(False).values.astype(bool)

    price_mean, price_std = price_vals.mean(), price_vals.std() + 1e-8
    log_pop_mean, log_pop_std = log_pop_vals.mean(), log_pop_vals.std() + 1e-8
    fb_mean, fb_std = fitment_breadth_vals.mean(), fitment_breadth_vals.std() + 1e-8

    price_norm = (price_vals - price_mean) / price_std
    log_pop_norm = (log_pop_vals - log_pop_mean) / log_pop_std
    fb_norm = (fitment_breadth_vals - fb_mean) / fb_std

    user_count_vals = ordered_vehicles["user_count"].fillna(0).values.astype(np.float32)
    prod_count_vals = ordered_vehicles["product_count"].fillna(0).values.astype(np.float32)
    uc_mean, uc_std = user_count_vals.mean(), user_count_vals.std() + 1e-8
    pc_mean, pc_std = prod_count_vals.mean(), prod_count_vals.std() + 1e-8
    vehicle_features = np.stack([
        (user_count_vals - uc_mean) / uc_std,
        (prod_count_vals - pc_mean) / pc_std,
    ], axis=1)

    # --- User Split (80/10/10 stratified by engagement tier) ---
    if "engagement_tier" in users_lookup.columns:
        engagement_by_user = users_lookup["engagement_tier"].astype(str).str.lower()
    else:
        engagement_by_user = pd.Series(dtype=str)

    train_mask = np.zeros(n_users, dtype=bool)
    val_mask = np.zeros(n_users, dtype=bool)
    test_mask = np.zeros(n_users, dtype=bool)

    split_ratios = config["eval"]["user_split"]
    rng = np.random.RandomState(42)

    for tier in ["cold", "warm", "hot"]:
        tier_indices = [
            uid for uid, email in enumerate(ordered_user_emails)
            if engagement_by_user.get(email, "cold") == tier
        ]
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
    data["product"].is_universal = torch.tensor(is_universal_vals, dtype=torch.bool)
    data["vehicle"].num_nodes = n_vehicles
    data["vehicle"].x = torch.tensor(vehicle_features, dtype=torch.float)

    # [Edge construction code omitted for brevity — builds 7 edge types:
    #  interacts, rev_interacts, fits, rev_fits, owns, rev_owns, co_purchased]

    split_masks = {
        "train_mask": torch.tensor(train_mask, dtype=torch.bool),
        "val_mask": torch.tensor(val_mask, dtype=torch.bool),
        "test_mask": torch.tensor(test_mask, dtype=torch.bool),
    }

    metadata = {
        "part_type_encoder": part_type_encoder,
        "n_part_types": n_part_types,
        "norm_stats": { ... },
    }

    return data, split_masks, metadata
```

### src/gnn/model.py

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
    def __init__(self, n_users, n_products, n_vehicles, n_part_types, config):
        super().__init__()
        model_cfg = config["model"]
        emb_dim = model_cfg["embedding_dim"]      # 128
        hidden_dim = model_cfg["hidden_dim"]       # 256
        num_heads = model_cfg["num_heads"]         # 4
        dropout = model_cfg["dropout"]             # 0.1
        proj_dropout = model_cfg["proj_dropout"]   # 0.2
        head_dim = hidden_dim // num_heads         # 64

        self.user_embedding = nn.Embedding(n_users, emb_dim)
        self.product_embedding = nn.Embedding(n_products, emb_dim)
        self.vehicle_embedding = nn.Embedding(n_vehicles, emb_dim)
        self.part_type_embedding = nn.Embedding(n_part_types, 32)
        self.product_feature_mlp = nn.Sequential(nn.Linear(32 + 3, emb_dim), nn.ReLU())

        # 2x HeteroConv with GATConv per edge type (7 directions each)
        self.conv1 = HeteroConv({...}, aggr="sum")  # 7 GATConv layers
        self.conv2 = HeteroConv({...}, aggr="sum")  # 7 GATConv layers
        self.dropout = nn.Dropout(dropout)

        self.user_proj = nn.Sequential(
            nn.Linear(hidden_dim, hidden_dim), nn.ReLU(),
            nn.Dropout(proj_dropout), nn.Linear(hidden_dim, emb_dim),
        )
        self.product_proj = nn.Sequential(
            nn.Linear(hidden_dim, hidden_dim), nn.ReLU(),
            nn.Dropout(proj_dropout), nn.Linear(hidden_dim, emb_dim),
        )
        self._init_weights()

    def get_initial_embeddings(self, data):
        user_x = self.user_embedding.weight
        pt_emb = self.part_type_embedding(data["product"].part_type_id)
        feat_input = torch.cat([pt_emb, data["product"].x_num], dim=1)
        product_x = self.product_embedding.weight + self.product_feature_mlp(feat_input)
        vehicle_x = self.vehicle_embedding.weight
        return {"user": user_x, "product": product_x, "vehicle": vehicle_x}

    def forward(self, data) -> tuple[torch.Tensor, torch.Tensor]:
        x_dict = self.get_initial_embeddings(data)
        edge_index_dict = {et: data[et].edge_index for et in data.edge_types if hasattr(data[et], "edge_index")}
        x_dict = self.conv1(x_dict, edge_index_dict)
        x_dict = {key: F.elu(self.dropout(x)) for key, x in x_dict.items()}
        x_dict = self.conv2(x_dict, edge_index_dict)
        x_dict = {key: F.elu(x) for key, x in x_dict.items()}
        user_embs = F.normalize(self.user_proj(x_dict["user"]), dim=1)
        product_embs = F.normalize(self.product_proj(x_dict["product"]), dim=1)
        return user_embs, product_embs

    @staticmethod
    def score(user_embs, product_embs):
        return torch.mm(user_embs, product_embs.t())

    @staticmethod
    def bpr_loss(pos_scores, neg_scores):
        return -F.logsigmoid(pos_scores - neg_scores).mean()
```

### src/gnn/trainer.py

```python
"""GNN training loop with dual optimizer, early stopping, and W&B logging."""

from __future__ import annotations
import logging
from typing import TYPE_CHECKING, Any
import numpy as np
import torch
import torch.nn as nn
from src.gnn.model import HolleyGAT
from src.metrics import hit_rate_at_k
from src.wandb_utils import log_metrics

logger = logging.getLogger(__name__)


class GNNTrainer:
    def __init__(self, model, data, split_masks, test_interactions, config, device=None):
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
        embedding_params = [model.user_embedding.weight, model.product_embedding.weight,
                           model.vehicle_embedding.weight, model.part_type_embedding.weight]
        embedding_ids = {id(p) for p in embedding_params}
        gnn_params = [p for p in model.parameters() if id(p) not in embedding_ids]
        self.opt_emb = torch.optim.Adam(embedding_params, lr=train_cfg["lr_embedding"],
                                         weight_decay=train_cfg["weight_decay"])
        self.opt_gnn = torch.optim.Adam(gnn_params, lr=train_cfg["lr_gnn"])

        self.model = self.model.to(self.device)
        self.data = self.data.to(self.device)
        self._prepare_training_edges()
        self._build_fitment_index()

        # Universal pool for validation-time candidate parity
        universal_mask = getattr(self.data["product"], "is_universal", None)
        if universal_mask is not None:
            self.universal_product_ids = universal_mask.nonzero(as_tuple=True)[0].detach().cpu().tolist()
        else:
            self.universal_product_ids = []
        self.all_product_ids = list(range(self.data["product"].num_nodes))
        self._eval_candidate_cache: dict[int, list[int]] = {}

    def _get_eval_candidates(self, user_id):
        if user_id in self._eval_candidate_cache:
            return self._eval_candidate_cache[user_id]
        fitment = self.user_fitment_products.get(user_id, [])
        eligible = list(dict.fromkeys(fitment + self.universal_product_ids))
        if not eligible:
            eligible = self.all_product_ids
        self._eval_candidate_cache[user_id] = eligible
        return eligible

    def _sample_negatives(self, user_ids, pos_product_ids):
        # Mixed strategy: in-batch + fitment-hard (rejection sampling) + random
        ...

    def train_epoch(self) -> float:
        # Forward, BPR loss, backward, clip, step. Returns loss.
        ...

    def validate(self, split="val") -> dict[str, float]:
        # Hit Rate@k on val/test split using _get_eval_candidates
        ...

    def train(self) -> dict[str, Any]:
        # Full loop with early stopping on val HR@4
        ...

    def save_checkpoint(self, path, id_mappings=None) -> str:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        checkpoint = {"model_state_dict": self.model.state_dict(), "config": self.config}
        if id_mappings is not None:
            checkpoint["id_mappings"] = id_mappings
        torch.save(checkpoint, path)
        return path
```

### src/gnn/evaluator.py

```python
"""GNN evaluation: stratified metrics, SQL baseline comparison, bootstrap CIs."""

from __future__ import annotations
import logging
from typing import TYPE_CHECKING, Any
import numpy as np
import pandas as pd
import torch
from src.gnn.model import HolleyGAT
from src.gnn.rules import apply_slot_reservation_with_diversity
from src.metrics import hit_rate_at_k, mrr, ndcg_at_k, recall_at_k

logger = logging.getLogger(__name__)


class GNNEvaluator:
    def __init__(self, model, data, split_masks, id_mappings, nodes, test_df,
                 sql_baseline_df, config, user_engagement_tiers=None, device=None):
        # Builds:
        # - self.universal_product_ids from nodes["products"]["is_universal"]
        # - self.part_type_by_product_id from nodes["products"]["part_type"]
        # - self.test_interactions from test_df (validates email_lower, base_sku columns)
        # - self.sql_baseline from sql_baseline_df (accepts sku or base_sku, deduplicates)
        # - self.user_fitment_products from graph edges
        # Raises ValueError if test_df missing required columns

    def _apply_business_rules(self, user_id, ranked_products):
        fitment_set = set(self.user_fitment_products.get(user_id, []))
        universal_set = set(self.universal_product_ids)
        return apply_slot_reservation_with_diversity(
            ranked_products, fitment_set, universal_set, self.part_type_by_product_id,
            fitment_slots=2, universal_slots=2, total_slots=4, max_per_part_type=2,
        )

    def evaluate(self, split="test"):
        # For each evaluable user: score eligible candidates, apply rules, compute metrics
        # Eligible = fitment + universal (fallback to all products)
        # Computes: gnn_pre_rules, gnn_post_rules, sql_baseline metrics
        # Stratifies by engagement tier
        # Bootstrap 95% CIs
        # Go/no-go uses COLD TIER metrics (not aggregate)
        # Unfair delta annotations for @10/@20 (SQL limited to 4 recs)

    def _go_no_go(self, gnn_metrics, sql_metrics):
        delta = gnn_metrics.get("hit_rate_at_4", 0) - sql_metrics.get("hit_rate_at_4", 0)
        if delta >= 0.03: return {"decision": "GO", ...}
        elif delta >= 0.01: return {"decision": "MAYBE", ...}
        elif delta >= -0.01: return {"decision": "SKIP", ...}
        else: return {"decision": "INVESTIGATE", ...}
```

### src/gnn/scorer.py

```python
"""GNN production scorer: generate shadow recommendations table."""

from __future__ import annotations
import logging
from typing import TYPE_CHECKING, Any
import numpy as np
import pandas as pd
import torch
from src.bq_client import BQClient
from src.gnn.model import HolleyGAT
from src.gnn.rules import apply_slot_reservation_with_diversity

logger = logging.getLogger(__name__)


class QAFailedError(Exception):
    """Raised when critical QA checks fail."""


class GNNScorer:
    def __init__(self, model, data, id_mappings, nodes, config, bq_client=None, device=None):
        # Builds: reverse mappings, product_meta, part_type_by_product_id,
        # vehicle_users, vehicle_products, universal_product_ids

    def score_all_users(self) -> pd.DataFrame:
        # Vehicle-grouped batch scoring
        # For each vehicle: batch all users x fitment products, batch x universal products
        # _select_top4 per user, _format_row, _qa_checks

    def _select_top4(self, fitment_ids, fitment_scores, universal_ids, universal_scores):
        # Merge fitment + universal scored lists, sort by score
        # Delegate to apply_slot_reservation_with_diversity
        # Return [(pid, score), ...] up to 4

    def _format_row(self, email, recs):
        # Wide-format: rec1_sku..rec4_sku, rec1_price..rec4_price, rec1_score..rec4_score
        # fitment_count, model_version

    def _qa_checks(self, df):
        # Checks: >= 250K users, no duplicates, slot1 always filled,
        # price >= min_price, score ordering (sample first 1000)
        # Raises QAFailedError on failure
```

### src/metrics.py (relevant functions)

```python
def hit_rate_at_k(predictions: list[int], actuals: set[int], k: int = 4) -> float:
    if not predictions or not actuals: return 0.0
    return 1.0 if any(item in actuals for item in predictions[:k]) else 0.0

def mrr(predictions: list[int], actuals: set[int]) -> float:
    if not predictions or not actuals: return 0.0
    for i, item in enumerate(predictions):
        if item in actuals: return 1.0 / (i + 1)
    return 0.0

def recall_at_k(predictions, actuals, k=10): ...
def ndcg_at_k(predictions, actuals, k=10): ...
def precision_at_k(predictions, actuals, k=10): ...
def mean_average_precision(predictions, actuals): ...
def catalog_coverage(all_predictions, catalog_size, k=10): ...

def compute_all_metrics(user_predictions, user_actuals, k_values=None, catalog_size=None):
    # Aggregates all per-user metrics, returns dict
```

---

## TEST CODE

### tests/test_gnn_rules.py (11 tests, all pass)

```python
"""Tests for shared GNN business rules (slot reservation + diversity)."""

import pytest
from src.gnn.rules import apply_slot_reservation_with_diversity


@pytest.fixture
def part_types():
    """Product ID -> PartType mapping. 20 products, 4 part types."""
    return {
        0: "Ignition", 1: "Ignition", 2: "Ignition",
        3: "Exhaust", 4: "Exhaust", 5: "Exhaust",
        6: "Brakes", 7: "Brakes", 8: "Brakes",
        9: "Wheels", 10: "Wheels", 11: "Wheels",
        12: "Ignition", 13: "Exhaust", 14: "Brakes",
        15: "Wheels", 16: "Ignition", 17: "Exhaust",
        18: "Brakes", 19: "Wheels",
    }


class TestSlotReservation:
    def test_basic_2_fitment_2_universal(self, part_types):
        ranked = [0, 1, 10, 11, 2, 3, 12, 13]
        fitment = {0, 1, 2, 3}
        universal = {10, 11, 12, 13}
        result = apply_slot_reservation_with_diversity(ranked, fitment, universal, part_types)
        assert len(result) == 4
        assert result[0] in fitment
        assert result[1] in fitment
        assert result[2] in universal
        assert result[3] in universal

    def test_empty_fitment_fills_from_universal_and_backfill(self, part_types):
        ranked = [10, 11, 3, 6]
        result = apply_slot_reservation_with_diversity(ranked, set(), {10, 11}, part_types)
        assert len(result) == 4
        assert 10 in result
        assert 11 in result

    def test_empty_universal_fills_from_fitment_and_backfill(self, part_types):
        ranked = [0, 3, 6, 9]
        result = apply_slot_reservation_with_diversity(ranked, {0, 3, 6, 9}, set(), part_types)
        assert len(result) == 4
        assert result[0] in {0, 3, 6, 9}

    def test_part_type_diversity_cap(self, part_types):
        all_ignition = {i: "Ignition" for i in range(20)}
        result = apply_slot_reservation_with_diversity(
            [0, 1, 2, 10, 11, 12], {0, 1, 2}, {10, 11, 12}, all_ignition)
        assert len(result) == 2

    def test_product_in_both_fitment_and_universal_counted_as_fitment(self, part_types):
        ranked = [5, 10, 11, 6, 7]
        result = apply_slot_reservation_with_diversity(
            ranked, {5, 6, 7}, {5, 10, 11}, part_types)
        assert len(result) == 4
        assert result[0] == 5
        assert 10 in result
        assert 11 in result
        assert 6 in result

    def test_fewer_products_than_slots(self, part_types):
        result = apply_slot_reservation_with_diversity([0, 10], {0}, {10}, part_types)
        assert result == [0, 10]

    def test_empty_ranked_list(self, part_types):
        result = apply_slot_reservation_with_diversity([], set(), set(), part_types)
        assert result == []

    def test_backfill_respects_diversity_cap(self, part_types):
        result = apply_slot_reservation_with_diversity(
            [0, 3, 10, 12, 16], {0, 3}, {10}, part_types)
        assert len(result) == 4
        assert result == [0, 3, 10, 12]

    def test_preserves_ranked_order_within_phases(self, part_types):
        result = apply_slot_reservation_with_diversity(
            [6, 0, 9, 3, 10, 11, 7, 8], {0, 3, 6, 7, 8, 9}, {10, 11}, part_types)
        assert result == [6, 0, 10, 11]

    def test_custom_slot_counts(self, part_types):
        result = apply_slot_reservation_with_diversity(
            [0, 3, 6, 10, 11], {0, 3, 6}, {10, 11}, part_types,
            fitment_slots=3, universal_slots=1, total_slots=4)
        assert result == [0, 3, 6, 10]

    def test_missing_part_type_treated_as_empty_string(self, part_types):
        result = apply_slot_reservation_with_diversity(
            [99, 100, 0, 10], {99, 100}, {0, 10}, part_types)
        assert len(result) == 4
        assert result[0] == 99
        assert result[1] == 100
```

### tests/test_gnn_data_loader.py (5 tests, all pass)

```python
"""Tests for GNN data loader with mocked BQ client."""

import pandas as pd
import pytest
from src.gnn.data_loader import GNNDataLoader


@pytest.fixture
def gnn_config():
    return {
        "bigquery": {"project_id": "test-project", "source_project": "test-source",
                      "dataset": "test_gnn", "company_id": 1950},
        "graph": {"min_price": 25},
        "eval": {"user_split": [0.8, 0.1, 0.1]},
    }

@pytest.fixture
def mock_bq(mocker):
    client = mocker.Mock()
    client.project = "test-project"
    client.dataset = "test_gnn"
    return client


class TestGNNDataLoader:
    def test_load_nodes_builds_id_mappings(self, gnn_config, mock_bq):
        # 3 users, 2 products, 2 vehicles — verifies mapping sizes and key existence
        ...

    def test_load_edges(self, gnn_config, mock_bq):
        mock_bq.run_query.return_value = pd.DataFrame({...})
        edges = loader.load_edges()
        assert "interactions" in edges  # etc.

    def test_get_id_mappings_empty_before_load(self, gnn_config, mock_bq):
        assert loader.get_id_mappings()["user_to_id"] == {}

    def test_id_mappings_are_deterministic_sorted_order(self, gnn_config, mock_bq):
        """IDs assigned in sorted key order regardless of input order."""
        # Input: z@, a@, m@ (unsorted) -> Expected: a@=0, m@=1, z@=2
        # Input: SKU9, SKU1, SKU5 (unsorted) -> Expected: SKU1=0, SKU5=1, SKU9=2
        # Input: FORD|MUSTANG, CHEVY|CAMARO -> Expected: CHEVY|CAMARO=0, FORD|MUSTANG=1
        ...  # Full assertions on exact ID values

    def test_load_nodes_deduplicates(self, gnn_config, mock_bq):
        """Duplicate rows in BQ output are deduplicated."""
        # Input: a@ twice, SKU1 twice, FORD|MUSTANG twice
        # Expected: user_to_id has 2 entries, product_to_id has 1, vehicle_to_id has 1
        ...
```

### tests/test_gnn_graph_builder.py (12 tests, 5 skip without torch)

```python
"""Tests for GNN graph builder."""

# Fixtures: sample_nodes (10 users, 20 products, 3 vehicles),
# sample_edges (4 interactions, 20 fitment, 10 ownership, 3 copurchase),
# sample_id_mappings, gnn_config
# These fixtures are shared by all torch-dependent test files.

class TestBuildHeteroGraph:
    def test_builds_correct_node_counts(self, ...):
        assert data["user"].num_nodes == 10
        assert data["product"].num_nodes == 20
        assert data["vehicle"].num_nodes == 3

    def test_product_features_correct_shape(self, ...):
        assert data["product"].part_type_id.shape == (20,)
        assert data["product"].x_num.shape == (20, 3)

    def test_vehicle_features_correct_shape(self, ...):
        assert data["vehicle"].x.shape == (3, 2)

    def test_user_split_sums_to_total(self, ...):
        total = masks["train_mask"].sum() + masks["val_mask"].sum() + masks["test_mask"].sum()
        assert total == 10

    def test_splits_are_disjoint(self, ...):
        assert (masks["train_mask"] & masks["val_mask"]).sum() == 0

    def test_fitment_edges_exist(self, ...):
        assert ("product", "fits", "vehicle") in data.edge_types

    def test_copurchase_edges_symmetric(self, ...):
        assert ei.shape[1] == 6  # 3 pairs * 2 directions

    def test_metadata_has_part_type_encoder(self, ...):
        assert meta["n_part_types"] == 4

    def test_drift_detection_raises_on_mismatched_user_mapping(self, ...):
        """ValueError when ID mapping has users not in node table."""
        bad_mappings = {"user_to_id": {"ghost@nowhere.com": 0, "user0@test.com": 1}, ...}
        with pytest.raises(ValueError, match="ID mapping mismatch"):
            build_hetero_graph(sample_nodes, sample_edges, bad_mappings, gnn_config)

    def test_drift_detection_raises_on_mismatched_product_mapping(self, ...):
        bad_mappings = {**sample_id_mappings, "product_to_id": {"NONEXISTENT_SKU": 0, "P000": 1}}
        with pytest.raises(ValueError, match="ID mapping mismatch"): ...

    def test_drift_detection_raises_on_mismatched_vehicle_mapping(self, ...):
        bad_mappings = {**sample_id_mappings, "vehicle_to_id": {"TESLA|CYBERTRUCK": 0}}
        with pytest.raises(ValueError, match="ID mapping mismatch"): ...

    def test_is_universal_stored_on_product_nodes(self, ...):
        assert hasattr(data["product"], "is_universal")
        assert data["product"].is_universal.dtype == torch.bool
        assert data["product"].is_universal.shape == (20,)
        assert data["product"].is_universal.sum().item() == 5
```

### tests/test_gnn_model.py (7 tests, all skip without torch)

```python
class TestHolleyGAT:
    def test_forward_output_shapes(self, ...):
        assert user_embs.shape == (10, 128)
        assert prod_embs.shape == (20, 128)

    def test_embeddings_are_normalized(self, ...):
        assert torch.allclose(user_norms, torch.ones_like(user_norms), atol=1e-5)

    def test_score_shape(self, ...):
        assert scores.shape == (3, 20)

    def test_bpr_loss_positive(self, ...):
        assert loss.item() > 0

    def test_bpr_loss_decreases_with_wider_margin(self, ...):
        assert loss_far.item() < loss_close.item()

    def test_model_parameter_count(self, ...):
        assert total > 10_000

    def test_initial_embeddings(self, ...):
        assert embs["user"].shape == (10, 128)
```

### tests/test_gnn_trainer.py (7 tests, all skip without torch)

```python
class TestGNNTrainer:
    def test_train_epoch_returns_loss(self, ...):
        assert isinstance(loss, float) and loss > 0

    def test_loss_decreases_over_epochs(self, ...):
        losses = [trainer.train_epoch() for _ in range(5)]
        assert losses[-1] < losses[0]

    def test_validate_returns_metrics(self, ...):
        assert "hit_rate_at_4" in metrics

    def test_eval_candidates_include_universal_pool(self, ...):
        assert 15 in candidates  # first universal product
        assert 1 in candidates   # fitment product for FORD|MUSTANG

    def test_eval_candidates_fallback_to_all_products(self, ...):
        # user8 (DODGE|CHARGER) has no fitment edges in fixture
        assert len(candidates) == data["product"].num_nodes

    def test_full_training_loop(self, ...):
        assert "best_epoch" in results
        assert results["total_epochs"] <= 5

    def test_save_checkpoint(self, ...):
        assert "model_state_dict" in checkpoint
        assert "config" in checkpoint

    def test_rejects_invalid_negative_mix(self, ...):
        # negative_mix summing to 1.3
        with pytest.raises(ValueError, match="must sum to 1.0"): ...
```

### tests/test_gnn_evaluator.py (4 tests, all skip without torch)

```python
class TestGNNEvaluator:
    def test_evaluate_returns_complete_report(self, ...):
        assert "gnn_pre_rules" in report
        assert "gnn_post_rules" in report
        assert "sql_baseline" in report
        assert "go_no_go" in report

    def test_go_no_go_thresholds(self, ...):
        # Tests all 4 boundaries: GO (>=+3%), MAYBE (+1-3%), SKIP (-1 to +1%), INVESTIGATE (<-1%)
        ...

    def test_business_rules_produce_max_4(self, ...):
        assert len(result) <= 4

    def test_bootstrap_ci_returns_tuples(self, ...):
        for _, (lo, hi) in cis.items():
            assert lo <= hi
```

### tests/test_gnn_scorer.py (6 tests, all skip without torch)

```python
class TestGNNScorer:
    def test_universal_pool_not_empty(self, ...):
        assert len(scorer.universal_product_ids) == 5

    def test_select_top4_respects_slot_reservation(self, ...):
        assert len(result) == 4
        assert pids[0] in fitment_ids
        assert pids[1] in fitment_ids

    def test_select_top4_max_4_results(self, ...):
        assert len(result) <= 4

    def test_format_row_has_expected_columns(self, ...):
        assert "rec1_sku" in row and "rec4_sku" in row
        assert "fitment_count" in row

    def test_qa_raises_on_too_few_users(self, ...):
        with pytest.raises(QAFailedError, match="250K"): ...

    def test_qa_raises_on_duplicates(self, ...):
        with pytest.raises(QAFailedError, match="duplicate"): ...
```

### tests/test_gnn_metrics.py (11 tests, all pass)

```python
class TestHitRateAtK:
    def test_hit_at_top(self): assert hit_rate_at_k([1,2,3,4], {1}, k=4) == 1.0
    def test_hit_at_last_position(self): assert hit_rate_at_k([1,2,3,4], {4}, k=4) == 1.0
    def test_no_hit(self): assert hit_rate_at_k([1,2,3,4], {5}, k=4) == 0.0
    def test_hit_beyond_k(self): assert hit_rate_at_k([1,2,3,4,5], {5}, k=4) == 0.0
    def test_empty_predictions(self): assert hit_rate_at_k([], {1,2}, k=4) == 0.0
    def test_empty_actuals(self): assert hit_rate_at_k([1,2,3], set(), k=4) == 0.0
    def test_multiple_hits(self): assert hit_rate_at_k([1,2,3,4], {1,2,3}, k=4) == 1.0

class TestMRR:
    def test_first_position(self): assert mrr([1,2,3], {1}) == 1.0
    def test_second_position(self): assert mrr([1,2,3], {2}) == 0.5
    def test_third_position(self): assert mrr([1,2,3], {3}) == pytest.approx(1/3)
    def test_no_match(self): assert mrr([1,2,3], {4}) == 0.0
    def test_empty(self): assert mrr([], {1}) == 0.0
    def test_multiple_relevant(self): assert mrr([1,2,3], {2,3}) == 0.5

class TestComputeAllMetrics:
    def test_includes_hit_rate_and_mrr(self):
        results = compute_all_metrics({1: [10,20,30,40,50]}, {1: {10,30}}, k_values=[4,10])
        assert results["hit_rate_at_4"] == 1.0
        assert results["mrr"] == 1.0
```

---

## Additional Context

Key design decisions to validate tests against:
1. **2+2 slot reservation**: 2 fitment + 2 universal products, with PartType diversity cap of 2
2. **Deterministic ID mappings**: Sorted alphabetically, deduplicated — critical for checkpoint reuse across runs
3. **Fail-fast drift detection**: Graph builder raises ValueError if ID mapping keys don't match node tables
4. **Cold-tier go/no-go**: Evaluation decisions use training-cold user metrics, not aggregate
5. **Temporal leakage prevention**: Train cutoff = T-30, test starts at T-30+1 day
6. **Universal candidate pool**: Evaluator, trainer, and scorer all use fitment + universal products as eligible candidates
7. **Checkpoint persistence**: ID mappings saved alongside model weights to prevent embedding misalignment
