# GNN Architecture Proposal: v6.0 Recommendation System

**Author:** Praveen M | **Date:** February 2026 | **Status:** Proposal
**Audience:** Auxia Engineering | **Decision needed by:** March 2026 kickoff (contingent on contract renewal)

---

## Executive Summary

We propose investing in a Graph Neural Network (GNN) recommendation system as a Q2 2026 roadmap item, contingent on Holley contract renewal. A complete prototype already exists — 965 lines of production-ready Python plus Metaflow pipelines — built on Faire's proven architecture that delivered **+4.85% order lift** in production A/B tests. The investment is modest: 1 engineer, 8–10 weeks, ~$500–1,000 in compute. The experiment is structured with go/no-go gates at weeks 5 and 7 so we can cut losses early if the approach doesn't outperform SQL. If it works, GNN unlocks capabilities SQL cannot provide: user similarity, cross-vehicle product discovery, and multi-hop intent propagation through the purchase graph.

---

## 1. Business Case

### What GNN Enables vs SQL

| Capability | SQL v5.17/v5.18 | GNN v6.0 |
|------------|-----------------|----------|
| Vehicle fitment matching | Direct joins on fitment table | Same, via graph edges |
| Popularity weighting | Aggregate counts | Learned, personalized |
| User similarity | Not possible | Embedding dot-product |
| Cross-vehicle discovery | Not possible | 2-hop paths: User→Vehicle→Product→Vehicle→Product |
| Intent propagation | Limited (view/cart/order counts) | Learned from interaction sequences |
| Cold-start handling | Popularity fallback | Vehicle-mediated embedding transfer |
| Diversity | Rule-based (max 2 per PartType) | Embedding space diversity + rules |
| Product similarity | Not available | Co-purchase graph embeddings |

### Industry Evidence

| Company | Model | Result | Relevance |
|---------|-------|--------|-----------|
| **Faire** | Heterogeneous GAT | **+4.85% order lift** on category pages; +10.5% order recall@10 vs factorization machines | Most comparable: B2B marketplace, product recommendations |
| **Amazon (DAEMON)** | Dual-embedding GNN | **+30–160% HitRate/MRR** over baselines | Cold-start handling via product metadata |
| **Pinterest** | PinSage | Deployed at billion-node scale | Proves GNN scales for recommendations |

Faire's architecture is particularly relevant: similar catalog size (11M products vs our 25K SKUs), heterogeneous graph with multiple entity types, and time-decayed edge weighting that drove their single biggest improvement (+25.8% recall@10).

### Strategic Upside

- **Contract renewal leverage**: demonstrating ML-forward capability beyond SQL
- **Platform positioning**: GNN embeddings are reusable across surfaces (email, web, search)
- **Compounding value**: graph improves as more interaction data accumulates

---

## 2. Honest Assessment

### Why We're Not Shipping GNN for the Feb 2026 A/B Test

1. **98% cold-start users**: most Holley users have zero intent events — GNN's core strength (learning from interactions) has limited signal for the vast majority
2. **Sparse purchase data**: 18% repeat buyer rate means thin co-purchase edges; our CF analysis showed only +0.06% gain from collaborative filtering
3. **4-week timeline**: GNN needs graph construction, training infrastructure, and embedding serving — not achievable safely for Feb
4. **SQL captures the primary signal**: vehicle fitment is already a direct join; GNN's implicit learning may not add much on top

The v5.18 SQL pipeline is the right choice for Feb 2026. This proposal is about what comes next.

### Core Tension

> Our data's biggest strength (vehicle fitment) is already captured by SQL joins. GNN's biggest strength (learning implicit relationships) needs dense interaction data we don't have yet.

This is exactly why the experiment has go/no-go gates — we need to prove GNN adds value beyond fitment before committing to production.

### Risk Summary

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| GNN doesn't beat SQL for cold users | High | High | Phase 1 gate: Recall@10 must exceed SQL by ≥5% |
| Infra costs exceed budget | Low | Medium | CPU-only scoring; GPU only for training |
| Serving latency too high | Medium | Medium | Batch pre-compute to BigQuery (same as SQL) |
| Data sparsity limits graph quality | Medium | High | Vehicle nodes bridge cold users to products |
| Contract doesn't renew | Medium | High | Don't start until renewal confirmed |

---

## 3. What We've Already Built

### Code Inventory

