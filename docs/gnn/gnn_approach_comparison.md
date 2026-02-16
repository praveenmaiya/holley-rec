# GNN Recommendation System: Three Approaches

**Problem:** 98% of Holley's email recipients are cold-start users with zero browsing/purchase history. The current SQL pipeline falls back to category-level popularity for these users — no personalization. We have a structural advantage competitors lack: a vehicle fitment graph that connects users to products through their registered vehicles (user → vehicle → product).

**Question we haven't answered yet:** Does a GNN that exploits this graph structure outperform the SQL popularity baseline? Everything below assumes we need to answer that first.

---

## Graph-LLM Integration: The Industry Direction

The current state of the art in recommendation systems combines Graph Neural Networks with Large Language Models. They solve complementary problems: GNNs capture structural relationships (who bought what, what fits which vehicle), while LLMs understand semantic meaning (what products *are*, why a user might want them). Neither alone is sufficient — GNNs can't reason about content, LLMs can't see network effects.

Industry deployments use three levels of coupling:

**Level 0 — No integration.** GNN operates on interaction data alone. The model sees graph topology but has no understanding of item content. This is where most academic GNN papers sit.

**Level 1 — One-way: LLM → Graph.** LLM-generated embeddings feed into the GNN as node features. The LLM enriches the graph with semantic understanding, but doesn't consume graph output. Pinterest uses this pattern at billion-node scale: content embeddings from their visual/text models become input features for PinSage (Ying et al., KDD 2018; deployed on 3B+ nodes, 18B+ edges). TextBridgeGNN (2025) formalizes this as using pretrained language model semantics to bridge data silos without costly LLM fine-tuning.

**Level 2 — Bidirectional: GNN ↔ LLM.** Graph embeddings flow back into the LLM as structured context, and LLM outputs inform graph construction or re-ranking. LinkedIn's STAR system exemplifies this at enterprise scale (800M+ members): LLMs encode job/profile semantics while LiGNN captures real-time interaction networks, with both signals feeding the final ranker (+1% hearing-back rate, +2% Ads CTR). TEA-GLM (NeurIPS 2024) takes this further — pretraining the GNN to align its representations with LLM token embeddings, enabling zero-shot generalization across datasets. K-RagRec projects graph embeddings as "soft prompts" into the LLM, teaching it to read graph structure directly. Note: these systems operate on graphs 3-6 orders of magnitude larger than Holley's (475K users, ~90K interactions).

**The Holley hypothesis:** One-way (Level 1) likely captures most of the cold-start value for us. The reverse direction — Graph → LLM, where graph embeddings provide warm-user context to an LLM re-ranker — primarily benefits users with enough interaction history for graph embeddings to be meaningful. Today that's ~2% of our users. This could change: if email engagement grows, or if vehicle-graph embeddings prove useful even for users with zero browsing history (cold but "vehicle-known"), Level 2's value increases. But at current interaction density (~90K sends), Level 1 addresses the dominant segment.

---

## Option A: GNN-Only (Level 0 — No Graph-LLM Integration)

### Graph-LLM Integration Level
None. The GNN operates on interaction topology and handcrafted features only. Products are represented by their graph position, not by what they are.

### How It Works
The graph has three node types (475K users, 25K products, 2K vehicles) connected by edges: user-viewed-product, user-owns-vehicle, product-fits-vehicle, and product-copurchased-product. A 2-layer HeteroGAT learns embeddings by passing messages along these edges. For cold users, the path user → vehicle → product provides signal: "users with your vehicle bought these parts." Scoring is dot-product similarity between user and product embeddings → top-K per user → write to BigQuery.

### Strengths
- **Cleanly validates the GNN hypothesis** — if lift comes, it's from the graph, not something else
- **Code is 90% written** — model, trainer, evaluator, SQL export, config all exist
- **Simple to debug** — one model, one pipeline, standard PyG patterns
- **No external API dependencies** — weekly batch job, fully self-contained

### Weaknesses
- **Cold-start signal is indirect** — vehicle-mediated recommendations are 2 hops away; may be too weak for 98% cold users
- **No semantic understanding** — a brake pad and brake rotor look unrelated unless they co-occur in purchase data
- **The industry has moved past this** — Level 0 is where academic GNN papers sit, not where production systems deploy

### Expected Lift
- Cold users (98%): **uncertain** — vehicle graph provides some transfer, but sparse vehicle-to-product edges limit it
- Warm users (2%): **+5-15% Recall@10** — direct interaction edges give strong signal
- Overall: **uncertain** — if cold-user lift is near zero, the 2% warm uplift produces negligible aggregate impact; if vehicle-mediated transfer works better than expected, could reach +3-5%

---

## Option A+: GNN + Semantic Enrichment (Level 1 — LLM → Graph)

### Graph-LLM Integration Level
One-way. LLM generates product descriptions → SentenceTransformer encodes them as 384-dim vectors → these become product node features in the GNN. The LLM enriches the graph's understanding of products, but never sees graph output. This is the same pattern Pinterest uses with PinSage: content embeddings as GNN input features.

### How It Works
Before training, each product gets a semantic embedding from its LLM-generated description (title + category + key attributes → natural language summary → SentenceTransformer). These embeddings become product node features. The GNN now has two signal types: structural (who bought what) and semantic (what products are). For cold users, message passing carries semantic similarity through the vehicle graph — "your vehicle fits these brake parts, and brake pads are semantically similar to brake rotors" becomes expressible even without co-purchase edges.

