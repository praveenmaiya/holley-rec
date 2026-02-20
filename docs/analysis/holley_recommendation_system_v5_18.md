# Product Recommendation System

Holley Performance Products

**Praveen Maiya**
**Implementation Guide**
Last Modified: February 19, 2026

| Metric | Value |
|--------|-------|
| Total Customers | 452,150 |
| Recommendations per Customer | 3-4 products |
| Average Price | $602.21 |
| Fitment Accuracy | 100% |
| Image Coverage | 100% |

## Overview

This recommendation system generates personalized product suggestions for Holley Performance Products customers. Each customer receives three to four part recommendations that are guaranteed to fit their registered vehicle, priced appropriately, and selected based on product popularity within their vehicle segment.

The system currently covers 452,150 customers. Every recommendation is a vehicle-specific fitment product — no universal or generic parts are included. This was a deliberate design decision based on client feedback to ensure every recommendation is directly relevant to the customer's registered vehicle.

### What Changed in v5.18

The previous version (v5.17) used a combination of customer browsing intent (views, cart additions) and product popularity to score recommendations. An A/B revenue test on v5.17 showed positive uplift and conversion. However, two issues were identified:

1. **Universal parts appearing for specialty vehicles** — non-fitment products were being recommended for vehicles like golf carts where they didn't make sense
2. **Scoring complexity** — the intent-based scoring (views, carts, orders) added complexity without proportional benefit since 98% of customers had no recent browsing activity

v5.18 addresses both issues:
- **All recommendations are now fitment-only** — every product is confirmed compatible with the customer's specific year, make, and model
- **Scoring simplified to popularity-only** — products are ranked by proven purchase history using a 3-tier fallback system, removing the intent scoring layer
- **Extended historical data** — order history now goes back to January 2024 (14 additional months), providing a richer popularity signal
- **Stricter diversity enforcement** — maximum 2 products per part category (was uncapped)

## How the System Works

### Step 1: Vehicle Compatibility

The foundation of every recommendation is vehicle fitment. The system only considers products that are confirmed compatible with the customer's registered vehicle. This eliminates the frustration of discovering incompatible parts after purchase.

> Example: A customer who owns a 2018 Ford F-150 will only see products explicitly designed for that year, make, and model.

Unlike the previous version, v5.18 does not include any universal or cross-vehicle products. Every recommendation slot is filled with a fitment-verified product.

### Step 2: Popularity Scoring with 3-Tier Fallback

Products are scored by purchase popularity using a three-tier system. The system tries the most specific data first and falls back to broader data if needed:

| Tier | Scope | Weight | Minimum Orders | When Used |
|------|-------|--------|----------------|-----------|
| 1. Segment | Products ordered by customers with the same vehicle generation (e.g., 1967-1969 Camaro) | 10.0 | 5 orders | Best signal — customers with similar vehicles bought this |
| 2. Make | Products ordered by customers with the same vehicle make (e.g., all Chevrolet) | 8.0 | 20 orders | Good signal — same brand owners bought this |
| 3. Global | Products ordered across all customers | 2.0 | None | Baseline — generally popular product |

The fallback is applied **per product**: if a specific product has no segment-level data, it checks make-level, then global. This ensures every recommended product has a non-zero score (score range: 1.39 - 47.45).

**Why this approach works:** Automotive parts purchasing patterns are remarkably consistent within vehicle segments. Customers who own a 1969 Camaro tend to buy the same types of performance upgrades. Segment-level popularity captures this natural clustering.

**Distribution across tiers (current run):**

| Tier | % of Recommendations |
|------|---------------------|
| Segment | 48.9% |
| Make | 45.6% |
| Global | 5.4% |

Nearly 95% of recommendations are backed by segment or make-level purchase data, meaning most customers see products with strong, relevant popularity signals.

### Step 3: Quality Filters

Before finalizing recommendations, the system applies several quality controls:

| Filter | Rule | Reason |
|--------|------|--------|
| No Repeats | Exclude products purchased in last 365 days | Customer already owns it |
| Variant Matching | Color variants count as the same product (e.g., RA003R and RA003B) | Prevents recommending the same part in a different color |
| Price Floor | Products must be $50 or higher | Focus on meaningful performance parts |
| Diversity | Maximum 2 products per part category | Ensure variety in recommendations |
| Minimum Quality | Customer must have at least 3 eligible fitment products | Skip if insufficient options |
| Image Required | Every product needs a product image | Email template requires visuals |
| Commodity Exclusion | Exclude commodity part types (oil filters, spark plugs, etc.) | Focus on performance/upgrade parts |

