# Peer Review: GNN Option A — Workflow Orchestration Audit Fixes

## Context

We have a GNN-based recommendation system (HeteroGAT) for vehicle fitment automotive parts. The system was built, tested (109 tests), and committed — but a retroactive "workflow orchestration audit" identified gaps between the design spec and the implementation. We just implemented the fixes. Please review the changes for correctness, edge cases, and anything we missed.

**System overview**: 4 email recommendation slots per user. Slot reservation: 2 fitment (vehicle-specific parts) + 2 universal. PartType diversity cap (max 2 per type). Products ranked by GNN dot-product scores.

**Test results after changes**: 113 tests passing (109 original + 4 new), 0 lint warnings (ruff).

## Changes Made (10 fixes)

| ID | Fix | Severity |
|----|-----|----------|
| E3 | QA score ordering check now validates ALL rows (was `.head(1000)`) | Must-fix |
| E1 | Extracted shared `build_fitment_index()` to `rules.py` (was duplicated 3x in trainer/evaluator/scorer) | Should-fix |
| E2 | Vectorized `_build_product_metadata()` — replaced `iterrows()` with column `.tolist()` | Nice-to-have |
| G1 | Added purchase exclusion (365-day lookback) via `excluded_products` param in slot reservation | Should-fix |
| G2 | Added `rec{i}_name`, `rec{i}_url`, `rec{i}_image_url` output columns | Should-fix |
| G3 | Added HTTPS image URL validation to QA checks | Should-fix |
| G5 | Scorer now logs vehicle-miss count (users with consent but no graph match) | Nice-to-have |
| E4 | Trainer and evaluator log warnings when falling back to all-product candidates (80x cost) | Nice-to-have |
| — | GNN dependencies already existed in pyproject.toml `[project.optional-dependencies] gnn` — no change needed | N/A |
| — | G4 (email-click sanity check) deferred — not implemented | Deferred |

## Review Focus Areas

1. **Purchase exclusion correctness (G1)**: The `excluded_products` are seeded into `seen_products` in `apply_slot_reservation_with_diversity`. Does this correctly exclude them from all 3 phases (fitment, universal, backfill)? Any edge cases with the `set()` initialization?

2. **Shared `build_fitment_index` (E1)**: The scorer still uses its own `_build_vehicle_groups()` because it needs vehicle→user and vehicle→product mappings (different structure from user→product). Was it right to NOT refactor the scorer's version?

3. **Vectorized metadata (E2)**: The new approach pre-extracts columns as `.tolist()` then loops by index. Is this actually faster than `iterrows()` for ~25K products? Any correctness risk with index alignment?

4. **HTTPS validation (G3)**: The check filters to non-empty, non-null strings then checks `startswith("https://")`. Edge cases: empty strings, NaN, protocol-relative URLs (`//cdn.example.com`)?

5. **Output schema change (G2)**: Adding 12 new columns (`name`, `url`, `image_url` × 4 slots). Does this break any downstream consumer expectations? The shadow table schema needs to match.

6. **Fallback warning pattern (E4)**: Trainer uses `hasattr(self, "_fallback_warned")` to log once. Evaluator uses a counter. Is the trainer pattern safe across multiple `validate()` calls within one training run?

7. **Test coverage gaps**: Are there any scenarios not tested? E.g., purchase exclusion removing ALL candidates, HTTPS validation with mixed valid/invalid URLs, vehicle-miss logging when 100% of users miss.

---

## File: `src/gnn/rules.py` (shared business rules)

