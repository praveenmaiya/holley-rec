# Holley Treatment Structure

Documentation of email treatment campaigns, recommendation types, and their organization.

**Last Updated:** 2026-01-19

---

## Overview

Holley email treatments are organized into **3 campaign types**, each with different recommendation strategies.

| Campaign Type | Trigger | Purpose |
|---------------|---------|---------|
| **Post Purchase** | After user completes an order | Cross-sell / upsell |
| **Browse Recovery** | User browses but doesn't buy | Re-engage browsers |
| **Abandon Cart** | User adds to cart but doesn't checkout | Recover abandoned carts |

---

## Campaign Type 1: Post Purchase

**Trigger:** User completes a purchase
**Goal:** Cross-sell complementary products
**Total Treatments:** 32

### Personalized Fitment Recommendations (10 treatments)

Vehicle-specific product recommendations based on user's Year/Make/Model (YMM).

| Treatment ID | Theme | Boost Factor | Status |
|--------------|-------|--------------|--------|
| 16150700 | Thanks | 100 | Active |
| 20142778 | Warm Welcome | 100 | Active |
| 20142785 | Relatable Wrencher | 100 | Active |
| 20142804 | Completer | 100 | Active |
| 20142811 | Momentum | 100 | Active |
| 20142818 | Weekend Warrior | 100 | Active |
| 20142825 | Visionary | 100 | Active |
| 20142832 | Detail Oriented | 100 | Active |
| 20142839 | Expert Pick | 100 | Active |
| 20142846 | Look Back | 100 | Active |

**Recommendation Source:** `auxia-reporting.company_1950_jp.final_vehicle_recommendations` (v5.17 pipeline)

### Static Recommendations (22 treatments)

Fixed product categories - same products shown to all recipients in that category.

| Treatment ID | Category | Boost Factor | Status |
|--------------|----------|--------------|--------|
| 16490932 | Sniper 2 Bluetooth Available | 1 | Active |
| 16490939 | Holley Apparel & Collectibles | 1 | Active |
| 16518436 | Air Cleaners General | 1 | Active |
| 16518443 | Retrobright | 1 | Active |
| 16564380 | Mr. Gasket Related Brands | 1 | Active |
| 16564387 | Tools | 1 | Active |
| 16564394 | Exhaust | 1 | Active |
| 16564401 | Cold Air Intakes | 1 | Active |
| 16564408 | Engine Hardware | 1 | Active |
| 16564415 | Brothers - Interior | 1 | Active |
| 16564423 | Brothers - LED Headlights | 1 | Active |
| 16564431 | Brothers - Grilles | 1 | Active |
| 16564439 | Brothers - Steering Column | 1 | Active |
| 16564447 | Brothers - Exterior | 1 | Active |
| 16564455 | Brothers - Interior 2 | 1 | Active |
| 16564463 | Brothers - Body/Rust Repair | 1 | Active |
| 16593451 | Brothers - Restoration | 1 | Active |
| 16593459 | Terminator X Transactional | 1 | Active |
| 16593467 | Terminator X Suggested Parts | 1 | Active |
| 16593475 | Terminator X CAN Input Output | 1 | Active |
| 16593483 | Wheels | 1 | Active |
| 16593491 | Tuners and Programmers | 1 | Active |

**Recommendation Source:** Manually curated product lists per category

---

## Campaign Type 2: Browse Recovery

**Trigger:** User browses products but doesn't purchase
**Goal:** Re-engage browsers with products they viewed
**Total Treatments:** 36

### Personalized Recommendations (25 treatments)

Shows browsed items PLUS additional personalized recommendations.

**Boost factor scales with browsed item count** (higher = more engaged user):

| # Browsed Items | Boost Factor | Treatment Count |
|-----------------|--------------|-----------------|
| 1 item | 100 | 5 |
| 2 items | 1,000 | 5 |
| 3 items | 10,000 | 5 |
| 4 items | 100,000 | 5 |
| 5 items | 1,000,000 | 5 |

**Messaging Themes (5 variants each):**
- Quick Picks Reminder
- Take Another Look
- Still Browsing Nudger
- Revisit Hot Items
- Round Two Alert

| Treatment ID Range | # Items | Theme | Boost |
|--------------------|---------|-------|-------|
| 21265193-21265214 | 1 | Various | 100 |
| 21265233-21265411 | 2 | Various | 1,000 |
| 21265240-21265418 | 3 | Various | 10,000 |
| 21265247-21265425 | 4 | Various | 100,000 |
| 21265260-21265438 | 5 | Various | 1,000,000 |
| 16150707 | 1 | Take Another Look | 100 |

### No Recommendations (11 treatments)

Shows ONLY the browsed items, no additional recommendations.

