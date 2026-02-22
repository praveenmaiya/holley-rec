"""GNN production scorer: generate shadow recommendations table."""

from __future__ import annotations

import logging
import re
from typing import TYPE_CHECKING, Any

import numpy as np
import pandas as pd
import torch

from src.bq_client import BQClient
from src.gnn.model import HolleyGAT
from src.gnn.rules import apply_slot_reservation_with_diversity, select_popularity_fallback

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
        self.min_coverage = float(qa_cfg.get("min_coverage", 0.95))

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

        # Build universal product ID set (for exclusion from candidates/output)
        self._build_universal_set()

        # Build popularity index for fallback tiers
        self._build_popularity_index()

        # Fallback config
        fallback_cfg = config.get("fallback", {})
        self.fallback_enabled = fallback_cfg.get("enabled", True)
        self.min_recs = fallback_cfg.get("min_recs", 3)
        self.score_sentinel = fallback_cfg.get("score_sentinel", 0.0)

        # Finding 6: validate min_recs against 4-slot output schema
        if not 0 <= self.min_recs <= 4:
            raise ValueError(
                f"fallback.min_recs must be 0-4 (output schema has 4 slots), got {self.min_recs}"
            )

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

    _VARIANT_SUFFIX_RE = re.compile(r"([0-9])[BRGP]$")

    def _build_purchase_exclusions(self, user_purchases: dict[str, set[str]]):
        """Build email -> set of purchased product_ids for exclusion.

        Normalises inputs defensively:
        - Emails are lowercased and trimmed.
        - SKUs have variant suffixes stripped (e.g. 140061B -> 140061).

        Args:
            user_purchases: email -> set of SKU strings (365-day lookback).
        """
        product_to_id = self.id_mappings["product_to_id"]
        self.user_excluded_products: dict[str, set[int]] = {}
        for raw_email, skus in user_purchases.items():
            if pd.isna(raw_email):
                continue
            email = str(raw_email).strip().lower()
            if not email:
                continue

            product_ids: set[int] = set()
            for raw_sku in skus:
                if pd.isna(raw_sku):
                    continue
                base_sku = self._VARIANT_SUFFIX_RE.sub(r"\1", str(raw_sku).strip())
                if not base_sku:
                    continue
                pid = product_to_id.get(base_sku)
                if pid is not None:
                    product_ids.add(pid)

            if product_ids:
                self.user_excluded_products.setdefault(email, set()).update(product_ids)

        if user_purchases:
            n_excluded = sum(len(pids) for pids in self.user_excluded_products.values())
            logger.info(
                f"Purchase exclusion: {len(self.user_excluded_products)} users, "
                f"{n_excluded} total product exclusions"
            )

    def _build_universal_set(self):
        """Build set of universal product IDs (for exclusion from candidates/output)."""
        product_to_id = self.id_mappings["product_to_id"]
        self.universal_product_ids: frozenset[int] = frozenset(
            product_to_id[sku]
            for sku, meta in self.product_meta.items()
            if meta.get("is_universal", False) and sku in product_to_id
        )
        logger.info(f"Universal products (excluded from output): {len(self.universal_product_ids)}")

    def _build_popularity_index(self):
        """Build popularity-ranked product lists for fallback tiers.

        Tiers mirror v5.18: vehicle → make → global.
        All indices contain fitment-only products (no universals).
        """
        products_df = self.nodes["products"]
        product_to_id = self.id_mappings["product_to_id"]

        # Build product_id -> log_popularity mapping
        self.product_popularity: dict[int, float] = {}
        for _, row in products_df.iterrows():
            pid = product_to_id.get(row.get("base_sku"))
            if pid is not None:
                self.product_popularity[pid] = float(row.get("log_popularity", 0.0))

        # Vehicle fitment by popularity (fitment-only, no universals)
        self.vehicle_fitment_by_popularity: dict[int, list[int]] = {}
        for vid, pids in self.vehicle_products.items():
            fitment_only = [p for p in pids if p not in self.universal_product_ids]
            self.vehicle_fitment_by_popularity[vid] = sorted(
                fitment_only, key=lambda p: -self.product_popularity.get(p, 0.0)
            )

        # Make fitment by popularity: make -> union of all vehicle fitment products for that make
        vehicles_df = self.nodes.get("vehicles")
        vehicle_to_id = self.id_mappings.get("vehicle_to_id", {})
        self.make_fitment_by_popularity: dict[str, list[int]] = {}
        if vehicles_df is not None:
            make_products: dict[str, set[int]] = {}
            for _, vrow in vehicles_df.iterrows():
                make = vrow.get("make", "")
                vkey = f"{vrow.get('make', '')}|{vrow.get('model', '')}"
                vid = vehicle_to_id.get(vkey)
                if vid is not None:
                    prods = self.vehicle_fitment_by_popularity.get(vid, [])
                    make_products.setdefault(make, set()).update(prods)
            for make, pids in make_products.items():
                self.make_fitment_by_popularity[make] = sorted(
                    pids, key=lambda p: -self.product_popularity.get(p, 0.0)
                )

        # Global fitment by popularity
        all_fitment = set()
        for pids in self.vehicle_products.values():
            all_fitment.update(p for p in pids if p not in self.universal_product_ids)
        self.global_fitment_by_popularity: list[int] = sorted(
            all_fitment, key=lambda p: -self.product_popularity.get(p, 0.0)
        )

        logger.info(
            f"Popularity index: {len(self.vehicle_fitment_by_popularity)} vehicles, "
            f"{len(self.make_fitment_by_popularity)} makes, "
            f"{len(self.global_fitment_by_popularity)} global fitment products"
        )

    def _apply_fallback(
        self,
        vehicle_ids: list[int] | None,
        makes: list[str] | None,
        existing_recs: list[tuple[int, float, bool]],
        excluded_products: set[int] | None,
        part_type_counts: dict[str, int],
    ) -> list[tuple[int, float, bool]]:
        """Apply 3-tier popularity fallback to fill up to min_recs.

        Tiers (mirrors v5.18 segment→make→global):
        1. Popularity-ranked fitment for user's specific vehicle(s)
        2. Popularity-ranked fitment for user's vehicle make(s)
        3. Global popular fitment products

        Finding 1: accepts multiple vehicles/makes for multi-vehicle users.
        Finding 2: returns (product_id, score_sentinel, True) with explicit provenance.
        """
        slots_needed = self.min_recs - len(existing_recs)
        if slots_needed <= 0:
            return []

        already_selected = {pid for pid, _, _ in existing_recs}
        excluded = excluded_products or set()
        fallback_recs: list[tuple[int, float, bool]] = []

        def _pick_from_pool(pool: list[int]) -> None:
            nonlocal slots_needed
            if slots_needed <= 0:
                return
            picks = select_popularity_fallback(
                pool, already_selected, excluded,
                self.part_type_by_product_id, part_type_counts,
                max_per_part_type=2, slots_needed=slots_needed,
                universal_product_ids=self.universal_product_ids,
            )
            for pid in picks:
                fallback_recs.append((pid, self.score_sentinel, True))
                already_selected.add(pid)
            slots_needed -= len(picks)

        # Tier 1: vehicle fitment by popularity (try each vehicle)
        if vehicle_ids:
            for vid in vehicle_ids:
                if slots_needed <= 0:
                    break
                _pick_from_pool(self.vehicle_fitment_by_popularity.get(vid, []))

        # Tier 2: make fitment by popularity (try each make)
        if makes:
            for make in makes:
                if slots_needed <= 0:
                    break
                _pick_from_pool(self.make_fitment_by_popularity.get(make, []))

        # Tier 3: global fitment by popularity
        if slots_needed > 0:
            _pick_from_pool(self.global_fitment_by_popularity)

        return fallback_recs

    @staticmethod
    def _output_columns() -> list[str]:
        """Canonical output schema for scorer output and QA validation."""
        cols = ["email_lower"]
        for i in range(1, 5):
            cols.extend([
                f"rec{i}_sku", f"rec{i}_name", f"rec{i}_url",
                f"rec{i}_image_url", f"rec{i}_price", f"rec{i}_score",
            ])
        cols.extend(["fitment_count", "is_fallback", "fallback_start_idx", "model_version"])
        return cols

    @torch.no_grad()
    def score_all_users(self) -> pd.DataFrame:
        """Score all target users using vehicle-grouped strategy + popularity fallback.

        v5.18 alignment: no universal products in output. All 4 slots are fitment.
        Users with sparse/no fitment get popularity-ranked fallback (vehicle→make→global).

        Finding 1: Multi-vehicle users get merged scores (max per product across
        all owned vehicles), then diversity selection runs once per user.

        Returns wide-format DataFrame matching final_vehicle_recommendations schema.
        """
        self.model.eval()
        self.model = self.model.to(self.device)
        self.data = self.data.to(self.device)

        user_embs, product_embs = self.model(self.data)
        user_embs = user_embs.cpu()
        product_embs = product_embs.cpu()

        # Only score target users (with email consent)
        users_df = self.nodes["users"]
        target_emails = set(users_df[users_df["has_email_consent"]]["email_lower"])

        # First pass: collect per-user product scores across ALL vehicles.
        # Finding 1: merge across vehicles (max per product) instead of overwriting.
        user_product_scores: dict[str, dict[int, float]] = {}
        email_vehicles: dict[str, list[tuple[int, str | None]]] = {}
        n_vehicles = len(self.vehicle_users)
        vehicle_target_emails: set[str] = set()

        for vid_idx, (vid, user_ids) in enumerate(self.vehicle_users.items()):
            if vid_idx % 200 == 0:
                logger.info(f"Scoring vehicle {vid_idx}/{n_vehicles}...")

            vkey = self.id_to_vehicle.get(vid, "")
            make = vkey.split("|")[0] if "|" in vkey else None

            target_uids = [uid for uid in user_ids
                           if self.id_to_user.get(uid) in target_emails]
            if not target_uids:
                continue

            for uid in target_uids:
                email = self.id_to_user[uid]
                vehicle_target_emails.add(email)
                email_vehicles.setdefault(email, []).append((vid, make))

            # Fitment-only candidates (exclude universals)
            raw_fitment = self.vehicle_products.get(vid, [])
            fitment_ids = [p for p in raw_fitment if p not in self.universal_product_ids]
            if not fitment_ids:
                continue

            target_uids_t = torch.tensor(target_uids, dtype=torch.long)
            batch_user_embs = user_embs[target_uids_t]
            fitment_ids_t = torch.tensor(fitment_ids, dtype=torch.long)
            fitment_embs = product_embs[fitment_ids_t]
            fitment_scores = torch.mm(batch_user_embs, fitment_embs.t())

            for i, uid in enumerate(target_uids):
                email = self.id_to_user[uid]
                scores_dict = user_product_scores.setdefault(email, {})
                for j, pid in enumerate(fitment_ids):
                    score = fitment_scores[i][j].item()
                    if pid not in scores_dict or score > scores_dict[pid]:
                        scores_dict[pid] = score

        # Select top4 for each user with merged scores
        user_recs: dict[str, list[tuple[int, float, bool]]] = {}
        for email, product_scores in user_product_scores.items():
            if not product_scores:
                continue
            sorted_items = sorted(product_scores.items(), key=lambda x: -x[1])
            merged_ids = [pid for pid, _ in sorted_items]
            merged_scores = torch.tensor([s for _, s in sorted_items])
            excluded = self.user_excluded_products.get(email)
            recs = self._select_top4(merged_ids, merged_scores, excluded_products=excluded)
            if recs:
                user_recs[email] = recs

        # Second pass (C4): iterate ALL target users — apply fallback for missing/sparse
        n_fallback = 0
        if self.fallback_enabled:
            for email in target_emails:
                existing = user_recs.get(email, [])
                if len(existing) >= self.min_recs:
                    continue

                # Finding 1: use all vehicles/makes for multi-vehicle fallback
                vids_and_makes = email_vehicles.get(email, [])
                # R3 #3: sort vids for deterministic tier-1 fallback ordering
                vids = sorted({vm[0] for vm in vids_and_makes}) or None
                # R2 LOW fix: sorted for deterministic make-tier fallback ordering
                makes_set = {vm[1] for vm in vids_and_makes if vm[1]}
                makes = sorted(makes_set) if makes_set else None
                excluded = self.user_excluded_products.get(email)

                # Carry over part_type_counts from existing recs
                part_type_counts: dict[str, int] = {}
                for pid, _, _ in existing:
                    pt = self.part_type_by_product_id.get(pid, "")
                    part_type_counts[pt] = part_type_counts.get(pt, 0) + 1

                fallback_recs = self._apply_fallback(
                    vids, makes, existing, excluded, part_type_counts,
                )
                if fallback_recs:
                    user_recs[email] = existing + fallback_recs
                    n_fallback += 1

        if n_fallback > 0:
            logger.info(f"Fallback applied to {n_fallback} users")

        # Build output DataFrame
        rows = []
        for email, recs in user_recs.items():
            rows.append(self._format_row(email, recs))

        df = pd.DataFrame(rows, columns=self._output_columns())

        # Diagnostics
        scored_emails = set(user_recs.keys())
        missing_emails = target_emails - scored_emails
        n_no_vehicle = len((target_emails - vehicle_target_emails) & missing_emails)

        if n_no_vehicle > 0:
            logger.warning(
                f"No vehicle match: {n_no_vehicle} consented users had no vehicle "
                f"in graph ({n_no_vehicle}/{len(target_emails)} = "
                f"{n_no_vehicle / len(target_emails) * 100:.1f}%)"
            )
        if missing_emails:
            logger.warning(
                f"Missing from output: {len(missing_emails)} target users "
                f"({len(missing_emails)}/{len(target_emails)} = "
                f"{len(missing_emails) / len(target_emails) * 100:.1f}%)"
            )
        logger.info(f"Scored {len(df)} users across {n_vehicles} vehicles")

        # Finding 4: pass target count for coverage QA check
        self._qa_checks(df, target_count=len(target_emails))
        return df

    def _select_top4(
        self,
        fitment_ids: list[int],
        fitment_scores: torch.Tensor,
        excluded_products: set[int] | None = None,
    ) -> list[tuple[int, float, bool]]:
        """Select top 4 fitment products with PartType diversity.

        v5.18 alignment: all 4 slots are fitment (no universals in output).
        Finding 2: returns (pid, score, is_fallback) 3-tuples with provenance.
        """
        fitment_scored = sorted(
            zip(fitment_ids, fitment_scores.numpy()),
            key=lambda x: -x[1],
        )

        ranked_products = [pid for pid, _ in fitment_scored]
        selected_products = apply_slot_reservation_with_diversity(
            ranked_products=ranked_products,
            fitment_set=set(fitment_ids),
            universal_set=frozenset(),
            part_type_by_product=self.part_type_by_product_id,
            fitment_slots=4,
            universal_slots=0,
            total_slots=4,
            max_per_part_type=2,
            excluded_products=excluded_products,
        )

        score_by_product: dict[int, float] = {}
        for pid, score in fitment_scored:
            if pid not in score_by_product:
                score_by_product[pid] = float(score)

        return [
            (pid, score_by_product.get(pid, float("-inf")), False)
            for pid in selected_products
        ]

    def _format_row(self, email: str, recs: list[tuple[int, float, bool]]) -> dict:
        """Format a single user's recommendations as a wide-format row.

        All recs are fitment (v5.18: no universals in output).
        Finding 2: is_fallback determined from explicit provenance flag,
        not from score equality (avoids false positives on GNN score == 0.0).
        """
        row = {"email_lower": email}
        has_fallback = False
        fallback_start_idx = len(recs)  # default: no fallback

        for i, (pid, score, from_fallback) in enumerate(recs, 1):
            sku = self.id_to_product.get(pid, "")
            meta = self.product_meta.get(sku, {})
            row[f"rec{i}_sku"] = meta.get("sku", sku)
            row[f"rec{i}_name"] = meta.get("name", "")
            row[f"rec{i}_url"] = meta.get("url", "")
            row[f"rec{i}_image_url"] = meta.get("image_url", "")
            row[f"rec{i}_price"] = meta.get("price", 0)
            row[f"rec{i}_score"] = score
            if from_fallback:
                if not has_fallback:
                    fallback_start_idx = i - 1  # 0-based index of first fallback slot
                has_fallback = True

        # Fill remaining slots with None
        for i in range(len(recs) + 1, 5):
            row[f"rec{i}_sku"] = None
            row[f"rec{i}_name"] = None
            row[f"rec{i}_url"] = None
            row[f"rec{i}_image_url"] = None
            row[f"rec{i}_price"] = None
            row[f"rec{i}_score"] = None

        row["fitment_count"] = len(recs)
        row["is_fallback"] = has_fallback
        # R3 #2: explicit boundary index so QA uses provenance, not score equality
        row["fallback_start_idx"] = fallback_start_idx
        row["model_version"] = self.config.get("output", {}).get(
            "model_version", "v6.0"
        )

        return row

    def _qa_checks(self, df: pd.DataFrame, target_count: int | None = None) -> None:
        """Run QA checks before writing to BQ. Raises QAFailedError on critical failures.

        Finding 3: Score ordering skips fallback rows (mixed GNN+fallback scores
        can have valid ordering violations at the boundary).
        Finding 4: Coverage check validates output vs target cohort size.
        """
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

        # Finding 4: coverage check against target cohort (R2: configurable threshold)
        if target_count is not None and target_count > 0:
            coverage = len(df) / target_count
            if coverage < self.min_coverage:
                failures.append(
                    f"Low target coverage: {len(df)}/{target_count} "
                    f"({coverage:.1%}, expected >= {self.min_coverage:.0%})"
                )

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

        # Finding 3 + R3 #2: Score ordering check using explicit provenance.
        # Non-fallback rows: full strict ordering.
        # Fallback rows: validate only GNN-scored prefix using fallback_start_idx
        # (avoids false negatives when GNN score == sentinel).
        score_cols = [f"rec{i}_score" for i in range(1, 5)]
        is_fb = df["is_fallback"].fillna(False).astype(bool)

        # Pure GNN rows: strict ordering
        non_fallback = df[~is_fb]
        if not non_fallback.empty:
            sm = non_fallback[score_cols].to_numpy(dtype=np.float64, copy=False)
            sm = np.where(np.isnan(sm), -np.inf, sm)
            if np.any(sm[:, :-1] < sm[:, 1:]):
                failures.append("Score ordering violated (non-fallback rows)")

        # Mixed rows: validate only the GNN-scored prefix using provenance index
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
