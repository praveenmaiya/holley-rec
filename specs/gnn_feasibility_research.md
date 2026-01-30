# GNN for Holley Recommendations — Research & Feasibility

## Context

Researching whether Graph Neural Networks could replace or augment our current SQL-based scoring pipeline (v5.18) for vehicle fitment recommendations.

---

## What the Industry Is Doing (2025-2026)

### Amazon — DAEMON (State of the Art)

**Source**: [Amazon Science Blog](https://www.amazon.science/blog/using-graph-neural-networks-to-recommend-related-products)

The most relevant production GNN system for our use case:

**Graph structure:**
- **Nodes** = Products (with metadata: name, type, description)
- **Edges** = Two types:
  - Co-purchase (directed): "bought phone → bought case" (asymmetric)
  - Similarity (bidirectional): Products viewed together under same search queries

**Key innovation — Dual embeddings per product:**
- **Source embedding**: What this product leads TO (outbound co-purchases + similarity)
- **Target embedding**: What leads TO this product (inbound co-purchases + similarity)
- At layer 1, source = target (just metadata). At layer 2+, they diverge.

**Cold-start handling:**
- Product metadata is the GNN input alongside graph structure
- New products with no purchase history still get meaningful embeddings from their catalog attributes

**Training:**
- Self-supervised contrastive learning
- Pulls connected nodes together, pushes random unconnected nodes apart
- Custom asymmetric loss enforces directional relationships

**Results: 30-160% improvement** in HitRate and MRR over baselines.

### Faire — GNN for Wholesale Recommendations (Most Similar to Holley)

**Source**: [Graph neural networks at Faire](https://craft.faire.com/graph-neural-networks-at-faire-386024e5a6d9) by Bo Ning Wang, Jan 2026

The closest analogy to our use case — B2B marketplace (3M retailers, 11M products, 2K+ categories, 140K brands). Replaced DeepFM with GNN.

**Graph structure:**
- **Bipartite graph**: Retailer nodes ↔ Product nodes
- **Retailer node features**: Store type, country, learned ID embedding (concatenated)
- **Product node features**: Pre-trained text embeddings (name/description, frozen), category, brand, brand country, learned product ID embedding
- **Edge weights**: Function of interaction frequency × engagement type (click < favorite < add-to-cart < order)

**Architecture — Two-tower GAT:**
- Separate embedding towers for retailers and products
- **GATConv** (Graph Attention) as core layer — learns which neighbor interactions matter most
- Edge weights incorporated into attention aggregation (orders weigh more than clicks)
- **1-hop neighbor sampling** (up to 50 neighbors per node) for scalability via PyTorch Geometric
- MLP projection head on top of GATConv output
- Dot product similarity between retailer and product embeddings for scoring
- Deployed to **Elasticsearch KNN** for real-time serving

**Training details:**
- **Positive samples**: Edges above a weight threshold (filters noise from light interactions)
- **Negative samples**: Mix of in-batch negatives + global random negatives
- **Loss**: BCE with edge-weight weighting (penalizes more for mispredicting strong engagements)
- **Time-decay on edge weights**: Most impactful single change — recall@10 +25.8%, recall@100 +15.4%
- **Dual optimizer**: Separate optimizer for embedding layers (higher LR, more weight decay) vs GNN/MLP layers (stable LR)
- **Warm-start retraining**: Regular cadence, loads previous embeddings as initialization to prevent drift

**Results:**
- GAT outperformed GraphSAGE in offline recall metrics
- Time-decayed edge weighting was the single biggest offline improvement
- **Online A/B test**: +10.5% order recall@10, +12% order recall@100 vs FM baseline
- **+4.85% lift in orders** on category pages (production impact)
- GNN contributed 34.1% of impressions vs FM's 33% — even though ranking pipeline was biased toward legacy FM features

**What's next for Faire:**
- Multi-hop neighbor aggregation (2-hop: retailer → product → similar retailers)
- Heterogeneous graph with brand and category nodes
- Multi-task learning (separate prediction heads for clicks, favorites, orders)

**Key takeaway for Holley**: Faire's scale (3M retailers) dwarfs ours (475K users), and their retailers actively browse/order on the platform. Their edge density is orders of magnitude higher than ours. The +4.85% order lift is impressive but came from a context (category browsing pages) with high interaction density — very different from our cold-start email scenario.

### Pinterest — PinSage
- Random-walk Graph Convolutional Network
- Billions of nodes, web-scale
- Key for us: proved GNNs work at scale for recommendation

### Zalando (Fashion E-commerce)
- Users and items as two node types (bipartite graph)
- GraphSAGE-based architecture to predict clicks
- Most similar to our setup (users + products)

### Key Architectures Being Benchmarked (Aug 2025 paper)
- **LightGCN**: Simplified graph convolution (best for pure collaborative filtering)
- **GraphSAGE**: Inductive — can embed unseen nodes (good for cold-start)
- **GAT**: Attention-weighted neighbor aggregation
- **PinSage**: Pinterest's scalable variant of GraphSAGE

---

## Mapping to Holley's Data

### Our Graph Would Look Like:

```
NODES:
  - Users (~475K) — attributes: v1_year, v1_make, v1_model, engagement_tier
  - Products (~25K SKUs) — attributes: PartType, price, fitment vehicles
  - Vehicles (~2K make/model combos) — attributes: make, model, year_range

EDGES:
  - user → product: VIEWED, CARTED, ORDERED (weighted, directed)
  - product → vehicle: FITS (from fitment data, undirected)
  - user → vehicle: OWNS (from v1 registration, undirected)
  - product ↔ product: CO-PURCHASED (from import_orders, weighted by frequency)
  - product ↔ product: CO-VIEWED (from staged_events, weighted)
```

### What GNN Would Give Us That SQL Can't:

| Capability | Current SQL | GNN |
|-----------|-------------|-----|
| "Users like you bought X" | No user-user similarity | Learned from graph neighborhoods |
| Cold-start users | Popularity fallback only | Infer from vehicle + segment embeddings |
| Cross-vehicle discovery | Only via universal pool | Learn "Mustang owners also like Camaro parts" |
| Intent signal propagation | Direct only (user→SKU) | 2-hop: user→SKU→similar_SKU |
| Embedding-based retrieval | Rule-based scoring | ANN search over learned embeddings |

### What We Already Have That Maps Well:

| GNN Input | Our Data Source | Quality |
|-----------|----------------|---------|
| User-product interactions | `staged_events` (views/carts/orders) | Good — Sep 1+ |
| Product-vehicle fitment | `vehicle_product_fitment_data` | Excellent — catalog data |
| Product co-purchases | `import_orders` (Apr-Aug) + events | Good — ~18% repeat buyers |
| Product metadata | `import_items` (PartType, price) | Excellent |
| User vehicle | `v1_year, v1_make, v1_model` | Excellent — 475K users |

---

## Honest Assessment for Holley

### Why GNN Is Exciting:
1. **Vehicle graph is natural**: User→Vehicle→Fitment→Product is a perfect graph structure
2. **Cross-segment learning**: "FORD/MUSTANG owners who buy carburetors also buy..." propagates through graph
3. **Cold-start via structure**: New product with fitment data gets embedded near similar products automatically
4. **Replaces hand-tuned weights**: No more 20/10/2 intent weights or 10.0/8.0/2.0 popularity weights — learned end-to-end

### Why GNN Is Risky for Feb 2026 Deadline:
1. **We have 4 weeks** — GNN needs: graph construction, model training, embedding pipeline, serving infra
2. **98% cold-start users**: Most users have NO intent events. GNN's power is in learning from interactions — but our users barely interact
3. **Sparse purchase data**: Only 18% repeat buyers. CF analysis already showed +0.06% gain — graph may hit same ceiling
4. **Infrastructure gap**: We run SQL on BigQuery. GNN needs PyTorch Geometric / DGL, GPU training, embedding store, ANN index
5. **Validation complexity**: Can't easily A/B test GNN vs SQL within the email blast timeframe
6. **Co-purchase graph is thin**: 4,500+ SKUs but long-tail distribution — most product pairs have 0-1 co-purchases

### The Core Tension:
Our data's biggest strength (vehicle fitment) is already captured by SQL joins. GNN's biggest strength (learning implicit relationships) needs dense interaction data we don't have.

---

## Recommendation

### For Feb 2026 A/B test: Ship v5.18 SQL as planned
- Proven, validated, dry-run passing
- Reserved slots + diversity already address the key gaps
- Risk of GNN failing to outperform is high given data sparsity

### For Q2 2026 (if contract renewed): Explore GNN as v6.0
Phase 1: Build the graph offline (BigQuery → export → NetworkX/PyG)
Phase 2: Train GraphSAGE on user→product interactions + fitment edges
Phase 3: Compare GNN embeddings vs SQL scores on historical click data
Phase 4: If GNN wins backtest, integrate as scoring layer replacing popularity weights

### Hybrid Option (lower risk):
Use GNN for product-product similarity only (not full user-product):
- Build co-purchase + co-view + fitment-overlap graph over products
- Train product embeddings
- Use embeddings to improve universal product selection (replace popularity ranking with embedding similarity to user's vehicle)
- This is additive to SQL pipeline, not a replacement

---

## Sources

- [Faire: Graph neural networks at Faire (Jan 2026)](https://craft.faire.com/graph-neural-networks-at-faire-386024e5a6d9)
- [Amazon DAEMON: Using GNNs to recommend related products](https://www.amazon.science/blog/using-graph-neural-networks-to-recommend-related-products)
- [GNN for Product Recommendation on Amazon Co-purchase Graph (Aug 2025)](https://arxiv.org/abs/2508.14059)
- [Zalando: Exploring GNN Recommendations](https://engineering.zalando.com/posts/2024/12/gnn-recommendations-zalando.html)
- [PinSage: Pinterest's web-scale GNN](https://medium.com/pinterest-engineering/pinsage-a-new-graph-convolutional-neural-network-for-web-scale-recommender-systems-88795a107f48)
- [Homogeneous vs Heterogeneous GNNs in Recommender Systems (Jan 2025)](https://www.sciencedirect.com/science/article/pii/S0925231225001183)
- [Decathlon: Building Recommender System Using GNN](https://medium.com/decathlondigital/building-a-recommender-system-using-graph-neural-networks-2ee5fc4e706d)
