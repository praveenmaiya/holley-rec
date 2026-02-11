# Root Cause Analysis: Why Personalized Recommendations Underperform

**Date**: 2026-01-03
**Issue**: AUX-11136 - Post launch data analysis
**Period**: Last 60 days
**Author**: Claude Code analysis

---

## Executive Summary

The Personalized recommendation system optimizes for **fitment coverage** (products that fit the user's vehicle) but ignores **purchase probability**. This leads to recommending products that technically fit but have low demand, while ignoring high-demand products with narrow/universal fitment.

**The smoking gun**: 0% of users who received Personalized recommendations bought what was recommended, despite 97% having valid recommendations and 61% making a purchase.

---

## The Core Problem: Algorithm Optimizes for Wrong Objective

```
FITMENT vs SALES PARADOX
========================

SKU         │ Vehicles Fit │ Recommended To │ Actually Bought │ Ratio
────────────┼──────────────┼────────────────┼─────────────────┼───────
0-80457S    │    3,891     │     389        │      17         │ 0.04x ◄ MOST recommended, LEAST bought
LFRB155     │    3,213     │     675        │     122         │ 0.18x
84130-3     │      641     │     261        │     498         │ 1.91x
RA003B      │      320     │     126        │     648         │ 5.14x
RA007       │       34     │     N/A        │     706         │ ∞    ◄ LEAST fitment, MOST bought!
```

**The algorithm recommends products that fit MANY vehicles, but customers buy products that fit FEW vehicles.**

### Product Details

| SKU | Product Type | Brand | Vehicles Fit | Sales (60d) |
|-----|--------------|-------|--------------|-------------|
| 0-80457S | Carburetor | BBVL | 3,891 | 17 |
| LFRB155 | Headlight | JRDL | 3,213 | 122 |
| 84130-3 | Vehicle Performance Monitor | BKDQ | 641 | 498 |
| RA003B | Multi-Function Module | FNBR | 320 | 648 |
| RA007 | Multi-Function Module | FNBR | 34 | 706 |

---

## Key Evidence

### 1. Zero Match Rate

```
Personalized Recipients Analysis (60 days)
──────────────────────────────────────────
Users sent Personalized:     2,307
Users with recommendations:  2,244 (97%)
Users who ordered:           1,411 (61%)
Users who bought what was recommended: 0 (0%!)
```

### 2. Click-to-Order Conversion Favors Static

```
Treatment    │ Clickers │ Converted │ Conv Rate │ Avg Item │ Revenue
─────────────┼──────────┼───────────┼───────────┼──────────┼─────────
Personalized │     68   │    43     │   63.2%   │  $237    │ $12.3K
Static       │    283   │   218     │   77.0%   │  $377    │ $96.2K
```

Static clickers convert better AND buy more expensive items!

### 3. What Clickers Actually Buy

```
After Personalized:              After Static:
─────────────────────            ──────────────
Air & Fuel: $7.7K (avg $387)     Air & Fuel: $51.8K (avg $700)
Other Parts: $4.3K               Other Parts: $37.5K
Apparel: $5 (1 item!)            Apparel: $376 (18 items)
```

Even Static (Apparel) email clickers buy mostly vehicle parts at HIGHER prices!

### 4. Sample: Recommended vs Actually Bought

| Recommended SKU | Rec Price | Ordered SKU | Ordered Price |
|-----------------|-----------|-------------|---------------|
| 84130-3 | $511.95 | EXT-SHIP-PROTECTION | $1.95 |
| 84130-3 | $511.95 | DGM17PLUSUNLK | $40.00 |
| 84130-3 | $511.95 | 550-932T | $1,609.95 |
| LFRB155 | $237.95 | 522-488 | $583.95 |
| 84130-3 | $511.95 | 30-0300 | $196.15 |

Users completely ignore recommendations and buy different products.

---

## Root Causes Identified

| # | Issue | Evidence | Impact |
|---|-------|----------|--------|
| 1 | **Fitment breadth optimization** | Top recs fit 3000+ vehicles, top sellers fit <100 | Wrong products shown |
| 2 | **Ignores purchase probability** | 0% of recipients bought recommended products | Complete mismatch |
| 3 | **No popularity signal** | RA007 (706 sales) rarely recommended | Missing conversion signal |
| 4 | **Cold-start problem** | Algorithm needs vehicle data, but top products are universal | Coverage gap |

---

## Why Static Outperforms

The paradox explained:

1. **Static shows apparel** → Low friction impulse buy option
2. **But users ignore apparel** → Buy vehicle parts anyway
3. **Static recipients are browsing** → Already engaged, buy what they came for
4. **Personalized shows wrong parts** → User sees irrelevant rec, ignores it, buys something else

**The Personalized recommendations are actively ANTI-helpful** — showing products users don't want based on fitment that's too broad.

---

## Recommended Fixes

### Immediate Actions

1. **Add purchase probability to scoring**
   - Weight by sales velocity, not just fitment
   - Formula: `score = fitment_score * log(sales_count + 1)`

2. **Narrow recommendations**
   - Products fitting 100-500 vehicles may convert better than 3000+
   - Test hypothesis: narrow fitment = higher purchase intent

3. **Cold-start fallback**
   - For users without vehicle data, show top sellers by category
   - Current: 93% of buyers have no vehicle data

### Strategic Changes

4. **Test hybrid approach**
   - Slot 1: Top seller that fits vehicle
   - Slots 2-3: Fitment-specific recommendations

5. **Add feedback loop**
   - Track which recommendations are clicked/bought
   - Down-weight products that are shown but never purchased

6. **Consider universal products**
   - Top sellers (RA007, RA003B) may not have extensive fitment data
   - These are "universal" products that work across vehicles

---

## Data Sources

```sql
-- Treatment sends
`auxia-gcp.company_1950.treatment_history_sent`
  WHERE treatment_id IN (16150700, 20142778, 20142785, ...)

-- Treatment interactions
`auxia-gcp.company_1950.treatment_interaction`

-- Orders
`auxia-gcp.company_1950.ingestion_unified_schema_incremental`
  WHERE event_name = 'Ordered Product'

-- Recommendations
`auxia-reporting.company_1950_jp.final_vehicle_recommendations`

-- Vehicle fitment
`auxia-gcp.data_company_1950.vehicle_product_fitment_data`

-- User attributes (email mapping)
`auxia-gcp.company_1950.ingestion_unified_attributes_schema_incremental`
```

---

## Related Documents

- `docs/buying_behavior_analysis_2026_01_02.md` - Buying behavior analysis
- `docs/post_launch_conversion_analysis_2026_01_02.md` - Conversion analysis
- `docs/analysis/treatment_ctr_unbiased_analysis_2025_12_17.md` - CTR MECE analysis
- `specs/v5_6_recommendations.md` - Current recommendation spec

---

*Generated by Claude Code for AUX-11136*
