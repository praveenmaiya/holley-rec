"""GNN evaluation: stratified metrics, baseline comparison, bootstrap CIs.

Generic evaluator driven by config and plugin hooks.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any

import numpy as np
import pandas as pd
import torch

from rec_engine.core.metrics import hit_rate_at_k, mrr, ndcg_at_k, recall_at_k
from rec_engine.core.model import HeteroGAT
from rec_engine.core.rules import apply_slot_reservation_with_diversity
from rec_engine.plugins import RecEnginePlugin
from rec_engine.topology import TopologyStrategy

if TYPE_CHECKING:
    from torch_geometric.data import HeteroData

logger = logging.getLogger(__name__)


class GNNEvaluator:
    """Evaluate GNN recommendations with stratification, CIs, and go/no-go."""

    def __init__(
        self,
        model: HeteroGAT,
        data: HeteroData,
        split_masks: dict[str, torch.Tensor],
        id_mappings: dict[str, dict],
        nodes: dict[str, pd.DataFrame],
        test_df: pd.DataFrame,
        config: dict[str, Any],
        strategy: TopologyStrategy,
        plugin: RecEnginePlugin,
        *,
        baseline_df: pd.DataFrame | None = None,
        user_engagement_tiers: dict[int, str] | None = None,
        device: torch.device | None = None,
    ):
        self.model = model
        self.data = data
        self.split_masks = split_masks
        self.id_mappings = id_mappings
        self.config = config
        self.strategy = strategy
        self.plugin = plugin
        self.device = device or torch.device("cuda" if torch.cuda.is_available() else "cpu")

        user_to_id = id_mappings["user_to_id"]
        product_to_id = id_mappings["product_to_id"]

        # Build product metadata
        # H4: Use graph tensor for excluded set (same source as scorer)
        excluded_mask = getattr(self.data["product"], "is_excluded", None)
        self.excluded_product_ids: frozenset[int]
        if excluded_mask is not None:
            self.excluded_product_ids = frozenset(
                excluded_mask.nonzero(as_tuple=True)[0].detach().cpu().tolist()
            )
        else:
            self.excluded_product_ids = frozenset()

        self.category_by_product_id: dict[int, str] = {}
        category_col = config.get("columns", {}).get("category", "category")

        if "products" in nodes:
            products = nodes["products"].drop_duplicates(subset=["product_id"]).copy()
            products["_pid"] = products["product_id"].map(product_to_id)
            products = products.dropna(subset=["_pid"])
            products["_pid"] = products["_pid"].astype(int)

            if category_col in products.columns:
                self.category_by_product_id = dict(zip(
                    products["_pid"],
                    products[category_col].fillna("").astype(str),
                ))

        logger.info("Excluded products (eval): %d", len(self.excluded_product_ids))

        # Build test set
        self.test_interactions: dict[int, set[int]] = {}
        test_pairs = test_df.assign(
            _uid=test_df["user_id"].map(user_to_id),
            _pid=test_df["product_id"].map(product_to_id),
        ).dropna(subset=["_uid", "_pid"])
        if not test_pairs.empty:
            test_pairs["_uid"] = test_pairs["_uid"].astype(int)
            test_pairs["_pid"] = test_pairs["_pid"].astype(int)
            for uid, group in test_pairs.groupby("_uid"):
                products = set(group["_pid"].tolist()) - self.excluded_product_ids
                if products:
                    self.test_interactions[int(uid)] = products

        # Build baseline (optional)
        self.baseline: dict[int, list[int]] = {}
        if baseline_df is not None and not baseline_df.empty:
            bl = baseline_df.copy()
            if "rank" in bl.columns:
                bl = bl.sort_values("rank")
            bl["_uid"] = bl["user_id"].map(user_to_id)
            bl["_pid"] = bl["product_id"].map(product_to_id)
            bl = bl.dropna(subset=["_uid", "_pid"])
            if not bl.empty:
                bl["_uid"] = bl["_uid"].astype(int)
                bl["_pid"] = bl["_pid"].astype(int)
                for uid, group in bl.groupby("_uid", sort=False):
                    deduped: list[int] = []
                    seen: set[int] = set()
                    for pid in group["_pid"].tolist():
                        if pid not in seen:
                            seen.add(pid)
                            deduped.append(pid)
                    self.baseline[int(uid)] = deduped

        self.user_tiers = user_engagement_tiers or {}
        self.user_fitment_products = strategy.build_fitment_index(self.data)

        # Precompute fallback candidate pool
        self.all_non_excluded_products: list[int] = [
            p for p in range(self.data["product"].num_nodes)
            if p not in self.excluded_product_ids
        ]

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
        scoring_cfg = self.config.get("scoring", {})
        total_slots = scoring_cfg.get("total_slots", 4)
        max_per_category = scoring_cfg.get("max_per_category", 2)

        evaluable_users = [
            uid.item() for uid in mask.nonzero(as_tuple=True)[0]
            if uid.item() in self.test_interactions
        ]
        logger.info("Evaluable %s users: %d", split, len(evaluable_users))

        # H5: Fail-fast on insufficient evaluable users
        min_evaluable = self.config.get("eval", {}).get("min_evaluable_users", 0)
        if min_evaluable > 0 and len(evaluable_users) < min_evaluable:
            raise ValueError(
                f"Only {len(evaluable_users)} evaluable users "
                f"(minimum: {min_evaluable}). Check test data coverage."
            )

        gnn_pre_rules: dict[int, list[int]] = {}
        gnn_post_rules: dict[int, list[int]] = {}
        n_fallback = 0

        for uid in evaluable_users:
            candidates = self.strategy.generate_candidates(
                uid, self.data,
                user_fitment_products=self.user_fitment_products,
                excluded_product_ids=self.excluded_product_ids,
            )
            if not candidates:
                candidates = self.all_non_excluded_products
                n_fallback += 1

            eligible_t = torch.tensor(candidates, dtype=torch.long)
            scores = torch.mv(product_embs[eligible_t], user_embs[uid])
            _, top_indices = scores.topk(min(max(k_values) * 2, len(candidates)))
            pre_rules = [candidates[idx.item()] for idx in top_indices]
            gnn_pre_rules[uid] = pre_rules

            # Apply business rules
            fitment_set = set(self.user_fitment_products.get(uid, []))
            post_rules = apply_slot_reservation_with_diversity(
                ranked_products=pre_rules,
                fitment_set=fitment_set,
                excluded_set=frozenset(),
                category_by_product=self.category_by_product_id,
                fitment_slots=total_slots,
                excluded_slots=0,
                total_slots=total_slots,
                max_per_category=max_per_category,
            )
            gnn_post_rules[uid] = post_rules

        if n_fallback > 0:
            logger.warning(
                "Candidate fallback: %d/%d eval users had no candidates",
                n_fallback, len(evaluable_users),
            )

        # Compute metrics
        gnn_pre = self._compute_metrics(gnn_pre_rules, k_values)
        gnn_post = self._compute_metrics(gnn_post_rules, k_values)

        # Baseline metrics
        baseline_preds = {uid: self.baseline.get(uid, []) for uid in evaluable_users}
        baseline_metrics = self._compute_metrics(baseline_preds, k_values)

        # Stratified
        by_tier = self._compute_stratified(
            gnn_pre_rules, gnn_post_rules, baseline_preds, k_values
        )

        # Bootstrap CIs
        n_bootstrap = self.config["eval"].get("bootstrap_samples", 1000)
        gnn_pre_ci = self._bootstrap_ci(gnn_pre_rules, k_values, n_bootstrap)
        gnn_post_ci = self._bootstrap_ci(gnn_post_rules, k_values, n_bootstrap)
        baseline_ci = self._bootstrap_ci(baseline_preds, k_values, n_bootstrap)

        # Deltas
        deltas = {}
        for key in gnn_pre:
            deltas[f"pre_rules_{key}_delta"] = gnn_pre[key] - baseline_metrics.get(key, 0)
            deltas[f"post_rules_{key}_delta"] = gnn_post[key] - baseline_metrics.get(key, 0)

        # Go/no-go — use configurable decision tier (defaults to "cold")
        go_no_go_cfg = self.config.get("eval", {}).get("go_no_go", {})
        decision_tier = go_no_go_cfg.get("decision_tier", "cold")
        tier_data = by_tier.get(decision_tier, {})
        tier_gnn = tier_data.get("gnn_pre_rules", gnn_pre)
        tier_baseline = tier_data.get("baseline", baseline_metrics)
        go_no_go = self._go_no_go(tier_gnn, tier_baseline)

        return {
            "gnn_pre_rules": gnn_pre,
            "gnn_post_rules": gnn_post,
            "baseline": baseline_metrics,
            "gnn_pre_rules_ci": gnn_pre_ci,
            "gnn_post_rules_ci": gnn_post_ci,
            "baseline_ci": baseline_ci,
            "by_tier": by_tier,
            "deltas": deltas,
            "go_no_go": go_no_go,
            "n_evaluable": len(evaluable_users),
        }

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
            metrics_lists[f"ndcg_at_{k}"] = []
        metrics_lists["mrr"] = []

        for uid, preds in predictions.items():
            actuals = self.test_interactions.get(uid, set())
            if not actuals or not preds:
                continue
            for k in k_values:
                metrics_lists[f"hit_rate_at_{k}"].append(hit_rate_at_k(preds, actuals, k))
                metrics_lists[f"recall_at_{k}"].append(recall_at_k(preds, actuals, k))
                metrics_lists[f"ndcg_at_{k}"].append(ndcg_at_k(preds, actuals, k))
            metrics_lists["mrr"].append(mrr(preds, actuals))

        result = {}
        for key, values in metrics_lists.items():
            result[key] = float(np.mean(values)) if values else 0.0
        result["n_users"] = len([u for u in predictions if self.test_interactions.get(u)])
        return result

    def _compute_stratified(
        self,
        gnn_pre: dict[int, list[int]],
        gnn_post: dict[int, list[int]],
        baseline_preds: dict[int, list[int]],
        k_values: list[int],
    ) -> dict[str, dict[str, Any]]:
        """Compute metrics stratified by engagement tier.

        Discovers actual tiers from user_tiers data rather than hardcoding.
        """
        # Discover tiers from evaluable users
        evaluable_uids = set(gnn_pre.keys())
        tier_names = sorted({
            self.user_tiers[uid] for uid in evaluable_uids
            if uid in self.user_tiers
        })
        if not tier_names:
            tier_names = ["all"]

        tiers: dict[str, dict[str, Any]] = {}
        for tier_name in tier_names:
            if tier_name == "all":
                tier_users = list(evaluable_uids)
            else:
                tier_users = [uid for uid in evaluable_uids if self.user_tiers.get(uid) == tier_name]
            if not tier_users:
                tiers[tier_name] = {"n_users": 0}
                continue
            tiers[tier_name] = {
                "gnn_pre_rules": self._compute_metrics(
                    {uid: gnn_pre[uid] for uid in tier_users if uid in gnn_pre}, k_values
                ),
                "gnn_post_rules": self._compute_metrics(
                    {uid: gnn_post[uid] for uid in tier_users if uid in gnn_post}, k_values
                ),
                "baseline": self._compute_metrics(
                    {uid: baseline_preds[uid] for uid in tier_users if uid in baseline_preds}, k_values
                ),
            }
        return tiers

    def _bootstrap_ci(
        self,
        predictions: dict[int, list[int]],
        k_values: list[int],
        n_samples: int,
    ) -> dict[str, tuple[float, float]]:
        """Compute 95% bootstrap confidence intervals."""
        seed = self.config.get("eval", {}).get("random_seed", 42)
        rng = np.random.RandomState(seed)
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
            boot_means = [rng.choice(arr, size=len(arr), replace=True).mean() for _ in range(n_samples)]
            boot_means = np.array(boot_means)
            cis[key] = (float(np.percentile(boot_means, 2.5)), float(np.percentile(boot_means, 97.5)))
        return cis

    def _go_no_go(
        self,
        gnn_metrics: dict[str, float],
        baseline_metrics: dict[str, float],
    ) -> dict[str, Any]:
        """Evaluate go/no-go thresholds.

        Uses plugin thresholds if provided, otherwise config eval.go_no_go.
        """
        # Get thresholds from plugin or config
        plugin_thresholds = self.plugin.get_go_no_go_thresholds()
        config_thresholds = self.config.get("eval", {}).get("go_no_go", {})
        thresholds = plugin_thresholds if plugin_thresholds is not None else config_thresholds

        # Configurable delta thresholds with sensible defaults
        go_delta = float(thresholds.get("go_delta", 0.03))
        maybe_delta = float(thresholds.get("maybe_delta", 0.01))
        investigate_delta = float(thresholds.get("investigate_delta", -0.01))
        metric_key = thresholds.get("metric", "hit_rate_at_4")

        delta = gnn_metrics.get(metric_key, 0) - baseline_metrics.get(metric_key, 0)

        if delta >= go_delta:
            decision = "GO"
            rationale = f"{metric_key} delta = {delta:+.4f} (>= {go_delta:+.4f}): proceed to online A/B"
        elif delta >= maybe_delta:
            decision = "MAYBE"
            rationale = f"{metric_key} delta = {delta:+.4f} ({maybe_delta:+.4f} to {go_delta:+.4f}): try alternative first"
        elif delta >= investigate_delta:
            decision = "SKIP"
            rationale = f"{metric_key} delta = {delta:+.4f} ({investigate_delta:+.4f} to {maybe_delta:+.4f}): go to alternative"
        else:
            decision = "INVESTIGATE"
            rationale = f"{metric_key} delta = {delta:+.4f} (< {investigate_delta:+.4f}): possible overfitting or data issue"

        return {
            "decision": decision,
            "rationale": rationale,
            f"gnn_{metric_key}": gnn_metrics.get(metric_key, 0),
            f"baseline_{metric_key}": baseline_metrics.get(metric_key, 0),
            "delta": delta,
            "thresholds_source": "plugin" if plugin_thresholds is not None else "config",
            "thresholds": thresholds,
        }

    def generate_report(self) -> dict[str, Any]:
        """Run evaluation and return complete report."""
        results = self.evaluate()
        logger.info("=== GNN Evaluation Report ===")
        logger.info("Evaluable users: %d", results["n_evaluable"])
        logger.info("GNN Pre-rules:  %s", results["gnn_pre_rules"])
        logger.info("GNN Post-rules: %s", results["gnn_post_rules"])
        logger.info("Baseline:       %s", results["baseline"])
        logger.info("Go/No-Go:       %s", results["go_no_go"])
        return results
