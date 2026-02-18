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

**Why A before A+**: The approach comparison doc (`docs/gnn/gnn_approach_comparison.md`) recommends A+ as the most promising option. We run A first because: (1) it isolates whether graph structure alone adds value — if topology is useless, semantic enrichment on a useless graph is wasted effort; (2) A is simpler to implement and debug; (3) A's infrastructure (data export, evaluation harness, scoring pipeline) is fully reusable for A+.

### Hard Prerequisites

Before GNN implementation begins:

1. **Deploy Phase 1 SQL fixes (Q1, Q2, S3)** — fitment slot reservation, PartType diversity cap, universal scoring discount. These affect 51% of users today and are independent of GNN. The GNN SQL baseline must be evaluated against the post-Phase-1 pipeline, not the current broken v5.17.
2. **Confirm GPU access** — T4 on gke-metaflow-dev (open question with Sumeet).
3. **Resolve or mitigate I1/I3** — ESP rate limiting (67% drops) and interaction tracking gap must be addressed before online A/B launch. Offline implementation can proceed without this.

GNN offline evaluation should compare against the Phase-1-fixed SQL baseline. Comparing against unfixed v5.17 would overstate GNN's improvement.

---

## 2. Corrected User Funnel

Prior GNN specs assumed ~475K users. Cross-campaign uplift analysis revealed the actual funnel.

### Population Glossary

| Label | Count | Definition |
|-------|------:|------------|
| **All-system** | 3,031,468 | All users in `ingestion_unified_attributes_schema_incremental` |
| **Fitment users** | 504,092 | Users with v1_year + v1_make + v1_model populated |
| **Target users** | 258,185 | Fitment users WITH email marketing consent — these receive recommendations |
| **Non-email fitment** | 245,907 | Fitment users WITHOUT email consent — in graph for density, never recommended to |
| **Zero-fitment recs** | ~258K | Users whose v5.17 output contains 0/4 vehicle-specific products (from fitment mismatch investigation) |
| **Email recipients** | 19,711 | Users who actually received email Dec-Feb 2026 |

Note: "Target users" (258,185) and "Zero-fitment recs" (~258K) are a coincidental near-match from different populations. The first is 258K of 504K fitment users with email consent. The second is 51.2% of ~504K fitment users whose recs lack fitment products. They overlap but are not identical.

### Funnel

| Stage | Users | Role in GNN |
|-------|------:|-------------|
| All-system | 3,031,468 | — |
| Fitment users | 504,092 | **All in graph** (provide density) |
| **Target users** | **258,185** | **Recommendation target** |
| Non-email fitment | 245,907 | In graph, never recommended to |
| Email recipients (Dec-Feb) | 19,711 | Email-click sanity evaluation |

### Engagement Tiers (of 504K fitment users)

| Tier | Users | % | Definition |
|------|------:|--:|------------|
| Cold | ~494K | 98% | No interactions in training window (Sep 1, 2025 to T-30) |
| Warm | ~7.5K | 1.5% | Views only in training window, no cart/purchase |
| Hot | ~2.5K | 0.5% | Cart or purchase activity in training window |

**Important**: "Cold" means no interactions in the *training window*, not globally. A user cold during training may have test-window interactions (and thus be evaluable offline). See Section 5.

Source: `docs/analysis/cross_campaign_uplift_analysis_2026_02_09.md`

---

## 3. Graph Structure

### Nodes (3 types)

| Type | Count | Source | Features |
|------|------:|--------|----------|
| User | ~504K | `ingestion_unified_attributes_schema_incremental` (v1_year + v1_make + v1_model required) | engagement_tier, email_lower |
| Product | ~25K | `import_items` (price >= $25, excl. refurbished/service/commodity). Note: current SQL pipeline uses $50 floor; GNN uses $25 per backlog Q3. **Evaluation must use matched candidate sets** — compare GNN@$25 vs SQL@$25 (re-run SQL baseline with $25 filter). | part_type (categorical), price, log_popularity, fitment_breadth |
| Vehicle | ~2K | Unique (make, model) from users + fitment catalog | user_count, product_count |

### Edges (4 types, all bidirectional)

