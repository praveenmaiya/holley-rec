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

if TYPE_CHECKING:
    from torch_geometric.data import HeteroData

logger = logging.getLogger(__name__)


class QAFailedError(Exception):
    """Raised when critical QA checks fail."""


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
        qa_cfg = config.get("output", {}).get("qa", {})
        self.min_users = int(qa_cfg.get("min_users", 250_000))
        if self.min_users < 0:
            raise ValueError(f"output.qa.min_users must be non-negative, got {self.min_users}")

        # Reverse mappings
        self.id_to_user = {v: k for k, v in id_mappings["user_to_id"].items()}
        self.id_to_product = {v: k for k, v in id_mappings["product_to_id"].items()}
        self.id_to_vehicle = {v: k for k, v in id_mappings["vehicle_to_id"].items()}

        # Product metadata for output columns
        self._build_product_metadata()

        # Build fitment and vehicle mappings
        self._build_vehicle_groups()

        # Build universal product pool (is_universal=True products)
        self._build_universal_pool()

    def _build_product_metadata(self):
        """Build sku -> (name, url, image_url, price) from product nodes."""
        products_df = self.nodes["products"]
        self.product_meta: dict[str, dict] = {}
        self.part_type_by_product_id: dict[int, str] = {}

        product_to_id = self.id_mappings["product_to_id"]

        for _, row in products_df.iterrows():
            sku = row["base_sku"]
            self.product_meta[sku] = {
                "sku": row.get("sku", sku),
                "price": row.get("price", 0),
                "part_type": row.get("part_type", ""),
                "is_universal": row.get("is_universal", False),
            }
            pid = product_to_id.get(sku)
            if pid is not None:
                self.part_type_by_product_id[pid] = row.get("part_type", "")

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

    def _build_universal_pool(self):
        """Build set of universal product IDs (is_universal=True)."""
        product_to_id = self.id_mappings["product_to_id"]
        self.universal_product_ids: list[int] = []
        for sku, meta in self.product_meta.items():
            if meta.get("is_universal", False) and sku in product_to_id:
                self.universal_product_ids.append(product_to_id[sku])
        logger.info(f"Universal product pool: {len(self.universal_product_ids)} products")

    @staticmethod
    def _output_columns() -> list[str]:
        """Canonical output schema for scorer output and QA validation."""
        cols = ["email_lower"]
        for i in range(1, 5):
            cols.extend([f"rec{i}_sku", f"rec{i}_price", f"rec{i}_score"])
        cols.extend(["fitment_count", "model_version"])
        return cols

    @torch.no_grad()
    def score_all_users(self) -> pd.DataFrame:
        """Score all target users using vehicle-grouped strategy.

        Returns wide-format DataFrame matching final_vehicle_recommendations schema.
        """
        self.model.eval()
        self.model = self.model.to(self.device)
        self.data = self.data.to(self.device)

        user_embs, product_embs = self.model(self.data)
        user_embs = user_embs.cpu()
        product_embs = product_embs.cpu()

        # Precompute universal product embeddings for universal slot scoring
        universal_ids_t = torch.tensor(self.universal_product_ids, dtype=torch.long)
        universal_embs = product_embs[universal_ids_t] if len(universal_ids_t) > 0 else None

        # Only score target users (with email consent)
        users_df = self.nodes["users"]
        target_emails = set(users_df[users_df["has_email_consent"]]["email_lower"])

        rows = []
        n_vehicles = len(self.vehicle_users)

        for vid_idx, (vid, user_ids) in enumerate(self.vehicle_users.items()):
            if vid_idx % 200 == 0:
                logger.info(f"Scoring vehicle {vid_idx}/{n_vehicles}...")

            fitment_ids = self.vehicle_products.get(vid, [])
            if not fitment_ids:
                continue

            fitment_ids_t = torch.tensor(fitment_ids, dtype=torch.long)
            fitment_embs = product_embs[fitment_ids_t]

            # Filter to target users in this vehicle group
            target_uids = [uid for uid in user_ids
                           if self.id_to_user.get(uid) in target_emails]
            if not target_uids:
                continue

            # Batch scoring: all users x all fitment products for this vehicle
            target_uids_t = torch.tensor(target_uids, dtype=torch.long)
            batch_user_embs = user_embs[target_uids_t]  # (N_users, 128)
            fitment_scores = torch.mm(batch_user_embs, fitment_embs.t())  # (N_users, N_fitment)

            # Batch scoring: all users x universal products
            universal_scores = None
            if universal_embs is not None and len(universal_embs) > 0:
                universal_scores = torch.mm(batch_user_embs, universal_embs.t())  # (N_users, N_universal)

            for i, uid in enumerate(target_uids):
                email = self.id_to_user[uid]
                recs = self._select_top4(
                    fitment_ids, fitment_scores[i],
                    self.universal_product_ids, universal_scores[i] if universal_scores is not None else None,
                )
                if recs:
                    rows.append(self._format_row(email, recs))

        df = pd.DataFrame(rows, columns=self._output_columns())
        logger.info(f"Scored {len(df)} users across {n_vehicles} vehicles")

        self._qa_checks(df)
        return df

    def _select_top4(
        self,
        fitment_ids: list[int],
        fitment_scores: torch.Tensor,
        universal_ids: list[int],
        universal_scores: torch.Tensor | None,
    ) -> list[tuple[int, float]]:
        """Select top 4 products: 2 fitment + 2 universal with PartType diversity."""
        # Rank fitment and universal pools by score
        fitment_scored = sorted(
            zip(fitment_ids, fitment_scores.numpy()),
            key=lambda x: -x[1],
        )

        universal_scored = []
        if universal_scores is not None and len(universal_ids) > 0:
            universal_scored = sorted(
                zip(universal_ids, universal_scores.numpy()),
                key=lambda x: -x[1],
            )

        combined_scored = sorted(
            fitment_scored + universal_scored,
            key=lambda x: -x[1],
        )
        ranked_products = [pid for pid, _ in combined_scored]
        selected_products = apply_slot_reservation_with_diversity(
            ranked_products=ranked_products,
            fitment_set=set(fitment_ids),
            universal_set=set(universal_ids),
            part_type_by_product=self.part_type_by_product_id,
            fitment_slots=2,
            universal_slots=2,
            total_slots=4,
            max_per_part_type=2,
        )

        score_by_product: dict[int, float] = {}
        for pid, score in combined_scored:
            if pid not in score_by_product:
                score_by_product[pid] = float(score)

        return [
            (pid, score_by_product.get(pid, float("-inf")))
            for pid in selected_products
        ]

    def _format_row(self, email: str, recs: list[tuple[int, float]]) -> dict:
        """Format a single user's recommendations as a wide-format row."""
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

        # Fill remaining slots with None
        for i in range(len(recs) + 1, 5):
            row[f"rec{i}_sku"] = None
            row[f"rec{i}_price"] = None
            row[f"rec{i}_score"] = None

        row["fitment_count"] = fitment_count
        row["model_version"] = "gnn_option_a_v1"

        return row

    def _qa_checks(self, df: pd.DataFrame) -> None:
        """Run QA checks before writing to BQ. Raises QAFailedError on critical failures."""
        failures = []

        required_cols = self._output_columns()
        missing_cols = [c for c in required_cols if c not in df.columns]
        if missing_cols:
            raise QAFailedError(
                "Missing required output columns: " + ", ".join(missing_cols)
            )

        # User count
        if len(df) < self.min_users:
            failures.append(f"Only {len(df)} users (expected >= {self.min_users})")

        # Duplicates
        n_dupes = df["email_lower"].duplicated().sum()
        if n_dupes > 0:
            failures.append(f"{n_dupes} duplicate users")

        # Slot 1 always filled
        null_slot1 = df["rec1_sku"].isna().sum()
        if null_slot1 > 0:
            failures.append(f"{null_slot1} users missing rec1")

        # Price floor
        min_price = self.config["graph"]["min_price"]
        for i in range(1, 5):
            col = f"rec{i}_price"
            if col in df.columns:
                below = (df[col].dropna() < min_price).sum()
                if below > 0:
                    failures.append(f"{below} recs in slot {i} below ${min_price}")

        # Score ordering (sample check — first 1000 rows)
        sample_scores = df.head(1000)[[f"rec{i}_score" for i in range(1, 5)]]
        score_matrix = sample_scores.to_numpy(dtype=np.float64, copy=False)
        score_matrix = np.where(np.isnan(score_matrix), -np.inf, score_matrix)
        if np.any(score_matrix[:, :-1] < score_matrix[:, 1:]):
            failures.append("Score ordering violated")

        if failures:
            for f in failures:
                logger.warning(f"QA FAIL: {f}")
            raise QAFailedError(
                f"QA checks failed ({len(failures)} issues): {'; '.join(failures)}"
            )

        logger.info("QA checks PASSED")

    def write_shadow_table(self, df: pd.DataFrame) -> None:
        """Write recommendations to shadow BQ table."""
        table_id = self.config["output"]["shadow_table"]
        logger.info(f"Writing {len(df)} rows to shadow table: {table_id}")
        self.bq.write_table(df, table_id)
        logger.info("Shadow table write complete")
