"""GNN evaluation: stratified metrics, SQL baseline comparison, bootstrap CIs."""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any

import numpy as np
import pandas as pd
import torch

from src.gnn.model import HolleyGAT
from src.gnn.rules import apply_slot_reservation_with_diversity, build_fitment_index
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
        nodes: dict[str, pd.DataFrame],
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

        # Build product metadata used by post-GNN rules.
        self.universal_product_ids: frozenset[int] = frozenset()
        self.part_type_by_product_id: dict[int, str] = {}
        if "products" in nodes:
            products = (
                nodes["products"][["base_sku", "part_type", "is_universal"]]
                .drop_duplicates(subset=["base_sku"])
                .copy()
            )
            products["product_id"] = products["base_sku"].map(product_to_id)
            products = products.dropna(subset=["product_id"])
            products["product_id"] = products["product_id"].astype(int)

            self.part_type_by_product_id = dict(zip(
                products["product_id"],
                products["part_type"].fillna("").astype(str),
            ))
            self.universal_product_ids = frozenset(
                products.loc[
                    products["is_universal"].fillna(False).astype(bool),
                    "product_id",
                ]
                .drop_duplicates()
                .tolist()
            )
        logger.info(f"Universal products (excluded from eval): {len(self.universal_product_ids)}")

        # Build test set: user_id -> set of product_ids
        self.test_interactions: dict[int, set[int]] = {}
        required_test_cols = {"email_lower", "base_sku"}
        missing_test_cols = required_test_cols - set(test_df.columns)
        if missing_test_cols:
            raise ValueError(
                "test_df missing required columns: "
                + ", ".join(sorted(missing_test_cols))
            )
        test_pairs = test_df.assign(
            user_id=test_df["email_lower"].map(user_to_id),
            product_id=test_df["base_sku"].map(product_to_id),
        ).dropna(subset=["user_id", "product_id"])
        if not test_pairs.empty:
            test_pairs["user_id"] = test_pairs["user_id"].astype(int)
            test_pairs["product_id"] = test_pairs["product_id"].astype(int)
            for uid, group in test_pairs.groupby("user_id"):
                # C3: filter universal products from test labels — they can't appear
                # in candidate pools so including them creates impossible positives.
                products = set(group["product_id"].tolist()) - self.universal_product_ids
                if products:
                    self.test_interactions[int(uid)] = products

        # Build SQL baseline: user_id -> list of product_ids (sorted by rank)
        self.sql_baseline: dict[int, list[int]] = {}
        sql_sorted = sql_baseline_df.sort_values("rank") if "rank" in sql_baseline_df.columns else sql_baseline_df
        sql_pairs = sql_sorted.copy()
        if "sku" in sql_pairs.columns:
            raw_sku = sql_pairs["sku"]
        elif "base_sku" in sql_pairs.columns:
            raw_sku = sql_pairs["base_sku"]
        else:
            raise ValueError("sql_baseline_df must include either 'sku' or 'base_sku' column")

        sql_pairs["base_sku"] = (
            raw_sku.fillna("").astype(str).str.replace(r"([0-9])[BRGP]$", r"\1", regex=True)
        )
        if "email_lower" not in sql_pairs.columns:
            raise ValueError("sql_baseline_df missing required column: email_lower")
        sql_pairs["user_id"] = sql_pairs["email_lower"].map(user_to_id)
        sql_pairs["product_id"] = sql_pairs["base_sku"].map(product_to_id)
        sql_pairs = sql_pairs.dropna(subset=["user_id", "product_id"])
        if not sql_pairs.empty:
            sql_pairs["user_id"] = sql_pairs["user_id"].astype(int)
            sql_pairs["product_id"] = sql_pairs["product_id"].astype(int)
            for uid, group in sql_pairs.groupby("user_id", sort=False):
                deduped: list[int] = []
                seen: set[int] = set()
                for pid in group["product_id"].tolist():
                    if pid in seen:
                        continue
                    seen.add(pid)
                    deduped.append(pid)
                self.sql_baseline[int(uid)] = deduped

        # Engagement tiers for stratification
        self.user_tiers = user_engagement_tiers or {}

        # Build fitment index: user_id -> list of product_ids
        self.user_fitment_products = build_fitment_index(self.data)

        # Finding 5: precompute fallback candidate pool once (O(1) per user)
        self.all_non_universal_products: list[int] = [
            p for p in range(self.data["product"].num_nodes)
            if p not in self.universal_product_ids
        ]

    @torch.no_grad()
    def evaluate(self, split: str = "test") -> dict[str, Any]:
        """Run full evaluation pipeline.

        Returns dict with:
            - gnn_pre_rules: metrics before business rules
            - gnn_post_rules: metrics after business rules
            - sql_baseline: SQL baseline metrics
            - by_tier: stratified metrics
            - deltas: GNN - SQL deltas
            - go_no_go: recommendation based on thresholds
        """
        self.model.eval()
        self.model = self.model.to(self.device)
        self.data = self.data.to(self.device)

        user_embs, product_embs = self.model(self.data)
        user_embs = user_embs.cpu()
        product_embs = product_embs.cpu()

        mask = self.split_masks[f"{split}_mask"]
        k_values = self.config["eval"]["k_values"]

        # Collect per-user predictions and metrics
        gnn_pre_rules_by_user: dict[int, list[int]] = {}
        gnn_post_rules_by_user: dict[int, list[int]] = {}

        evaluable_users = []
        for uid in mask.nonzero(as_tuple=True)[0]:
            uid_int = uid.item()
            if uid_int not in self.test_interactions:
                continue
            evaluable_users.append(uid_int)

        logger.info(f"Evaluable {split} users: {len(evaluable_users)}")

        n_fallback = 0
        for uid in evaluable_users:
            fitment = self.user_fitment_products.get(uid, [])
            # Fitment-only candidates (no universals — v5.18 alignment)
            eligible = [p for p in fitment if p not in self.universal_product_ids]
            if not eligible:
                # Finding 5: use precomputed list instead of rebuilding per user
                eligible = self.all_non_universal_products
                n_fallback += 1

            eligible_t = torch.tensor(eligible, dtype=torch.long)
            scores = torch.mv(product_embs[eligible_t], user_embs[uid])
            _, top_indices = scores.topk(min(max(k_values) * 2, len(eligible)))
            pre_rules = [eligible[idx.item()] for idx in top_indices]
            gnn_pre_rules_by_user[uid] = pre_rules

            post_rules = self._apply_business_rules(uid, pre_rules)
            gnn_post_rules_by_user[uid] = post_rules

        if n_fallback > 0:
            logger.warning(
                "Candidate fallback: %d/%d eval users had no fitment products, "
                "using all non-universal products as candidates",
                n_fallback, len(evaluable_users),
            )

        # Compute metrics
        gnn_pre = self._compute_metrics(gnn_pre_rules_by_user, k_values)
        gnn_post = self._compute_metrics(gnn_post_rules_by_user, k_values)

        # SQL baseline metrics (same users)
        sql_preds = {uid: self.sql_baseline.get(uid, []) for uid in evaluable_users}
        sql_metrics = self._compute_metrics(sql_preds, k_values)

        # Stratified metrics
        by_tier = self._compute_stratified(
            gnn_pre_rules_by_user, gnn_post_rules_by_user, sql_preds, k_values
        )

        # Bootstrap CIs
        n_bootstrap = self.config["eval"]["bootstrap_samples"]
        gnn_pre_ci = self._bootstrap_ci(gnn_pre_rules_by_user, k_values, n_bootstrap)
        gnn_post_ci = self._bootstrap_ci(gnn_post_rules_by_user, k_values, n_bootstrap)
        sql_ci = self._bootstrap_ci(sql_preds, k_values, n_bootstrap)

        # Deltas (only @4 is a fair comparison — SQL baseline has max 4 recs)
        deltas = {}
        fair_keys = {k for k in gnn_pre if k.endswith("_at_4") or k in ("mrr", "n_users")}
        for key in gnn_pre:
            delta_pre = gnn_pre[key] - sql_metrics.get(key, 0)
            delta_post = gnn_post[key] - sql_metrics.get(key, 0)
            deltas[f"pre_rules_{key}_delta"] = delta_pre
            deltas[f"post_rules_{key}_delta"] = delta_post
            if key not in fair_keys:
                deltas[f"pre_rules_{key}_delta_NOTE"] = "unfair: SQL limited to 4 recs"
                deltas[f"post_rules_{key}_delta_NOTE"] = "unfair: SQL limited to 4 recs"

        # Go/no-go uses cold-tier metrics per design spec Section 5
        cold_tier = by_tier.get("cold", {})
        cold_gnn = cold_tier.get("gnn_pre_rules", gnn_pre)
        cold_sql = cold_tier.get("sql_baseline", sql_metrics)
        go_no_go = self._go_no_go(cold_gnn, cold_sql)

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
        self,
        user_id: int,
        ranked_products: list[int],
    ) -> list[int]:
        """Apply post-GNN business rules (fitment slots, diversity, etc.).

        Note: purchase exclusion is intentionally omitted here. Evaluation
        measures model ranking quality, not production filtering. Adding
        exclusion would make offline metrics non-comparable across runs.
        """
        fitment_set = set(self.user_fitment_products.get(user_id, []))
        return apply_slot_reservation_with_diversity(
            ranked_products=ranked_products,
            fitment_set=fitment_set,
            universal_set=frozenset(),
            part_type_by_product=self.part_type_by_product_id,
            fitment_slots=4,
            universal_slots=0,
            total_slots=4,
            max_per_part_type=2,
        )

    def _compute_metrics(
        self,
        predictions: dict[int, list[int]],
        k_values: list[int],
    ) -> dict[str, float]:
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
                metrics_lists[f"hit_rate_at_{k}"].append(
                    hit_rate_at_k(preds, actuals, k)
                )
                metrics_lists[f"recall_at_{k}"].append(
                    recall_at_k(preds, actuals, k)
                )
            metrics_lists["mrr"].append(mrr(preds, actuals))
            metrics_lists["ndcg_at_10"].append(ndcg_at_k(preds, actuals, 10))

        result = {}
        for key, values in metrics_lists.items():
            result[key] = float(np.mean(values)) if values else 0.0
        result["n_users"] = len([u for u in predictions if self.test_interactions.get(u)])

        return result

    def _compute_stratified(
        self,
        gnn_pre: dict[int, list[int]],
        gnn_post: dict[int, list[int]],
        sql_preds: dict[int, list[int]],
        k_values: list[int],
    ) -> dict[str, dict[str, float]]:
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

    def _bootstrap_ci(
        self,
        predictions: dict[int, list[int]],
        k_values: list[int],
        n_samples: int,
    ) -> dict[str, tuple[float, float]]:
        """Compute 95% bootstrap confidence intervals."""
        rng = np.random.RandomState(42)
        users = [uid for uid in predictions if self.test_interactions.get(uid)]

        if not users:
            return {}

        # Collect per-user metric values
        per_user: dict[str, list[float]] = {f"hit_rate_at_{k}": [] for k in k_values}

        for uid in users:
            preds = predictions[uid]
            actuals = self.test_interactions[uid]
            for k in k_values:
                per_user[f"hit_rate_at_{k}"].append(hit_rate_at_k(preds, actuals, k))

        # Bootstrap
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

    def _go_no_go(
        self,
        gnn_metrics: dict[str, float],
        sql_metrics: dict[str, float],
    ) -> dict[str, str]:
        """Evaluate go/no-go thresholds from design spec Section 5.

        Uses training-cold user Hit Rate@4 delta vs SQL baseline.
        Caller must pass cold-tier metrics, not aggregate.
        """
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
            "decision": decision,
            "rationale": rationale,
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
