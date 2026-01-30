"""Offline evaluation: GNN recommendations vs SQL baseline.

Metrics: MRR, Recall@{1,5,10,20}, NDCG@10
Stratified by engagement tier (cold/warm/hot).
"""

import logging
from dataclasses import dataclass

import numpy as np
import pandas as pd
import torch
from torch_geometric.data import HeteroData

from src.gnn.model import HolleyGAT

logger = logging.getLogger(__name__)


@dataclass
class EvalMetrics:
    """Evaluation metrics container."""
    mrr: float
    recall_at_1: float
    recall_at_5: float
    recall_at_10: float
    recall_at_20: float
    ndcg_at_10: float
    num_users: int

    def to_dict(self) -> dict:
        return {
            "MRR": self.mrr,
            "Recall@1": self.recall_at_1,
            "Recall@5": self.recall_at_5,
            "Recall@10": self.recall_at_10,
            "Recall@20": self.recall_at_20,
            "NDCG@10": self.ndcg_at_10,
            "num_users": self.num_users,
        }


class GNNEvaluator:
    """Evaluate GNN recommendations against test clicks and SQL baseline."""

    def __init__(
        self,
        model: HolleyGAT,
        data: HeteroData,
        graph_builder,  # HolleyGraphBuilder (for encoder access)
        top_k: int = 20,
        device: str = "cpu",
    ):
        self.model = model.to(device)
        self.data = data.to(device)
        self.graph_builder = graph_builder
        self.top_k = top_k
        self.device = device

    @torch.no_grad()
    def generate_recommendations(self) -> pd.DataFrame:
        """Generate top-K recommendations for all users.

        Returns:
            DataFrame with columns: user_id, sku, rank, score
        """
        self.model.eval()
        user_emb, product_emb = self.model(self.data)

        # Compute all user-product scores
        scores = torch.mm(user_emb, product_emb.t())  # [num_users, num_products]

        # Top-K per user
        topk_scores, topk_indices = scores.topk(self.top_k, dim=1)

        # Decode back to original IDs
        user_ids = self.graph_builder.user_encoder.classes_
        product_ids = self.graph_builder.product_encoder.classes_

        rows = []
        for i in range(len(user_ids)):
            for rank in range(self.top_k):
                rows.append({
                    "user_id": user_ids[i],
                    "sku": product_ids[topk_indices[i, rank].item()],
                    "rank": rank + 1,
                    "score": topk_scores[i, rank].item(),
                })

        return pd.DataFrame(rows)

    def evaluate_against_clicks(
        self,
        test_clicks: pd.DataFrame,
        user_nodes: pd.DataFrame,
    ) -> dict[str, EvalMetrics]:
        """Evaluate GNN recommendations against test clicks.

        Args:
            test_clicks: DataFrame with columns user_id, sku
            user_nodes: DataFrame with user_id, engagement_tier

        Returns:
            Dict of metrics: "overall" + per-tier ("cold", "warm", "hot")
        """
        recs = self.generate_recommendations()

        # Build lookup: user_id → list of recommended SKUs (ordered)
        rec_lookup = (
            recs.sort_values(["user_id", "rank"])
            .groupby("user_id")["sku"]
            .apply(list)
            .to_dict()
        )

        # Build ground truth: user_id → set of clicked SKUs
        gt_lookup = (
            test_clicks.groupby("user_id")["sku"]
            .apply(set)
            .to_dict()
        )

        # Merge engagement tier
        tier_map = user_nodes.set_index("user_id")["engagement_tier"].to_dict()

        # Evaluate per tier
        results = {}
        for tier in ["cold", "warm", "hot", "overall"]:
            if tier == "overall":
                eval_users = set(gt_lookup.keys()) & set(rec_lookup.keys())
            else:
                eval_users = {
                    u for u in gt_lookup.keys()
                    if u in rec_lookup and tier_map.get(u) == tier
                }

            if not eval_users:
                results[tier] = EvalMetrics(0, 0, 0, 0, 0, 0, 0)
                continue

            mrr_vals, r1, r5, r10, r20, ndcg10 = [], [], [], [], [], []

            for user_id in eval_users:
                recs_list = rec_lookup[user_id]
                gt_set = gt_lookup[user_id]

                mrr_vals.append(self._mrr(recs_list, gt_set))
                r1.append(self._recall_at_k(recs_list, gt_set, 1))
                r5.append(self._recall_at_k(recs_list, gt_set, 5))
                r10.append(self._recall_at_k(recs_list, gt_set, 10))
                r20.append(self._recall_at_k(recs_list, gt_set, 20))
                ndcg10.append(self._ndcg_at_k(recs_list, gt_set, 10))

            results[tier] = EvalMetrics(
                mrr=np.mean(mrr_vals),
                recall_at_1=np.mean(r1),
                recall_at_5=np.mean(r5),
                recall_at_10=np.mean(r10),
                recall_at_20=np.mean(r20),
                ndcg_at_10=np.mean(ndcg10),
                num_users=len(eval_users),
            )

        return results

    def compare_with_sql_baseline(
        self,
        sql_recs: pd.DataFrame,
        test_clicks: pd.DataFrame,
        user_nodes: pd.DataFrame,
    ) -> pd.DataFrame:
        """Compare GNN vs SQL baseline metrics side by side.

        Args:
            sql_recs: SQL baseline recs with user_id, sku, rank columns
            test_clicks: Ground truth clicks
            user_nodes: User engagement tiers

        Returns:
            Comparison DataFrame
        """
        gnn_metrics = self.evaluate_against_clicks(test_clicks, user_nodes)

        # Evaluate SQL baseline the same way
        sql_lookup = (
            sql_recs.sort_values(["user_id", "rank"])
            .groupby("user_id")["sku"]
            .apply(list)
            .to_dict()
        )
        gt_lookup = test_clicks.groupby("user_id")["sku"].apply(set).to_dict()
        tier_map = user_nodes.set_index("user_id")["engagement_tier"].to_dict()

        sql_metrics = {}
        for tier in ["cold", "warm", "hot", "overall"]:
            if tier == "overall":
                eval_users = set(gt_lookup.keys()) & set(sql_lookup.keys())
            else:
                eval_users = {
                    u for u in gt_lookup.keys()
                    if u in sql_lookup and tier_map.get(u) == tier
                }

            if not eval_users:
                sql_metrics[tier] = EvalMetrics(0, 0, 0, 0, 0, 0, 0)
                continue

            mrr_vals, r1, r5, r10, r20, ndcg10 = [], [], [], [], [], []
            for user_id in eval_users:
                recs_list = sql_lookup.get(user_id, [])
                gt_set = gt_lookup[user_id]
                mrr_vals.append(self._mrr(recs_list, gt_set))
                r1.append(self._recall_at_k(recs_list, gt_set, 1))
                r5.append(self._recall_at_k(recs_list, gt_set, 5))
                r10.append(self._recall_at_k(recs_list, gt_set, 10))
                r20.append(self._recall_at_k(recs_list, gt_set, 20))
                ndcg10.append(self._ndcg_at_k(recs_list, gt_set, 10))

            sql_metrics[tier] = EvalMetrics(
                mrr=np.mean(mrr_vals),
                recall_at_1=np.mean(r1),
                recall_at_5=np.mean(r5),
                recall_at_10=np.mean(r10),
                recall_at_20=np.mean(r20),
                ndcg_at_10=np.mean(ndcg10),
                num_users=len(eval_users),
            )

        # Build comparison table
        rows = []
        for tier in ["cold", "warm", "hot", "overall"]:
            gnn = gnn_metrics[tier].to_dict()
            sql = sql_metrics[tier].to_dict()
            for metric in ["MRR", "Recall@1", "Recall@5", "Recall@10", "Recall@20", "NDCG@10"]:
                rows.append({
                    "tier": tier,
                    "metric": metric,
                    "gnn": gnn[metric],
                    "sql": sql[metric],
                    "delta": gnn[metric] - sql[metric],
                    "delta_pct": (
                        (gnn[metric] - sql[metric]) / sql[metric] * 100
                        if sql[metric] > 0 else 0
                    ),
                })

        return pd.DataFrame(rows)

    @staticmethod
    def _mrr(recs: list, gt: set) -> float:
        for i, item in enumerate(recs):
            if item in gt:
                return 1.0 / (i + 1)
        return 0.0

    @staticmethod
    def _recall_at_k(recs: list, gt: set, k: int) -> float:
        hits = sum(1 for item in recs[:k] if item in gt)
        return hits / len(gt) if gt else 0.0

    @staticmethod
    def _ndcg_at_k(recs: list, gt: set, k: int) -> float:
        dcg = sum(
            1.0 / np.log2(i + 2)
            for i, item in enumerate(recs[:k])
            if item in gt
        )
        idcg = sum(1.0 / np.log2(i + 2) for i in range(min(len(gt), k)))
        return dcg / idcg if idcg > 0 else 0.0