```python
"""Shared recommendation business rules for GNN evaluation and scoring."""

from __future__ import annotations

from collections.abc import Iterable
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from torch_geometric.data import HeteroData


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
    excluded_products: set[int] | None = None,
) -> list[int]:
    """Select final recommendations with slot reservation + part-type cap.

    The selection policy is:
    1. Fill up to `fitment_slots` from ranked fitment products.
    2. Fill up to `universal_slots` from ranked universal products.
    3. Backfill from the global ranked list until `total_slots` is reached.
    4. Enforce `max_per_part_type` across all phases.
    5. Skip products in `excluded_products` (e.g. recently purchased).
    """
    result: list[int] = []
    seen_products: set[int] = set(excluded_products) if excluded_products else set()
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


def build_fitment_index(data: HeteroData) -> dict[int, list[int]]:
    """Build user -> fitment product mapping from graph ownership and fitment edges.

    Shared across trainer (hard negative sampling), evaluator (candidate pool),
    and scorer (vehicle-grouped scoring). Extracted to avoid 3x duplication.
    """
    result: dict[int, list[int]] = {}

    own_type = ("user", "owns", "vehicle")
    fits_type = ("vehicle", "rev_fits", "product")

    if own_type not in data.edge_types or fits_type not in data.edge_types:
        return result

    own_ei = data[own_type].edge_index
    fits_ei = data[fits_type].edge_index

    vehicle_products: dict[int, set[int]] = {}
    for v, p in zip(fits_ei[0].cpu().numpy(), fits_ei[1].cpu().numpy()):
        vehicle_products.setdefault(int(v), set()).add(int(p))

    for u, v in zip(own_ei[0].cpu().numpy(), own_ei[1].cpu().numpy()):
        result[int(u)] = list(vehicle_products.get(int(v), set()))

    return result
```