The diversity filter is particularly important. Without it, a customer might receive four air filters when a mix of filters, headers, and carburetors would be more engaging.

The variant matching is a v5.18 improvement. The system normalizes SKU color suffixes (B, R, G, P) so that if a customer bought product RA003B (blue), they won't be recommended RA003R (red) — since it's essentially the same part in a different color.

## Real-World Examples

### Example 1: Segment-Level Recommendations

John owns a 1969 Chevrolet Camaro. The system finds products popular among 1967-1969 Camaro owners:

| Rank | Product | Score | Popularity Tier |
|------|---------|-------|-----------------|
| 1 | 71223029HKR (Headers) | 38.50 | Segment |
| 2 | LFRB155 (Air Filter) | 32.15 | Segment |
| 3 | 0-80457SA (Carburetor) | 28.90 | Segment |
| 4 | 550-511-3XX (Full Kit) | 24.35 | Segment |

All four products are proven bestsellers among owners of the same vehicle generation. The 1969 Camaro is the most popular vehicle in the system (4,094 customers), so segment-level data is robust.

### Example 2: Make-Level Fallback

Lisa owns a 2019 Jeep Wrangler. Her specific vehicle generation has limited order history (fewer than 5 orders for most products), so the system falls back to make-level popularity:

| Rank | Product | Score | Popularity Tier |
|------|---------|-------|-----------------|
| 1 | 7805 (Throttle Body) | 22.40 | Make (Jeep) |
| 2 | 300-260 (Intake Manifold) | 19.85 | Make (Jeep) |
| 3 | 26-610WK (Air Filter) | 15.30 | Segment |
| 4 | FRBR-67212 (Rebuild Kit) | 8.90 | Global |

Notice the mix: most products come from Jeep-wide popularity, one has enough segment data, and one falls through to global. The per-product fallback ensures every slot gets the best available signal.

### Example 3: Diversity in Action

Sarah owns a 1970 Chevrolet Chevelle. Before applying the diversity filter, her top four products might all be air filters:

| Rank | Product | Category | Score |
|------|---------|----------|-------|
| 1 | LFRB155 | Air Filter | 32.15 |
| 2 | LFRB146 | Air Filter | 30.95 |
| 3 | LFRB135 | Air Filter | 29.85 |
| 4 | 71223029HKR | Headers | 28.43 |

The diversity filter (maximum 2 per category) transforms this into:

| Rank | Product | Category | Score |
|------|---------|----------|-------|
| 1 | LFRB155 | Air Filter | 32.15 |
| 2 | LFRB146 | Air Filter | 30.95 |
| 3 | 71223029HKR | Headers | 28.43 |
| 4 | FRBR-67212 | Rebuild Kit | 22.89 |

The result is better product discovery and more engaging recommendations.

## Common Questions

### Why switch from intent + popularity to popularity-only?

The v5.17 A/B test revealed that 98% of customers in a re-engagement email campaign had no recent browsing activity. The intent scoring layer (views, carts) only affected 2% of customers while adding significant complexity. By simplifying to popularity-only, we:

- Eliminated a class of edge cases (stale intent data, incorrect event attribution)
- Made the scoring fully transparent and auditable
- Focused engineering effort on what matters most: accurate fitment and strong popularity signals

The A/B test on v5.17 already showed positive revenue uplift, confirming that fitment + popularity is the core value driver.

### Why remove universal products?

The client flagged a case where universal (non-fitment) parts were being recommended for a golf cart. Universal products aren't guaranteed to fit any specific vehicle — they're "one-size-fits-most" parts. By restricting to fitment-verified products only, every recommendation is guaranteed compatible. This is a stronger value proposition for email campaigns where trust matters.

### Why use a 3-tier fallback instead of a single popularity score?

A single global popularity score would recommend the same bestsellers to everyone regardless of vehicle. The 3-tier approach (segment, make, global) respects the natural clustering in automotive purchases:

- **Segment-level** captures that 1967-1969 Camaro owners buy specific performance upgrades
- **Make-level** captures brand-wide patterns (Chevrolet owners vs Ford owners)
- **Global** is the safety net ensuring every product gets a score

The per-product fallback (new in v5.18) ensures no product gets stuck with a zero score. If a product has no segment data, it automatically checks make, then global.

### Why exclude previously purchased products?

