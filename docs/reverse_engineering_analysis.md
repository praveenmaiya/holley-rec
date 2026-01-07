# Reverse Engineering Analysis

**Goal**: Understand actual purchase patterns to build better recommendations
**Data**: Sep 2025 - Jan 2026 purchases by vehicle fitment users
**Date**: 2026-01-07

---

## Executive Summary

**The core problem**: Only ~5% of purchases are both (1) fitment-matched AND (2) predictable via intent signals. Our algorithm can only address this 5% segment, which explains the 0.02% match rate ceiling.

---

## 1. Purchase Funnel Analysis (5-Month Average)

| Metric | Value | Implication |
|--------|-------|-------------|
| Total purchases/month | ~5,000 | By vehicle fitment users |
| Unique buyers/month | ~2,000 | Average 2.5 items/buyer |
| Fits registered vehicle | **17%** | Only 17% buy fitment-matched products |
| Had prior view signal | 17% | Viewed exact SKU before buying |
| Had prior cart signal | 12% | Carted exact SKU before buying |
| Any intent signal | 20% | View OR cart |
| **Fits AND Intent** | **5%** | Golden segment (predictable) |
| Cold (no signal) | **66%** | Completely unpredictable |

---

## 2. Product Category Breakdown (Dec 2025)

| Category | Purchases | % | Addressable? |
|----------|-----------|---|--------------|
| Fits registered vehicle | 830 | 20% | ✓ Current target |
| Fits OTHER vehicle | 678 | 16% | Partial (multi-vehicle users) |
| Universal (not in catalog) | 2,656 | 64% | ✗ Cannot recommend via fitment |

**Key insight**: 64% of purchases are products NOT in the fitment catalog:
- Gauges (Air/Fuel Ratio, Fuel Pressure)
- Electronics (Harnesses, Connectors, Computer Chips)
- Safety gear (Helmet Shields)
- Sensors (Oxygen, Pressure)

---

## 3. Signal Strength by Lookback Window (Dec 2025)

| Window | View Signal | Cart Signal | Any Signal |
|--------|-------------|-------------|------------|
| 7 days | 12.6% | 11.4% | 15.9% |
| 14 days | 14.8% | 12.8% | — |
| 30 days | 16.3% | 13.8% | 19.3% |
| 60 days | 17.6% | 14.4% | 20.5% |
| 90 days | 18.0% | 14.9% | 21.2% |

**Key insight**:
- 7-day window captures 75% of total signal (15.9/21.2)
- Diminishing returns beyond 30 days
- Cart signal almost as strong as view signal

---

## 4. Timing Analysis

| Metric | Average | Range |
|--------|---------|-------|
| Days from view to purchase | 9 days | 3-13 days |
| Days from cart to purchase | 7 days | 3-10 days |

**Key insight**: Most purchases happen within 14 days of intent signal

---

## 5. Why Match Rate Is Hard to Improve

### Current Algorithm Addressable Market
```
473K users × 0.02% match rate = ~97 matches

Where that 0.02% comes from:
- 473K users get recommendations
- ~2K make purchases (0.4% buy rate)
- Of buyers: 17% buy fitment products (340)
- Of those: 5% had intent signal (~17)
- 17 / 473K = 0.004% (lower bound)
```

### Fundamental Constraints

1. **64% of purchases are unreachable** - Products not in fitment catalog
2. **17% fits but no intent** - We recommend these but can't predict timing
3. **16% wrong vehicle** - User has multiple vehicles; we recommend for wrong one
4. **Only 5% is predictable** - Both fits AND showed intent

---

## 6. Algorithm Recommendations

### Option A: Stay with V5.12 (Current Best)
- Match rate: 0.0205%
- Pro: Simple, stable
- Con: Near ceiling

### Option B: Target High-Intent Users
**New approach**: Only recommend to users with recent cart activity
```
WHERE user has cart event in last 7 days
```
- Reduces population from 473K to ~10K
- Higher match rate among targeted users
- Trade-off: Fewer users get recommendations

### Option C: Add Universal Products
**Expand recommendation pool**:
- Include top-selling universal products (gauges, sensors)
- Recommend based on purchase patterns, not fitment
- Could address the 64% currently unreachable

### Option D: Multi-Vehicle Support
**User has 16% buying for "other" vehicle**:
- Add v2_year/make/model attributes
- Recommend for multiple vehicles
- Could capture additional 16% of purchases

---

## 7. Recommended Next Steps

1. **Short term**: Keep V5.12, it's at the practical ceiling for fitment-only recs
2. **Medium term**: Test targeting high-intent users (Option B)
3. **Long term**: Expand to universal products (Option C) or multi-vehicle (Option D)

---

## Key Data Sources

| Table | Used For |
|-------|----------|
| `ingestion_unified_schema_incremental` | Purchase events, view/cart signals |
| `ingestion_unified_attributes_schema_incremental` | User vehicle data |
| `vehicle_product_fitment_data` | SKU → Vehicle mapping |
| `import_items` | Product catalog (PartType) |

---

*Analysis completed: 2026-01-07*
