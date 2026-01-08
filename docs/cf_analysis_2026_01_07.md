# Collaborative Filtering Analysis - SKIPPED

**Date**: 2026-01-07
**Decision**: Skip CF implementation - not worth complexity for minimal gain

---

## Summary

Investigated collaborative filtering ("users who bought X also bought Y") as a way to improve match rate beyond V5.16's segment-based popularity.

**Result**: CF adds only **+0.06% match rate** improvement (9.01% → 9.07%). Not worth implementation complexity.

---

## Analysis Results

### Co-Purchase Patterns Found

| Metric | Value |
|--------|-------|
| Total co-purchase pairs (min 5 users) | 70 |
| Segments with pairs | 17 |
| Avg users bought both | 6.6 |
| Avg conditional probability | 71.1% |
| Max users bought both | 90 |

**Top Global Co-Purchase Pairs:**
| SKU A | SKU B | Users Bought Both |
|-------|-------|-------------------|
| 556-152 | 556-154 | 90 |
| 558-443 | 558-465 | 85 |
| 71221018HKR | 71223015HKR | 55 |
| D1001-3 | DGM17PLUSUNLK | 40 |

These are real patterns (likely kits/related parts), but data is sparse.

### Coverage Analysis

| Metric | Count | % of Buyers |
|--------|-------|-------------|
| Total eval buyers | 3,583 | 100% |
| Repeat buyers (have prior purchase) | 645 | 18.0% |
| Segment match (V5.16) | 321 | 9.0% |
| CF match | 59 | 1.6% |
| CF-only (incremental) | 46 | 1.3% |
| Combined (V5.16 + CF) | 360 | 10.1% |

### Options Tested

| Approach | Match Rate | Notes |
|----------|------------|-------|
| V5.16 Baseline (Segment Top 4) | 9.01% | Current |
| Option A: Hybrid Score | 7.45% | **Worse** - CF boost displaces segment items |
| Option B: Reserved Slot (3+1) | 9.07% | +0.06% - minimal gain |

---

## Why CF Doesn't Help Much

1. **Only 18% are repeat buyers** - CF only applies to users with prior purchase history

2. **Data sparsity** - Need 3+ users to co-purchase same pair for valid CF signal

3. **Most purchases are unpredictable**:
   - 37% of purchased SKUs never seen in training
   - Only 15.2% of buyers had prior VIEW intent on what they bought
   - Long-tail distribution: need 500 products to cover 55% of buyers

4. **Slot competition** - CF recommendations compete with already-strong segment popularity signals

---

## Conclusion

**DO NOT IMPLEMENT CF** - The +0.06% improvement doesn't justify:
- Additional pipeline complexity
- More tables to maintain
- Longer pipeline runtime
- Risk of bugs

Focus optimization efforts elsewhere.

---

## Alternative Improvements to Consider

1. **More recommendation slots** (4 → 8) - Would roughly double coverage
2. **Real-time personalization** - Recommend based on current session browsing
3. **Segment expansion** - Fall back to make-only when make/model is sparse
4. **Category-based recommendations** - "You viewed carburetors, here are popular carbs"

---

## Files Created During Analysis

- `sql/recommendations/v5_17_collaborative_filtering_prototype.sql` - CF prototype (not for production)

---

*Analysis by: Claude Code*
*Decision: Skip CF, focus on other improvements*