Automotive parts typically last for years. If a customer bought a carburetor eight months ago, they don't need another one. The 365-day exclusion window prevents recommending products the customer already owns. In v5.18, this exclusion also handles color variants — buying RA003B (blue) excludes RA003R (red) since they're the same part.

### Why 3-4 recommendations instead of always 4?

v5.18 allows customers with only 3 qualifying fitment products to still receive recommendations. Previously, these customers were excluded entirely (the minimum was 4). This expands coverage: 98.5% of customers receive 4 recommendations, and 1.5% receive 3. It's better to send 3 excellent, relevant recommendations than to skip the customer entirely.

### Why the $50 minimum price?

The price floor was raised from $20 to $50 to focus on meaningful performance parts. Products under $50 tend to be accessories, hardware, and low-margin items that don't drive significant revenue or customer engagement in email campaigns. The $50 threshold ensures every recommendation is a substantive product worth clicking through for.

### Why limit to 2 products per category?

Without this limit, a customer might receive recommendations for four different carburetors, which is monotonous. With the limit, they might get a carburetor, headers, an air filter, and a fuel pump. This variety improves engagement and helps customers discover products across different categories. In v5.18, this cap is strictly enforced (previously it was uncapped at 999).

## System Performance Metrics

| Metric | Value | Notes |
|--------|-------|-------|
| Total Customers | 452,150 | Fitment-verified customers with valid vehicles |
| Unique Vehicles | 9,746 | Distinct year/make/model combinations |
| Customers with 4 Recs | 445,468 (98.5%) | Full recommendation set |
| Customers with 3 Recs | 6,682 (1.5%) | Partial set (still high quality) |
| Hot Customers | 9,573 (2.1%) | Have recent order activity |
| Cold Customers | 442,577 (97.9%) | No recent orders — rely on popularity |
| Average Price | $602.21 | Across all recommendations |
| Price Range | $50.57 - $2,609.95 | Performance parts only |
| Score Range | 1.39 - 47.45 | 0 zero scores (per-product fallback) |
| Top Vehicle | 1969 Chevrolet Camaro | 4,094 customers |

## Validation & Quality Checks

The system runs a comprehensive automated validation suite with 14 checks ranked by severity:

| Check | Severity | Result |
|-------|----------|--------|
| Fitment mismatch (YMM x SKU) | CRITICAL | PASS (0 violations) |
| Purchase exclusion (variant-normalized) | CRITICAL | PASS (0 violations) |
| Price floor violations | CRITICAL | PASS (0 violations) |
| Universal products in output | CRITICAL | PASS (0 found) |
| Duplicate users | HIGH | PASS (0 duplicates) |
| Diversity cap violations | HIGH | PASS (0 violations) |
| Score floor (zero scores) | MEDIUM | PASS (0 zero scores) |
| Final user coverage | MEDIUM | PASS (452,150 users) |

Every recommended SKU is verified against the authoritative fitment database to confirm it fits the customer's specific year, make, and model. This is an end-to-end check, not just a pass-through of the fitment filter.

## Known Limitations

The current system has several limitations planned for future versions:

- **Single Vehicle Support**: Only uses the primary registered vehicle. Customers with multiple vehicles (e.g., Camaro and Mustang) only get recommendations for one.
- **No Time Decay**: All orders in the historical window contribute equally to popularity. Future versions could weight recent purchases more heavily.
- **Popularity-Only Scoring**: The system doesn't incorporate individual browsing behavior. For the 2% of customers with recent activity, personalized intent signals could improve recommendations. A Graph Neural Network (GNN) approach is under development to address this.
- **Same-Vehicle Similarity**: Customers with the same vehicle generation receive similar recommendations, differentiated only by purchase exclusion. Collaborative filtering could improve individual differentiation.

These limitations don't prevent the system from working effectively. The v5.17 A/B test demonstrated positive revenue uplift with this approach, validating the fitment + popularity strategy.

## Summary

This recommendation system follows a straightforward, proven approach:

- **Start with vehicle compatibility** — every product must fit the customer's specific vehicle
- **Score by purchase popularity** — 3-tier fallback (segment, make, global) ensures relevant, data-backed rankings
- **Apply strict quality filters** — diversity, price floor, purchase exclusion, variant matching
- **Validate comprehensively** — 14 automated checks with severity rankings before any deployment

The system is data-driven and defensible. The A/B test on the previous version showed positive revenue uplift and conversion, confirming that fitment-guaranteed products scored by real purchase data translates into customer value and business results.

--- End of Implementation Guide ---
