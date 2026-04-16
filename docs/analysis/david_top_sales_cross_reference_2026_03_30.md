# David's Top Sales by YMM — Cross-Reference Analysis

**Ticket:** AUX-13883
**Date:** 2026-03-30
**Data source:** David Stephens' top-5-products-by-YMM sales file (2026-03-13)
**Production table:** `company_1950_jp.final_vehicle_recommendations`
**Codex reviews:** 2 rounds (2026-03-26 filter funnel, 2026-03-30 filter analysis)

---

## David's Data Profile

```
Total rows ............. 66,860
Unique products ........    944
Unique YMMs ............ 21,085
Year range ............. 1928–2027
Divisions .............. 3
Categories ............. 12
```

**By Category:**

| Category | Rows | % | Products |
|---|---|---|---|
| EFI & IGNITION | 24,737 | 37.0% | 243 |
| ACCESSORIES | 16,632 | 24.9% | 119 |
| EURO & IMPORT | 10,744 | 16.1% | 153 |
| CARBURETORS & FUEL | 4,275 | 6.4% | 11 |
| DOMESTIC TUNING | 3,278 | 4.9% | 93 |
| OFF-ROAD SUSPENSION | 2,308 | 3.5% | 54 |
| ENGINE SWAP & FITTINGS | 1,694 | 2.5% | 68 |
| EXHAUST | 1,183 | 1.8% | 100 |
| WHEELS & TRUCK | 1,087 | 1.6% | 19 |
| BRAKES | 460 | 0.7% | 49 |
| RESTORATION | 433 | 0.6% | 26 |
| INSTRUMENTATION | 29 | 0.0% | 9 |

**By Division:**

| Division | Rows | % | Products |
|---|---|---|---|
| AMERICAN PERFORMANCE | 47,800 | 71.5% | 476 |
| EURO & IMPORT | 10,744 | 16.1% | 153 |
| TRUCK AND OFF-ROAD | 8,316 | 12.4% | 315 |

---

## YMM Coverage

```
David's YMMs ............. 21,085  (100%)
In our prod recs ..........  9,794  (46.5%)
Not in our recs ........... 11,291  (53.5%)  ← no registered email users

Bidirectional:
  David → Us:   9,794 / 21,085 = 46.5%
  Us → David:   9,794 /  9,794 = 100.0%
  Jaccard:      46.5%
```

Every YMM we serve appears in David's data. The 53.5% gap is entirely vehicles David sells for but where we have no registered email users.

---

## Filter Analysis: David's 944 Products vs v5.18 Pipeline Gates

Mirrors exact production SQL (`v5_18_fitment_recommendations.sql`). Validated by 2 Codex peer reviews.

### Gate-by-gate (individual filters)

| Gate | Pass | Fail | Notes |
|---|---|---|---|
| Fitment catalog | 888 | 56 | Hard gate: must exist in fitment data |
| Refurbished | 941 | 3 | Tags LIKE '%refurbished%' |
| Prefix exclusion | 944 | 0 | EXT-/GIFT-/WARRANTY-/SERVICE-/PREAUTH- |
| Commodity PartType | 936 | 8 | Gasket/Decal/Key/Washer/Clamp |
| Price ≥ $50 | 837 | 107 | Event-derived, COALESCE fallback to $50 |
| Image required | 918 | 26 | Event-derived from sku_image_urls |
| UNKNOWN + low price | 937 | 7 | PartType=UNKNOWN and price<3000 |
| **Purchase signal** | **575** | **369** | **Must have segment/make/global popularity** |

### True distinct result (no double-counting)

```
Pass ALL gates ........... 438  (46.4%)
Fail ANY gate ............ 506  (53.6%)
```

### Failure decomposition

```
Single gate failure ...... 447  (88% of failures)
  No purchase signal ..... 318  ← 63% of all failures
  Price < $50 .............  74
  Not in fitment ..........  38
  No image ................  11
  Commodity PartType ......   3
  Refurbished .............   3

Double failure ............  49
Triple+ failure ...........  10
```

**The #1 filter is `require_purchase_signal`:** 369 of David's 944 products have zero purchase history in our email user data. Our algorithm has no signal to score them.

### Row-weighted impact (David's 66,860 rows)

| Metric | Rows | % |
|---|---|---|
| Rows with eligible products | 51,787 | 77.5% |
| Rows with ineligible products | 15,073 | 22.5% |
| ↳ No purchase signal | 8,450 | |
| ↳ Price < $50 | 6,398 | |
| ↳ No image | 965 | |
| ↳ Not in fitment | 924 | |
| ↳ UNKNOWN safeguard | 205 | |
| ↳ Refurbished | 130 | |
| ↳ Commodity PartType | 20 | |

### By category

| Category | SKUs | Pass | Fail | Pass Rate |
|---|---|---|---|---|
| DOMESTIC TUNING | 93 | 84 | 9 | 90.3% |
| ACCESSORIES | 119 | 71 | 48 | 59.7% |
| EFI & IGNITION | 243 | 144 | 99 | 59.3% |
| EXHAUST | 100 | 46 | 54 | 46.0% |
| CARBURETORS & FUEL | 11 | 5 | 6 | 45.5% |
| RESTORATION | 26 | 10 | 16 | 38.5% |
| EURO & IMPORT | 153 | 42 | 111 | 27.5% |
| BRAKES | 49 | 12 | 37 | 24.5% |
| INSTRUMENTATION | 9 | 2 | 7 | 22.2% |
| ENGINE SWAP | 68 | 14 | 54 | 20.6% |
| WHEELS & TRUCK | 19 | 3 | 16 | 15.8% |
| OFF-ROAD SUSPENSION | 54 | 5 | 49 | 9.3% |

