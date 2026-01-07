# Algorithm Iteration Log

**Goal**: Improve recommendation match rate beyond v5.7 baseline (0.02%)
**Started**: 2026-01-06 (overnight autonomous run)

---

## Baseline: V5.7

| Metric | Value |
|--------|-------|
| Match Rate | 0.020% |
| Matched Users | 94 |
| Total Matches | 156 |
| Unique SKUs (rec_part_1) | 787 |

**Algorithm**: Intent score + Global popularity
```
final_score = intent_score + LOG(1 + global_orders) * 2
```

---

## V5.8: Segment Popularity + Narrow Fit Bonus

**Hypothesis**: Users buy what other owners of the same vehicle buy. Narrow-fit products are more relevant.

**Changes**:
- Replace global popularity with segment popularity (same make/model/year)
- Add narrow fit bonus (products fitting <100 vehicles get +5 points)

**Results**:
| Metric | V5.7 | V5.8 | Delta |
|--------|------|------|-------|
| Match Rate | 0.0209% | 0.0139% | -33% |
| Matched Users | 98 | 65 | -34% |

**Why It Failed**:
- Segment popularity data is sparse (only 1,152 segments with data)
- Most users have vehicles with insufficient purchase history
- Narrow fit bonus doesn't compensate for loss of global popularity signal

---

## V5.9: Category-Aware Recommendations

**Hypothesis**: Users will buy products in the same category they recently browsed. A user viewing headlights will buy headlights.

**Changes**:
- 50-point bonus for products matching user's primary category (most recent browsed)
- 30-day exponential decay for intent signals
- 60-day recency window for category detection

**Results**:
| Metric | V5.7 | V5.9 | Delta |
|--------|------|------|-------|
| Match Rate | 0.020% | 0.015% | -25% |
| Matched Users | 94 | 70 | -26% |
| Unique SKUs | 787 | 3,223 | +310% |

**Why It Failed**:
- Category loyalty is weak: only 7.3% of purchases match user's "primary category"
- Users browse across categories (view headlight → buy carburetor is common)
- The 50-point category boost overweights same-category products that users don't actually want
- More diversity (4x more unique SKUs) but worse match rate

**Key Insight**: Users don't stay in one category. Category-based prioritization is wrong.

---

## V5.10: Co-Purchase Patterns

**Hypothesis**: Users buy products that are frequently purchased together. If user shows intent for product A, recommend products commonly bought with A.

**Changes**:
- Build co-purchase matrix from historical orders (min 5 co-purchases)
- For each user's intent products, find associated products
- Score: `final = co_purchase_boost * 2 + intent_score + popularity * 0.5`

**Results**:
| Metric | V5.7 | V5.10 | Delta |
|--------|------|-------|-------|
| Match Rate | 0.0202% | 0.0194% | -4% |
| Matched Users | 95 | 91 | -4% |
| Total Matches | 157 | 149 | -5% |

**Why It Failed**:
- Co-purchase matrix too sparse: only 10,478 pairs with 2,870 unique SKUs
- Only 4,410 users (0.9%) got any co-purchase boost
- Average co-purchase boost was only 0.49 - too weak to change rankings
- Most user intent products don't appear in co-purchase matrix
- 99% of users defaulted to popularity-based ranking anyway

**Key Insight**: Co-purchase data is too sparse to be useful. Need to lower threshold or find different signal.

---

## V5.11: Pure Segment Popularity

**Hypothesis**: Intent signals might be HURTING matches. Users don't buy what they browsed. Try only segment popularity - what do other owners of the same vehicle buy?

**Changes**:
- Remove intent score entirely
- Only use segment popularity (purchases by same make/model/year owners)
- Add narrow fit bonus for specific parts

**Results**:
| Metric | V5.7 | V5.11 | Delta |
|--------|------|-------|-------|
| Match Rate | 0.0202% | 0.0134% | **-34%** |
| Matched Users | 95 | 63 | -34% |
| Total Matches | 157 | 97 | -38% |

**Why It Failed**:
- Segment popularity data extremely sparse: only 1,152 segments, 3,747 pairs
- 69% of users (321,335) had NO segment score at all
- Removing intent HURT - intent signal is actually useful, not harmful
- Global popularity provides the strongest baseline signal

**Key Insight**: Intent signals ARE valuable. The problem is not too much intent, but how we combine signals.

---

## V5.12: No Diversity Filter

**Hypothesis**: Forcing max 2 SKUs per PartType might be hurting matches. Users may want multiple items from the same category.

**Changes**:
- Remove diversity filter (allow any number from same PartType)
- Keep all other V5.7 scoring: intent + global popularity

**Results**:
| Metric | V5.7 | V5.12 | Delta |
|--------|------|-------|-------|
| Match Rate | 0.0202% | **0.0205%** | **+1.5%** |
| Matched Users | 95 | 97 | +2 |
| Total Matches | 157 | 158 | +1 |
| Users Covered | 469,338 | 473,690 | +4,352 |

**First Improvement!** Small but positive signal.

**Why It Worked (Slightly)**:
- Only 1.86% of users had all 4 recs from same PartType
- Diversity filter was preventing ~4,000 users from getting 4 recs
- Users actually do buy multiple products from same category

**Key Insight**: Diversity filter provides minimal value but excludes some users. Remove it.

