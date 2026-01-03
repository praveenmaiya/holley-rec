# Buying Behavior Analysis

**Date**: 2026-01-02
**Issue**: AUX-11136 - Post launch data analysis
**Period**: Last 60 days
**Author**: Claude Code analysis

---

## Executive Summary

Analysis of 24,478 orders reveals that the Holley business is dominated by high-value vehicle parts, with apparel representing only **0.4% of revenue**. Users exhibit single-item purchasing behavior with an average order value of $300.

---

## 1. Product Category Breakdown

```
                     CATEGORY DISTRIBUTION BY REVENUE
┌──────────────────────────────────────────────────────────────────┐
│ Vehicle Parts     ████████████████████████████████████ 85.1%    │
│ Unknown           ████████ 12.1%                                │
│ Safety Gear       ██ 2.5%                                       │
│ Apparel           ▏ 0.4%                                        │
└──────────────────────────────────────────────────────────────────┘
```

| Category | Items | Buyers | Revenue | Avg Price | % Revenue |
|----------|-------|--------|---------|-----------|-----------|
| **Vehicle Parts** | 16,917 | 16,110 | $6.25M | $369 | 85.1% |
| Unknown | 6,662 | 6,452 | $889K | $133 | 12.1% |
| Safety Gear | 381 | 369 | $183K | $479 | 2.5% |
| **Apparel** | 530 | 514 | **$26K** | **$50** | **0.4%** |

**Key Insight**: Apparel is only **0.4% of revenue** - a tiny fraction. The business is dominated by high-value vehicle parts.

---

## 2. Basket Composition

```
                    ORDER VALUE DISTRIBUTION

$0-50      ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  31.1% orders │  1.7% rev
$50-100    ▓▓▓▓▓▓▓▓▓▓▓▓                     11.5% orders │  2.8% rev
$100-200   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓                  14.3% orders │  7.1% rev
$200-500   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓       25.7% orders │ 27.1% rev  ◄ Sweet Spot
$500-1000  ▓▓▓▓▓▓▓▓▓▓▓                      10.5% orders │ 23.5% rev
$1000-2000 ▓▓▓▓▓▓                            5.6% orders │ 27.1% rev  ◄ High Value
$2000+     ▓▓                                1.3% orders │ 10.7% rev
```

| Metric | Value |
|--------|-------|
| **Total Orders** | 24,478 |
| **Unique Buyers** | 23,077 |
| **Avg Items/Order** | **1.0** (single-item orders!) |
| **Avg Order Value** | **$300** |
| **Order Range** | $0.01 - $6,543 |

**Key Insight**: Almost **100% single-item orders**. Users buy ONE specific part per transaction.

---

## 3. Top Selling Products

| Rank | Product | Brand | Price | Qty | Revenue |
|------|---------|-------|-------|-----|---------|
| 1 | Insight CTS3 (Monitor) | Edge | $451 | 498 | $224K |
| 2 | DFM Module GM Refresh | Range Tech | $227 | 706 | $160K |
| 3 | AFM/DFM Disabler-Blue | Range Tech | $236 | 648 | $153K |
| 4 | Terminator X Max LS1/LS6 | Holley EFI | $1,667 | 53 | $88K |
| 5 | AFM/DFM Disabler-Red | Range Tech | $236 | 344 | $81K |

**Key Insight**: AFM/DFM Disablers dominate volume (Range Tech), while Holley EFI Terminator systems drive high-value sales.

---

## 4. Buying Patterns by Treatment Type

### After Personalized Treatments (Vehicle Fitment Emails):

```
                         PRODUCT TYPE
┌─────────────────────────────────────────────┐
│ Vehicle Parts    ██████████████████ 78.3%   │ $39.8K revenue
│ Unknown          █████ 19.7%                │ $1.4K
│ Apparel          ▏ 1.9%                     │ $75
└─────────────────────────────────────────────┘
Avg Price: $324  │  110 users ordered
```

### After Static Treatments (Apparel Emails):

```
                         PRODUCT TYPE
┌─────────────────────────────────────────────┐
│ Vehicle Parts    █████████████████ 66.2%    │ $203K revenue
│ Unknown          ████████ 31.7%             │ $89K
│ Apparel          ▏ 2.1%                     │ $530
└─────────────────────────────────────────────┘
Avg Price: $239  │  736 users ordered
```

**Key Insight**: Even after receiving Static (Apparel) emails, users still primarily buy **Vehicle Parts** (66%)! Apparel conversion is only 2%.

### Detailed Category Breakdown

#### After Personalized Treatments:
| Category | Items | Revenue | Avg Price |
|----------|-------|---------|-----------|
| Air & Fuel Delivery | 69 | $28,402 | $412 |
| Deals | 33 | $8,597 | $261 |
| Unknown | 31 | $1,403 | $45 |
| All Exhaust | 2 | $746 | $373 |
| Safety Equipment | 1 | $425 | $425 |