| File | Lines | Purpose |
|------|------:|---------|
| `src/gnn/model.py` | 195 | Heterogeneous GAT with two-tower architecture |
| `src/gnn/trainer.py` | 230 | Training loop with Faire-inspired techniques |
| `src/gnn/evaluator.py` | 269 | Offline eval: MRR, Recall@K, NDCG, stratified by engagement |
| `src/gnn/graph_builder.py` | 188 | DataFrame → PyG HeteroData construction |
| `src/gnn/data_loader.py` | 82 | BigQuery export → DataFrames → Parquet |
| `flows/train_gnn.py` | 177 | Metaflow training pipeline (K8s, GPU) |
| `flows/score_gnn.py` | 132 | Metaflow batch scoring pipeline |
| `configs/gnn_config.yaml` | 65 | All hyperparameters, config-driven |
| **Total** | **1,338** | **Ready for offline evaluation** |

### Architecture Highlights

**Graph structure** — 3 node types (user, product, vehicle), 7 edge types:

```
User ──interacts──→ Product ──fits──→ Vehicle
  │                    ↕                  ↑
  └────owns──────→ Vehicle          co_purchased
```

**Model** — Heterogeneous GAT (Faire's winning architecture):
- 128-dim learned embeddings per node type
- Product feature MLP: part_type embedding (32-dim) + price + log_popularity + fitment_breadth
- 2-layer HeteroConv with 4 attention heads, 256 hidden dim
- Two-tower output: separate user/product MLPs → L2-normalized → dot-product scoring

**Training techniques** (all from Faire's paper):
- Edge-weighted BCE loss (order=5×, cart=3×, view=1×)
- Time-decay weighting: `exp(-days/30)` — Faire's single biggest improvement
- Dual optimizer: embeddings at LR=0.001, GNN/MLP at LR=0.01
- Mixed negative sampling: 50% in-batch, 30% fitment-aware, 20% global random
- Early stopping (patience=10), gradient clipping, warm-start retraining

**Production patterns**: config-driven (`configs/gnn_config.yaml`), checkpoint saving, Metaflow orchestration on K8s with GPU support.

---

## 4. Minimum Viable Experiment

### Phase 1: Offline Evaluation (Weeks 1–3)

**Goal:** Prove GNN embeddings outperform SQL scores on historical data.

| Task | Details |
|------|---------|
| Export interaction graph from BigQuery | Users, products, vehicles, events since Sep 2025 |
| Build heterogeneous graph | ~475K user nodes, ~25K product nodes, ~2K vehicle nodes |
| Train model on K8s (GPU) | 100 epochs with early stopping, ~2–4 hours |
| Evaluate vs SQL baseline | Recall@{1,5,10,20}, MRR, NDCG@10 on held-out 30-day clicks |
| Stratify by engagement tier | Cold (98%), Warm (~2%), Hot (<1%) |

**Go/No-Go Gate:**
- **Pass:** GNN Recall@10 exceeds SQL baseline by ≥5% overall
- **Fail:** Recall@10 ≤ SQL → stop, document learnings, try hybrid fallback (Phase 2B)

### Phase 2: Hybrid Integration (Weeks 4–6)

**Goal:** Integrate GNN scores into the existing pipeline and measure CTR lift.

| Task | Details |
|------|---------|
| GNN scoring as additional signal | Blend GNN similarity with SQL popularity/recency scores |
| Hybrid formula | `final_score = α × sql_score + (1-α) × gnn_score`, tune α |
| A/B test via treatment split | 50% SQL-only vs 50% hybrid, same treatment infrastructure |
| Measure CTR and conversion | 2-week observation window |

**Go/No-Go Gate:**
- **Pass:** CTR lift ≥ 10% for hybrid vs SQL-only
- **Fail:** CTR lift < 10% → evaluate if product-similarity-only is viable (Phase 2B)

**Phase 2B (fallback):** Use GNN for product-product similarity only — improve universal product selection by replacing popularity ranking with co-purchase graph embeddings. This is additive to SQL, not a replacement.

### Phase 3: Production Deploy (Weeks 7–8)

**Goal:** Ship to production with safety rails.

| Task | Details |
|------|---------|
| Shadow mode | GNN scores logged alongside SQL, not served |
| Validation | Compare GNN recs vs SQL recs on QA checks (450K users, 0 duplicates, prices ≥$50) |
| Gradual rollout | 10% → 25% → 50% → 100% over 2 weeks |
| Monitoring | CTR, conversion, diversity metrics, cold-start coverage |

### When to Stop and Cut Losses

| Signal | Action |
|--------|--------|
| Phase 1 Recall@10 ≤ SQL | Stop. Document. Total cost: ~$100 compute, 3 weeks |
| Phase 2 CTR lift < 10% | Evaluate hybrid fallback (2B). If 2B also fails, stop |
| Phase 3 CTR regression in shadow | Roll back to SQL. Investigate offline/online gap |
| Compute costs 2× over budget | Reduce graph size or switch to CPU-only training |

---

## 5. Infrastructure Requirements

### Compute Budget

| Resource | Monthly Cost | Notes |
|----------|-------------|-------|
| GPU training (K8s) | $50–100 | 1× T4/A10, ~2–4 hours per training run, weekly retrain |
| K8s CPU (scoring + serving) | $300–500 | Batch scoring pipeline, same as current Metaflow setup |
| BigQuery (storage + queries) | $100–200 | Graph export, score write-back, evaluation queries |
| **Total** | **$450–800/month** | **$500–1,000 for full experiment** |

### Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| PyTorch + PyTorch Geometric | Configured | Already in prototype, Metaflow K8s images |
| Metaflow (K8s orchestration) | Production | Currently used for `src/bandit_click_holley.py` |
| BigQuery (data source/sink) | Production | Same tables as SQL pipeline |
| GCS (model artifacts) | Configured | `gs://holley-models/gnn/` for checkpoints + embeddings |

No new infrastructure needed — everything runs on existing K8s + BigQuery + GCS stack.

### Maintenance

- **Weekly retraining**: automated via Metaflow, ~2–4 hours on GPU
- **Embedding monitoring**: drift detection on embedding norms and distribution shifts
- **Graph refresh**: new interactions incorporated weekly, full rebuild monthly

---

## 6. Timeline & Milestones

```
                    March 2026                    April 2026              May 2026
Week:    1    2    3    4    5    6    7    8    9    10
         ├────┼────┼────┼────┼────┼────┼────┼────┼────┤
Phase 1: [===Export===][==Train==][=Eval=]
                                  ↑ GO/NO-GO #1
Phase 2:                          [==Hybrid==][=A/B=]
                                              ↑ GO/NO-GO #2
Phase 3:                                      [Shadow][Rollout]
```

**Critical path dependencies:**
1. Contract renewal decision (mid-Feb 2026) → green light to start
2. v5.18 A/B test results (end-Feb 2026) → baseline CTR for comparison
3. Phase 1 go/no-go (week 5) → continue or stop
4. Phase 2 go/no-go (week 7) → deploy or fall back to hybrid-only

---

## 7. Alternatives Considered

### A: Continue Iterating SQL (Status Quo)

- **Pros:** Proven, low risk, zero additional compute cost
- **Cons:** Hits personalization ceiling — SQL cannot learn user similarity, cross-vehicle discovery, or propagate intent through the graph
- **When to choose:** If GNN fails Phase 1, this is the fallback

### B: GNN for Product Similarity Only (Hybrid Fallback)

- **Pros:** Lower risk — embeddings improve universal product ranking without replacing SQL scoring; additive, not destructive
- **Cons:** Misses the biggest GNN upside (user-level personalization)
- **When to choose:** If Phase 2 full hybrid fails but Phase 1 offline metrics look promising

### C: Wait for More Interaction Data

- **Pros:** More data = denser graph = GNN works better
- **Cons:** Misses the Q2 window; if contract renews, waiting means less time to demonstrate ML value
- **When to choose:** If cold-start rate drops below 90% organically

### Recommendation

**Option A (iterate SQL) is the baseline.** We propose attempting the full GNN experiment with Option B as the Phase 2 fallback. The experiment is time-boxed with clear exit criteria, so the worst case is $100 in compute and 3 weeks of work if Phase 1 fails.

---

## 8. The Ask

1. **Approve GNN as a Q2 2026 roadmap item**, contingent on contract renewal (mid-Feb decision)
2. **Allocate $500–1,000 compute budget** for the 8–10 week experiment
3. **Designate a technical owner** to review prototype code in `src/gnn/` and validate architecture decisions
4. **Staffing**: 1 engineer, full-time for 8–10 weeks

### Next Steps

| When | What |
|------|------|
| Mid-Feb 2026 | Contract renewal decision |
| End-Feb 2026 | v5.18 A/B test results → establish baseline CTR |
| Early March | Technical owner reviews prototype code (`src/gnn/`, `flows/train_gnn.py`) |
| March kickoff | Phase 1 begins: export graph, train model, evaluate |
| Week 5 (~mid-April) | Go/no-go #1: does GNN beat SQL offline? |
| Week 7 (~end-April) | Go/no-go #2: does hybrid lift CTR? |
| May 2026 | Production deploy or documented learnings |

---

*This proposal is designed to fail fast and cheap. The worst outcome is 3 weeks and $100 confirming that SQL is the right approach for Holley's data density. The best outcome is a reusable ML system that compounds in value as interaction data grows.*