| Type | ~Count | Source | Weight | Temporal constraint |
|------|-------:|--------|--------|---------------------|
| User -> Product (interacts) | ~90K | Unified events (view/cart/purchase) | base x time_decay (view=1, cart=3, order=5, halflife=30d) | Sep 1, 2025 to T-30 |
| Product -> Vehicle (fits) | ~500K | `vehicle_product_fitment_data` | Binary | Full catalog (atemporal) |
| User -> Vehicle (owns) | ~504K | User v1_make/v1_model | Binary (1 per user) | Full data (atemporal) |
| Product -> Product (co_purchased) | ~200K | `import_orders` self-join, threshold >= 2 | log(1 + count) | **Sep 1, 2025 to T-30** |

**Total**: ~1.3M edges across 4 types, 7 message-passing directions.

### Co-purchase Edge Quality

The co-purchase threshold (>= 2 co-purchases) filters noise but may still include spurious pairs. Consider during implementation:
- **PMI filtering**: Pointwise mutual information to remove pairs that co-occur only because both products are popular
- **Top-K cap**: Limit each product to its top-K (e.g., 50) strongest co-purchase neighbors to prevent hub dominance

### Temporal Split

- **Training edges**: Sep 1, 2025 -> T-30 days — applies to **all temporal edges** (interaction AND co-purchase)
- **Structural edges**: Fitment (product->vehicle) and ownership (user->vehicle) use full data — these are atemporal catalog/profile facts, not behavioral signals
- **Test set**: Last 30 days of user interactions (browse + cart + purchase)
- **User split**: Split all users 80/10/10 train/val/test (stratified by training-window engagement tier). Training uses only train-split users' interaction edges. Val/test users' training-window interactions are **excluded from training edges** to prevent leakage. Evaluation is computed only on val/test users with >= 1 test-window interaction.

**Leakage prevention**: Co-purchase edges are time-sliced to the same pre-T-30 window as interaction edges. A co-purchase edge built from a test-window purchase would leak future signal into training.

### Key Structural Property

For training-cold users, the only path to product embeddings is:

```
User -> (owns) -> Vehicle -> (rev_fits) -> Products
```

This 2-hop path IS the GNN's entire value proposition. The GNN must learn useful patterns from this structure that SQL popularity doesn't already capture.

### Edges Not Included (and Why)

| Candidate Edge | Reason for Exclusion |
|----------------|----------------------|
| Vehicle -> Vehicle (shared fitment) | Likely redundant — the 2-hop path User->Vehicle->Product already propagates cross-vehicle signal through shared products |
| Product -> PartType (taxonomy) | Part_type is already a product node feature; adding as edge type adds complexity without clear marginal value for a hypothesis test |
| User -> User (same vehicle) | Too dense (~250 users/vehicle avg), and signal is already captured by shared Vehicle node |

These can be revisited for Option A+ if the base graph shows promise.

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

### Why 7 Directions

The 4 edge types produce 8 directed variants (4 forward + 4 reverse), but Product<->Product co-purchase is symmetric (same GATConv weights in both directions), yielding 7 distinct learned convolutions:

1. User -> Product (interacts)
2. Product -> User (rev_interacts)
3. Product -> Vehicle (fits)
4. Vehicle -> Product (rev_fits)
5. User -> Vehicle (owns)
6. Vehicle -> User (rev_owns)
7. Product <-> Product (co_purchased, symmetric — single GATConv)

### Overfitting Risk and Mitigation

The model has ~68M learnable embedding parameters (504K x 128 user + 25K x 128 product + 2K x 128 vehicle) but only ~90K interaction edges as supervision. This is a **high overfitting risk**.

Mitigations:
1. **L2 regularization** on embeddings (weight_decay=0.01) — critical
2. **Dropout** (0.1 on GNN layers, 0.2 on projection heads)
3. **Early stopping** on validation Hit Rate@4 (patience=10)
4. **Monitor train/val gap** — if train HR@4 >> val HR@4, reduce embedding dimension

**Ablation to consider**: If overfitting is severe, reduce user embedding from 128 to 64 or 32 dimensions. Product and vehicle embeddings can stay at 128 since they have richer feature inputs.

### Memory Estimate

| Component | Size |
|-----------|------|
| User embeddings (504K x 128 x float32) | 256 MB |
| + Adam optimizer states (2x) | 512 MB |
| Product + Vehicle embeddings + optim | ~20 MB |
| GNN parameters + optim | ~5 MB |
| Hidden activations (2 layers, ~531K total nodes x 256) | ~1 GB |
| Edge index storage (~1.3M x 2 x int64) | ~20 MB |
| **Total estimate** | **~2 GB** |

