# GNN Option A: Clean Hypothesis Test — Design Spec

**Date**: 2026-02-16
**Status**: Draft
**Author**: Praveen Maiya
**Linear**: AUX-12314

---

## 1. Problem Statement

The v5.17 SQL pipeline serves 258K fitment+email users. 98% are cold (no browsing/purchase history) and get identical popularity-ranked recommendations per vehicle segment. The pipeline uses 8 hand-tuned weights and a 3-tier segment fallback (`segment → make → global`), which means every user with the same vehicle segment sees the same top-4 products ranked by popularity.

**The GNN hypothesis**: Can graph structure (User→Vehicle→Product message passing + Product co-purchase similarity) produce more relevant recommendations than SQL popularity for cold users?

This is a clean hypothesis test. If it fails, we skip to Option A+ (semantic enrichment with LLM-generated product embeddings). If it succeeds, we justify GNN infrastructure investment.

---

## 2. Corrected User Funnel

Prior GNN specs assumed ~475K users. Cross-campaign uplift analysis revealed the actual funnel:

| Stage | Users | Role in GNN |
|-------|------:|-------------|
| Total in system | 3,031,468 | — |
| Has fitment (YMM) | 504,092 | **All in graph** (provide density) |
| **Fitment + email consent** | **258,185** | **Recommendation target** |
| Fitment, no email consent | 245,907 | In graph, never recommended to |
| Actually received email (Dec–Feb) | 19,711 | Evaluation signal |

**Engagement tiers** (of 504K fitment users):
| Tier | Users | % | Definition |
|------|------:|--:|------------|
| Cold | ~494K | 98% | No interactions since Sep 1, 2025 |
| Warm | ~7.5K | 1.5% | Views only, no cart/purchase |
| Hot | ~2.5K | 0.5% | Cart or purchase activity |

Source: `docs/analysis/cross_campaign_uplift_analysis_2026_02_09.md`

---

## 3. Graph Structure

### Nodes (3 types)

| Type | Count | Source | Features |
|------|------:|--------|----------|
| User | ~504K | `ingestion_unified_attributes_schema_incremental` (v1_year + v1_make + v1_model required) | engagement_tier, email_lower |
| Product | ~25K | `import_items` (price >= $25, excl. refurbished/service/commodity) | part_type (categorical), price, log_popularity, fitment_breadth |
| Vehicle | ~2K | Unique (make, model) from users + fitment catalog | user_count, product_count |

### Edges (4 types, all bidirectional)

| Type | ~Count | Source | Weight |
|------|-------:|--------|--------|
| User → Product (interacts) | ~90K | Unified events (view/cart/purchase), Sep 1 2025 to T-30 | base x time_decay (view=1, cart=3, order=5, halflife=30d) |
| Product → Vehicle (fits) | ~500K | `vehicle_product_fitment_data` | Binary |
| User → Vehicle (owns) | ~504K | User v1_make/v1_model | Binary (1 per user) |
| Product → Product (co_purchased) | ~200K | `import_orders` self-join, threshold >= 2 | log(1 + count) |

**Total**: ~1.2M edges across 4 types (8 message-passing directions including reverse).

### Temporal Split

- **Training edges**: Sep 1, 2025 → T-30 days (interaction edges only; structural edges use full data)
- **Test set**: Last 30 days of ALL user interactions (browse + cart + purchase)
- **User split**: 80/10/10 train/val/test (random, stratified by engagement tier)

### Key Structural Property

For cold users (98%), the only path to product embeddings is:

```
User → (owns) → Vehicle → (rev_fits) → Products
```

This 2-hop path IS the GNN's entire value proposition. The GNN must learn useful patterns from this structure that SQL popularity doesn't already capture.

---

## 4. Model Architecture

HeteroGAT (Two-Tower):

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

### Training Configuration

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Loss | BPR (pairwise) | Standard for implicit feedback ranking |
| Negatives | 50% in-batch, 30% fitment-hard, 20% random | Balance efficiency with hard negative mining |
| Optimizer | Dual Adam (emb lr=0.001, GNN lr=0.01) | Learned embeddings need slower updates |
| Gradient clipping | max_norm=1.0 | Prevent exploding gradients with sparse data |
| Early stopping | patience=10 epochs on val Hit Rate@4 | Prevent overfitting to sparse interactions |
| Max epochs | 100 | Upper bound with early stopping |
| Batch mode | Full-batch | Graph fits in memory at this scale |

### Why 7 Directions (not 8)

The 4 edge types create 8 potential message-passing directions, but User→User is not a defined edge type. The 7 directions are:
1. User → Product (interacts)
2. Product → User (rev_interacts)
3. Product → Vehicle (fits)
4. Vehicle → Product (rev_fits)
5. User → Vehicle (owns)
6. Vehicle → User (rev_owns)
7. Product → Product (co_purchased, symmetric)

---

## 5. Evaluation

### Test Set

Last 30 days of browse/cart/purchase interactions from unified events. NOT email clicks — only 19.7K users received emails, far too sparse for reliable evaluation.

### Metrics

| Metric | Purpose |
|--------|---------|
| **Hit Rate@4** (primary) | Did the user interact with any of the top-4 recommended products? Matches 4 email slots. |
| Recall@{10, 20} | Broader ranking quality beyond email slots |
| MRR | Position of first relevant product |
| NDCG@10 | Position-weighted ranking quality |

### Stratification