---

## V5.13: Lower Price Threshold

**Hypothesis**: $50 minimum price may exclude products users actually buy. Try $25.

**Changes**:
- Lower min_price from $50 to $25
- Keep no diversity filter from V5.12
- Keep intent + global popularity scoring

**Results**:
| Metric | V5.12 | V5.13 | Delta |
|--------|-------|-------|-------|
| Eligible SKUs | 21,957 | 21,957 | 0% |

**Why It Had No Effect**:
- SKU pool is identical at $25 and $50 thresholds
- Prices come from events data; products without known prices default to threshold
- All products in fitment catalog with known prices are $50+
- Lowering threshold only affects products without price data (which already pass)

**Key Insight**: Price threshold change doesn't expand candidate pool. Focus on scoring improvements instead.

---

## V5.14: Recency-Weighted Popularity

**Hypothesis**: Recent purchases (last 60 days before cutoff) are better predictors than historical 8-month window.

**Changes**:
- Add recency window: Oct 16 - Dec 15 (60 days before cutoff)
- Weight recent purchases 3x higher than historical
- `popularity_score = LOG(1 + hist_orders) * 2 + LOG(1 + recent_orders) * 6`

**Results**:
| Metric | V5.12 | V5.14 | Delta |
|--------|-------|-------|-------|
| Match Rate | 0.0205% | 0.0194% | **-5.4%** |
| Matched Users | 97 | 92 | -5 |
| Total Matches | 158 | 142 | -10% |

**Impact on Recommendations**:
- 111,375 users (24%) had their top recommendation changed
- 277,789 users (59%) had their #2 recommendation changed

**Why It Failed**:
- Recency doesn't improve predictions in this domain
- Automotive parts purchases are project-driven, not seasonal/trending
- Historical 8-month window captures more signal than recent 60 days
- Overweighting recent purchases destabilized good recommendations

---

## Summary: What We Learned (V5.8 - V5.14)

### Best Performing
| Version | Match Rate | Delta vs Baseline |
|---------|------------|-------------------|
| **V5.12 (no diversity)** | **0.0205%** | **+1.5%** |
| V5.7 (baseline) | 0.0202% | — |
| V5.10 (co-purchase) | 0.0194% | -4% |
| V5.14 (recency) | 0.0194% | -4% |
| V5.9 (category) | 0.015% | -25% |
| V5.8 (segment pop) | 0.0139% | -33% |
| V5.11 (no intent) | 0.0134% | -34% |

### Key Findings

**1. Intent signals ARE valuable**
- Removing intent (V5.11) caused 34% drop in match rate
- Users DO buy things they've browsed, despite low conversion rate

**2. Global popularity beats alternatives**
- Segment popularity: too sparse (1,152 segments)
- Category matching: only 7.3% accuracy
- Co-purchase: too sparse (10,478 pairs)
- Recency: destabilizes recommendations

**3. Constraint relaxation helps**
- Removing diversity filter: +1.5% (only improvement so far)
- Price threshold: no effect (data limitation)

**4. The fundamental problem**
- 473K users with vehicle data
- Only ~1,300 made purchases in 21-day window
- Only 97 bought something we recommended
- **Base rate is extremely low** - 0.02% match rate may be near ceiling

### Why Match Rate Is Hard to Improve

1. **Low purchase intent**: Most users aren't in buying mode when recommendations are generated
2. **Project-driven purchases**: Automotive parts are need-based, not impulse/trend-driven
3. **Long purchase cycles**: Users browse for weeks/months before buying
4. **High product diversity**: 22K+ SKUs, most purchased only once

### Potential Next Steps

1. **Targeting** - Focus recs on users with high purchase propensity (recent cart activity)
2. **Timing** - Generate recs closer to email send time
3. **Different metrics** - Measure CTR (engagement) not just match rate (conversion)
4. **Larger evaluation window** - 21 days may be too short for automotive parts cycle

---

## V5.15: Universal + Fitment Products

**Hypothesis**: V5.12 only recommends fitment products, missing 70% of VFU purchases. Adding universal products should dramatically improve match rate.

**Changes**:
- Add universal products (NOT in fitment catalog) to recommendation pool
- Fitment products: Still require YMM match
- Universal products: Available to ALL users (no YMM filter needed)
- Limit to top 500 universal products by popularity

**Results (Dec 16 - Jan 5 backtest)**:
| Metric | V5.12 | V5.15 | Improvement |
|--------|-------|-------|-------------|
| Buyers matched | 375 | **983** | **+162%** (2.6x) |
| Total matches | 538 | **1,823** | **+239%** (3.4x) |
| Fitment matches | 538 | 538 | 0% |
| Universal matches | 0 | 1,285 | NEW |
| Match rate (buyers) | 27.8% | **72.9%** | +45pp |

**Why It Worked**:
- VFU purchases are 70.2% universal products (gauges, sensors, electronics)
- V5.12 could only recommend 29.8% of products users actually buy
- Universal products have comparable intent signals (23.8%) to fitment (27.9%)
- Adding top 500 universal products captures the most popular items

**Key Insight**: The recommendation pool was fundamentally too narrow. Adding universal products expanded addressable purchases from 30% to 100%.

---

*Last updated: 2026-01-07*