Fits comfortably on T4 (16 GB). Full-batch is viable. If memory becomes an issue (e.g., larger graph in future), fall back to **NeighborLoader mini-batch** sampling (sample 2-hop neighborhoods per batch of 1024 users).

### Training Configuration

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Loss | BPR (pairwise) | Standard for implicit feedback ranking |
| Negatives | 50% in-batch, 30% within-fitment hard, 20% random | See note below |
| Optimizer | Dual Adam (emb lr=0.001, GNN lr=0.01) | Embeddings have more params, need slower updates to avoid instability |
| Weight decay | 0.01 (embeddings only) | Regularize against overfitting |
| Gradient clipping | max_norm=1.0 | Prevent exploding gradients with sparse data |
| Early stopping | patience=10 epochs on val Hit Rate@4 | Prevent overfitting to sparse interactions |
| Max epochs | 100 | Upper bound with early stopping |
| Batch mode | Full-batch (mini-batch fallback if needed) | Graph fits in ~2 GB |

**Negative sampling clarification**: "Fitment-hard" negatives are sampled from products that **fit the user's vehicle but were not interacted with**. This teaches within-fitment ranking (which product is better for this vehicle?), not fitment-vs-non-fitment separation. The 20% random negatives provide general contrast.

**LR ablation**: The emb=0.001 / GNN=0.01 split follows Faire's dual-optimizer pattern. If convergence is poor, try: (a) equal LR=0.005 for both, (b) inverted LR (emb=0.01, GNN=0.001). Log all ablations in W&B.

---

## 5. Evaluation

### Cold-User Evaluation Paradox

"Cold" = no interactions in the training window (Sep 1, 2025 to T-30). But evaluation requires test-window interactions. This creates three user groups:

| Group | Definition | Evaluable? |
|-------|-----------|------------|
| Training-cold, test-active | No training interactions, but browse/cart/purchase in last 30 days | **Yes** — these are the target evaluation cohort |
| Training-cold, test-inactive | No interactions in either window | No — no ground truth |
| Training-warm/hot | Interactions in training window | Yes — but not the primary cohort |

The **primary evaluation cohort** is training-cold users who became active in the test window. This is the exact population where the GNN hypothesis matters: can graph structure predict which products a previously-inactive user will engage with?

**Expected cohort sizes** (rough estimate): Of ~494K training-cold users, perhaps 1-3% interact in the test window = ~5K-15K evaluable cold users. If this is too small for reliable metrics, we expand the test window.

### Test Set

Last 30 days of browse/cart/purchase interactions from unified events. Evaluation is restricted to users with **at least 1 positive interaction** in the test window.

**Email-click sanity check**: Additionally compute Hit Rate@4 on the 19.7K email recipients using actual email clicks as positives. This provides a secondary signal on real recommendation quality, though the sample is smaller and noisier.

### Metrics

| Metric | Purpose |
|--------|---------|
| **Hit Rate@4** (primary) | Did the user interact with any of the top-4 recommended products? Matches 4 email slots. |
| Recall@{10, 20} | Broader ranking quality beyond email slots |
| MRR | Position of first relevant product |
| NDCG@10 | Position-weighted ranking quality |

All metrics reported with **95% confidence intervals** (bootstrap, 1000 samples).

**Expected SQL baseline**: Hit Rate@4 is likely in the 1-5% range (with ~300 eligible products per vehicle, random chance is ~1.3%). The SQL baseline should beat random by ranking popular products first.

### Stratification

All metrics computed for: training-cold (primary), training-warm, training-hot, overall.

Training-cold performance is the only metric that matters for go/no-go. Warm/hot improvements are nice-to-have but don't justify the system since they represent <2% of users.

### Metric Reporting: Pre-Rules and Post-Rules

Report all metrics **twice**:
1. **Pre-rules**: Raw GNN ranking vs raw SQL ranking (no business rules applied)
2. **Post-rules**: After fitment slot reservation, purchase exclusion, diversity cap, etc.

This separates model quality from business constraint impact. If pre-rules GNN >> SQL but post-rules are equal, the business rules are masking model improvements.

### Baseline

Phase-1-fixed SQL baseline recommendations reshaped to long format (email_lower, sku, rank). Same test set interactions and evaluation cohort used for both GNN and SQL. **Important**: SQL baseline must be re-run with $25 price floor to match GNN candidate set (current production uses $50).

