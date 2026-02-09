# Session Summary - 2026-02-09

## Context
- Confirmed **v5.17 is the latest production pipeline**.
- v5.18 exists as a **one-time revenue A/B test pipeline** (not production by default).
- Goal: prepare for the revenue A/B test and improve recommendations; began exploring **GNNs**.

## GNN Article Reviewed
Source: Faire engineering article on GNNs for recommendations.

### Key Takeaways
- Reframed personalization as a **graph problem** (retailer–product bipartite graph) to capture relational signals beyond matrix factorization.
- Built **edge-weighted interactions** (orders/carts > views/clicks) and applied **time decay** for recency.
- Used a **two-tower GNN** with **neighbor sampling**; embeddings served via **KNN retrieval** (Elasticsearch) to generate candidates.
- Training highlights: **edge-weight thresholds** for positives, **in-batch + global negatives**, **weighted BCE loss**, **warm-start retraining**.
- Reported gains: **improved recall@K** and **online order lift** on category pages.

## Relevance to Holley (Discussion Points)
- A GNN could help overcome **fitment gaps** and **broad-fitment bias** by learning relational signals between users and products.
- Possible strategy: use GNN for **candidate retrieval**, then apply existing business rules and ranking logic (price, exclusions, diversity, purchase suppression).

## Open Questions
- Which Holley signals should drive **edge weights** (views, carts, orders, email clicks)?
- Do we have sufficient **product metadata** for item features, or rely on ID embeddings only?
- For the A/B test, should GNN be a **separate retrieval arm** or a **candidate generator** feeding the v5.17 ranker?
- What **success metric** matters most for the test (revenue per send, order lift, recall@K, fitment-aware relevance)?

## Next Steps (Non-Implementation)
- Align on A/B test design boundaries (production v5.17 vs experimental retrieval).
- Decide success criteria and evaluation metrics for GNN exploration.
