"""GNN production scorer: generate recommendations with fallback logic.

Generic scorer driven by config, topology strategy, and plugin hooks.
No client-specific hardcoding.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any

import numpy as np
import pandas as pd
import torch

from rec_engine.core.model import HeteroGAT
from rec_engine.core.rules import apply_slot_reservation_with_diversity, select_popularity_fallback
from rec_engine.plugins import FallbackTier, RecEnginePlugin
from rec_engine.topology import TopologyStrategy

if TYPE_CHECKING:
    from torch_geometric.data import HeteroData

logger = logging.getLogger(__name__)


class QAFailedError(Exception):
    """Raised when critical QA checks fail."""


class GNNScorer:
    """Score all target users and produce recommendations DataFrame."""

    def __init__(
        self,
        model: HeteroGAT,
        data: HeteroData,
        id_mappings: dict[str, dict],
        nodes: dict[str, pd.DataFrame],
        config: dict[str, Any],
        strategy: TopologyStrategy,
        plugin: RecEnginePlugin,
        *,
        device: torch.device | None = None,
        user_purchases: dict[str, set[str]] | None = None,
    ):
        self.model = model
        self.data = data
        self.id_mappings = id_mappings
        self.nodes = nodes
        self.config = config
        self.strategy = strategy
        self.plugin = plugin
        self.device = device or torch.device("cuda" if torch.cuda.is_available() else "cpu")

        scoring_cfg = config.get("scoring", {})
        self.total_slots = scoring_cfg.get("total_slots", 4)
        self.max_per_category = scoring_cfg.get("max_per_category", 2)

        qa_cfg = config.get("output", {}).get("qa", {})
        self.min_users = int(qa_cfg.get("min_users", 0))
        self.min_coverage = float(qa_cfg.get("min_coverage", 0.95))

        # Reverse mappings
        self.id_to_user = {v: k for k, v in id_mappings["user_to_id"].items()}
        self.id_to_product = {v: k for k, v in id_mappings["product_to_id"].items()}
        entity_to_id = id_mappings.get("entity_to_id", {})
        self.id_to_entity = {v: k for k, v in entity_to_id.items()}

        # Purchase exclusions
        self._build_purchase_exclusions(user_purchases or {})

        # Product metadata
        self._build_product_metadata()

        # Entity mappings (3-node topology)
        self._build_entity_groups()

        # Excluded product set
        self._build_excluded_set()

        # Popularity index
        self._build_popularity_index()

        # Fallback config
        fallback_cfg = config.get("fallback", {})
        self.fallback_enabled = fallback_cfg.get("enabled", True)
        self.min_recs = scoring_cfg.get("min_recs", 3)
        self.score_sentinel = fallback_cfg.get("score_sentinel", 0.0)

        if not 0 <= self.min_recs <= self.total_slots:
            raise ValueError(
                f"scoring.min_recs must be 0-{self.total_slots}, got {self.min_recs}"
            )

    def _build_product_metadata(self):
        """Build product_id -> metadata dict from product nodes."""
        products_df = self.nodes["products"]
        product_to_id = self.id_mappings["product_to_id"]
        category_col = self.config.get("columns", {}).get("category", "category")

        self.product_meta: dict[str, dict] = {}
        self.category_by_product_id: dict[int, str] = {}

        for _, row in products_df.iterrows():
            pid_str = row.get("product_id", "")
            self.product_meta[pid_str] = {
                "product_id": pid_str,
                "price": row.get("price", 0),
                "category": row.get(category_col, ""),
                "name": row.get("name", ""),
                "url": row.get("url", ""),
                "image_url": row.get("image_url", ""),
            }
            pid = product_to_id.get(pid_str)
            if pid is not None:
                self.category_by_product_id[pid] = str(row.get(category_col, ""))

    def _build_entity_groups(self):
        """Build entity -> (user_ids, product_ids) mappings from graph."""
        self.entity_users: dict[int, list[int]] = {}
        self.entity_products: dict[int, list[int]] = {}

        entity_type_name = self.config.get("entity", {}).get("type_name", "entity")

        own_type = ("user", "owns", entity_type_name)
        fits_type = (entity_type_name, "rev_fits", "product")

        if own_type in self.data.edge_types:
            own_ei = self.data[own_type].edge_index
            for u, e in zip(own_ei[0].cpu().numpy(), own_ei[1].cpu().numpy()):
                self.entity_users.setdefault(int(e), []).append(int(u))

        if fits_type in self.data.edge_types:
            fits_ei = self.data[fits_type].edge_index
            for e, p in zip(fits_ei[0].cpu().numpy(), fits_ei[1].cpu().numpy()):
                self.entity_products.setdefault(int(e), []).append(int(p))

        # M10: Precompute entity_id → group mapping (avoids O(entities*df_rows) scan)
        self.entity_to_group: dict[int, str] = {}
        group_col = self.config.get("entity", {}).get("group_column")
        if group_col and "entities" in self.nodes:
            entities_df = self.nodes["entities"]
            entity_to_id_map = self.id_mappings.get("entity_to_id", {})
            for _, row in entities_df.iterrows():
                eid = entity_to_id_map.get(row.get("entity_id"))
                if eid is not None:
                    self.entity_to_group[eid] = str(row.get(group_col, ""))

    def _build_purchase_exclusions(self, user_purchases: dict[str, set[str]]):
        """Build user_id -> set of purchased product_ids for exclusion.

        UIDs are treated as opaque canonical keys (already normalized by
        mode_score). PIDs are whitespace-stripped and then deduped via
        plugin.dedup_variant() (e.g., "140061B " -> "140061B" -> "140061").
        """
        from rec_engine import is_valid_scalar

        product_to_id = self.id_mappings["product_to_id"]
        self.user_excluded_products: dict[str, set[int]] = {}

        for raw_uid, product_ids in user_purchases.items():
            if not is_valid_scalar(raw_uid):
                continue
            uid = str(raw_uid)
            if not uid:
                continue

            # Guard against bare-string (would iterate characters) and
            # non-iterable values (None, int, float)
            if isinstance(product_ids, str):
                product_ids = {product_ids}
            elif not hasattr(product_ids, "__iter__"):
                continue

            pids: set[int] = set()
            for raw_pid in product_ids:
                if not is_valid_scalar(raw_pid):
                    continue
                deduped = self.plugin.dedup_variant(str(raw_pid).strip())
                if not deduped:
                    continue
                pid = product_to_id.get(deduped)
                if pid is not None:
                    pids.add(pid)

            if pids:
                self.user_excluded_products.setdefault(uid, set()).update(pids)

        if user_purchases:
            n_excluded = sum(len(pids) for pids in self.user_excluded_products.values())
            n_input_pids = sum(
                len(p) if isinstance(p, (set, list, tuple)) else 1
                for p in user_purchases.values()
            )
            n_unresolved = n_input_pids - n_excluded
            logger.info(
                "Purchase exclusion: %d users, %d total product exclusions (%d input PIDs unresolved)",
                len(self.user_excluded_products), n_excluded, n_unresolved,
            )

    def _build_excluded_set(self):
        """Build set of excluded product IDs."""
        excluded_mask = getattr(self.data["product"], "is_excluded", None)
        if excluded_mask is not None:
            self.excluded_product_ids: frozenset[int] = frozenset(
                excluded_mask.nonzero(as_tuple=True)[0].detach().cpu().tolist()
            )
        else:
            self.excluded_product_ids = frozenset()
        logger.info("Excluded products (output): %d", len(self.excluded_product_ids))

    def _build_popularity_index(self):
        """Build popularity-ranked product lists for fallback tiers."""
        products_df = self.nodes["products"]
        product_to_id = self.id_mappings["product_to_id"]
        pop_col = self.config.get("columns", {}).get("popularity", "popularity")

        self.product_popularity: dict[int, float] = {}
        for _, row in products_df.iterrows():
            pid = product_to_id.get(row.get("product_id"))
            if pid is not None:
                self.product_popularity[pid] = float(row.get(pop_col, 0.0))

        # Entity-level fitment by popularity
        self.entity_fitment_by_popularity: dict[int, list[int]] = {}
        for eid, pids in self.entity_products.items():
            fitment_only = [p for p in pids if p not in self.excluded_product_ids]
            self.entity_fitment_by_popularity[eid] = sorted(
                fitment_only, key=lambda p: -self.product_popularity.get(p, 0.0)
            )

        # Entity group fitment by popularity
        group_col = self.config.get("entity", {}).get("group_column")
        self.group_fitment_by_popularity: dict[str, list[int]] = {}
        if group_col and "entities" in self.nodes:
            entities_df = self.nodes["entities"]
            entity_to_id_map = self.id_mappings.get("entity_to_id", {})
            group_products: dict[str, set[int]] = {}
            for _, erow in entities_df.iterrows():
                group = str(erow.get(group_col, ""))
                eid = entity_to_id_map.get(erow.get("entity_id"))
                if eid is not None:
                    prods = self.entity_fitment_by_popularity.get(eid, [])
                    group_products.setdefault(group, set()).update(prods)
            for group, pids in group_products.items():
                self.group_fitment_by_popularity[group] = sorted(
                    pids, key=lambda p: -self.product_popularity.get(p, 0.0)
                )

        # Global fitment by popularity
        all_fitment: set[int] = set()
        for pids in self.entity_products.values():
            all_fitment.update(p for p in pids if p not in self.excluded_product_ids)
        if not all_fitment:
            # 2-node: all non-excluded products
            all_fitment = {
                p for p in range(self.data["product"].num_nodes)
                if p not in self.excluded_product_ids
            }
        self.global_fitment_by_popularity: list[int] = sorted(
            all_fitment, key=lambda p: -self.product_popularity.get(p, 0.0)
        )

    def _apply_fallback(
        self,
        entity_ids: list[int] | None,
        entity_groups: list[str] | None,
        existing_recs: list[tuple[int, float, bool]],
        excluded_products: set[int] | None,
        category_counts: dict[str, int],
    ) -> list[tuple[int, float, bool]]:
        """Apply tiered popularity fallback to fill up to min_recs."""
        slots_needed = self.min_recs - len(existing_recs)
        if slots_needed <= 0:
            return []

        already_selected = {pid for pid, _, _ in existing_recs}
        excluded = excluded_products or set()
        fallback_recs: list[tuple[int, float, bool]] = []

        tiers = self.strategy.get_fallback_tiers(
            self.plugin,
            {"topology": self.config.get("topology", "user-product")},
        )

        def _pick_from_pool(pool: list[int]) -> None:
            nonlocal slots_needed
            if slots_needed <= 0:
                return
            picks = select_popularity_fallback(
                pool, already_selected, excluded,
                self.category_by_product_id, category_counts,
                max_per_category=self.max_per_category, slots_needed=slots_needed,
                additional_excluded_ids=self.excluded_product_ids,
            )
            for pid in picks:
                fallback_recs.append((pid, self.score_sentinel, True))
                already_selected.add(pid)
            slots_needed -= len(picks)

        for tier in tiers:
            if slots_needed <= 0:
                break
            if tier == FallbackTier.ENTITY and entity_ids:
                for eid in entity_ids:
                    if slots_needed <= 0:
                        break
                    _pick_from_pool(self.entity_fitment_by_popularity.get(eid, []))
            elif tier == FallbackTier.ENTITY_GROUP and entity_groups:
                for group in entity_groups:
                    if slots_needed <= 0:
                        break
                    _pick_from_pool(self.group_fitment_by_popularity.get(group, []))
            elif tier == FallbackTier.GLOBAL:
                _pick_from_pool(self.global_fitment_by_popularity)

        return fallback_recs

    def _output_columns(self) -> list[str]:
        """Canonical output schema."""
        cols = ["user_id"]
        for i in range(1, self.total_slots + 1):
            cols.extend([
                f"rec{i}_product_id", f"rec{i}_name", f"rec{i}_url",
                f"rec{i}_image_url", f"rec{i}_price", f"rec{i}_score",
            ])
        cols.extend(["rec_count", "is_fallback", "fallback_start_idx", "model_version"])
        return cols

    @torch.no_grad()
    def score_all_users(
        self, target_user_ids: set[str] | None = None
    ) -> pd.DataFrame:
        """Score all target users using topology-appropriate strategy.

        Args:
            target_user_ids: Optional set of user IDs to score.
                If None, scores all users in the graph.
        """
        self.model.eval()
        self.model = self.model.to(self.device)
        self.data = self.data.to(self.device)

        user_embs, product_embs = self.model(self.data)
        user_embs = user_embs.cpu()
        product_embs = product_embs.cpu()

        user_to_id = self.id_mappings["user_to_id"]

        if target_user_ids is None:
            target_user_ids = set(user_to_id.keys())

        if self.strategy.is_entity_topology:
            return self._score_3node(user_embs, product_embs, target_user_ids)
        return self._score_2node(user_embs, product_embs, target_user_ids)

    def _score_2node(
        self,
        user_embs: torch.Tensor,
        product_embs: torch.Tensor,
        target_user_ids: set[str],
    ) -> pd.DataFrame:
        """Score for 2-node topology: all products are candidates.

        Uses batched matrix multiply for scalability.
        """
        user_to_id = self.id_mappings["user_to_id"]
        user_recs: dict[str, list[tuple[int, float, bool]]] = {}

        candidate_ids = [
            p for p in range(self.data["product"].num_nodes)
            if p not in self.excluded_product_ids
        ]
        candidate_t = torch.tensor(candidate_ids, dtype=torch.long)
        candidate_embs = product_embs[candidate_t]

        # Collect valid user mappings
        uid_pairs = [
            (uid_str, user_to_id[uid_str])
            for uid_str in target_user_ids
            if uid_str in user_to_id
        ]

        # Batched scoring
        batch_size = self.config.get("scoring", {}).get("batch_size", 512)
        for batch_start in range(0, len(uid_pairs), batch_size):
            batch = uid_pairs[batch_start:batch_start + batch_size]
            batch_int_ids = torch.tensor(
                [uid for _, uid in batch], dtype=torch.long
            )
            batch_embs = user_embs[batch_int_ids]
            # [batch_size, n_candidates]
            all_scores = torch.mm(batch_embs, candidate_embs.t())

            for i, (uid_str, _uid) in enumerate(batch):
                excluded = self.user_excluded_products.get(uid_str)
                recs = self._select_top_n(
                    candidate_ids, all_scores[i],
                    excluded_products=excluded, user_id=uid_str,
                )
                if recs:
                    user_recs[uid_str] = recs

        return self._finalize(user_recs, target_user_ids)

    def _score_3node(
        self,
        user_embs: torch.Tensor,
        product_embs: torch.Tensor,
        target_user_ids: set[str],
    ) -> pd.DataFrame:
        """Score for 3-node topology: entity-grouped batch inference + merge."""
        user_product_scores: dict[str, dict[int, float]] = {}
        user_entities: dict[str, list[tuple[int, str | None]]] = {}
        entity_target_users: set[str] = set()

        for eid, user_ids in self.entity_users.items():
            group = self.entity_to_group.get(eid)

            target_uids = [
                uid for uid in user_ids
                if self.id_to_user.get(uid) in target_user_ids
            ]
            if not target_uids:
                continue

            for uid in target_uids:
                uid_str = self.id_to_user[uid]
                entity_target_users.add(uid_str)
                user_entities.setdefault(uid_str, []).append((eid, group))

            fitment_ids = [
                p for p in self.entity_products.get(eid, [])
                if p not in self.excluded_product_ids
            ]
            if not fitment_ids:
                continue

            target_uids_t = torch.tensor(target_uids, dtype=torch.long)
            batch_user_embs = user_embs[target_uids_t]
            fitment_ids_t = torch.tensor(fitment_ids, dtype=torch.long)
            fitment_embs = product_embs[fitment_ids_t]
            fitment_scores = torch.mm(batch_user_embs, fitment_embs.t())

            for i, uid in enumerate(target_uids):
                uid_str = self.id_to_user[uid]
                scores_dict = user_product_scores.setdefault(uid_str, {})
                for j, pid in enumerate(fitment_ids):
                    score = fitment_scores[i][j].item()
                    if pid not in scores_dict or score > scores_dict[pid]:
                        scores_dict[pid] = score

        # Select top-N with diversity
        user_recs: dict[str, list[tuple[int, float, bool]]] = {}
        for uid_str, product_scores in user_product_scores.items():
            if not product_scores:
                continue
            sorted_items = sorted(product_scores.items(), key=lambda x: -x[1])
            merged_ids = [pid for pid, _ in sorted_items]
            merged_scores = torch.tensor([s for _, s in sorted_items])
            excluded = self.user_excluded_products.get(uid_str)
            recs = self._select_top_n(merged_ids, merged_scores, excluded_products=excluded, user_id=uid_str)
            if recs:
                user_recs[uid_str] = recs

        return self._finalize(user_recs, target_user_ids, user_entities=user_entities)

    def _select_top_n(
        self,
        product_ids: list[int],
        scores: torch.Tensor,
        excluded_products: set[int] | None = None,
        user_id: str | None = None,
    ) -> list[tuple[int, float, bool]]:
        """Select top-N products with category diversity."""
        scored = sorted(
            zip(product_ids, scores.numpy()),
            key=lambda x: -x[1],
        )
        # Apply plugin post-rank filter with enriched context
        filter_context = {"scorer": True, "user_id": user_id}
        scored = [
            (pid, s) for pid, s in scored
            if self.plugin.post_rank_filter(pid, {
                **filter_context,
                "product_str_id": self.id_to_product.get(pid, ""),
                "category": self.category_by_product_id.get(pid, ""),
            })
        ]
        ranked_products = [pid for pid, _ in scored]
        fitment_set = set(product_ids)

        selected = apply_slot_reservation_with_diversity(
            ranked_products=ranked_products,
            fitment_set=fitment_set,
            excluded_set=frozenset(),
            category_by_product=self.category_by_product_id,
            fitment_slots=self.total_slots,
            excluded_slots=0,
            total_slots=self.total_slots,
            max_per_category=self.max_per_category,
            excluded_products=excluded_products,
        )

        score_by_product: dict[int, float] = {}
        for pid, score in scored:
            if pid not in score_by_product:
                score_by_product[pid] = float(score)

        return [(pid, score_by_product.get(pid, float("-inf")), False) for pid in selected]

    def _finalize(
        self,
        user_recs: dict[str, list[tuple[int, float, bool]]],
        target_user_ids: set[str],
        *,
        user_entities: dict[str, list[tuple[int, str | None]]] | None = None,
    ) -> pd.DataFrame:
        """Apply fallback and build output DataFrame."""
        n_fallback = 0

        if self.fallback_enabled:
            for uid_str in target_user_ids:
                existing = user_recs.get(uid_str, [])
                if len(existing) >= self.min_recs:
                    continue

                entity_info = (user_entities or {}).get(uid_str, [])
                eids = sorted({e[0] for e in entity_info}) if entity_info else None
                groups_set = {e[1] for e in entity_info if e[1]} if entity_info else None
                groups = sorted(groups_set) if groups_set else None
                excluded = self.user_excluded_products.get(uid_str)

                category_counts: dict[str, int] = {}
                for pid, _, _ in existing:
                    cat = self.category_by_product_id.get(pid, "")
                    category_counts[cat] = category_counts.get(cat, 0) + 1

                fallback_recs = self._apply_fallback(
                    eids, groups, existing, excluded, category_counts,
                )
                if fallback_recs:
                    user_recs[uid_str] = existing + fallback_recs
                    n_fallback += 1

        if n_fallback > 0:
            logger.info("Fallback applied to %d users", n_fallback)

        # Build output
        rows = []
        for uid_str, recs in user_recs.items():
            rows.append(self._format_row(uid_str, recs))

        df = pd.DataFrame(rows, columns=self._output_columns())
        logger.info("Scored %d users", len(df))

        self._qa_checks(df, target_count=len(target_user_ids))
        return df

    def _format_row(self, user_id: str, recs: list[tuple[int, float, bool]]) -> dict:
        """Format a single user's recommendations as a wide-format row."""
        row: dict[str, Any] = {"user_id": user_id}
        has_fallback = False
        fallback_start_idx = len(recs)

        for i, (pid, score, from_fallback) in enumerate(recs, 1):
            pid_str = self.id_to_product.get(pid, "")
            meta = self.product_meta.get(pid_str, {})
            row[f"rec{i}_product_id"] = meta.get("product_id", pid_str)
            row[f"rec{i}_name"] = meta.get("name", "")
            row[f"rec{i}_url"] = meta.get("url", "")
            row[f"rec{i}_image_url"] = meta.get("image_url", "")
            row[f"rec{i}_price"] = meta.get("price", 0)
            row[f"rec{i}_score"] = score
            if from_fallback and not has_fallback:
                fallback_start_idx = i - 1
                has_fallback = True

        for i in range(len(recs) + 1, self.total_slots + 1):
            row[f"rec{i}_product_id"] = None
            row[f"rec{i}_name"] = None
            row[f"rec{i}_url"] = None
            row[f"rec{i}_image_url"] = None
            row[f"rec{i}_price"] = None
            row[f"rec{i}_score"] = None

        row["rec_count"] = len(recs)
        row["is_fallback"] = has_fallback
        row["fallback_start_idx"] = fallback_start_idx
        row["model_version"] = self.config.get("output", {}).get("model_version", "1.0")
        return row

    def _qa_checks(self, df: pd.DataFrame, target_count: int | None = None) -> None:
        """Run QA checks. Raises QAFailedError on critical failures."""
        failures: list[str] = []

        required_cols = self._output_columns()
        missing_cols = [c for c in required_cols if c not in df.columns]
        if missing_cols:
            raise QAFailedError("Missing required output columns: " + ", ".join(missing_cols))

        if self.min_users > 0 and len(df) < self.min_users:
            failures.append(f"Only {len(df)} users (expected >= {self.min_users})")

        if target_count is not None and target_count > 0:
            coverage = len(df) / target_count
            if coverage < self.min_coverage:
                failures.append(
                    f"Low target coverage: {len(df)}/{target_count} "
                    f"({coverage:.1%}, expected >= {self.min_coverage:.0%})"
                )

        n_dupes = df["user_id"].duplicated().sum()
        if n_dupes > 0:
            failures.append(f"{n_dupes} duplicate users")

        null_slot1 = df["rec1_product_id"].isna().sum()
        if null_slot1 > 0:
            failures.append(f"{null_slot1} users missing rec1")

        min_price = self.config.get("graph", {}).get("min_price", 0)
        if min_price > 0:
            for i in range(1, self.total_slots + 1):
                col = f"rec{i}_price"
                if col in df.columns:
                    below = (df[col].dropna() < min_price).sum()
                    if below > 0:
                        failures.append(f"{below} recs in slot {i} below ${min_price}")

        # Score ordering check using provenance
        score_cols = [f"rec{i}_score" for i in range(1, self.total_slots + 1)]
        is_fb = df["is_fallback"].where(df["is_fallback"].notna(), False).astype(bool)

        non_fallback = df[~is_fb]
        if not non_fallback.empty:
            sm = non_fallback[score_cols].to_numpy(dtype=np.float64, copy=False)
            sm = np.where(np.isnan(sm), -np.inf, sm)
            if np.any(sm[:, :-1] < sm[:, 1:]):
                failures.append("Score ordering violated (non-fallback rows)")

        fallback_rows = df[is_fb]
        if not fallback_rows.empty:
            sm = fallback_rows[score_cols].to_numpy(dtype=np.float64, copy=False)
            fb_idx = fallback_rows["fallback_start_idx"].to_numpy(dtype=int)
            for i, row_scores in enumerate(sm):
                prefix_len = fb_idx[i]
                for j in range(prefix_len - 1):
                    if not np.isnan(row_scores[j]) and not np.isnan(row_scores[j + 1]):
                        if row_scores[j] < row_scores[j + 1]:
                            failures.append("Score ordering violated (GNN prefix in fallback rows)")
                            break
                else:
                    continue
                break

        if failures:
            for f in failures:
                logger.warning("QA FAIL: %s", f)
            raise QAFailedError(
                f"QA checks failed ({len(failures)} issues): {'; '.join(failures)}"
            )

        logger.info("QA checks PASSED")