| Treatment ID | # Browsed Items | Theme | Boost Factor |
|--------------|-----------------|-------|--------------|
| 17049625 | 1 | Take Another Look | 1 |
| 21265451 | 2 | Take Another Look | 1 |
| 21265458 | 3 | Take Another Look | 1 |
| 21265465 | 4 | Take Another Look | 1 |
| 21265478 | 5 | Take Another Look | 1 |
| 21265485 | 1 | Second Look | 1 |
| 21265492 | 2 | Second Look | 1 |
| 21265499 | 3 | Second Look | 1 |
| 21265506 | 4 | Second Look | 1 |
| 21265513 | 5 | Second Look | 1 |

---

## Campaign Type 3: Abandon Cart

**Trigger:** User adds items to cart but doesn't complete checkout
**Goal:** Recover abandoned carts
**Total Treatments:** ~45

### Fitment Recommendations (~25 treatments)

Cart items PLUS vehicle-specific recommendations.

| # Cart Items | Boost Factor | Status |
|--------------|--------------|--------|
| 1 item | 200 | Active |
| 2 items | 2,000 | Active |
| 3 items | 20,000 | Active |
| 4 items | 200,000 | Mixed |
| 5 items | 2,000,000 | Paused |

**Messaging Themes:**
- Your Build is Almost There...
- Don't Drive Off Just Yet!
- Get Your Project Started!
- Complete Your Order Before It's Too Late!
- Take Another Look At Your Cart!
- Complete Your Checkout NOW!
- Your Cart Still Has Items Waiting For You!

**Active Treatment IDs (Fitment):**
- 16593503-16593531 (Your Build is Almost There)
- 18056699-18056732 (Don't Drive Off Just Yet)

### Static Recommendations (~20 treatments)

Cart items PLUS static category recommendations.

| # Cart Items | Boost Factor | Status |
|--------------|--------------|--------|
| 1 item | 200 | Mixed |
| 2 items | 2,000 | Mixed |
| 3 items | 20,000 | Mixed |
| 4 items | 200,000 | Paused |
| 5 items | 2,000,000 | Paused |

**Active Treatment IDs (Static):**
- 16444546 (1 Item - Your Build is Almost There)
- 17049596-17049603 (2-3 Items - Your Build is Almost There)

---

## Summary: Treatment Counts

| Campaign | Personalized Fitment | Personalized (Behavior) | Static | No Recs | Total |
|----------|---------------------|------------------------|--------|---------|-------|
| **Post Purchase** | 10 | 0 | 22 | 0 | 32 |
| **Browse Recovery** | 0 | 25 | 0 | 11 | 36 |
| **Abandon Cart** | ~25 | 0 | ~20 | 0 | ~45 |
| **Total** | ~35 | 25 | ~42 | 11 | ~113 |

---

## Boost Factor Logic

Boost factor determines treatment selection priority in the bandit model.

| Factor | Meaning |
|--------|---------|
| 1 | Lowest priority (baseline) |
| 100 | Standard personalized |
| 200 - 2,000,000 | Scales with cart/browse item count |

**Pattern:** More items in cart/browse = higher boost = higher priority

```
1 item:   200 (cart) / 100 (browse)
2 items:  2,000 / 1,000
3 items:  20,000 / 10,000
4 items:  200,000 / 100,000
5 items:  2,000,000 / 1,000,000
```

---

## Fair Comparison Guidelines

For valid A/B analysis, **only compare treatments within the same campaign type**:

| Campaign | Valid Comparison |
|----------|------------------|
| **Post Purchase** | Personalized Fitment (10) vs Static (22) |
| **Browse Recovery** | Personalized Recs (25) vs No Recs (11) |
| **Abandon Cart** | Fitment Recs vs Static Recs |

**Invalid comparisons:**
- ❌ Post Purchase vs Browse Recovery (different triggers)
- ❌ Abandon Cart vs Post Purchase (different user intent)
- ❌ Personalized Fitment vs Browse Recovery Personalized (different data sources)

---

## Data Sources

### PostgreSQL (Treatment Metadata)
```sql
SELECT * FROM EXTERNAL_QUERY(
  "projects/auxia-gcp/locations/asia-northeast1/connections/jp-psql_hbProdDb",
  "SELECT treatment_id, name, boost_factor, is_paused
   FROM treatment
   WHERE company_id = 1950"
)
```

### BigQuery (Treatment Performance)
- `auxia-gcp.company_1950.treatment_history_sent` - Send records
- `auxia-gcp.company_1950.treatment_interaction` - Opens/clicks

### Treatment ID Reference Files
- `configs/personalized_treatments.csv` - 10 Personalized Fitment IDs
- `configs/static_treatments.csv` - 22 Static IDs

---

## Changelog

| Date | Change |
|------|--------|
| 2026-01-19 | Initial documentation of treatment structure |