## File: `src/gnn/scorer.py` (production scorer)

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
        user_purchases: dict[str, set[str]] | None = None,
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

        # Purchase exclusion: email -> set of product_ids (365-day lookback)
        self._build_purchase_exclusions(user_purchases or {})

        # Product metadata for output columns
        self._build_product_metadata()

        # Build fitment and vehicle mappings
        self._build_vehicle_groups()

        # Build universal product pool (is_universal=True products)
        self._build_universal_pool()

    def _build_product_metadata(self):
        """Build sku -> (name, url, image_url, price) from product nodes."""
        products_df = self.nodes["products"]
        product_to_id = self.id_mappings["product_to_id"]

        # Vectorized: build meta dict from columns directly
        base_skus = products_df["base_sku"].tolist()
        skus = products_df["sku"].tolist() if "sku" in products_df.columns else base_skus
        prices = (products_df["price"] if "price" in products_df.columns
                  else pd.Series(0, index=products_df.index)).tolist()
        part_types = (products_df["part_type"].fillna("") if "part_type" in products_df.columns
                      else pd.Series("", index=products_df.index)).tolist()
        is_universals = (products_df["is_universal"].fillna(False) if "is_universal" in products_df.columns
                         else pd.Series(False, index=products_df.index)).tolist()
        names = (products_df["name"].fillna("") if "name" in products_df.columns
                 else pd.Series("", index=products_df.index)).tolist()
        urls = (products_df["url"].fillna("") if "url" in products_df.columns
                else pd.Series("", index=products_df.index)).tolist()
        image_urls = (products_df["image_url"].fillna("") if "image_url" in products_df.columns
                      else pd.Series("", index=products_df.index)).tolist()

        self.product_meta: dict[str, dict] = {}
        self.part_type_by_product_id: dict[int, str] = {}

        for i, base_sku in enumerate(base_skus):
            self.product_meta[base_sku] = {
                "sku": skus[i],
                "price": prices[i],
                "part_type": part_types[i],
                "is_universal": is_universals[i],
                "name": names[i],
                "url": urls[i],
                "image_url": image_urls[i],
            }
            pid = product_to_id.get(base_sku)
            if pid is not None:
                self.part_type_by_product_id[pid] = part_types[i]

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

    def _build_purchase_exclusions(self, user_purchases: dict[str, set[str]]):
        """Build email -> set of purchased product_ids for exclusion.

        Args:
            user_purchases: email_lower -> set of base_sku strings (365-day lookback).
        """
        product_to_id = self.id_mappings["product_to_id"]
        self.user_excluded_products: dict[str, set[int]] = {}
        n_excluded = 0
        for email, skus in user_purchases.items():
            product_ids = set()
            for sku in skus:
                pid = product_to_id.get(sku)
                if pid is not None:
                    product_ids.add(pid)
            if product_ids:
                self.user_excluded_products[email] = product_ids
                n_excluded += len(product_ids)
        if user_purchases:
            logger.info(
                f"Purchase exclusion: {len(self.user_excluded_products)} users, "
                f"{n_excluded} total product exclusions"
            )

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
            cols.extend([
                f"rec{i}_sku", f"rec{i}_name", f"rec{i}_url",
                f"rec{i}_image_url", f"rec{i}_price", f"rec{i}_score",
            ])
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
                universal_scores = torch.mm(batch_user_embs, universal_embs.t())

            for i, uid in enumerate(target_uids):
                email = self.id_to_user[uid]
                excluded = self.user_excluded_products.get(email)
                recs = self._select_top4(
                    fitment_ids, fitment_scores[i],
                    self.universal_product_ids, universal_scores[i] if universal_scores is not None else None,
                    excluded_products=excluded,
                )
                if recs:
                    rows.append(self._format_row(email, recs))

        df = pd.DataFrame(rows, columns=self._output_columns())

        # Log vehicle-miss count: users with consent but no vehicle in graph
        scored_emails = {r["email_lower"] for r in rows} if rows else set()
        vehicle_miss_count = len(target_emails - scored_emails)
        if vehicle_miss_count > 0:
            logger.warning(
                f"Vehicle miss: {vehicle_miss_count} consented users had no vehicle match "
                f"in graph ({vehicle_miss_count}/{len(target_emails)} = "
                f"{vehicle_miss_count / len(target_emails) * 100:.1f}%)"
            )
        logger.info(f"Scored {len(df)} users across {n_vehicles} vehicles")

        self._qa_checks(df)
        return df

    def _select_top4(
        self,
        fitment_ids: list[int],
        fitment_scores: torch.Tensor,
        universal_ids: list[int],
        universal_scores: torch.Tensor | None,
        excluded_products: set[int] | None = None,
    ) -> list[tuple[int, float]]:
        """Select top 4 products: 2 fitment + 2 universal with PartType diversity."""
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
            excluded_products=excluded_products,
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
            row[f"rec{i}_name"] = meta.get("name", "")
            row[f"rec{i}_url"] = meta.get("url", "")
            row[f"rec{i}_image_url"] = meta.get("image_url", "")
            row[f"rec{i}_price"] = meta.get("price", 0)
            row[f"rec{i}_score"] = score
            if not meta.get("is_universal", True):
                fitment_count += 1

        # Fill remaining slots with None
        for i in range(len(recs) + 1, 5):
            row[f"rec{i}_sku"] = None
            row[f"rec{i}_name"] = None
            row[f"rec{i}_url"] = None
            row[f"rec{i}_image_url"] = None
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

        # HTTPS image URL validation
        for i in range(1, 5):
            col = f"rec{i}_image_url"
            if col in df.columns:
                non_empty = df[col].dropna()
                non_empty = non_empty[non_empty.astype(str).str.len() > 0]
                bad_urls = non_empty[~non_empty.astype(str).str.startswith("https://")]
                if len(bad_urls) > 0:
                    failures.append(f"{len(bad_urls)} non-HTTPS image URLs in slot {i}")

        # Score ordering (all rows — numpy comparison is cheap)
        score_matrix = df[[f"rec{i}_score" for i in range(1, 5)]].to_numpy(
            dtype=np.float64, copy=False
        )
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
```

## File: `src/gnn/evaluator.py` (key changes only — `build_fitment_index` import + fallback warning)

```python
# Line 13: import changed
from src.gnn.rules import apply_slot_reservation_with_diversity, build_fitment_index

# Line 130: replaced 20-line _build_fitment_index method with single call
self.user_fitment_products = build_fitment_index(self.data)