All metrics computed for: cold (~98%), warm (~1.5%), hot (~0.5%), overall.

Cold-user performance is the only metric that matters for go/no-go. Warm/hot improvements are nice-to-have but don't justify the system since they represent <2% of users.

### Baseline

SQL v5.17 recommendations reshaped to long format (email_lower, sku, rank). Same test set interactions used for both GNN and SQL evaluation.

### Go/No-Go Thresholds

Based on cold user Hit Rate@4 delta vs SQL baseline:

| Delta vs SQL | Decision |
|-------------|----------|
| >= +3% absolute | **GO** — proceed to online A/B test |
| +1% to +3% | **MAYBE** — try Option A+ (semantic enrichment) first |
| -1% to +1% | **SKIP** — go directly to Option A+ |
| < -1% | **INVESTIGATE** — possible overfitting or data issue |

---

## 6. Production Scoring

### Vehicle-Grouped Strategy

For 258K target users (fitment + email consent):

```
For each vehicle (~2K groups, ~129 users avg):
  user_embs = all users owning this vehicle        # shape: (N_users, 128)
  prod_embs = all products fitting this vehicle     # shape: (N_prods, 128) ~300 avg
  scores = user_embs @ prod_embs.T                  # shape: (N_users, N_prods)
  -> apply business rules per user -> output 4 recs
```

**Complexity**: ~2K vehicles x ~129 users x ~300 products = ~77M dot products. ~10-15 min on CPU.

Compare to naive approach: 258K x 25K = 6.5B dot products.

### Business Rules (Post-GNN, Hard Constraints)

Applied after GNN scoring, not learned by the model:

| Rule | Implementation |
|------|---------------|
| Fitment slot reservation | 2 fitment + 2 universal, backfill when insufficient |
| Purchase exclusion | 365-day lookback against `import_orders` |
| Excluded SKUs | Refurbished (tags), service, commodity categories |
| Variant dedup | Regex `[0-9][BRGP]$` strips color suffixes |
| PartType diversity | Max 2 products per PartType |
| Price floor | >= $25 |
| HTTPS images | Required for email rendering |

### Output Format

Wide-format table matching `final_vehicle_recommendations` schema:
- `email_lower`, `rec1_sku`, `rec1_name`, `rec1_url`, `rec1_image_url`, `rec1_price`, `rec1_score`, ... (x4 slots)
- Additional columns: `fitment_count` (how many of 4 recs are fitment products)

### QA Checks (Must Pass Before BQ Write)

| Check | Threshold |
|-------|-----------|
| User count | >= 250K (target: 258K) |
| Duplicate users | 0 |
| Slot 1 always filled | 100% |
| Prices | >= $25 |
| Images | HTTPS protocol |
| Score ordering | rec1_score >= rec2_score >= rec3_score >= rec4_score |

---

## 7. Honest Assessment

### Likely Outcome

**The GNN will NOT beat SQL baseline for cold users on Hit Rate@4.** Here's why:

1. **98% cold users have zero interaction edges** — the only signal path is User→Vehicle→Product (2 hops)
2. **For the same vehicle, GNN and SQL see the same fitment catalog** — the product set is identical
3. **SQL popularity already captures "most popular for this vehicle segment"** — which is the strongest signal available without interactions
4. **GNN's theoretical advantage is cross-vehicle pattern transfer** — learning that "Mustang buyers who liked X also liked Y, and Camaros share that pattern." But this requires enough warm/hot users per vehicle to learn meaningful collaborative patterns
5. **~10K warm/hot users across ~2K vehicles = ~5 per vehicle** — insufficient signal density for reliable pattern learning

### Why Run It Anyway

- **Proves/disproves the graph hypothesis with real data** — no more speculation
- **If null result** → skip to Option A+ (semantic enrichment) with confidence and evidence
- **If positive** → justifies GNN infrastructure investment for Holley and other customers
- **Either way, we learn something** — negative results are valuable when they're rigorous
- **Builds infrastructure** — data export, evaluation harness, scoring pipeline are reusable for A+

### What Could Surprise Us

- Co-purchase edges might capture cross-vehicle patterns that SQL segment scoring misses
- Product feature MLP (price + part_type + fitment_breadth) might learn non-obvious feature combinations
- Vehicle embeddings might cluster semantically similar vehicles (muscle cars, trucks, imports) enabling transfer

---

## 8. Dependencies and Open Questions

| Question | Owner | Status |
|----------|-------|--------|
| GPU availability on gke-metaflow-dev (T4) | Sumeet | Open |
| `auxia.prediction.colab` package documentation | Sumeet | Open |
| Feature Store integration vs standalone BQ exports | Sumeet | Open |
| A/B test infrastructure for online evaluation | Sumeet | Open |

---

## 9. References

| Document | Content |
|----------|---------|
| `docs/gnn/gnn_approach_comparison.md` | Option A/A+/B comparison and rationale |
| `docs/gnn/gnn_recommendation_system_proposal.md` | Original multi-phase GNN+LLM proposal |
| `docs/analysis/fitment_mismatch_investigation_2026_02_12.md` | 51% zero-fitment root cause |
| `docs/analysis/cross_campaign_uplift_analysis_2026_02_09.md` | Corrected user funnel (258K) |
| `specs/v5_18_revenue_ab_test.md` | V5.18 slot reservation design (reference for business rules) |
| `docs/architecture/pipeline_architecture.md` | Current SQL pipeline architecture |
