# GNN Recommendation System — Meeting Talking Points

**Date:** February 2026 | **Audience:** Engineering + Product

---

## 1. One-Liner

GNN learns recommendations from the user-product-vehicle graph — capturing relationships SQL can't: user similarity, cross-vehicle discovery, and co-purchase propagation.

---

## 2. Current State (SQL v5.17)

**What it does well:**
- Vehicle fitment matching (direct joins)
- Popularity ranking (aggregate counts)
- Diversity rules (max 2 SKUs per PartType)
- Price/variant/refurbished filters

**What it can't do:**
- "Users like you" signals (no user-user similarity)
- Cross-vehicle discovery ("Mustang owners also like Camaro parts")
- Multi-hop intent propagation (user → SKU → similar SKU)
- Personalized ranking (everyone with the same vehicle sees the same order)

---

## 3. How GNN Works (Non-Technical)

**The graph:**
- 3 node types: users (~475K), products (~25K SKUs), vehicles (~2K)
- Connected by interactions (views, carts, orders), fitment, ownership, co-purchases

**What the model does:**
- Learns a 128-dimensional vector (embedding) for every user and product
- Each embedding encodes its graph neighborhood — who interacted with what, what fits where
- Score = dot product of user embedding x product embedding
- Higher score = better recommendation

**What changes downstream: nothing.**
- Same BigQuery output table, same email pipeline, same treatment infrastructure
- Just better rankings within each user's recommendation set

---

## 4. End-to-End Pipeline

```
BigQuery  ──export──>  Parquet files  ──build graph──>  PyG HeteroData
                                                              │
                                                    Train on K8s GPU
                                                       (2-4 hours)
                                                              │
                                                     Score all users
                                                              │
BigQuery  <──write back──  Recommendation scores  <───────────┘
    │
    └──>  Email system reads from BQ (same as today)
```

- **Data**: BigQuery → Parquet export (nodes + edges)
- **Train**: K8s GPU, 2-4 hours, weekly retrain
- **Score**: Batch nightly, write back to BigQuery
- **Serve**: Same as today — email system reads from BQ
- **Infra**: All existing (K8s + Metaflow + BigQuery + GCS). No new services needed.

---

## 5. What GNN Adds (Concrete Example)

> **Sarah** owns a 1967 Ford Mustang. She bought Holley 0-80508S carburetor last month.

**SQL (today):** Recommends top-selling Mustang parts by popularity — air filter, fuel pump, water pump. Generic, not personalized. MSD Ignition ranks ~15th.

**GNN:** Sees that other carburetor buyers for classic Mustangs frequently also buy MSD 8529 Ignition Kit (co-purchase edge, weight=high). The path:

```
Sarah ──bought──> Holley Carburetor ──co_purchased──> MSD Ignition
                         │
                    ──fits──> '67 Mustang ──fits──> HEI Distributor
```

GNN ranks MSD Ignition in the top 5 — a cross-category discovery SQL can't make because it only sees popularity within fitment, not purchase patterns across users.

---

## 6. Honest Challenges

| Challenge | Detail |
|-----------|--------|
| **98% cold-start users** | Most users have zero intent events — GNN's core strength (learning from interactions) has limited signal for the majority |
| **18% repeat buyer rate** | Thin co-purchase graph; our CF analysis showed only +0.06% gain from collaborative filtering |
| **SQL already captures fitment** | Vehicle fitment is the strongest signal and it's already a direct join — GNN's implicit learning may not add much on top |
| **Industry evidence caveat** | Faire's +4.85% order lift came from dense browsing pages (3M active retailers); our email context is much sparser |

**The core tension:**
> Our data's biggest strength (vehicle fitment) is already captured by SQL. GNN's biggest strength (learning implicit relationships) needs dense interaction data we don't have yet.

This is exactly why the experiment has go/no-go gates.

---

## 7. What We've Built

| File | Lines | Purpose |
|------|------:|---------|
| `src/gnn/model.py` | 195 | Heterogeneous GAT, two-tower architecture |
| `src/gnn/trainer.py` | 230 | Training loop with Faire-inspired techniques |
| `src/gnn/evaluator.py` | 269 | Offline eval (MRR, Recall@K, NDCG), stratified by engagement |
| `src/gnn/graph_builder.py` | 188 | DataFrame → PyG HeteroData graph construction |
| `src/gnn/data_loader.py` | 82 | BigQuery export → DataFrames → Parquet |
| `flows/train_gnn.py` | 177 | Metaflow training pipeline (K8s, GPU) |
| `flows/score_gnn.py` | 132 | Metaflow batch scoring pipeline |
| `configs/gnn_config.yaml` | 65 | All hyperparameters, config-driven |
| **Total** | **1,338** | **Ready for offline evaluation** |

Architecture based on Faire's winning design: Heterogeneous GAT, two-tower, time-decay edge weighting (+25.8% recall@10 at Faire), edge-weighted BCE loss, dual optimizer, mixed negative sampling.

---

## 8. Phased Experiment Plan

### Phase 1: Offline Eval (Weeks 1-3)
- Export graph from BigQuery, train on K8s GPU
- Evaluate: does GNN beat SQL on Recall@10 for held-out clicks?
- Stratify by cold (98%) / warm (~2%) / hot (<1%) users
- **Gate: GNN Recall@10 must exceed SQL by >= 5%**

### Phase 2: Hybrid Integration + A/B Test (Weeks 4-6)
- Blend: `final_score = alpha x sql_score + (1-alpha) x gnn_score`
- A/B test: 50% SQL-only vs 50% hybrid
- **Gate: CTR lift >= 10%**
- Fallback (2B): use GNN for product-product similarity only (additive, not replacement)

### Phase 3: Production Deploy (Weeks 7-8)
- Shadow mode → gradual rollout (10% → 25% → 50% → 100%)
- Same QA checks as SQL: 450K users, 0 duplicates, prices >= $50

**If Phase 1 fails, we stop. Total cost: ~$100 + 3 weeks.**

---

## 9. Numbers

| Item | Value |
|------|-------|
| **Compute budget** | $500-1,000 for full experiment |
| **Timeline** | 8-10 weeks (March-May 2026) |
| **Staffing** | 1 engineer, full-time |
| **Monthly run cost** | $450-800 (GPU training + K8s scoring + BQ) |
| **Worst-case loss** | $100 compute + 3 weeks if Phase 1 fails |
| **Code ready** | 1,338 lines, ready for offline eval |
| **New infra needed** | None — K8s, Metaflow, BigQuery, GCS all existing |

---

## 10. Decisions Needed

1. **Approve GNN as Q2 2026 roadmap item** — contingent on contract renewal (mid-Feb decision)
2. **Allocate $500-1,000 compute budget** for the 8-10 week experiment
3. **Designate technical owner** for code review of `src/gnn/` and architecture sign-off

### Next Steps

| When | What |
|------|------|
| Mid-Feb | Contract renewal decision |
| End-Feb | v5.18 A/B test results → baseline CTR |
| Early March | Technical owner reviews prototype code |
| March kickoff | Phase 1 begins |
| Mid-April (Week 5) | Go/no-go #1: offline eval |
| End-April (Week 7) | Go/no-go #2: A/B test results |
| May | Production deploy or documented learnings |