# Lines 168-191: added fallback counter and warning log
n_fallback = 0
for uid in evaluable_users:
    fitment = self.user_fitment_products.get(uid, [])
    eligible = list(dict.fromkeys(fitment + self.universal_product_ids))
    if not eligible:
        eligible = list(range(self.data["product"].num_nodes))
        n_fallback += 1
    # ... scoring logic unchanged ...

if n_fallback > 0:
    logger.warning(
        "Candidate fallback: %d/%d eval users had no fitment/universal products, "
        "using all %d products as candidates",
        n_fallback, len(evaluable_users), self.data["product"].num_nodes,
    )
```

## File: `src/gnn/trainer.py` (key changes only — `build_fitment_index` import + fallback warning)

```python
# Line 14: import added
from src.gnn.rules import build_fitment_index

# Line 83: replaced _build_fitment_index() method call with shared function
self.user_fitment_products = build_fitment_index(self.data)

# Lines 116-124: added one-time fallback warning
if not eligible:
    eligible = self.all_product_ids
    if not hasattr(self, "_fallback_warned"):
        logger.warning(
            "Eval candidate fallback: user %d has no fitment/universal products, "
            "using all %d products (80x+ cost increase)",
            user_id, len(eligible),
        )
        self._fallback_warned = True
```

## File: `tests/test_gnn_rules.py` (new tests only)

```python
def test_excluded_products_are_skipped(self, part_types):
    """Products in excluded_products set are filtered from all phases."""
    ranked = [0, 1, 10, 11, 2, 3, 12, 13]
    fitment = {0, 1, 2, 3}
    universal = {10, 11, 12, 13}

    result = apply_slot_reservation_with_diversity(
        ranked, fitment, universal, part_types,
        excluded_products={0, 10},
    )

    assert len(result) == 4
    assert 0 not in result
    assert 10 not in result
    assert result[0] == 1
    assert 11 in result

def test_excluded_products_none_has_no_effect(self, part_types):
    """excluded_products=None behaves same as empty set."""
    ranked = [0, 1, 10, 11]
    fitment = {0, 1}
    universal = {10, 11}

    result = apply_slot_reservation_with_diversity(
        ranked, fitment, universal, part_types,
        excluded_products=None,
    )

    assert len(result) == 4
    assert result[0] == 0
```

## File: `tests/test_gnn_scorer.py` (new tests only)

```python
def test_purchase_exclusion_filters_bought_products(self, scorer_setup):
    from src.gnn.scorer import GNNScorer

    model, data, id_map, nodes, config, mock_bq = scorer_setup
    products_df = nodes["products"]
    excluded_sku = products_df["base_sku"].iloc[0]

    user_purchases = {"user_1@test.com": {excluded_sku}}

    scorer = GNNScorer(
        model=model, data=data, id_mappings=id_map,
        nodes=nodes, config=config, bq_client=mock_bq,
        user_purchases=user_purchases,
    )

    assert "user_1@test.com" in scorer.user_excluded_products
    pid = id_map["product_to_id"][excluded_sku]
    assert pid in scorer.user_excluded_products["user_1@test.com"]

def test_purchase_exclusion_empty_by_default(self, scorer_setup):
    from src.gnn.scorer import GNNScorer

    model, data, id_map, nodes, config, mock_bq = scorer_setup

    scorer = GNNScorer(
        model=model, data=data, id_mappings=id_map,
        nodes=nodes, config=config, bq_client=mock_bq,
    )

    assert scorer.user_excluded_products == {}
```

---

## What I want from the review

1. **Bugs**: Anything that would produce wrong results in production.
2. **Edge cases**: Scenarios that could crash or produce unexpected behavior.
3. **Design concerns**: Anything that will be painful to maintain or extend.
4. **Missing tests**: Specific test scenarios we should add.
5. **Nits**: Style, naming, performance — low priority but worth noting.

Please structure your response with these 5 sections. Be specific — cite line numbers and explain the impact.