#### After Static Treatments:
| Category | Items | Revenue | Avg Price |
|----------|-------|---------|-----------|
| Unknown | 389 | $88,959 | $229 |
| Air & Fuel Delivery | 273 | $83,968 | $308 |
| Deals | 258 | $67,797 | $263 |
| Helmets | 7 | $8,446 | $1,207 |
| AFM | 20 | $5,531 | $277 |

---

## 5. Price Tier by Treatment

```
PRICE TIER DISTRIBUTION (% of items purchased)

           Personalized                    Static
Under $50  ████████████████████ 42.7%     ████████████████████ 38.7%
$50-100    █████ 9.6%                     ██████ 13.1%
$100-200   ██████ 12.1%                   ███████ 15.0%
$200-500   ██████████ 20.4%               ██████████ 20.1%
$500-1000  █████ 8.9%                     █████ 8.5%
$1000+     ███ 6.4%                       ██ 4.6%
```

| Treatment | Price Tier | Items | Revenue | % Items |
|-----------|------------|-------|---------|---------|
| Personalized | Under $50 | 67 | $1,200 | 42.7% |
| Personalized | $50-100 | 15 | $1,084 | 9.6% |
| Personalized | $100-200 | 19 | $2,950 | 12.1% |
| Personalized | $200-500 | 32 | $10,459 | 20.4% |
| Personalized | $500-1000 | 14 | $9,527 | 8.9% |
| Personalized | $1000+ | 10 | $16,100 | 6.4% |
| Static | Under $50 | 475 | $8,522 | 38.7% |
| Static | $50-100 | 160 | $11,889 | 13.1% |
| Static | $100-200 | 184 | $28,160 | 15.0% |
| Static | $200-500 | 247 | $80,997 | 20.1% |
| Static | $500-1000 | 104 | $69,470 | 8.5% |
| Static | $1000+ | 56 | $93,577 | 4.6% |

**Key Insight**: ~40% of items in both treatments are under $50, but the **high-value items ($200+) drive the revenue**.

---

## 6. Where Apparel Fits

| Apparel Category | Items | Orders | Revenue | Avg Price |
|-----------------|-------|--------|---------|-----------|
| Apparel & Collectibles | 316 | 316 | $5,939 | $18.79 |
| Apparel and Collectibles | 97 | 97 | $4,360 | $44.95 |
| Racing Suits | 22 | 22 | $4,544 | $206.55 |
| Gloves | 24 | 24 | $3,661 | $152.53 |
| Cosmetics and Gear | 43 | 40 | $4,005 | $93.14 |
| **Total Apparel** | **~550** | **~540** | **~$26K** | **$47** |

**Key Insight**: Apparel contributes **<1% of revenue** with an average price of ~$47 vs $369 for vehicle parts.

---

## Summary Insights

1. **Apparel is negligible** (0.4% of revenue) - the Static treatment showing apparel isn't generating significant apparel sales

2. **Single-item orders dominate** - users come for ONE specific part, not baskets

3. **High-value vehicle parts drive revenue** - $200-$2000 price tier accounts for 61% of revenue

4. **Treatment paradox**: Static (Apparel) emails generate more total revenue ($203K) than Personalized ($40K), but users are buying **vehicle parts**, not apparel

5. **Top products are EFI systems and AFM Disablers** - these are the money makers

---

## Recommendations

### Product Strategy
1. **Focus on vehicle parts** - apparel is not a meaningful revenue driver
2. **Promote AFM/DFM Disablers** - high volume, good margins
3. **Upsell Holley EFI systems** - high AOV products

### Email Strategy
1. **Reconsider Static (Apparel) treatments** - users buy parts anyway, not apparel
2. **Test cross-sell in Personalized** - recommend complementary parts
3. **Focus on $200-$500 price tier** - sweet spot for conversion and revenue

### Further Investigation
1. Why is "Unknown" category 12% of revenue? Need category mapping fix
2. Are Static treatment buyers just more engaged users who would buy anyway?
3. Test hybrid approach: vehicle parts with apparel add-ons

---

## Data Sources

```sql
-- Ordered Products
`auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  WHERE event_name = 'Ordered Product'

-- Treatment History
`auxia-gcp.company_1950.treatment_history_sent`

-- Treatment Interactions
`auxia-gcp.company_1950.treatment_interaction`
```

---

## Related Documents

- `docs/post_launch_conversion_analysis_2026_01_02.md` - Conversion analysis
- `docs/treatment_ctr_unbiased_analysis_2025_12_17.md` - CTR MECE analysis
- `docs/apparel_vs_vehicle_parts_analysis_2025_12_27.md` - Previous category analysis

---

*Generated by Claude Code for AUX-11136*
