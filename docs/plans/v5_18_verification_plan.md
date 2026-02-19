# V5.18 Recommendation Verification Plan

**Date**: February 18, 2026
**Status**: Draft — discussion captured, implementation pending
**Pipeline**: `sql/recommendations/v5_18_fitment_recommendations.sql`
**Output**: `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`

## Problem

The pipeline produces 4 recommendations for ~250K users. QA checks verify structural correctness (no duplicates, price floors, etc.) but don't verify that each user got the *right* recommendation.

## What "Right" Means — Three Layers

### Layer 1: Correctness (deterministic, 100% verifiable)
- Part actually fits the user's vehicle (YMM match)
- Score calculation is correct
- Filters applied properly (price, refurbished, service, commodity, image)

### Layer 2: Optimality (deterministic, verify via sampling)
- User got the *best* 4 products (no better candidate dropped)
- Fallback tier assignment is correct (segment vs make vs global)

### Layer 3: Relevance (evaluate via outcomes only)
- User actually wants these products
- Recommendation leads to click/purchase

## Verification Approaches

### 1. Deterministic Trace (Layer 1 & 2)

For a sample of users, independently reconstruct what the pipeline *should* produce, then diff against actual output.

**Step-by-step trace for one user:**
1. User has YMM = e.g. 2018 / FORD / MUSTANG
2. Query `vehicle_product_fitment_data`: what SKUs fit this vehicle?
3. Apply all filters (price >= $25, has image, not refurbished, not commodity, not service SKU)
4. Check: does this generation have >= 4 eligible parts?
5. Get popularity scores: segment (FORD/MUSTANG), make (FORD), global
6. Determine fallback tier: segment >= 5 orders? Use segment. Else make >= 20? Use make. Else global.
7. Remove products this user already purchased (365 days)
8. Apply variant dedup (base SKU collapsing)
9. Apply diversity cap (max 2 per PartType)
10. Rank by final_score, take top 4
11. Compare to pipeline output row

**Sampling strategy** — don't just pick random users, sample across:
- Different vehicles (popular vs rare)
- Different fallback tiers (segment vs make vs global)
- Users with 3 recs vs 4 recs
- Users with purchase exclusions applied
- Hot vs cold engagement tier

**Target**: 50-100 users, 100% match = pipeline correct. Any mismatch = bug.

### 2. Backtest Hit Rate (Layer 3, offline)

Before sending, evaluate relevance against historical behavior:
- Take the 250K users with recs
- Look at their actual purchases in the last 30-60 days
- What % bought one of their 4 recommended products? (hit rate)
- What % bought a product in the same PartType? (category hit rate)
- Compare to a random baseline (4 random fitment products per user)

Tells you: "is popularity-based ranking better than random?"

### 3. Segment Coverage Audit (Layer 2, manual)

For top 20 vehicle segments by user count:
- Inspect the top 4 recommended products
- Do they make sense for that vehicle?
- Are prices reasonable?
- Are PartTypes diverse?

### 4. Edge Case Audit (Layer 1 & 2)

Specifically examine:
- Users with exactly 3 recs (NULL rec4)
- Users with purchase exclusions applied (verify excluded products)
- Rare vehicles with global fallback (are global recs reasonable?)
- Vehicles at the per_generation boundary (exactly 4 eligible parts)

### 5. Live Evaluation (Layer 3, after sending)

Track outcomes post-deployment:
- Click-through rate on recommended products in emails
- Orders matching recommended SKUs within 7/14/30 day windows
- CTR by slot position (rec1 vs rec4)
- Conversion rate by fallback tier (segment > make > global expected)

## Key Consideration

With popularity-only scoring in v5.18, everyone with the same vehicle gets the same recs (minus purchase exclusion). So "right" = "right for this vehicle segment." Individual personalization comes only from purchase exclusion.

This is an acceptable tradeoff for email — auto parts are vehicle-specific by nature. A 2018 Mustang owner is likely interested in what other 2018 Mustang owners buy.

## Implementation Priority

1. Deterministic trace (highest value, catches bugs)
2. Segment coverage audit (quick manual sanity check)
3. Backtest hit rate (quantifies relevance)
4. Edge case audit (catches boundary bugs)
5. Live evaluation (post-deployment, ongoing)

## Next Steps

- [ ] Write deterministic trace query (SQL or Python)
- [ ] Define sampling criteria and user selection query
- [ ] Run backtest hit rate analysis
- [ ] Manual segment audit for top 20 vehicles
- [ ] Set up live tracking after deployment
