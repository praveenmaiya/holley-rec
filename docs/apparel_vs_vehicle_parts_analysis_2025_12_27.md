# Apparel vs Vehicle Parts Analysis

**Date:** 2025-12-27
**Context:** Sumeet raised concern that generic apparel recommendations may be outperforming vehicle part recommendations, suggesting the recommendation logic over-indexed on vehicle parts.

## Executive Summary

**Finding:** Vehicle parts dominate Holley's business (96% of orders, 98% of revenue). Apparel/safety gear is a small but consistent category (4% of orders, 2% of revenue). The vehicle-centric recommendation approach is correctly aligned with the business.

**Recommendation:** No major change to recommendation logic needed. Consider a hybrid approach for users who show strong apparel affinity.

---

## Data Analysis

### Overall Category Split

| Category | Order Lines | % of Orders | Est. Revenue | % of Revenue | Avg Price |
|----------|-------------|-------------|--------------|--------------|-----------|
| Vehicle Parts | 218,894 | 95.9% | $43.8M | 98.2% | $274.12 |
| Apparel/Safety | 9,367 | 4.1% | $801K | 1.8% | $100.07 |

**Key Insight:** Vehicle parts have 2.7x higher average order value than apparel.

### Time Period Comparison

| Period | Category | Order Lines | Units | Unique Orders |
|--------|----------|-------------|-------|---------------|
| Prior 3mo (Apr-Jun) | Vehicle Parts | 142,964 | 152,277 | 67,327 |
| Prior 3mo (Apr-Jun) | Apparel/Safety | 6,135 | 5,473 | 3,466 |
| Recent 3mo (Jul-Sep) | Vehicle Parts | 75,930 | 81,203 | 38,816 |
| Recent 3mo (Jul-Sep) | Apparel/Safety | 3,232 | 2,560 | 1,971 |

**Apparel share:** 4.1% (Prior) → 4.1% (Recent) - **No growth trend**

### Monthly Trend

| Month | Apparel Units | Parts Units | Apparel % |
|-------|---------------|-------------|-----------|
| 2025-01 | 519 | 18,689 | 2.7% |
| 2025-02 | 896 | 24,744 | 3.5% |
| 2025-03 | 1,152 | 33,688 | 3.3% |
| 2025-04 | 1,159 | 25,816 | **4.3%** |
| 2025-05 | 1,118 | 30,912 | 3.5% |
| 2025-06 | 710 | 20,816 | 3.3% |
| 2025-07 | 721 | 18,552 | 3.7% |
| 2025-08 | 586 | 22,765 | 2.5% |
| 2025-09 | 671 | 23,178 | 2.8% |
| 2025-10 | 501 | 14,320 | 3.4% |

**Trend:** Apparel peaked in April (4.3%) but has declined since. No upward trend.

### Price Distribution

#### Vehicle Parts
| Price Bucket | Order Lines | Units | Revenue | % of Parts Revenue |
|--------------|-------------|-------|---------|-------------------|
| <$50 | 62,856 | 84,684 | $1.69M | 3.9% |
| $50-99 | 24,951 | 24,482 | $1.75M | 4.0% |
| $100-199 | 25,248 | 25,339 | $3.84M | 8.8% |
| $200-499 | 33,021 | 30,853 | $10.18M | 23.2% |
| $500-999 | 13,365 | 12,192 | $8.23M | 18.8% |
| **$1000+** | 12,042 | 11,012 | **$18.12M** | **41.3%** |

**Key Insight:** 60% of vehicle parts revenue comes from items $500+. High-value parts are the core business.

#### Apparel/Safety
| Price Bucket | Order Lines | Units | Revenue | % of Apparel Revenue |
|--------------|-------------|-------|---------|---------------------|
| <$50 | 4,602 | 3,743 | $72K | 9.0% |
| $50-99 | 935 | 879 | $71K | 8.8% |
| $100-199 | 1,476 | 1,455 | $214K | 26.7% |
| **$200-499** | 1,449 | 1,309 | **$344K** | **42.9%** |
| $500-999 | 158 | 150 | $91K | 11.4% |
| $1000+ | 8 | 8 | $9K | 1.1% |

**Key Insight:** Apparel revenue is driven by mid-range safety gear ($200-499), not cheap t-shirts.

### Top Selling Items

#### Apparel/Safety (by units)
| SKU | Type | Units |
|-----|------|-------|
| 10434-XLHOL | T-Shirt | 78 |
| 10434-LGHOL | T-Shirt | 71 |
| 610353 | T-Shirt | 68 |
| 276915RQP | Helmet | 67 |
| 276666RQP | Helmet | 64 |

#### Vehicle Parts (by units)
| SKU | Type | Units |
|-----|------|-------|
| 36-525 | License Plate Bracket | 2,447 |
| PREAUTH-PCM | PCM | 1,661 |
| 9728 | Spark Plug Wire Holder | 1,538 |
| 750066ERL | Fuel Hose | 1,408 |
| 558-443 | Programmer Cable | 1,330 |

---

## Conclusions

### Question: Has apparel always been a significant purchase category?

**Answer: No.** Apparel/Safety is a consistent but minor category:
- 4% of orders (stable, not growing)
- 2% of revenue
- Lower average order value ($100 vs $274)

### Question: Did we miss something when designing the vehicle-centric system?

**Answer: The vehicle-centric approach is correct** for the dominant use case:
- 96% of orders are vehicle parts
- 98% of revenue comes from vehicle parts
- High-value parts ($500+) drive 60% of revenue

### Why might apparel recommendations appear to perform well?

Possible explanations:
1. **Novelty effect** - Users see something unexpected, click out of curiosity
2. **Lower barrier** - $30 t-shirt vs $500 exhaust system
3. **Cross-sell opportunity** - Vehicle buyers also interested in merch

---

## Recommendations

### Short Term (No Change)
The current vehicle-centric recommendation system is correctly aligned with the business.

### Medium Term (Consider)
1. **Hybrid approach for high-apparel users**: If a user's purchase history is >50% apparel, consider mixing apparel into their recommendations
2. **Cross-sell after purchase**: After a vehicle part order, show branded apparel as a follow-up

### Long Term (Monitor)
Track apparel share monthly. If it trends above 10%, reconsider the recommendation mix.

---

## Methodology

- **Data source:** `import_orders` joined with `import_items` (PartType classification)
- **Price source:** `Viewed Product` events (double_value from Price property)
- **Time period:** Last 6 months (Apr-Oct 2025)
- **Apparel definition:** T-Shirt, Racing Suit, Racing Shoes, Racing Gloves, Racing Jacket, Racing Underwear, Jacket, Hoodie, Hat, Baseball Cap, Sweatshirt, Fire Resistant Underwear, Button-Down Shirt, Polo Shirt, Helmet, Head and Neck Restraint, Safety Harness