### Strengths
- **Directly addresses the 98% cold-start problem** — products with zero interactions still have meaningful embeddings that propagate through the vehicle graph
- **Follows the industry pattern** — Pinterest, TextBridgeGNN, and production RecSys teams use LLM → Graph as their baseline integration
- **Incremental over Option A** — same architecture, richer input features; existing code needs minimal changes
- **One-time catalog enrichment** — embeddings only regenerate when products change, not every training cycle
- **Still validates the GNN** — the GNN remains the only scoring mechanism; semantics improve its inputs, not replace it

### Weaknesses
- **May mask whether graph topology alone adds value** — harder to attribute lift to "GNN structure" vs "better product features"
- **Embedding quality depends on product descriptions** — automotive parts have terse, jargon-heavy descriptions; LLM rewrite quality matters
- **One-way integration ceiling** — can't leverage graph structure to improve LLM understanding (that's Level 2)

### Expected Lift
- Cold users (98%): **+5-10% Recall@10** — semantic features propagate through vehicle edges, giving cold products and cold users meaningful representations
- Warm users (2%): **+5-15% Recall@10** — similar to A; these users already have rich interaction data
- Overall: **+5-8%**, meaningfully better than A for the cold majority

---

## Option B: Full Bidirectional Platform (Level 2 — GNN ↔ LLM)

### Graph-LLM Integration Level
Bidirectional. LLM enriches product features (like A+), AND graph embeddings flow back to the LLM for re-ranking warm/hot users. This is the LinkedIn STAR / TEA-GLM pattern: the LLM consumes graph-derived context to make ranking decisions that account for both content semantics and network structure. Knowledge distillation eventually replaces the LLM at inference.

### How It Works
Four-stage pipeline: (1) LLM enriches catalog → SentenceTransformer embeddings (same as A+), (2) HeteroGAT trains on enriched graph → user/product embeddings, (3) FAISS retrieves top-100 → hybrid scorer blends GNN + semantic + popularity + recency → top-K, (4) for warm/hot users, LLM re-ranks top-20 using graph-derived user embeddings as context ("this user's graph neighborhood indicates affinity for performance parts") → distill rankings into MLP over time.

### Strengths
- **Strongest theoretical performance** — both directions of information flow are active
- **LLM re-ranking adds contextual reasoning** — can explain "why this product" using graph context, not just score it
- **Production-proven at scale** — LinkedIn (LiGNN: +1% hearing-back, +2% Ads CTR), Pinterest (40% accuracy improvement)
- **Knowledge distillation eliminates LLM at inference** — student MLP serves at embedding speed after training

### Weaknesses
- **The Graph → LLM direction primarily helps ~2% of users today** — warm/hot users with enough interaction history for meaningful graph embeddings; 98% cold users get the same treatment as A+ (this ratio could shift if engagement grows)
- **Doesn't answer "does GNN help?"** — four interacting layers make attribution nearly impossible
- **Over-engineering for current state** — LinkedIn has billions of interactions justifying bidirectional flow; we have ~90K email sends
- **Complexity** — 5 pipelines, 15-20 files; FAISS index corruption, LLM API outages, distillation divergence are all new failure modes

### Expected Lift
- Cold users (98%): **+5-10% Recall@10** — same as A+ (semantic embeddings do the heavy lifting)
- Warm users (2%): **+10-20% Recall@10** — LLM re-ranking with graph context provides meaningful uplift for users with history
- Overall: **+5-10%**, though the marginal gain over A+ comes almost entirely from the 2% warm minority

---

## Summary

| | A: Level 0 (GNN-Only) | A+: Level 1 (LLM → Graph) | B: Level 2 (GNN ↔ LLM) |
|---|---|---|---|
| **Graph-LLM integration** | None | One-way: LLM enriches graph | Bidirectional: mutual context |
| **Industry parallel** | Academic baseline | Pinterest PinSage, TextBridgeGNN | LinkedIn STAR, TEA-GLM |
| **Cold-start approach** | Vehicle graph hops only | + semantic product embeddings | + hybrid scoring + LLM re-rank |
| **Answers "does GNN work?"** | Yes, cleanly | Mostly (richer inputs) | No (too many variables) |
| **Cold-start lift (98%)** | Uncertain (0 to +5%) | +5-10% Recall@10 | +5-10% Recall@10 |
| **Warm lift (2%)** | +5-15% Recall@10 | +5-15% Recall@10 | +10-20% Recall@10 |
| **Operational complexity** | Low | Low | High |

### Recommendation

**Start with A+ (Level 1).** One-way LLM → Graph integration is where the industry's cold-start value concentrates, and cold-start is 98% of our problem. Level 2's bidirectional flow (LinkedIn, TEA-GLM) adds the Graph → LLM direction — but that direction only benefits the 2% of users with enough interaction history to produce meaningful graph embeddings. For Holley's user distribution, Level 1 captures nearly all of Level 2's aggregate lift at a fraction of the complexity.

If A+ proves the GNN hypothesis in offline eval, the path to Level 2 is clear: add FAISS retrieval, hybrid scoring, and LLM re-ranking selectively for warm users. But build that bridge only after we know the graph adds value.