### Go/No-Go Thresholds

Based on training-cold user Hit Rate@4 delta vs SQL baseline (pre-rules):

| Delta vs SQL | Decision |
|-------------|----------|
| >= +3% absolute | **GO** — proceed to online A/B test |
| +1% to +3% | **MAYBE** — try Option A+ (semantic enrichment) first |
| -1% to +1% | **SKIP** — go directly to Option A+ |
| < -1% | **INVESTIGATE** — possible overfitting or data issue |

Note: Given the honest assessment (Section 7) that the GNN likely won't beat SQL for cold users, the +3% GO threshold is intentionally ambitious. A null result in the -1% to +1% range is the expected outcome and leads to the pre-planned A+ path.

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

### Multi-Vehicle Users

The v1 data provides a single vehicle per user. For this phase, each user is assigned to exactly one vehicle group based on their v1_make + v1_model. Multi-vehicle handling (Q6 in the backlog) is deferred — it requires v2/v3 vehicle data that is currently sparse.

If a user's v1 vehicle doesn't match any vehicle node (typo, unsupported model), they fall back to Phase-1-fixed SQL baseline recommendations.

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

**Note on slot reservation**: With 2 fitment + 2 universal slots, only the 2 universal slots are purely GNN-ranked (fitment slots are GNN-ranked within fitment products). This limits the model's influence. Pre-rules vs post-rules metric comparison (Section 5) will quantify this effect.

### Output Format

Wide-format table matching `final_vehicle_recommendations` schema:
- `email_lower`, `rec1_sku`, `rec1_name`, `rec1_url`, `rec1_image_url`, `rec1_price`, `rec1_score`, ... (x4 slots)
- Additional columns: `fitment_count` (how many of 4 recs are fitment products), `model_version`

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

1. **98% cold users have zero interaction edges** — the only signal path is User->Vehicle->Product (2 hops)
2. **For the same vehicle, GNN and SQL see the same fitment catalog** — the product set is identical
3. **SQL popularity already captures "most popular for this vehicle segment"** — which is the strongest signal available without interactions
4. **GNN's theoretical advantage is cross-vehicle pattern transfer** — learning that "Mustang buyers who liked X also liked Y, and Camaros share that pattern." But this requires enough warm/hot users per vehicle to learn meaningful collaborative patterns
5. **~10K warm/hot users across ~2K vehicles = ~5 per vehicle** — insufficient signal density for reliable pattern learning

### Cheaper Pre-Tests to Consider

Before committing to full GNN implementation, these analyses could signal whether graph structure adds value:

1. **Co-purchase overlap analysis**: Do vehicles that share co-purchase patterns also share user preferences? If not, the GNN's co-purchase edges won't help.
2. **Vehicle clustering**: Do warm/hot user interactions cluster by vehicle similarity? If Mustang and Camaro users buy similar products, cross-vehicle transfer is plausible.
3. **Node2Vec baseline**: Train simple node2vec embeddings on the graph and evaluate Hit Rate@4. If node2vec matches SQL, the GNN's attention mechanism is unlikely to add much.

These are optional — each takes 1-2 days and could save weeks if the signal isn't there. Decision: run them if time permits before full GNN training.

### Why Run It Anyway

- **Proves/disproves the graph hypothesis with real data** — no more speculation
- **If null result** -> skip to Option A+ (semantic enrichment) with confidence and evidence
- **If positive** -> justifies GNN infrastructure investment for Holley and other customers
- **Either way, we learn something** — negative results are valuable when they're rigorous
- **Builds infrastructure** — data export, evaluation harness, scoring pipeline are reusable for A+

### What Could Surprise Us

- Co-purchase edges might capture cross-vehicle patterns that SQL segment scoring misses
- Product feature MLP (price + part_type + fitment_breadth) might learn non-obvious feature combinations
- Vehicle embeddings might cluster semantically similar vehicles (muscle cars, trucks, imports) enabling transfer

---

## 8. Production Readiness

### Cost Estimate

| Component | One-time | Recurring (weekly) |
|-----------|---------|-------------------|
| Data export (BQ -> Parquet) | — | ~$5 (BQ scan) |
| Graph construction | — | ~$5 (compute) |
| Training (T4 GPU, ~2-4 hrs) | — | ~$10 |
| Scoring (CPU, ~15 min) | — | ~$5 |
| Storage (embeddings, model) | ~1 GB GCS | ~$0.03/mo |
| **Total** | — | **~$25/week = ~$100/month** |