---

## User-Level Hit Rate

For each of our 455K users: how many of their 4 recs match David's top 5 for their vehicle?

```
0 of 4 recs match ......... 206,366  (45.3%)
1 of 4 recs match ......... 187,421  (41.1%)
2 of 4 recs match .........  45,695  (10.0%)
3 of 4 recs match .........  12,286  ( 2.7%)
4 of 4 recs match .........   3,785  ( 0.8%)

At least 1 match .......... 249,187  (54.7%)
```

---

## Per-YMM Hit Distribution

Of the 9,794 YMMs we both cover: how many of David's top 5 do we match?

```
0 of 5 matched ............ 2,227  (22.8%)
1 of 5 matched ............ 3,488  (35.7%)
2 of 5 matched ............ 2,304  (23.6%)
3 of 5 matched ..............951  ( 9.7%)
4 of 5 matched ..............781  ( 8.0%)
5 of 5 matched ...............10  ( 0.1%)

At least 1 match .......... 7,534  (77.2%)
At least 3 matches ........ 1,742  (17.8%)
```

### Hit rate by David's sales rank

```
David's #1 seller ......... 57.2% in our recs
David's #2 seller ......... 55.0%
David's #3 seller ......... 36.0%
David's #4 seller ......... 38.8%
David's #5 seller ......... 30.8%
```

---

## Why "More Users = Fewer Matches"

Inverse correlation confirmed (not a query artifact). Root cause: **popularity tier fallback**, NOT collaborative filtering (v5.18 has no CF).

| Pop Source | Avg Users | Avg Hits | ≥1 Match |
|---|---|---|---|
| Global | 7 | 2.28 | 96.0% |
| Make | 28 | 1.29 | 72.4% |
| Segment | 195 | 1.08 | 75.0% |

Sparse YMMs fall back to **global popularity** (aligns with David's sales). Dense YMMs use **segment popularity** (more targeted, diverges from David).

Pop source distribution by user density:

```
1 user:     1.6% segment |  67.1% make | 31.3% global
2–5:        4.8% segment |  72.0% make | 23.2% global
6–20:       9.7% segment |  74.1% make | 16.2% global
21–100:    28.9% segment |  65.1% make |  5.9% global
100+:      66.9% segment |  32.4% make |  0.7% global
```

---

## Make/Model Benchmark

Our scorer ranks at make/model level, not year/make/model. At the same granularity:

| Hit Rate | Make/Models | Avg Hit % |
|---|---|---|
| 0% | 75 | 0.0% |
| 1–25% | 263 | 19.5% |
| 26–50% | 608 | 39.8% |
| 51–75% | 294 | 63.5% |
| 76–100% | 310 | 86.4% |

78% of make/models have 26%+ overlap with David's top sellers.

---

## Key Takeaways

1. **54% of David's unique products can't surface in our recs** — dominated by no purchase signal (63% of failures), not price or fitment.
2. **Of the 46% that are eligible, we match 57% of David's #1 sellers** at the YMM level.
3. **The gap is structural**: David's sales data covers all channels; our pipeline only sees email user behavior. Products that sell well at retail/dealers but aren't browsed by email users have no signal for our algorithm.
4. **Category variance is extreme**: Domestic Tuning passes 90%, Off-Road Suspension passes 9%.
5. **Our scorer operates at make/model granularity** while David's benchmark is year-specific — this explains much of the residual divergence for covered YMMs.

---

## Data Locations

| Asset | Location |
|---|---|
| David's original CSV | `/Users/praveenm/dev/auxia/docs/20260313 - Top Sales by YMM  .csv` |
| BQ raw data | `temp_holley_v5_18.david_top_sales_by_ymm` |
| BQ v1 enrichment | `temp_holley_v5_18.david_top_sales_enriched` |
| BQ v2 enrichment | `temp_holley_v5_18.david_top_sales_enriched_v2` |
| Local CSV v1 | `data/processed/top_sales_by_ymm_enriched.csv` |
| Local CSV v2 | `data/processed/top_sales_by_ymm_enriched_v2.csv` |
| Enrichment SQL | `sql/analysis/aux_13883_v2_enrichment.sql` |
| Summary SQL | `sql/analysis/aux_13883_v2_summary.sql` |
| Codex review 1 | `docs/2026-03-26-codex-review-aux13883-funnel-*.md` |
| Codex review 2 | `docs/2026-03-30-codex-review-filter-analysis-*.md` |

---

## Codex Review History

| Round | Date | Findings | Key Fix |
|---|---|---|---|
| 1 | 2026-03-26 | 1C 3H 3M 1L | Wrong CF explanation → corrected to popularity tiers |
| 2 | 2026-03-30 | 1C 2H 2M 1L | Missing `require_purchase_signal` gate; "14%" → "54%" |