Development effort: ~2-3 weeks for implementation + evaluation (assuming GPU access).

### Rollback Plan

GNN output writes to a **shadow table** (`temp_holley_gnn.gnn_recommendations`), NOT directly to production. The production table (`company_1950_jp.final_vehicle_recommendations`) continues to be populated by the Phase-1-fixed SQL baseline.

Cutover to GNN requires ALL of:
1. Offline eval passes go/no-go thresholds (pre-rules Hit Rate@4)
2. Email-click sanity check shows **directional agreement** (GNN >= SQL on email-click Hit Rate@4 for the 19.7K recipient cohort)
3. Online A/B test shows positive results on per-user binary click rate
4. Manual table swap (GNN shadow -> production)

Rollback = stop writing GNN shadow table, production SQL pipeline is unaffected.

### Treatment/Bandit Integration

The GNN produces the **product recommendation table** (which 4 products each user sees). The bandit system operates at the **treatment level** (which email template/message each user receives). These are separate layers:

```
GNN -> product recommendations (4 SKUs per user)
       -> inserted into treatment content slots
Bandit -> treatment selection (which template to send)
       -> operates on treatment-level CTR, independent of product content
```

The GNN replaces the SQL scoring that populates product slots within treatments. It does NOT replace or interact with the Thompson Sampling bandit that selects treatments.

### Online A/B Test Design (If GO)

- **Randomization unit**: User (not session or email)
- **Arms**: Control (SQL recs) vs Treatment (GNN recs)
- **Split**: 50/50
- **Primary metric**: Per-user binary click rate (did user click any email in 30 days?)
- **Guardrail metrics**: Unsubscribe rate, open rate, conversion rate
- **Duration**: 4 weeks minimum (need ~2 weekly email cycles per user)
- **Sample size**: Dec-Feb delivered 19.7K users over 3 months (~6.6K/month). A 4-week test window yields ~6-7K delivered users total, so ~3-3.5K per arm. This is underpowered for +1% absolute detection. Either extend to 8 weeks or accept lower power for larger effect sizes (detectable: +3% at 80% power with 3.5K/arm). Power analysis must use **expected delivered volume**, not total eligible (258K target population).
- **Treatment policy**: **Decision**: Freeze bandit treatment allocation during online A/B test. Fixed-effects stratification is the fallback only if freezing is technically infeasible. This isolates recommendation quality from template mix effects.
- **Fallback handling**: Users whose vehicle doesn't match a GNN vehicle node fall back to SQL recs. Track fallback rate and **exclude fallback users from primary analysis** (they receive identical recs in both arms). Apply identical fallback logic in control arm for parity.

### Vehicle Change Handling

Users occasionally update their vehicle (e.g., buy a new car). The recommendation pipeline re-runs weekly:
- Graph rebuilds with current v1_make/v1_model from user attributes
- User is reassigned to new vehicle group automatically
- Previous vehicle's product recommendations are replaced
- No explicit "vehicle change" event detection needed — the weekly rebuild handles it

---

## 9. Dependencies and Open Questions

| Question | Owner | Status |
|----------|-------|--------|
| GPU availability on gke-metaflow-dev (T4) | Sumeet | Open |
| `auxia.prediction.colab` package documentation | Sumeet | Open |
| Feature Store integration vs standalone BQ exports | Sumeet | Open |
| A/B test infrastructure for online evaluation | Sumeet | Open |

---

## 10. References

| Document | Content |
|----------|---------|
| `docs/gnn/gnn_approach_comparison.md` | Option A/A+/B comparison and rationale |
| `docs/gnn/gnn_recommendation_system_proposal.md` | Original multi-phase GNN+LLM proposal |
| `docs/analysis/fitment_mismatch_investigation_2026_02_12.md` | 51% zero-fitment root cause |
| `docs/analysis/cross_campaign_uplift_analysis_2026_02_09.md` | Corrected user funnel (258K target) |
| `specs/v5_18_revenue_ab_test.md` | V5.18 slot reservation design (reference for business rules) |
| `docs/architecture/pipeline_architecture.md` | Current SQL pipeline architecture |
